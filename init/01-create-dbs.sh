#!/bin/bash
# n3xusDB initialization — runs once on first container boot

set -e

# --- Augur DB ---
psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
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

    -- Phase 2
    -- CREATE USER logsentry_user WITH PASSWORD '${LOGSENTRY_DB_PASSWORD}';
    -- CREATE DATABASE logsentry_db OWNER logsentry_user;

    -- CREATE USER alertflow_user WITH PASSWORD '${ALERTFLOW_DB_PASSWORD}';
    -- CREATE DATABASE alertflow_db OWNER alertflow_user;

    -- CREATE USER netwatch_user WITH PASSWORD '${NETWATCH_DB_PASSWORD}';
    -- CREATE DATABASE netwatch_db OWNER netwatch_user;

    -- Shared database with unified event outbox
    CREATE USER shared_user WITH PASSWORD '${SHARED_DB_PASSWORD}';
    CREATE DATABASE shared_db OWNER shared_user;
EOSQL

# --- event_outbox schema in shared_db ---
psql -v ON_ERROR_STOP=1 --username postgres -d shared_db <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS timescaledb;
    CREATE EXTENSION IF NOT EXISTS pgcrypto;

    CREATE TABLE event_outbox (
        id UUID NOT NULL DEFAULT gen_random_uuid(),
        source VARCHAR(64) NOT NULL,
        source_instance VARCHAR(128) NOT NULL,
        event_type VARCHAR(64) NOT NULL,
        severity VARCHAR(16) NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        payload JSONB DEFAULT '{}'::jsonb,
        context JSONB DEFAULT '{}'::jsonb,
        tags TEXT[] DEFAULT '{}',
        raw TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        pushed BOOLEAN NOT NULL DEFAULT FALSE,
        pushed_at TIMESTAMPTZ,
        delivery_attempts INT NOT NULL DEFAULT 0,
        error TEXT
    );

    SELECT create_hypertable('event_outbox', 'created_at');

    -- Composite unique constraint (TimescaleDB requires partition column in unique indexes)
    CREATE UNIQUE INDEX idx_event_outbox_pk ON event_outbox (created_at, id);

    CREATE INDEX idx_outbox_pending ON event_outbox (pushed, created_at)
        WHERE pushed = FALSE;

    CREATE INDEX idx_outbox_source ON event_outbox (source, created_at DESC);

    -- Omn1L1nk user (read/write event_outbox only)
    CREATE USER omn1l1nk_user WITH PASSWORD '${OMN1L1NK_DB_PASSWORD}';
    GRANT USAGE ON SCHEMA public TO omn1l1nk_user;
    GRANT SELECT, INSERT, UPDATE ON event_outbox TO omn1l1nk_user;

    -- Schema for daemon API keys
    CREATE TABLE daemon_api_keys (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        api_key_hash VARCHAR(64) NOT NULL,
        label VARCHAR(128) NOT NULL,
        source VARCHAR(64) NOT NULL,
        source_instance VARCHAR(128) NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    GRANT SELECT, INSERT, UPDATE, DELETE ON daemon_api_keys TO omn1l1nk_user;

    -- Schema for enrichment rules
    CREATE TABLE enrich_rules (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name VARCHAR(255) NOT NULL UNIQUE,
        match JSONB NOT NULL,
        enrich JSONB NOT NULL,
        priority INT NOT NULL DEFAULT 100,
        enabled BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    GRANT SELECT, INSERT, UPDATE, DELETE ON enrich_rules TO omn1l1nk_user;

    -- Permissions for per-project users
    GRANT CONNECT ON DATABASE shared_db TO shared_user;
    GRANT USAGE ON SCHEMA public TO shared_user;
    GRANT INSERT ON event_outbox TO shared_user;
EOSQL
