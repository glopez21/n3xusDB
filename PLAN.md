# n3xusDB — Centralized Database for All SOC Projects

## Vision

A single TimescaleDB (PG16) instance serving as the unified data backbone for the entire SOC ecosystem. All daemons (LogSentry, EventFlow, AlertFlow, NetWatch, etc.) write events here. The Omn1L1nk connector reads from it and delivers to Augur, ThreatPulse, or any other hub.

Removes the need for each project to bundle its own PostgreSQL container, eliminates redundant databases (~1.2GB RAM freed), and centralizes backups, monitoring, and security.

## Why TimescaleDB?

- **Time-series native** — hypertables for events, streams, alerts, and metrics
- **Full PostgreSQL** — works as a regular PG for users, configs, entities
- **One engine for all workloads** — no dual-database complexity
- **Built-in retention** — `add_retention_policy()` for automatic data lifecycle management
- **Native columnar compression** — saves ~90% on old time-series data

## Architecture

```
┌─ Remote Machines (AWS / Linode / LAN) ────────────────────────┐
│                                                                │
│  LogSentry (daemon)                                            │
│    ├── primary: HTTPS → Omn1L1nk:9000/api/v1/ingest           │
│    └── fallback: local SQLite outbox (on network failure)      │
│                                                                │
│  EventFlow (daemon) — same pattern                             │
│  AlertFlow (daemon) — same pattern                             │
│  NetWatch  (daemon) — same pattern                             │
│                                                                │
└────────────────────────────────────────────────────────────────┘

┌─ Local Machine (n3xusDB host) ───────────────────────────────┐
│                                                                │
│  n3xusDB — TimescaleDB (PG16) :5432                            │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Databases:                                              │  │
│  │  ┌──────────┐ ┌──────────┐ ┌────────────┐               │  │
│  │  │ augur_db │ │ twn_db   │ │ eventflow  │  (project DBs)│  │
│  │  │ logsentry│ │ alertflow│ │ _db        │               │  │
│  │  │ _db      │ │ _db      │ │ netwatch_db│               │  │
│  │  └──────────┘ └──────────┘ └────────────┘               │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │ shared_db                                         │   │  │
│  │  │  ┌───────────────────────────────────────────┐    │   │  │
│  │  │  │ event_outbox (unified delivery queue)      │    │   │  │
│  │  │  │ id | source | event_type | severity | ...  │    │   │  │
│  │  │  │ payload | pushed | created_at              │    │   │  │
│  │  │  └───────────────────────────────────────────┘    │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  Omn1L1nk — Connector (:9000)                                  │
│    ├── accepts HTTPS from remote daemons (POST /api/v1/ingest) │
│    ├── polls event_outbox for unpushed events                   │
│    ├── enriches (severity, confidence, tags)                   │
│    ├── writes to event_outbox for direct-DB daemons            │
│    └── POSTs to Augur and/or ThreatPulse                       │
│                                                                │
│  Augur hub (:8001) — reads from augur_db, receives from Omn1L1nk│
│  ThreatPulse (:8081) — receives from Omn1L1nk                   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### Key architectural rules

1. **Local daemons** (on the n3xusDB host) write directly to `shared_db.event_outbox` via Unix socket. Fast, simple, no HTTP hop.

2. **Remote daemons** (AWS, Linode, LAN machines) POST to `Omn1L1nk:9000/api/v1/ingest`. Omn1L1nk validates and writes to `event_outbox`.

3. **Omn1L1nk** is the single delivery pipeline — it reads unpushed events from `event_outbox`, enriches them, and routes to Augur/ThreatPulse.

4. **No daemon touches Augur or ThreatPulse directly.** All data flows through n3xusDB → Omn1L1nk → hubs. This decouples data producers from consumers.

## Connection Modes

| Mode | Who uses it | Connection | Security |
|------|-------------|-----------|----------|
| **Local DB write** | Daemons on n3xusDB host | `postgresql://user:pass@localhost:5432/shared_db` via Unix socket | Localhost only |
| **Omn1L1nk HTTP** | Remote daemons | `POST https://omn1l1nk:9000/api/v1/ingest` with API key | HTTPS + API key auth |
| **Omn1L1nk DB poll** | Omn1L1nk itself | `postgresql://omn1l1nk_user:pass@localhost:5432/shared_db` | Localhost only |
| **Hub read** | Augur, ThreatPulse | Read from their own project DBs | Localhost or Docker network |

## Database Layout

One database per project, one user per project, all on the same TimescaleDB instance:

| Database | Owner | Purpose | Time-series? |
|----------|-------|---------|-------------|
| `augur_db` | `augur_user` | Augur's own schema (events, agents, incidents, etc.) | Yes |
| `twn_db` | `twn_user` | ThreatWireNews data | No |
| `eventflow_db` | `eventflow_user` | EventFlow internal state | Yes |
| `logsentry_db` | `logsentry_user` | LogSentry internal config/state | Yes |
| `alertflow_db` | `alertflow_user` | AlertFlow triage data | No |
| `netwatch_db` | `netwatch_user` | NetWatch packet metadata | Yes |
| `shared_db` | `shared_user` | Unified event outbox + cross-project lookups | Yes (event_outbox) |

## The Event Outbox Schema

Defined in `shared_db`. This is the unified event queue that all daemons write to and Omn1L1nk reads from:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE event_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source VARCHAR(64) NOT NULL,              -- 'logsentry', 'eventflow', 'alertflow', 'netwatch'
    source_instance VARCHAR(128) NOT NULL,    -- hostname or instance ID
    event_type VARCHAR(64) NOT NULL,          -- 'auth_failure', 'malware_detected', etc.
    severity VARCHAR(16) NOT NULL,            -- 'low', 'medium', 'high', 'critical'
    title VARCHAR(512) NOT NULL DEFAULT '',
    payload JSONB DEFAULT '{}'::jsonb,        -- event-specific data
    context JSONB DEFAULT '{}'::jsonb,        -- environment, host, IP, MITRE IDs, etc.
    tags TEXT[] DEFAULT '{}',
    raw TEXT,                                 -- original raw log if applicable
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    pushed BOOLEAN NOT NULL DEFAULT FALSE,     -- has Omn1L1nk delivered this?
    pushed_at TIMESTAMPTZ,
    delivery_attempts INT NOT NULL DEFAULT 0,
    error TEXT                                 -- last delivery error message
);

-- Hypertable on created_at for time-series performance
SELECT create_hypertable('event_outbox', 'created_at');

-- Composite index for Omn1L1nk's poll query
CREATE INDEX idx_outbox_pending ON event_outbox (pushed, created_at)
    WHERE pushed = FALSE;

-- Index for per-daemon queries
CREATE INDEX idx_outbox_source ON event_outbox (source, created_at DESC);
```

This schema maps directly to Augur's `AugurEvent` model — the connector's transformation is mostly a field rename.

### Omn1L1nk's poll loop

```sql
-- Fetch next batch of undelivered events
SELECT * FROM event_outbox
WHERE pushed = FALSE
ORDER BY created_at
LIMIT 100
FOR UPDATE SKIP LOCKED;

-- After successful delivery:
UPDATE event_outbox
SET pushed = TRUE, pushed_at = NOW()
WHERE id = ANY(:delivered_ids);

-- After failed delivery:
UPDATE event_outbox
SET delivery_attempts = delivery_attempts + 1, error = :error
WHERE id = :failed_id;
```

`FOR UPDATE SKIP LOCKED` ensures multiple Omn1L1nk instances (if scaled) don't step on each other.

## How Daemons Write Events

### Local daemons (same machine as n3xusDB)

Write directly to `event_outbox` using SQLAlchemy or asyncpg:

```python
INSERT INTO event_outbox (source, source_instance, event_type, severity, title, payload, context, tags)
VALUES ('logsentry', 'host-01', 'ssh_bruteforce', 'high',
        'SSH brute force detected from 10.0.0.5',
        '{"attempts": 50, "target_user": "root"}'::jsonb,
        '{"ip": "10.0.0.5", "mitre_id": "T1110"}'::jsonb,
        ARRAY['ssh', 'auth', 'bruteforce']);
```

The daemon does NOT need to know about Augur, ThreatPulse, or Omn1L1nk. It only needs n3xusDB credentials for `shared_db` (write-only, restricted to `event_outbox` INSERT).

### Remote daemons (AWS, Linode, LAN)

POST to Omn1L1nk's HTTP endpoint. If the request fails (network issue, Omn1L1nk down), fall back to a local SQLite buffer:

```python
def send_event(event: dict):
    try:
        httpx.post("https://omn1l1nk:9000/api/v1/ingest",
                   json=event, headers={"X-API-Key": api_key}, timeout=10)
    except (httpx.ConnectError, httpx.TimeoutError):
        write_to_local_buffer(event)  # SQLite table: outbox(id, event_json, created_at, sent=0)

# On next successful POST, flush buffer:
def flush_buffer():
    unsent = local_db.query("SELECT * FROM outbox WHERE sent = 0")
    for item in unsent:
        httpx.post("https://omn1l1nk:9000/api/v1/ingest", json=item.event_json, ...)
        local_db.query("UPDATE outbox SET sent = 1 WHERE id = ?", item.id)
```

This gives full resilience — network blips, reboots, and maintenance windows cause zero data loss.

## Deployment Matrix

| Machine | Runs | Writes events to | Notes |
|---------|------|-----------------|-------|
| **Local (DB host)** | n3xusDB, Omn1L1nk, Augur, ThreatPulse | Direct DB write via Unix socket | Core infrastructure |
| **Local (LAN)** | LogSentry, EventFlow daemons | Omn1L1nk HTTP or direct DB | LAN = low latency, HTTP is fine |
| **AWS EC2** | LogSentry daemon | Omn1L1nk HTTPS + local SQLite fallback | Resilience needed |
| **Linode** | LogSentry, AlertFlow daemons | Omn1L1nk HTTPS + local SQLite fallback | Resilience needed |
| **Future machines** | Any daemon combo | Same pattern | Same as above |

## Security

- **DB port bound to 127.0.0.1:5432 only** — Docker services use internal `n3xus-net`, host services use localhost, remote machines have no route to the DB
- **One PostgreSQL user per project** — each user owns only its own database
- **Omn1L1nk API key auth** — remote daemons authenticate with per-machine or per-daemon API keys
- **No DB credentials on remote machines** — they only have the Omn1L1nk API key, never PostgreSQL credentials
- **Passwords in environment variables** — never in code or docker-compose files
- **HTTPS for remote ingestion** — Omn1L1nk should be behind a reverse proxy with TLS termination

## Omn1L1nk — Unified Delivery Pipeline

Omn1L1nk is the single service that connects the data layer to the hub layer. See `/home/w01f/projects/omn1l1nk/PLAN.md` for the full design.

### Omn1L1nk responsibilities

1. **HTTP ingest** — receive events from remote daemons, validate API key, write to `event_outbox`
2. **Poll loop** — continuously poll `event_outbox` for unpushed events
3. **Enrichment** — apply rules to set severity, confidence score, tags, and priority metadata
4. **Routing** — push enriched events to Augur (`POST /api/v1/events`) and/or ThreatPulse
5. **Delivery tracking** — mark events as pushed, retry on failure with backoff
6. **Health monitoring** — expose `/health` endpoint with queue depth, delivery lag, error rate

### What Omn1L1nk is NOT

- Not a database — it only reads/writes n3xusDB
- Not a hub — it doesn't store its own event schema, correlate, or visualize
- Not a monolith — it's a single-purpose pipeline with zero business logic about security analysis

## Docker Compose Setup

### n3xusDB Service

```yaml
services:
  n3xusdb:
    image: timescale/timescaledb:latest-pg16
    container_name: n3xusdb
    restart: unless-stopped
    ports:
      - "127.0.0.1:5432:5432"
    environment:
      POSTGRES_PASSWORD: ${DB_SUPER_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - n3xus-net

networks:
  n3xus-net:
    name: n3xus-net
    external: false

volumes:
  pgdata:
```

### Init Script

`init/01-create-dbs.sh` — runs once on first boot:

```sql
-- Per-project databases
CREATE USER augur_user WITH PASSWORD '${AUGUR_DB_PASSWORD}';
CREATE DATABASE augur_db OWNER augur_user;
\c augur_db
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE USER twn_user WITH PASSWORD '${TWN_DB_PASSWORD}';
CREATE DATABASE twn_db OWNER twn_user;

CREATE USER eventflow_user WITH PASSWORD '${EVENTFLOW_DB_PASSWORD}';
CREATE DATABASE eventflow_db OWNER eventflow_user;
\c eventflow_db
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Shared database with unified outbox
CREATE USER shared_user WITH PASSWORD '${SHARED_DB_PASSWORD}';
CREATE DATABASE shared_db OWNER shared_user;
\c shared_db
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Event outbox table (see schema above)
CREATE TABLE event_outbox (...);
SELECT create_hypertable('event_outbox', 'created_at');
CREATE INDEX idx_outbox_pending ON event_outbox (pushed, created_at) WHERE pushed = FALSE;

-- Omn1L1nk user (read/write event_outbox, no other DB access)
CREATE USER omn1l1nk_user WITH PASSWORD '${OMN1L1NK_DB_PASSWORD}';
GRANT USAGE ON SCHEMA public TO omn1l1nk_user;
GRANT SELECT, INSERT, UPDATE ON event_outbox TO omn1l1nk_user;

-- Phase 2: additional databases as needed
```

## Data Migration Procedure

### One-time migration per project

```bash
# 1. Dump from old database
pg_dump -h localhost -p 5434 -U augur augur > /tmp/augur_dump.sql

# 2. Load into n3xusDB
psql -h localhost -p 5432 -U augur_user -d augur_db < /tmp/augur_dump.sql

# 3. Update connection string in .env
# DATABASE_URL=postgresql+asyncpg://augur_user:pass@localhost:5432/augur_db

# 4. Restart the app
systemctl restart augur-backend

# 5. Verify data integrity
# SELECT count(*) FROM events;

# 6. Stop and remove old DB container
docker stop augur-db-1 && docker rm augur-db-1
```

### Migration order

| Order | Project | From | Effort | Risk |
|-------|---------|------|--------|------|
| 1 | **EventFlow** | :5432/eventflow | Low | Low |
| 2 | **ThreatWireNews** | :25432/threatwirenews | Low | Low |
| 3 | **Augur** | :5434/augur | Low | Medium |
| 4 | **shared_db + event_outbox** | New | Low (new) | None |
| 5 | **Omn1L1nk** | New | New project | None |
| 6 | **LogSentry** (standalone) | :5432/logsentry | Low | Low |
| 7 | **AlertFlow** | SQLite → PG | Medium | Medium |
| 8 | **NetWatch** | None → new | Low | None |

## Operations

### Backups
```bash
# Full backup
docker exec n3xusdb pg_dumpall -U postgres > /backups/n3xusdb-$(date +%F).sql

# Per-database
docker exec n3xusdb pg_dump -U augur_user augur_db > /backups/augur_db-$(date +%F).sql
```

### Monitoring
- `pg_stat_activity` — see all connected projects
- `pg_stat_statements` — query performance per project
- `timescaledb_information.hypertables` — hypertable health
- Omn1L1nk `/health` — queue depth, delivery lag, error rate

### Memory Planning
For a machine with 16GB RAM: `shared_buffers` = ~4GB, `effective_cache_size` = ~12GB.

### Cleaning Up Old Containers
After migration, remove old DB containers:
- `augur-db-1` (TimescaleDB :5434) — ~1GB RAM — Remove
- `threatwirenews-postgres` (PG15 :25432) — ~200MB — Remove
- `eventflow-postgres-1` (PG16 :5432) — ~200MB — Remove

Total savings: ~1.4GB RAM.

## Exclusions

The following stay on their own databases:

- **Threat-Pulse** — massive standalone platform (20+ microservices, own TimescaleDB + Neo4j + Redis). Too risky to consolidate.
- **Other independent projects** (deskpilot, h3lix, aegisSec, etc.) — not part of the SOC ecosystem.

## Implementation Priority

```
Phase 0: n3xusDB container + init script       (Week 1)
Phase 1: shared_db + event_outbox schema       (Week 1)
Phase 2: Omn1L1nk — core poll + push loop      (Week 2)
Phase 3: Omn1L1nk — HTTP ingest + API key auth  (Week 2-3)
Phase 4: Migrate Phase 1 projects to n3xusDB   (Week 3)
Phase 5: Add enrichment rules to Omn1L1nk      (Week 4)
Phase 6: Remote daemon deployment with failover (Week 4-5)
```

## Future Considerations

- **Read replicas** — for analytics queries without impacting write performance
- **pgBouncer** — connection pooling if many daemons connect simultaneously
- **WAL-G** — continuous archiving to S3-compatible storage (MinIO on OpsForge)
- **Omn1L1nk HA** — multiple connector instances with `FOR UPDATE SKIP LOCKED`
- **TLS for DB connections** — only needed if n3xusDB ever moves to a different machine
