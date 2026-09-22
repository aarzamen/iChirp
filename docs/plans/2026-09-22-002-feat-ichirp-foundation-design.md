---
title: iChirp foundation and M1 (Parakeet file transcription) design
date: 2026-09-22
status: APPROVED 2026-09-22 (owner; amendment: FluidAudio latest 0.16.1 from day one)
author: Claude (Opus 5.5) with Aaron Arzamendi
decisions_by_owner:
  layout: iChirp at repo root; MacParakeet moved to upstream/macparakeet as a pinned reference
  gemini_code: set aside in legacy/gemini-ios; rebuild the app shell from the design canvas
  scope: foundation + app shell + real Parakeet v3 file transcription, verified on iPhone 17 Pro
  display_name: Parakeet
  fluidaudio: exact 0.16.1 (latest), not the upstream 0.15.7 pin
---

# iChirp foundation and M1 (Parakeet file transcription) design

## 1. Goal

Turn the repo into a clean, agent-ready home for **iChirp**, the iPhone edition of MacParakeet (home-screen name: **Parakeet**).
In this session, ship a real Parakeet v3 file-transcription slice that runs on the owner's iPhone 17 Pro.

**End goal**, which the README and AGENTS.md carry forward:
- A polished, accurate, flexible iOS app.
- It turns voice, meetings, YouTube and podcast links, device audio/video, text files and PDFs into deliverables: transcripts, raw documents, LLM-polished documents, meeting notes, agendas, SOAP notes, summaries, subtitles, and more.
- Speech-to-text engines, large language models, small language models and structure models (for example Needle, Jev, Laya) are all plug-and-play.

**Not in this session:**
- Dictation, meeting recording, URL/PDF ingest, LLM deliverables, extensions (keyboard, share, widget/Live Activity), and the Structure-model plug-ins.
- Each of these is on the roadmap (§12) with an executor-ready plan.

## 2. Why rebuild instead of patch (summary of the review)

The full review goes to `docs/reviews/2026-09-22-gemini-ios-review.md`. Gemini's app compiles and runs, but:

1. **Transcription is Apple's legacy `SFSpeechRecognizer`, not Parakeet.** The "final" transcript is the last partial result: no timestamps, no final pass, no persistence. Meeting audio is written as uncompressed Float32 audio into a `.m4a` file and the error is swallowed.
2. **URL and file transcription, the Library, and Transforms are simulated.** They use timed sleeps, scripted status text, hardcoded demo rows, and a Transform that just prefixes "✨".
3. **The extensions don't exist.** A SwiftPM `executableTarget` cannot carry keyboard, share or widget extensions, and the hand-assembled `.app` has no App Group entitlement. The IPC, share and Live Activity code is never called.
4. **The license was changed.** MacParakeet's GPL-3.0 license was replaced with MIT under a new copyright holder, which is not valid for a derivative work.
5. **32 upstream Core files were edited behind `#if` guards.** The macOS build still passes (verified: 80 s, 0 errors). On iOS, some stand-in code quietly does the wrong thing: a "DOCX" export that writes plain text, a PDF export that draws one page, and audio-device calls that always report success.
6. **Settings are cosmetic.** API keys are kept in plaintext in `UserDefaults` (upstream uses the Keychain), the engine picker isn't wired, and "Clear cache" is a no-op.

The core value is reusable. FluidAudio (MacParakeet pins 0.15.7; iChirp uses 0.16.1, which is API-compatible) supports iOS 17+ and ships:
- Parakeet TDT v3 and v2
- Streaming Parakeet and Nemotron
- Silero VAD
- Offline and streaming diarization
- Inverse text normalization

MacParakeet's pipeline therefore ports to iOS almost unchanged, except for FFmpeg, AppKit, ScreenCaptureKit and CoreAudio HAL.

## 3. Repository layout (owner-approved)

```
/                         iChirp: the product this repo builds
├── README.md             product intent, status, quick start, layout, license
├── AGENTS.md             canonical agent guide (≈ one screen or two)
├── CLAUDE.md             @AGENTS.md plus Claude-only overlay
├── LICENSE               GPL-3.0 (restored), copyright MacParakeet authors plus iChirp contributors
├── THIRD_PARTY_LICENSES.md
├── project.yml           XcodeGen spec; the .xcodeproj is generated and never committed
├── Config/               xcconfigs (Shared, Debug, Release, Signing.local.xcconfig.example)
├── App/                  iOS app target: composition root, screens, resources
├── ChirpKit/             local SwiftPM package with every non-UI module plus tests
├── spec/                 vision, architecture, pipelines, data model, testing, ADRs, contracts
├── docs/                 reviews, plans (single plan location), research, solutions, workflows
├── scripts/              bootstrap/gen/check/test/run_sim/run_device/device_smoke/build_ipa/…
├── .github/workflows/    CI (package tests plus simulator build)
├── upstream/
│   ├── README.md         what this is, pinned SHA, sync procedure, porting rules
│   └── macparakeet/      MacParakeet at upstream commit bbae9e0e, unmodified, read-only reference
└── legacy/gemini-ios/    Gemini's iOS files, not built, with salvage notes
```

Rules:
- **Upstream is read-only.** `upstream/macparakeet/` is never edited in place. `scripts/sync_upstream.sh <ref>` replaces it wholesale and records the SHA, so the diff between two syncs shows exactly what upstream changed.
- **Ported code records its source.** Every ported file starts with `// Ported from MacParakeet (GPL-3.0): <upstream path> @ <sha>`. Agents can then compute the upstream deltas that still need porting.
- **Legacy code is temporary.** `legacy/` is salvage-only. It is deleted once the listed salvage items land or are rejected.

## 4. Build system

- **Project generation.** XcodeGen 2.45.4 is already installed. `project.yml` is the only project source of truth.
- **Targets:**
  - `iChirp`: the iOS app. Display name `Parakeet`, bundle ID `com.aarzamen.ichirp` (base defined in `Config/Shared.xcconfig`).
  - `iChirpTests`: app-hosted tests.
  - Extensions are added in later milestones.
- **Minimum iOS 26.0.** All of the owner's devices run it (iPhone 17 Pro, iPhone 15 Pro, iPhone 12 Pro Max, iPad Pro M1). It unlocks SpeechAnalyzer, Foundation Models and `BGContinuedProcessingTask`. It also removes the iOS-17 CoreML generation, where upstream needed an ANE serialization workaround. Recorded as an ADR.
- **Swift.** Swift 6.2 language mode with strict concurrency, on Xcode 26.6 (installed; iOS 26.5 SDK). Verified target device: iPhone 17 Pro on iOS 26.2, Developer Mode on, paired.
- **iOS 27 APIs are a later prerequisite.** iOS 27 shipped 2026-09-14. Its Foundation Models `LanguageModel` protocol (with third-party model conformers), Core AI, and new Speech input providers need **Xcode 27**. They are adopted behind `#available` in M4/M7 so iOS 26 devices keep working.
- **Signing.**
  - `Config/Signing.local.xcconfig` is gitignored and optional. It holds `DEVELOPMENT_TEAM` (the owner's team, XM6E4PUXTU, which has a 1-year profile and so appears to be a paid team) with automatic signing. `scripts/run_device.sh` uses `-allowProvisioningUpdates`.
  - No capabilities in M1, so the existing wildcard profile is enough.
  - Fallback: `scripts/build_ipa.sh` produces an unsigned IPA for SideStore.
- **Build identity** (owner's standing rule). A build phase runs `scripts/stamp_build_identity.sh`. It writes `ChirpGitCommit`, `ChirpGitBranch`, `ChirpGitDirty` and `ChirpBuildDateUTC` into the built product's Info.plist, and sets `CFBundleVersion` to a UTC timestamp. `BuildIdentity` (ChirpCore) reads these keys. Settings → About shows version (build), commit, branch, date, and a Copy button, and the identity is logged at launch.

## 5. ChirpKit modules

`ChirpKit/Package.swift` uses tools 6.2 and platforms iOS 26 and macOS 26. Package tests run on the Mac host with `swift test`, with no simulator needed for logic.

| Target | Depends on | Owns |
|---|---|---|
| `ChirpCore` | nothing heavy | Domain models (`Transcription`, `TimestampedWord`, `TranscriptSegment`, `Speaker`, `SourceKind`); engine protocols and descriptors (§6); `PrivacyClass` and routing policy; `SpeechJobScheduler` (port of STTScheduler semantics); `BuildIdentity`; `AppPaths`; logging |
| `ChirpAudio` | AVFoundation | `AudioFileDecoder` (any audio/video file → 16 kHz mono Float32 WAV via AVAssetReader), media metadata. Later: AVAudioSession controller and capture |
| `ChirpText` | ChirpCore | Ports: `TextProcessingPipeline` and `CustomWordReplacer`, `STTWordTimingBuilder`, `SpeakerMerger` plus isolated-assignment smoothing, `TranscriptParagraphBuilder`, `TranscriptCueBuilder`, `TranscriptSegmenter` |
| `ChirpStore` | GRDB 7 | `DatabaseManager` (iChirp's own migrations, modelled on upstream's `transcriptions` table), `TranscriptionRepository`, `CustomWordRepository` |
| `ChirpExport` | ChirpText | TXT, Markdown, SRT, VTT, JSON (ports). PDF and DOCX later (UIKit or Core Text, and an OOXML writer) |
| `ChirpEngineFluidAudio` | FluidAudio **exact 0.16.1** | `ParakeetEngine` (TDT v3/v2), `FluidAudioModelStore` (download with progress, verify, delete, sizes, exclude from backup), `DiarizationEngine` (OfflineDiarizerManager, high-accuracy preset), `ANEInferenceGate` (iOS policy) |
| `ChirpFeatures` | Core, Store, Text, Export, Audio | `@Observable` view models: `CaptureViewModel`, `LibraryViewModel`, `TranscriptViewModel`, `SpeechSettingsViewModel`, `FileTranscriptionCoordinator` (the job runner). Engines are injected as protocols |
| `ChirpUI` | SwiftUI | Design tokens and components from the canvas (§9) |

The app target is only the composition root plus screens. **Engine plug-in rule:** every engine is a target named `ChirpEngine<Provider>`. It depends only on ChirpCore plus its SDK, and exposes `register(into: EngineCatalog)`. Nothing else imports an engine SDK.

**Dependency pins.** FluidAudio is **exact 0.16.1** (2026-09-21), the latest release (owner decision: start on latest; don't carry the old pin).
- **Upstream compatibility.** Upstream MacParakeet pins 0.15.7. A public-API diff of the surfaces it uses (`ASRConfig`, `AsrModels`, `AsrManager`, `Diarizer/*`, `VAD/*`) shows **no removals or changes, only additions** (`AsrModels.loadLocal`, model `revision` pinning, `ModelRegistry.resolveModel(_:_:revision:)` with a default). Upstream's Swift code is therefore still the working example.
- **What 0.16.1 adds:** fixes for streaming-ASR window joins, sentence-final punctuation and blank-window recovery; diarization model files pinned to a fixed Hugging Face revision; a bundled NeMo text normalizer (the `NemoTextProcessing` trait, about 8 MB, kept on for dictation number formatting in M2).
- **Keep upstream's bump discipline** (ADR-010): pins stay `exact`, and each bump gets an STT and diarization regression pass using the device smoke test and the model integration test.

GRDB is `from: 7.0.0`.

**License gate for plug-ins.** The repo is GPL-3.0. Some plug-ins have a license that isn't GPL-compatible, or a runtime that is binary-only:
- the Cactus engine uses a custom small-company license;
- Needle 3's `libneedle.a` has Apache-2.0 weights but a closed-source runtime.

Plug-ins like these sit behind an opt-in build flag (the same pattern as upstream's `MACPARAKEET_ENABLE_MLX_LOCAL_LLM`), are off by default, and are allowed only in personal builds, never in a distributed IPA. Each plug-in's ADR records its license verdict.

## 6. Engine plug-in architecture (Speech, Language, Structure)

These live in `ChirpCore/Engines/`:

- `EngineDescriptor` fields:
  - `id`, `kind` (`.speech` / `.language` / `.structure`), `provider`, `displayName`
  - `locality` (`.onDevice` / `.localNetwork` / `.cloud`), `license`
  - `footprintBytes`, `capabilities`
- Speech capabilities port upstream's `SpeechEngineCapabilityRegistry`: word timestamps, native live, tail preview, languages, custom vocabulary, and a memory floor.
- `SpeechEngine`: `prepare(progress:)`, `transcribe(fileAt:options:progress:) -> SpeechResult` (`text`, `words`, `language`, `engine`, `variant`).
  - Optional `LiveSpeechSession` (M2).
  - `Diarizing` returns speaker segments.
- `LanguageModel`: `generate(_ request:) -> AsyncThrowingStream<GenerationEvent, Error>`, plus structured output where supported (M4).
  - Evaluate Hugging Face **AnyLanguageModel** first as the implementation. It is Apache-2.0 and ships as a Swift package, with a Foundation-Models-shaped API over Apple's on-device model, Core ML, MLX, llama.cpp, Ollama, Anthropic, OpenAI and Gemini. A single plug-in target could cover most providers.
  - Long transcripts need chunked map-reduce on 4K-context on-device models; a 60-minute meeting is about 12K tokens. Upstream has map-reduce only in its in-process client. iChirp ports it and makes it the default for small-context models.
  - MLX and other GPU runtimes are foreground-only on iPhone. Neural Engine and CPU work (FluidAudio) can continue in the background.
- `StructureModel`: `extract(schema:from:)`, `classify(choices:)`, `embed(_:)`. Every result carries a calibrated `confidence`. Consumers must gate on it (act / confirm / escalate), and numeric fields are re-validated in code (M6).
- `ModelAssetManaging`: status, download(progress), delete, bytesOnDisk.
- **Routing mirrors upstream ADR-016 and ADR-026.** There is a *live* route and a *final* route. A final job snapshots its engine selection at enqueue time, and a lease blocks engine switches mid-session.
- **Privacy router.** Each content item carries a `PrivacyClass` (`.general` / `.personal` / `.clinical`). Clinical content, such as SOAP notes, may only use `.onDevice` engines or a `.localNetwork` endpoint the user marked trusted. Cloud needs a per-run explicit override, which is logged without content. Jev is cloud-only, so it can never see clinical content by default.

## 7. The M1 transcription pipeline (mirrors MacParakeet `TranscriptionService`)

Upstream reference: `upstream/macparakeet/Sources/MacParakeetCore/Services/TranscriptionService.swift` (local file entry ~L871, `transcribeAudio` ~L1907, `completeTranscription` ~L2162).

1. **Import.** The Capture tile "Import audio" opens `fileImporter` for audio and movie types. The file is copied into `Application Support/iChirp/media/<id>/source.<ext>` under security-scoped access. AVFoundation reads metadata (duration, title). A `transcriptions` row is inserted with `status = processing`.
2. **Normalize.** `AudioFileDecoder` uses AVAssetReader with `AVAudioMixOutput` (LinearPCM Float32, 16 kHz, 1 channel). It writes `media/<id>/normalized-16k.wav`, which replaces upstream's FFmpeg subprocess. The audio-track ordinal follows upstream semantics.
3. **Schedule.** The job is enqueued as `.fileTranscription` on `SpeechJobScheduler`, which keeps upstream's two-slot semantics:
   - *interactive* for dictation;
   - *background* with priority meetingFinalize > meetingLiveChunk > fileTranscription, FIFO within a priority, never preempting a running file job.
   - Cancellation is supported. Only the file-job path is exercised in M1.
4. **Transcribe.** `ParakeetEngine` (v3 default, v2 English-only option) calls `AsrManager.transcribe(url)`. FluidAudio switches to disk-backed chunking above 30 s: about 15 s windows with 2 s overlap and token dedup at the seams. Two managers share one `AsrModels`. Every inference goes through `ANEInferenceGate`. iOS 26 is in the same CoreML generation as macOS 26, so the gate does not serialize, matching upstream on macOS 15+. The parallel-chunk concurrency is a tunable, benchmarked on device (starting value 2; upstream uses 4).
5. **Words.** The ported `STTWordTimingBuilder` merges FluidAudio token timings into words on the `▁` boundary and averages confidences.
6. **Diarize** (optional; Settings → Speaker labels, default on per the design). FluidAudio `OfflineDiarizerManager` with upstream's high-accuracy preset (stepRatio 0.1, minSegmentDuration 0, zeroVoteReembed). Speakers are renamed S1…Sn in order of first speech. `SpeakerMerger` assigns each word the speaker with maximum overlap, then applies isolated-assignment smoothing. Failure is non-fatal: the transcript is kept without speakers.
7. **Complete.** Ported from upstream `completeTranscription`:
   - The deterministic pipeline produces `cleanTranscript`; `rawTranscript` is kept.
   - A derived title and snippet are computed.
   - `TranscriptSegmenter` builds speaker-turn segments.
   - The result is saved while preserving user metadata edited during processing (title, favorite).
   - The normalized WAV is deleted unless audio retention says otherwise; the source file is kept for playback.
   - Which text is shown: the timestamped Transcript view is built from the engine's words (Parakeet output is already punctuated and cased). Settings → Clean-up is **Raw** by default (matching upstream ADR-004 and `AppRuntimePreferences`: `cleanTranscript` stays nil and everything shows the engine text). With **Clean** on, the deterministic pipeline runs for non-meeting sources (upstream `completeTranscription`), and plain copy and export use `cleanTranscript`.
8. **Recover.** On launch, rows stuck in `processing` become `interrupted` with Retry. Long jobs request background time. `BGContinuedProcessingTask` (iOS 26) is the M1.5 upgrade that lets a long job finish after you leave the app, with a system progress UI.
9. **Export and share.** TXT, Markdown, SRT, VTT and JSON, using the ported paragraph and cue rules: paragraphs of at most 3 sentences or 80 words, broken on pauses of 2.5 s or more; cues break on speaker change, on sentence end with at least 2 words, on gaps over 800 ms, at 12 words, or past 7 s.

**Model management.** Settings → Speech model shows Parakeet v3, its size on disk, and Download / Delete / progress. A Speaker-labels row does the same for the ~130 MB diarizer. Models are marked `isExcludedFromBackup`, because they can be re-downloaded. First use of an engine never downloads silently: a missing model routes the user to download.

## 8. Data model (M1 subset)

`transcriptions` is modelled on upstream's table, with the same field names where they overlap so code ports cleanly:

- `id` (UUID), `createdAt`, `updatedAt`
- `sourceType` (`file` | `dictation` | `meeting` | `url` | `podcast` | `document`)
- `fileName`, `sourceBookmark` / `mediaPath`, `durationMs`
- `rawTranscript`, `cleanTranscript`
- `wordTimestamps` (JSON), `speakers` (JSON), `diarizationSegments` (JSON), `transcriptSegments` (JSON)
- `speakerCount`
- `status` (`processing` | `completed` | `failed` | `interrupted` | `cancelled`), `errorMessage`
- `engine`, `engineVariant`, `language`
- `titleOverride`, `derivedTitle`, `derivedSnippet`, `isFavorite`, `privacyClass`

Other rules:
- `custom_words` is ported now; its UI comes later.
- Migrations are registered inline in `DatabaseManager`. A migration is never edited after it has been installed on a device.
- Tests use an in-memory database.
- Documented in `spec/01-data-model.md`.

## 9. UI (from the design canvas; the text handoff goes to `docs/plans/2026-09-22-001-feat-iphone-app-design-handoff.md`)

- **Tokens:**
  - Colors: accent `#E86B3B`, accent-ink `#BE4E26`, ground `#FAFAF7`, surface `#FFFFFF`, border `#E8E8E0`, ink `#1A1A1A`, secondary `#6B6B6B`, tint `#FFF0EB`, success `#33A854`, rosette green `#59A659`, record red `#E64D42`, stop red `#C9342B`, dictation night `#141417`.
  - Type: SF Pro Rounded headlines over SF Pro body.
  - Radii: 14 / 16 / 20 / 24.
  - Covers: Seed-of-Life on a night field.
  - Speaker palette: blue, purple, green, amber, each with an ink pair.
- **Four tabs:** Capture, Library, Transforms, Settings.
- **M1 screens** (real, not placeholders):
  - **Capture:** header, Dictate card, link and import tiles, meeting row, Recent list with live progress.
  - **Library:** search, chips (All / Meetings / Dictations / Video / Local), day groups, delete with confirmation.
  - **Transcript:** header with favorite; Transcript tab; audio player bar (play, scrub, times, speed); speaker paragraphs with tappable timestamps and a highlight for the current paragraph; Copy / Share (formats) / Transform bar.
  - **Settings:** Speech model, Language, Speaker labels, Clean-up (Raw / Clean), Privacy statement, About (build identity), plus a DEBUG-only Diagnostics section.
- **Honest placeholders**, never simulated progress: Dictate, Paste a link, Record Meeting, the Notes and Ask tabs, Transforms, and cloud toggles. Each shows a clear "Not built yet (milestone Mx)" sheet.
- **Copy corrections to the canvas:**
  - "Hold the Action Button" becomes "Press the Action Button". Third-party apps get no key-up event, so hold-to-talk is impossible.
  - The meeting "Room" meter needs a real signal. The iPhone has no system-audio capture, so it becomes a second built-in-mic or voice-isolation reading, or it is dropped (M3 decision).

## 10. Verification

- **Package tests on the Mac host.** `scripts/check.sh <Filter>` for focused runs, full once per task. They cover the pipeline ports (text, merger, segmenter, cues, paragraphs), the decoder (fixtures synthesized with `say`), the store, the scheduler, exporters, and the engine with a FluidAudio fake.
- **Real-model integration test.** Gated by `CHIRP_MODEL_TESTS=1`; downloads Parakeet v3 once and transcribes the bundled synthetic sample.
- **Simulator build.** `scripts/test.sh` builds the app for the simulator and runs the app-hosted tests.
- **Device smoke test** (autonomous, repeatable). `scripts/device_smoke.sh`:
  1. Builds Debug.
  2. Installs to the paired iPhone with `devicectl`.
  3. Launches with `-ChirpSmoke transcribe-sample` (DEBUG only). The app transcribes the bundled synthetic sample and writes `Documents/smoke-result.json`.
  4. Pulls the file back with `devicectl device copy from` and asserts the expected words.
  If the phone is locked, it asks the owner to unlock.
- **Manual QA checklist** in the PR notes: import a real Voice Memo, check speakers and timestamps, play and seek, export each format, delete.

## 11. Agent environment (what AGENTS.md and the docs encode)

These are adapted from the upstream inventory; generic rules are kept and Mac-only rules dropped.

- **AGENTS.md sections:** Project shape → Commands (the scripts above) → Layout and boundaries (module table, engine plug-in rule, upstream read-only, porting provenance) → Product rules (local-first, privacy classes, never lose user data, honest UI with no simulated progress) → Working method (find the governing spec/ADR/test first; state scope and must-not-change; focused tests, full suite once; device smoke for pipeline changes) → Review and commit → Where to look → Roadmap pointer.
- **CLAUDE.md:** `@AGENTS.md` plus the upstream Claude overlay rules (memory is a hint; promote lessons to the narrowest versioned surface; enforce with tests or scripts).
- **spec/:** README (status, locked decisions, release channels and feature flags, ADR index, milestones), `00-vision` … `10-ai-coding-method`, `adr/000-template.md` plus seed ADRs, `contracts/` (README, `speech-engine-plugin-v1`, `transcript-json-v1`, `media-storage-layout-v1`).
- **docs/:**
  - README map
  - `reviews/` (Gemini review)
  - `plans/` (single location, with a status board and an executor-plan template)
  - `research/` (MacParakeet pipeline map, on-device runtimes, iOS platform constraints, Cactus/Needle/Jev)
  - `solutions/` (frontmatter template)
  - adapted `commit-guidelines`, `pr-review-workflow`, `agent-memory-governance`, and a new `distribution.md` for device installs and the SideStore IPA
- **Subsystem READMEs** in every ChirpKit module (Entry point / What's here / What to know before editing / How to verify). `scripts/check_readme_references.sh` enforces that referenced files exist.
- **Hygiene:** `.swift-format` and `.editorconfig` adopted; lint is a hard gate from day one; the `.gitignore` covers the generated project, build output, local signing, and `.remember/`.

## 12. Roadmap (milestones after this session; each gets an executor plan)

| Milestone | Scope |
|---|---|
| **M0** (this session) | Foundation and environment |
| **M1** (this session) | Parakeet file transcription, model management, Library, Transcript, export, device smoke test |
| M1.5 | `BGContinuedProcessingTask`, import from the Share sheet (share extension plus App Group), Voice Memos |
| M2 | Dictation. AVAudioSession plus a shared mic stream (port the upstream semantics). Live preview: tail-window Parakeet or native streaming. Final Parakeet pass on the recording. Clean pipeline; copy or paste. Action Button App Intent with a Live Activity. Dictating screen. |
| M3 | Meeting recording. Background audio, fragmented m4a plus `recording.lock` crash recovery (ADR-019 port), VAD live chunks, final pass plus diarization, Notes tab. |
| M4 | Language models and deliverables. Providers: Apple Foundation Models, OpenAI-compatible / Anthropic / Gemini cloud, and Ollama / LM Studio over the LAN. Keys in the Keychain. Templates: summary, meeting notes, action items, agenda, SOAP, polish/distill/decide/brief. Ask with timestamp citations. Privacy router. |
| M5 | Ingest breadth. Podcasts (iTunes lookup), direct media URLs, a YouTube strategy, PDF (PDFKit plus Vision OCR), TXT/MD/RTF/DOCX import. |
| M6 | Structure models. Needle 3 through its own `libneedle.a` runtime, without Cactus, called from one actor and gated as personal-build-only. Used for extraction, routing and embeddings, with confidence gating. Jev cloud (opt-in, non-clinical). Laya (Core ML conversion research). |
| M7 | Engine breadth and benchmarks. Apple SpeechTranscriber / DictationTranscriber, WhisperKit (`argmax-oss-swift` 1.1, a breaking upgrade), Nemotron and Parakeet EOU streaming, MLX and llama.cpp local LLMs; an on-device benchmark harness. |
| M8 | Polish. PDF/DOCX export, keyboard extension, Transforms share extension, widgets, accessibility, iPad layout, localization. |

**Plug-in engine matrix** (from `docs/research/2026-09-22-on-device-runtimes.md`; P0 = first to build, P1 = next, P2 = later):

| Kind | P0 | P1 | P2 / gated |
|---|---|---|---|
| Speech | FluidAudio Parakeet TDT v3 (batch), Silero VAD, offline diarization; Apple SpeechTranscriber (no download, iOS 26, device only) | FluidAudio Parakeet EOU / Nemotron streaming for live; WhisperKit large-v3 turbo (626 MB, 99 languages) | FluidAudio Cohere (1.8 GB, iOS 18+); Core AI Parakeet/Whisper (iOS 27); Cactus STT (license-gated) |
| Language | Apple Foundation Models (4K context, `@Generable`); AnyLanguageModel as the plug-in layer; HTTP cloud and LAN providers (Anthropic, OpenAI-compatible, Gemini, Ollama, LM Studio) | MLX Swift (foreground only); llama.cpp GGUF (Qwen3.5-2B, LFM2.5-1.2B, Qwen3-4B-Instruct-2507) | LiteRT-LM (Gemma 4), ExecuTorch, Core AI (iOS 27); Apple Private Cloud Compute (entitlement-gated) |
| Structure | none in M1 | Needle 3 (`libneedle.a`, personal builds) for extraction, routing and embeddings | Jev (cloud API, opt-in, non-clinical); Laya (needs Core ML conversion); FluidAudio CUA-S1-FORMS |

**Memory budget.** Paid-team builds can add the Increased Memory Limit entitlement. SideStore builds cannot, so keep total model weights around 2–3 GB or less there (field report: a 3.65 GB model failed to load on an iPhone 17 Pro without the entitlement).

## 13. Risks and open questions

- **Signing.** Automatic signing with `-allowProvisioningUpdates` needs the owner's Apple ID signed into Xcode. If it isn't, `run_device.sh` fails with a clear message.
- **Parakeet v3 on iPhone.** First-load CoreML compile time and peak memory are unmeasured. The device smoke test records both, and the chunk-concurrency tunable is the fallback lever.
- **Long files in the background.** Until M1.5, a long file stops progressing when the app leaves the foreground. The UI says so.
- **iOS 27 background Neural Engine restriction.** iOS 27 (shipped 2026-09-14; the owner's phone is still on 26.2) blocks background ANE access unless the app has the `com.apple.developer.background-tasks.continued-processing.inference` entitlement. This affects background file jobs (M1.5), locked-screen dictation (M2) and meetings (M3). Plan on CPU fallback when backgrounded, measure it on device, and test whether the paid team can get the entitlement. GPU (MLX) work is foreground-only on iPhone.
- **SideStore specifics.**
  - Use version 0.7.0-alpha or later.
  - IDs are rewritten with a `.TEAMID` suffix, so derive App Group and background-task IDs at runtime.
  - Entitlements must be embedded by ad-hoc signing before zipping the IPA.
  - Keep the app to at most 1 + 2 extensions (keyboard, and one widget extension for the Live Activity and Controls) to fit the App ID budget.
- **Design canvas.** It is ahead of implementation. Screens beyond M1 are documented, and their placeholders never pretend to work.
