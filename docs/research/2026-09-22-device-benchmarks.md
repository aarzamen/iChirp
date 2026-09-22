---
title: device benchmarks
date: 2026-09-22
status: RESEARCH SNAPSHOT (verify before relying; facts drift)
source: Task 14 final gate (M0+M1 plan 003), branch ichirp/foundation
---

> Simulator and device smoke-test evidence gathered while closing out plan 003 (M0 + M1).
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

The device runs below used later commits of the same branch; the transcription path is unchanged since `e232b62d`.
Their build stamps show `b2dd8a67` / `8f6c874d`: those commits were later reworded locally (assistant trailers
removed, same trees) and are now `617c3280` / `52cd3c09`.

## 2026-09-22 — Device smoke, iPhone 15 Pro, `617c3280` — PASS

`DEVICE_ID=DF20767D-0672-56DB-9928-AD2191C2CCA5 scripts/device_smoke.sh` (iPhone 15 Pro "Default15", A17 Pro, 8 GB),
same DEBUG smoke runner and bundled synthetic two-voice sample as the simulator run.

| Field | Value |
|---|---|
| status | `completed` |
| text | "The quick brown fox jumps over the lazy dog. Parapete runs entirely on this iPhone." |
| wordCount | 15 |
| speakerCount | 2 |
| modelLoadMs | 13042 |
| elapsedMs (transcribe) | 3989 |
| peakMemoryMB | 2323 |
| build stamp | `0.1.0 (202609222052) · b2dd8a67451e · ichirp/foundation` |

Notes: "Parapete" for "Parakeet" is a recognition miss on the synthetic TTS voice, not a pipeline fault (the smoke
assertion checks the word count and speaker count). Peak memory on device (2.3 GB) is ~4× the simulator figure; watch
it when M2 meeting capture keeps the recorder and a Parakeet pool resident together.

## 2026-09-22 — Device smoke, iPhone 17 Pro, `52cd3c09` — PASS

`scripts/device_smoke.sh` on the owner's iPhone 17 Pro (A19 Pro, 12 GB, iOS 26.2) on Wi-Fi, models already on the
phone (downloaded earlier in the session once it had a working connection), so this is a warm load, not a first run.

| Field | Value |
|---|---|
| status | `completed` |
| text | "The quick brown fox jumps over the lazy dog. Parapete runs entirely on this iPhone." |
| wordCount | 15 |
| speakerCount | 2 |
| modelLoadMs | 1436 (cached, compiled models) |
| elapsedMs (transcribe) | 2525 |
| peakMemoryMB | 263 |
| build stamp | `0.1.0 (202609222054) · 8f6c874dc425 · ichirp/foundation` |

Compare the 15 Pro's 13 s / 2.3 GB: most of that first-run cost is FluidAudio compiling the CoreML models after the
download (`ModelHub.loadModels`), not steady-state transcription.

## iPhone 17 Pro — first-download failures explained

Two earlier smoke attempts on the iPhone 17 Pro failed in the model download with "The request timed out." and
elapsedMs 0. The first hypothesis (iOS suspending a foreground `URLSession` after the app backgrounded) was **wrong**.
The DEBUG probe (`-ChirpNetCheck`, `App/Sources/Debug/NetworkDiagnostics.swift`, writes `Documents/net-check.json`)
settled it:

| Run | Path | Result |
|---|---|---|
| 17 Pro, 13:45 | cellular only, satisfied, isExpensive | **every** request timed out after 20 s, including `apple.com` (NSURLErrorDomain −1001) |
| 15 Pro, 13:46, same build | cellular, satisfied | all passed: apple 200 / 158 ms, HF API 200, HF CDN range 206 / 700 ms |
| 17 Pro, 13:54 | Wi-Fi (isExpensive: a hotspot) | all passed: raw TCP/TLS ready, apple 200, HF API 200, HF CDN range 206 / 1006 ms; `cellularData = notRestricted` |

So the app's download code and Hugging Face were fine. The 17 Pro's cellular link passed no traffic at that time,
and the per-app Settings toggle was not off. Since commit `68e89428`, connectivity failures (timeout, offline, DNS,
connect) say what to check instead of URLSession's bare text.

The background `URLSession` follow-up in
[`docs/plans/2026-09-22-010-m1.5-share-and-background.md`](../plans/2026-09-22-010-m1.5-share-and-background.md)
still stands on its own merits (a ~0.5 GB first download should survive a screen lock). This failure did not motivate it.

## 2026-09-22 — Final-gate device smoke, iPhone 17 Pro, `a6cd8f2d` — PASS

After the review fix round (retry/offline/readable download failures, stricter "ready" check, bounded
normalization): 15 words, 2 speakers, transcribe 408 ms, peak 273 MB, **modelLoadMs 15776**. No model file was
re-downloaded (every Parakeet file on the phone still dates from the 20:55Z download), so the slower load is Core ML
re-specializing the models for the Neural Engine after the app was reinstalled — expect ~15 s for the first load
after an install, ~1.5 s once warm.
