---
title: device benchmarks
date: 2026-09-22
status: RESEARCH SNAPSHOT (verify before relying; facts drift)
source: Task 14 final gate (M0+M1 plan 003), branch ichirp/foundation
---

> Simulator and device smoke-test evidence for commit `e232b62d`, gathered while closing out plan 003 (M0 + M1).
> Update this file — don't create a new one — the next time `scripts/device_smoke.sh` or the simulator smoke runner
> produces a fresh result.

## 2026-09-22 — Simulator smoke, `e232b62d`

Ran via the DEBUG smoke runner (`-ChirpSmoke transcribe-sample`, `App/Sources/Debug/SmokeTestRunner.swift`) in the
iPhone 17 Pro simulator, iOS 26.5. Full status:

| Field | Value |
|---|---|
| status | `completed` |
| wordCount | 15 |
| speakerCount | 2 |
| elapsedMs (transcribe) | 1852 |
| peakMemoryMB | 592 |

This is the same commit installed on the owner's phone; see below for why it isn't yet confirmed on-device.

## Device — pending

Two on-device smoke attempts failed before any transcription ran, both during the Parakeet model's first download on
the phone (not a transcription-path failure). The app was backgrounded/locked immediately after launch both times.

| Field | Attempt 1 | Attempt 2 |
|---|---|---|
| status | `failed` | `failed` |
| error | "The request timed out." | "The request timed out." |
| elapsedMs | 0 | 0 |
| peakMemoryMB | 76 | 60 |
| build stamp | `0.1.0 (202609222032) · e232b62dea3e` | `0.1.0 (202609222034) · e232b62dea3e` |

**Hypothesis:** the FluidAudio model download (`AsrModels.download(to:version:progressHandler:)`, called from
`ChirpEngineFluidAudio`) uses a foreground `URLSession` task. iOS suspends foreground network tasks shortly after the
app backgrounds or the screen locks, so a large first-time model fetch that hasn't finished by then gets cut off with
a client-side timeout and zero bytes received — it never got far enough to report partial progress. This is
plausible but **not yet confirmed**: no packet capture or `URLSession` delegate log was taken during either attempt.

**What's left:** the owner opens Parakeet → Settings → Speech model → Download with the app kept in the foreground
(so the download completes before any lock/background transition), then runs `scripts/device_smoke.sh`. Do not
re-attempt the download unattended until that path is proven, or until the background-download fix below lands.

**Follow-up tracked:** move the model download to a background `URLSession` so it survives backgrounding — added to
the M1.5 plan scope: [`docs/plans/2026-09-22-010-m1.5-share-and-background.md`](../plans/2026-09-22-010-m1.5-share-and-background.md).
