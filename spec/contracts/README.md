# Boundary Contracts

> Status: ACTIVE — canonical home for tested boundary contracts (format adopted from upstream MacParakeet).

Boundary contracts describe surfaces that other code, exported files, later milestones or future agents depend on.
They sit between ADRs and tests: ADRs explain why a design exists; these files define the stable shape that must
not drift by accident.

## Format

Each contract document includes:

- **Purpose:** what boundary is being protected.
- **Producers:** code paths that create or change the boundary.
- **Consumers:** code paths, tools or workflows that read it.
- **Stable fields:** names, file names, states or semantics that tests must protect.
- **Non-stable fields:** timestamps, generated values, ordering, copy or other details that may change freely.
- **Versioning and compatibility:** how additive and breaking changes are handled.
- **Tests that enforce this:** exact test classes or test names.
- **When this changes:** the docs, tests and migrations to update in the same commit.

## Rules

- A commit that changes a listed boundary updates the matching contract doc and its focused tests in the same
  change.
- Tests pin semantic stability, not incidental formatting. Do not freeze generated timestamps, absolute user paths
  or pretty-print details that do not matter to consumers.
- Additive fields are allowed when existing consumers keep working. Removing or renaming a stable field requires an
  explicit version bump (a new `-v2` document) and a migration or compatibility story.
- A test named here that does not exist yet is part of the contract's plan: the task that implements the producer
  must add it.

## Current contracts

- [Speech Engine Plug-in v1](speech-engine-plugin-v1.md): the `ChirpCore` protocols every engine target implements.
- [Transcript JSON v1](transcript-json-v1.md): the `ichirp.transcript/v1` JSON export.
- [Media Storage Layout v1](media-storage-layout-v1.md): the on-disk layout under `Application Support/iChirp/`.
- [File Transcription Audio Tracks v1](file-transcription-audio-tracks-v1.md): which audio track of an imported
  file is transcribed, the track picker, and `transcriptions.audioTrackOrdinal` (M1.5).

## Candidate contracts (write them with their milestone)

- Share-extension inbox manifest in the App Group (M1.5).
- `recording.lock` and meeting session folder (M3, port of upstream `meeting-artifacts-v1` and
  `meeting-recovery-retention`).
- Deliverable and prompt-template records (M4).
- App Intents and URL-scheme parameters (`ichirp://…`) once they are public automation surfaces (M2).
