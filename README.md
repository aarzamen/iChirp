# iChirp — Parakeet for iPhone

**iChirp** is the iPhone edition of [MacParakeet](https://github.com/moona3k/macparakeet). On the home screen it
is called **Parakeet**. It turns speech into text on the iPhone itself, using NVIDIA's Parakeet model through
FluidAudio on the Neural Engine, and keeps the audio and the transcripts on the device.

## What it is for

The end goal, in the owner's words:

> "An iOS, highly polished, competent, accurate, flexible, and easy-to-use application that's used for
> transcription of voice files, meetings, YouTube links, device files, text files, and PDFs into all manner of
> transcription, raw documents, large language model polished documents, meeting notes, agendas, SOAP notes,
> transcripts, and all manner of other deliverable text formats and documents. It should do this with the utmost
> flexibility, being able to plug and play various different speech-to-text engines, large language models, and
> small language models"

That includes miscellaneous models such as Needle (tiny on-device extraction), Jev (cloud decisions) and Laya, and
the Cactus runtime. The product vision is in [`spec/00-vision.md`](spec/00-vision.md).

## Status

All of this is merged on `main`. "Built" means the code and tests are in and the milestone passed on the simulator;
"device QA pending" means the owner's checklist in [`docs/human-qa-guide.md`](docs/human-qa-guide.md) has not been
walked yet. The authoritative per-milestone table (plans, commits, what was verified) is in
[`spec/README.md`](spec/README.md#milestones); this one only summarizes it.

| Milestone | Scope | Status |
|---|---|---|
| M0 | Foundation: XcodeGen project, `ChirpKit` package, scripts, specs, agent docs | Built (`e232b62d`) |
| M1 | Parakeet v3 file transcription: import, speaker labels, Library, Transcript with player, export, model management, device smoke test | Built: device smoke passes on iPhone 17 Pro and iPhone 15 Pro (`a6cd8f2d`) |
| M1.5 | Finish long files in the background; import from the Share sheet and Voice Memos | Built; device QA pending |
| M2 | Dictation (Action Button, Live Activity, live preview, final pass, copy) | Built; device QA pending |
| M3 | Meeting recording with crash recovery, Notes tab | Built; device QA pending |
| M4 | Language models and deliverables: summaries, meeting notes, agendas, SOAP notes, Ask | Built; device QA pending |
| M5 | Ingest breadth: podcasts, media links, YouTube, PDFs, text documents (YouTube audio through the Mac companion) | Built; device QA pending |
| M6 | Structure models: Needle 3, Jev, Laya | Needle 3 (experimental accuracy) and the Jev trial built; Jev's live eval waits on the owner's key; Laya not started |
| M7 | Engine breadth and on-device benchmarks: Apple Speech, WhisperKit, small language models on the iPhone | Built; some iPhone measurements pending; streaming Parakeet not built |
| M8 | Polish: PDF/DOCX export, keyboard, widgets, accessibility, iPad | In progress: PDF and Word export (with Create), accessibility and the dark palette are in; keyboard, Transforms extension, home-screen widgets, iPad and localization are not |

Open work and the verification state of each plan live on the [plans board](docs/plans/README.md). The few features
not built yet say "Not built yet — milestone Mx" in the app; nothing is simulated.

## Quick start

On a Mac with Xcode 26 or later and [Homebrew](https://brew.sh):

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/bootstrap.sh      # checks Xcode, XcodeGen, swift-format; offers the signing config; generates the project
scripts/run_sim.sh        # builds and launches Parakeet in the iPhone simulator
scripts/run_device.sh     # builds, installs and launches on the paired iPhone (Developer Mode on, unlocked)
```

`scripts/run_device.sh` signs with the owner's paid Apple Developer team using the provisioning profiles that
already exist. It never asks Xcode to create or update profiles. If it says "Signing failed", follow that message and
read [`APPLE_DEVELOPER_WARNING.md`](APPLE_DEVELOPER_WARNING.md); any other error it prints is a build error in the
code, not a signing problem. Other install paths, including the optional SideStore IPA, are in
[`docs/distribution.md`](docs/distribution.md).

Two optional runtimes are built from pinned source on your Mac; without them Settings says Needle and the small
on-device language models are "not in this build" (CI builds both):

```bash
scripts/build_needle.sh       # Needle 3 (needs Rust: https://rustup.rs); builds vendor/NeedleC.xcframework
scripts/build_llamacpp.sh     # llama.cpp for the on-device language models (needs CMake or uv); builds vendor/llama.xcframework
```

The Mac companion (the owner's local voices and YouTube audio for the phone) runs with `scripts/companion.sh`; see
[`companion/README.md`](companion/README.md).

Everyday commands for contributors and coding agents are in [`AGENTS.md`](AGENTS.md#2-commands).

## Layout

```
README.md  AGENTS.md  CLAUDE.md  LICENSE  THIRD_PARTY_LICENSES.md  APPLE_DEVELOPER_WARNING.md
project.yml        XcodeGen spec; the .xcodeproj is generated and gitignored
Config/            xcconfigs (Shared, Debug, Release, Signing.local.xcconfig.example, Device.local.example)
App/               iOS app target: composition root, screens, resources, the privacy manifest
Widgets/           widget extension: the dictation and meeting Live Activities and the Dictate Control
AppTests/          app-hosted tests (run in the simulator)
UITests/           simulator screen tours for QA screenshots (never part of scripts/test.sh)
ChirpKit/          Swift package with every non-UI module and its tests (runs on the Mac with `swift test`)
companion/         the Parakeet companion for the Mac (Python, uv): local voices and YouTube audio
spec/              vision, architecture, pipelines, data model, testing, privacy, ADRs, contracts
docs/              plans, reviews, research, design canvas, solutions, workflows
scripts/           bootstrap, gen, check, check_scripts, test, run_sim, run_device, device_*, build_needle, build_llamacpp, …
vendor/            gitignored: the Needle and llama.cpp runtimes built by the two build scripts
upstream/          MacParakeet at a pinned commit, read-only, for porting
legacy/gemini-ios/ an earlier iOS attempt kept only for salvage; not built
```

## Engines

Every engine is a plug-in target behind a `ChirpCore` protocol, so speech engines, language models and structure
models can be swapped without touching the app. What is built and what is planned (details in
[`spec/06-speech-engines.md`](spec/06-speech-engines.md) and
[`spec/08-language-and-structure-models.md`](spec/08-language-and-structure-models.md)):

| Kind | Built | Next | Later or gated |
|---|---|---|---|
| Speech | Parakeet TDT v3 via FluidAudio with offline speaker labels (M1); Apple SpeechTranscriber and WhisperKit (M7) | Streaming Parakeet / Nemotron for live text | Cohere Transcribe; Apple Core AI models; Cactus (license-gated) |
| Language | Apple Foundation Models; cloud and home-network providers (Anthropic, OpenAI-compatible, Gemini, Ollama, LM Studio) as direct ports ([ADR-011](spec/adr/011-language-model-providers-direct-ports.md)); small models on the iPhone through llama.cpp (Qwen; [ADR-015](spec/adr/015-on-device-llm-llama-cpp.md), MLX not adopted) | More llama.cpp models (LFM) | LiteRT-LM, ExecuTorch, Core AI |
| Structure | Needle 3 built from needle-rs source, no license gate, experimental accuracy ([ADR-012](spec/adr/012-needle-from-needle-rs-source.md)); Jev (cloud, opt-in, never clinical; [ADR-013](spec/adr/013-jev-decision-model.md)) | Laya | Cactus's binary-only `libneedle.a` ([ADR-010](spec/adr/010-plugin-license-gate.md) gate: personal builds only) |

## Privacy

- Audio and transcripts stay on the iPhone, and Parakeet never uploads a recording. Every use of the network is an
  explicit, listed surface: model downloads, cloud or home-network language models, voices, link and YouTube
  downloads, the Mac companion (see the network table in [`spec/12-privacy.md`](spec/12-privacy.md#network-surfaces)).
  Like other app data, recordings are part of your iPhone backup.
- Each transcript carries a privacy class: general, personal (the default) or clinical. Clinical content, such as a
  SOAP note, may only be processed on the device or by a home-network computer you marked as trusted. Cloud models
  need an explicit per-run override.
- The repo contains no real recordings or patient data: every sample is synthetic.

Full rules: [`spec/12-privacy.md`](spec/12-privacy.md).

## License

GPL-3.0, the same as MacParakeet: see [`LICENSE`](LICENSE). iChirp is a derivative work, so it must stay GPL-3.0
and keep the original copyright notices. Personal installs and sideloading are fine. Distribution through the App
Store would need permission from MacParakeet's copyright holder. Third-party components:
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).

## Credits

- [MacParakeet](https://github.com/moona3k/macparakeet) by Daniel Moon: the pipeline, scheduler, text processing and
  export logic that iChirp ports.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference: Core ML speech recognition and
  speaker diarization on Apple devices (Apache-2.0).
- NVIDIA [Parakeet TDT 0.6B](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) speech models (CC-BY-4.0).
- [GRDB.swift](https://github.com/groue/GRDB.swift) by Gwendal Roué (MIT).
