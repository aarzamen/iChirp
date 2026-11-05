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
  from this tree, start the new iChirp file with this exact header, followed by
  a one-line summary of what changed in the port:

  ```swift
  // Ported from MacParakeet (GPL-3.0): <path relative to upstream/macparakeet> @ bbae9e0e
  ```

  For example:
  `// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/STTWordTimingBuilder.swift @ bbae9e0e`.
  Code that re-implements upstream behavior without copying lines says so:
  `// Semantics from MacParakeet (GPL-3.0): <path> @ bbae9e0e — … Fresh implementation, not a line port.`
  After a sync to a newer ref, the header of a re-ported file carries the new SHA.
  `grep -rl "Ported from MacParakeet" ChirpKit App` lists every ported file.

## In the tree, not a submodule (decided 2026-11-05)

This folder is about 118 MB (2,125 files), most of the repository's weight, and it carries MacParakeet's marketing
GIFs, screenshots and benchmark dumps along with the sources; none of it is built, linked or shipped. It stays a plain
in-tree copy rather than a git submodule at the pinned SHA because:

- `scripts/sync_upstream.sh` records each sync as one commit, so `git diff <old-sync>..<new-sync> -- upstream/macparakeet/`
  is an ordinary diff in this repository. With a submodule the same question becomes a diff inside another repository
  and a pointer change here.
- The byte-for-byte contract is verifiable with `git write-tree --prefix=upstream/macparakeet/` against upstream's
  tree id; a submodule only points at a commit.
- Every provenance header (`// Ported from MacParakeet (GPL-3.0): <path> @ <sha>`) names a path that exists in this
  tree, and a plain `git clone` needs no `--recurse-submodules` for the reference to be there.

The cost is clone size. A clone that will never port can skip the folder's contents:

```bash
git clone --filter=blob:none https://github.com/aarzamen/iChirp    # file contents fetched on first read
git -C iChirp sparse-checkout set --no-cone '/*' '!/upstream'      # or leave the folder out of the working tree
```

Revisit the decision if the folder grows past what a phone-tethered clone tolerates, or if GitHub's repository size
guidance becomes a problem; a submodule would then also need `scripts/sync_upstream.sh` and this file rewritten.

## How to sync

```bash
scripts/sync_upstream.sh <ref>
```

Updates `upstream/macparakeet/` to match a newer upstream ref, preserving the
read-only, verbatim-copy contract described above. The sync is its own commit,
so what upstream changed between two syncs is:

```bash
git log --oneline -- upstream/macparakeet | head -5      # find the two sync commits
git diff <old-sync>..<new-sync> -- upstream/macparakeet/Sources/MacParakeetCore/STT/
```

Port the deltas that matter into iChirp's files, then update their provenance
SHA. See `AGENTS.md`, section 6.

## Where to look

- The pipeline map: `docs/research/2026-09-22-macparakeet-pipeline-map.md`.
- Core subsystems worth reading before porting:
  - `Sources/MacParakeetCore/STT`
  - `Sources/MacParakeetCore/Audio`
  - `Sources/MacParakeetCore/TextProcessing`
  - `Sources/MacParakeetCore/Services/Diarization`
  - `Sources/MacParakeetCore/Database`
