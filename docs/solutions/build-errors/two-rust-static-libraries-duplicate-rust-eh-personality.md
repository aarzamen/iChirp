---
title: Pre-link a Rust static library with `ld -r` and an exported-symbols list so it can sit next to FluidAudio's
date: 2026-09-22
category: build-errors
module: scripts
problem_type: build_error
component: needle-c static library, FluidAudio libtext_processing_rs.a, ld64
severity: medium
applies_when:
  - "duplicate symbol '_rust_eh_personality' in: .../libneedle_c.a(std-….rcgu.o) .../libtext_processing_rs.a(std-….rcgu.o)"
  - linking a second Rust `staticlib` (Needle's needle-c, or any future Rust engine) into ChirpKit tests or the app
resolution_type: code_fix
tags: [rust, staticlib, xcframework, needle, fluidaudio, duplicate-symbol, ld-r]
---

## Context
Plan 015 Step 1: `scripts/build_needle.sh` builds needle-rs's `needle-c` crate as a static library and packages
`vendor/NeedleC.xcframework`. `swift build` passed; `swift test --filter ChirpEngineNeedleTests` failed at link time.

## Problem
```
duplicate symbol '_rust_eh_personality' in:
    .build/arm64-apple-macosx/debug/libneedle_c.a[14](std-….std.….rcgu.o)
    .build/arm64-apple-macosx/debug/libtext_processing_rs.a[arm64][65](std-….std.….rcgu.o)
```
Every Rust `staticlib` carries its own copy of Rust's standard library. FluidAudio already links one
(`libtext_processing_rs.a`, the NeMo text-normalization trait), so a second plain Rust archive collides.

## Solution
Pre-link each slice into one relocatable object that exports only the C API, then archive that single object
(`scripts/build_needle.sh`):

```bash
echo '_needle_*' > vendor/NeedleC-exports.txt
(cd work/objects && ar x /path/to/libneedle_c.a)
xcrun ld -r -arch arm64 -platform_version ios 17.0 17.0 \
  -exported_symbols_list vendor/NeedleC-exports.txt work/objects/*.o -o work/needle_c.o
xcrun libtool -static -o work/libneedle_c.a work/needle_c.o
```
(`ios-simulator` and `macos` for the other slices.) Extract the members first: `ld -r -all_load archive.a` left most
of the crate's objects out.

## Why this works
`-exported_symbols_list` makes every other global hidden, and `ld -r` turns hidden symbols into local (static) ones in
its output unless `-keep_private_externs` is passed. Only `_needle_*` stays global, so Needle's copy of Rust's std can
no longer clash with anyone else's. A dynamic framework would also work but adds embedding and signing steps.

## Prevention
The script fails if the pre-linked object exports anything but `_needle_*`
(`nm -g … | grep -v " U " | grep -qv " _needle_"`), and `NeedleCSmokeTests` links the library into the same test
bundle as FluidAudio on every `swift test`.
