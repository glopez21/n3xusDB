# n3xusDB

A from-scratch central time-series database for the SOC ecosystem, built in Rust with a WAL, segment store, and compaction.

## Intent

A single TimescaleDB-style backbone that unifies event storage across the whole SOC stack — LogSentry, EventFlow, AlertFlow, NetWatch, and friends write events here, and the Omn1L1nk connector fans them out to Augur, ThreatPulse, or any other hub. It removes the need for each project to bundle its own database container, eliminates redundant instances, and centralizes backups, monitoring, and security.

## Design

- **WAL-first writes** — durable append log before segment flush
- **Segment store** — time-bucketed segments with compaction
- **Full PostgreSQL surface** — usable as a regular PG for users, configs, and entities
- **Built-in retention** — `add_retention_policy()`-style lifecycle management
- **Native columnar compression** — reclaims space on old time-series data

## Tech stack

Rust · WAL · Segment Store · PostgreSQL (TimescaleDB) · Docker Compose