# ADR-007: GRDB Persistence with Inline Migrations

> Status: Accepted
> Date: 2026-09-22
> Related: [spec/01-data-model.md](../01-data-model.md), [spec/contracts/media-storage-layout-v1.md](../contracts/media-storage-layout-v1.md)

## Context

The Library needs durable, queryable, observable storage for transcripts with large JSON payloads (word timestamps,
speakers, segments), crash recovery (rows left in `processing`), and metadata-preserving saves (a rename during a job
must survive). MacParakeet solved this with GRDB (a Swift SQLite toolkit): one `transcriptions` table with JSON
columns, migrations registered inline, `ValueObservation` for live UI, and an in-memory database for tests. Its
repository code ports almost unchanged.

## Decision

- SQLite through **GRDB 7** (`from: "7.0.0"`), in `ChirpStore` only.
- One database file, `Application Support/iChirp/ichirp.sqlite`, opened as a `DatabasePool` (WAL, foreign keys on,
  5 s busy timeout); tests use `DatabaseManager.inMemory()`.
- Migrations are registered inline in `DatabaseManager`, named `v<N>-<slug>`, and **never edited after they have
  run on any device**.
- Field names match upstream where they overlap; arrays and nested structs are JSON `TEXT` columns.
- One store per table, behind a `ChirpCore` protocol (`TranscriptionStoring` for M1).
- Media paths are stored relative to the app root.
- UUIDs are never compared as raw SQL strings (upstream trap); use record APIs.

## Alternatives considered

- **SwiftData / Core Data.** Rejected: no port path from upstream, harder to test on the Mac host, migration
  behavior less explicit.
- **Plain files (one JSON per transcript).** Rejected: no efficient search, ordering or observation; crash
  consistency is on us.
- **SQLite without GRDB.** Rejected: re-implements what GRDB gives (observation, Codable records, migrations).

## Consequences

- Store code and tests port from upstream with small changes.
- Schema changes are always additive migrations; a bad migration is fixed by a new one.
- The schema is documented in [spec/01](../01-data-model.md) and changes in the same commit as the migration.
