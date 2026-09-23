---
title: ASR engine benchmarks
date: 2026-09-22
status: RESEARCH SNAPSHOT (verify before relying; facts drift)
source: plan 016 (M7) Step 6, branch lane/asr-engines
---

> Speech-engine numbers from iChirp's benchmark harness (`ChirpFeatures/Benchmark`,
> `ASRBenchmarkRunner`). The Mac numbers below were measured in this lane. **The iPhone numbers are still to be
> measured by the controller** (see "iPhone run"). Add later runs to this file; don't create a new one.

## What is measured

- **Reference set:** 5 synthetic recordings made with macOS `say` (`scripts/make_benchmark_audio.sh`,
  `App/Resources/Benchmark`), 31.1 s of audio and 93 reference words in total. The voices are Samantha, Daniel,
  Karen, Moira and Tessa. The texts contain no numbers: one scheduling sentence, one clinical-style dictation (invented,
  no PHI), one science sentence, one set of directions and the fox pangram. Synthetic speech is clean and easy, so
  treat the error rates as a **sanity floor, not accuracy on real speech**.
- **WER:** word error rate = (substitutions + deletions + insertions) ÷ reference words, summed over the set (corpus
  WER). It uses upstream's simple normalizer (`benchmarks/asr/score.py --simple`): lowercase, punctuation to spaces,
  so "follow-up" = "follow up".
- **RTF:** real-time factor = transcription time ÷ audio length, for the transcribe call only (0.02 = 50× faster than
  real time). The total is total time ÷ total audio.
- **Load:** `prepare()` right after the harness unloaded the engine. On a first run this includes the one-time Core ML
  compile or specialization. On the next run the compiled model is cached, which gives the warm figure.
- **Peak memory:** the process's peak `phys_footprint`, sampled every 100 ms while the engine loads and runs, with the
  test process's own baseline included.
- **Order:** each engine runs alone, one recording at a time, through `SpeechJobScheduler`'s background slot (the same
  runner as the app's Benchmark screen).

## 2026-09-22 — Mac run (M4 Max, macOS 26.5.1), `lane/asr-engines`

Command: `CHIRP_BENCHMARK=1 swift test --package-path ChirpKit --filter ASRBenchmarkMacRunTests` (Debug build,
`swift test`). Hardware: `Mac16,5`, 36 GB. Versions: Parakeet v3 on FluidAudio 0.16.1; Apple `SpeechTranscriber`
(en_US); WhisperKit `argmax-oss-swift` 1.1.0, `openai_whisper-base` and
`openai_whisper-large-v3-v20240930_turbo_632MB`, with VAD chunking and two concurrent windows.

**The machine was heavily loaded.** Other agent lanes were building in parallel. The load average was about 60–80
during run 1 and about 21 during run 2. Speed figures are therefore conservative and noisy. Compare engines within one
run, not with other machines.

| Engine | WER (errors / words) | RTF (run 2) | Speed | Load, first run | Load, warm | Peak footprint (run 2) |
|---|---|---|---|---|---|---|
| Parakeet v3 | **1.1 %** (1 / 93) | 0.021 | ~48× | 13.97 s | 0.18 s | 50 MB |
| Apple Speech | **0 %** (0 / 93) | 0.025 | ~40× | 3 ms | 5 ms | 46 MB |
| Whisper Base | **0 %** (0 / 93) | 0.039 | ~26× | 0.64 s | 0.71 s | 217 MB |
| Whisper Large v3 Turbo | **0 %** (0 / 93) | 0.115 | ~9× | **159 s** | 1.83 s | 307 MB |

Run 1's RTFs were within ±15 % of run 2's for every engine: 0.017, 0.026, 0.036 and 0.112. Every item succeeded in
both runs. Raw files: `asr-benchmark-mac-run1|run2.csv` / `.json`, one row per engine × recording, are attached to
the lane report (`.superpowers/sdd/milestones/w2-asr-bench/`, not in git). The command above regenerates them.

Observations:

- **Parakeet's one error:** "Plan rest" was heard as "planned rest" in the clinical dictation (1 substitution). The
  other engines got all 93 words right on this easy synthetic set.
- **Speed:** Parakeet is fastest, with Apple Speech close behind. Whisper Base is about half Parakeet's speed, and
  Large v3 Turbo about a fifth. Every engine is at least 9× faster than real time on the Mac.
- **First-load cost:** WhisperKit's first load of Large v3 Turbo took **2 min 39 s** on this Mac (Core ML
  specialization of a 632 MB model, under load); later loads took 1.8 s. The iPhone will pay a comparable one-time cost
  after each download or app update. The first transcription with a new engine then sits in its transcribing stage
  for that long, and the UI does not warn about it yet (a follow-up). Parakeet's first load after the unload was 14 s (ANE compile), then 0.18 s.
- **Memory on the Mac is not the iPhone budget.** On macOS, Core ML and Neural Engine model memory is largely not
  counted in the process footprint. Parakeet shows 50 MB here, against 275–592 MB on the iPhone 17 Pro in the M1 device
  smoke. Apple Speech runs in a system process, so its model is never counted. Use these figures only to compare
  WhisperKit variants with each other, and take the budget numbers from the iPhone run.

## 2026-09-22 — Simulator run (iPhone 17 Pro simulator, iOS 26.5), `bdb77de6` + lane changes

This run went through the app's own Benchmark screen (`-ChirpBenchmark run`, DEBUG). The Parakeet v3 and Whisper Base
models were copied into the Simulator's container from the Mac caches. The Simulator has no Neural Engine, so
inference runs on the Mac's CPU and GPU. This run proves the screen and the store work end to end, **not device
speed**. Apple Speech is listed as unavailable here, as expected.

| Engine | WER | RTF | Load | Peak footprint |
|---|---|---|---|---|
| Parakeet v3 | 1.1 % (the same "planned rest") | 0.21 (~5×) | 2.6 s | 98 MB |
| Whisper Base | 0 % | 0.13 (~8×) | 1.5 s | 72 MB |

## iPhone run (controller: to do)

Headless (fix/asr-review): `scripts/device_benchmark.sh` builds and installs the Debug app on the phone that
`scripts/run_device.sh --print-device` picks, launches it with `-ChirpBenchmarkDevice
parakeet,whisper-base,whisper-turbo,apple-speech`, and prints one line per engine from
`Documents/asr-device-benchmark.json` (kept in `.build/device-benchmarks/`). It downloads missing models; Apple Speech
reads "permission-needed" until Speech Recognition was allowed once through its Download button. Run it twice: the
first run's load time includes the one-time Core ML compile, the second is the warm load. It measures each engine
alone; the combined live-plus-final memory (review I3) still needs a dictation with two different engines and Xcode's
memory gauge.

By hand: install the build (`scripts/run_device.sh`) and download the engines in Settings → Speech
engines: Apple Speech, Whisper Base and Whisper Large v3 Turbo. Then Settings → Speech engines → Benchmark engines,
turn on every engine, Run, and Export CSV and JSON. Paste the summary here, with:

- the build stamp (Settings → About) and the iOS version;
- **Whisper Large v3 Turbo's peak memory.** The registry estimates 1.5 GB against the 2.5 GB budget
  (`SpeechEngineCapabilityRegistry`). If it is higher, lower the estimate or mark the row;
- **The first-load peak** (fix/speech-memory-fit). Turbo's first load was killed by iOS on the iPhone 17 Pro, so the
  registry now carries a first-load compile peak, checked at run time against `os_proc_available_memory()`:
  placeholders Whisper Base 0.6 GB and Turbo 3.5 GB. `scripts/device_benchmark.sh` prints `avail MB` (the memory
  iOS let the app use right before each load), `load pk MB` (the app's peak during the load alone) and `rise MB`
  (that peak minus the app's memory right before the load). Run it right after a fresh download (first load, with
  the compile) and paste the numbers here, then replace `approximateFirstLoadPeakMemoryBytes` with `rise MB` plus a
  margin. If `avail MB` is below Turbo's 3.5 GB
  placeholder, the app refuses the load and the reason names both numbers: the Increased Memory Limit entitlement
  (745ea14c) must be active on the App ID for the measurement;
- the first-load time of each engine right after its download, which is the one-time Core ML compile, then the warm
  load from a second run;
- Apple Speech's WER and speed. It only runs on the device; the Simulator lists it as unavailable.
