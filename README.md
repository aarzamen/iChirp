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

| Milestone | Scope | Status |
|---|---|---|
| M0 | Foundation: XcodeGen project, `ChirpKit` package, scripts, specs, agent docs | Built in source (branch `ichirp/foundation`) |
| M1 | Parakeet v3 file transcription: import, speaker labels, Library, Transcript with player, export, model management, device smoke test | Built in source (branch `ichirp/foundation`) |
| M1.5 | Finish long files in the background; import from the Share sheet and Voice Memos | Roadmap |
| M2 | Dictation (Action Button, Live Activity, live preview, final pass, copy) | Roadmap |
| M3 | Meeting recording with crash recovery, Notes tab | Roadmap |
| M4 | Language models and deliverables: summaries, meeting notes, agendas, SOAP notes, Ask | Roadmap |
| M5 | Ingest breadth: podcasts, media links, YouTube, PDFs, text documents | Roadmap |
| M6 | Structure models: Needle, Jev, Laya | Roadmap |
| M7 | Engine breadth and on-device benchmarks | Roadmap |
| M8 | Polish: PDF/DOCX export, keyboard, widgets, accessibility, iPad | Roadmap |

Test and device-verification state for each milestone lives on the [plans board](docs/plans/README.md). Screens
for unbuilt milestones exist in the app as honest "Not built yet — milestone Mx" placeholders; nothing is simulated.

## Quick start

On a Mac with Xcode 26 or later and [Homebrew](https://brew.sh):

```bash
cd /Users/ama/Documents/GitHub/iChirp
scripts/bootstrap.sh      # checks Xcode, XcodeGen, swift-format; offers the signing config; generates the project
scripts/run_sim.sh        # builds and launches Parakeet in the iPhone simulator
scripts/run_device.sh     # builds, installs and launches on the paired iPhone (Developer Mode on, unlocked)
```

`scripts/run_device.sh` signs with the owner's paid Apple Developer team using the provisioning profiles that
already exist. It never asks Xcode to create or update profiles. If signing fails, follow the message it prints and
read [`APPLE_DEVELOPER_WARNING.md`](APPLE_DEVELOPER_WARNING.md). Other install paths, including the optional
SideStore IPA, are in [`docs/distribution.md`](docs/distribution.md).

Everyday commands for contributors and coding agents are in [`AGENTS.md`](AGENTS.md#2-commands).

## Layout

```
README.md  AGENTS.md  CLAUDE.md  LICENSE  THIRD_PARTY_LICENSES.md  APPLE_DEVELOPER_WARNING.md
project.yml        XcodeGen spec; the .xcodeproj is generated and gitignored
Config/            xcconfigs (Shared, Debug, Release, Signing.local.xcconfig.example)
App/               iOS app target: composition root, screens, resources
AppTests/          app-hosted tests (run in the simulator)
ChirpKit/          Swift package with every non-UI module and its tests (runs on the Mac with `swift test`)
spec/              vision, architecture, pipelines, data model, testing, privacy, ADRs, contracts
docs/              plans, reviews, research, design canvas, solutions, workflows
scripts/           bootstrap, gen, check, test, run_sim, run_device, device_smoke, build_ipa, …
upstream/          MacParakeet at a pinned commit, read-only, for porting
legacy/gemini-ios/ an earlier iOS attempt kept only for salvage; not built
```

## Engines

Every engine is a plug-in target behind a `ChirpCore` protocol, so speech engines, language models and structure
models can be swapped without touching the app. Summary of the plan (details in
[`spec/06-speech-engines.md`](spec/06-speech-engines.md) and
[`spec/08-language-and-structure-models.md`](spec/08-language-and-structure-models.md)):

| Kind | First | Next | Later or gated |
|---|---|---|---|
| Speech | Parakeet TDT v3 via FluidAudio (M1); offline speaker labels; Apple SpeechTranscriber | Streaming Parakeet / Nemotron for live text; WhisperKit | Cohere Transcribe; Apple Core AI models; Cactus (license-gated) |
| Language | Apple Foundation Models; cloud and home-network providers (Anthropic, OpenAI-compatible, Gemini, Ollama, LM Studio) | MLX and llama.cpp small models (Qwen, LFM) | LiteRT-LM, ExecuTorch, Core AI |
| Structure | none yet | Needle 3 (personal builds only) | Jev (cloud, opt-in, never clinical); Laya |

## Privacy

- Audio and transcripts stay on the iPhone. The only network use in M1 is the one-time model download from
  Hugging Face.
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
