# upstream/macparakeet

## What this is

A verbatim copy of MacParakeet at commit `bbae9e0e` (the last pristine
upstream commit before the Gemini iOS port landed on this fork). Source:
<https://github.com/moona3k/macparakeet>.

The tree under `upstream/macparakeet/` is byte-for-byte identical to
`bbae9e0e^{tree}` — verified with `git write-tree --prefix=upstream/macparakeet/`
against `git rev-parse bbae9e0e^{tree}`.

## Rules

- **Read-only.** Do not edit files under `upstream/macparakeet/` directly.
  Changes belong in the iChirp app at the repo root, or upstream itself.
- **Port, don't import.** When iChirp needs behavior from here, re-implement
  or adapt it into iChirp's own sources rather than depending on this tree at
  build time. This directory exists for reference and diffing, not linking.
- **Provenance headers.** When porting a file or a substantial chunk of logic
  from this tree, note its origin (path + commit) in a comment at the top of
  the new iChirp file, so later readers can trace it back to `bbae9e0e`.

## How to sync

```bash
scripts/sync_upstream.sh <ref>
```

Updates `upstream/macparakeet/` to match a newer upstream ref, preserving the
read-only, verbatim-copy contract described above.

## Where to look

- The pipeline map: `docs/research/2026-09-22-macparakeet-pipeline-map.md`.
- Core subsystems worth reading before porting:
  - `Sources/MacParakeetCore/STT`
  - `Sources/MacParakeetCore/Audio`
  - `Sources/MacParakeetCore/TextProcessing`
  - `Sources/MacParakeetCore/Services/Diarization`
  - `Sources/MacParakeetCore/Database`
