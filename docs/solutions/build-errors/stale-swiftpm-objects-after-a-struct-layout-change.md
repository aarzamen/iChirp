---
title: Delete the Chirp module build folders when SwiftPM links stale objects after a struct gains a stored property
date: 2026-10-01
category: build-errors
module: tooling
problem_type: build_error
component: SwiftPM incremental build (ChirpKit)
severity: medium
applies_when:
  - "Undefined symbols for architecture arm64: \"ChirpCore.TranscriptSegmentRecord.init(id:startMs:...)\" referenced from a test object"
  - "a test crashes with EXC_BAD_ACCESS in _swift_release_dealloc and no useful backtrace, right after a public struct changed"
  - "xctest exits with \"error: Process ... xctest ... \" and no failing assertion"
  - a public struct in ChirpCore, ChirpText or ChirpExport gained a stored property or an init parameter with a default
resolution_type: workflow_improvement
tags: [swiftpm, incremental, stale, undefined-symbols, exc_bad_access, struct-layout, build-folder]
---

## Context

Plan 025 Part A added stored properties to public structs that many modules use: `TranscriptSegmentRecord`,
`TranscriptTextLine`, `TranscriptText`, `TranscriptExporter`. It also added new parameters with defaults to their
initializers. The work ran with `swift build --package-path ChirpKit --jobs 3 --build-tests`, then `swift test
--skip-build`.

## Problem

Some modules that depend on the changed structs were not recompiled, so the test bundle linked object files built
against the old layout. Two different symptoms showed up:

- **At link time** (after an initializer changed):
  `Undefined symbols for architecture arm64: "ChirpCore.TranscriptSegmentRecord.init(id: ..., wordRange: ...)", referenced from: ... TranscriptExporterTests.swift.o`.
- **At run time** (after a stored property was added): a test that only calls ChirpText crashed with
  `EXC_BAD_ACCESS (code=1, address=0x3)` in `_swift_release_dealloc`. The backtrace had one frame, and `swift test`
  printed only `error: Process '.../xctest ...'` with no failing assertion. The other modules were still reading the
  struct with its old memory layout.

## Solution

Delete the build products of the repo's own modules, keep the third-party ones, and rebuild:

```bash
cd /Users/ama/Documents/GitHub/iChirp/ChirpKit/.build/arm64-apple-macosx/debug   # or the worktree's ChirpKit
rm -rf Chirp*.build Modules/Chirp*
cd ../../../..
swift build --package-path ChirpKit --jobs 3 --build-tests
```

The rebuild is about one minute, because FluidAudio, WhisperKit, GRDB and the rest are not rebuilt. Touching only the
named test files works for the link error but not for the crash.

## Why this works

Each `Chirp*.build` folder holds that module's object files and incremental-build records. Removing them, and the
`.swiftmodule` files under `Modules/`, makes the driver recompile every Chirp module against the current layout.
The missing recompile came from the incremental build's dependency tracking, not from the code.

## Prevention

None in code. When you change a public struct's stored properties or an initializer in ChirpCore, ChirpText or
ChirpExport, clean as above before you trust a crash or a link error. Always do it before the full suite. A crash with
no failing assertion right after such a change is this problem until proven otherwise.
