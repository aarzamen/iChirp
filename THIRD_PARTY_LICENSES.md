# Third-Party Software and Model Attributions

iChirp itself is GPL-3.0 (see [`LICENSE`](LICENSE)). This file lists what the app links, what it downloads at run
time, and what it ports. Keep it in the same commit as any dependency or model change. An entry marked
**verify before distributing** has not been checked against its source in this repo; check the linked page and
record the result here before shipping an IPA to anyone else.

## Ported source

### MacParakeet

- License: GPL-3.0. Copyright (C) 2026 Daniel Moon.
- Source: <https://github.com/moona3k/macparakeet>, pinned read-only copy in `upstream/macparakeet/`
  (see [`upstream/README.md`](upstream/README.md)).
- Used for: the transcription pipeline, scheduler semantics, text processing, speaker merging, segmenting and
  export logic that ChirpKit ports. Every ported file carries a provenance header naming its upstream path.

## Swift package dependencies (linked into the app)

### FluidAudio

- Version: exact 0.16.1 (see `ChirpKit/Package.swift`).
- License: Apache License 2.0 (from the resolved package checkout's `LICENSE`).
- Source: <https://github.com/FluidInference/FluidAudio>
- Used for: Parakeet speech recognition, offline speaker diarization and model download/loading on Core ML.
- Includes: the NeMo text-processing (text normalization) framework as a package trait. License: Apache-2.0 per
  FluidAudio's package notes, **verify before distributing**.

### GRDB.swift

- Version: from 7.0.0 (see `ChirpKit/Package.resolved`).
- License: MIT. Copyright (C) 2015-2025 Gwendal Roué.
- Source: <https://github.com/groue/GRDB.swift>
- Used for: the local SQLite database.

## System frameworks and remote services used by language engines (M4)

- **Apple Foundation Models** (`FoundationModels.framework`, iOS 26): Apple system framework, not redistributed.
  Used by `ChirpEngineAppleFM`; the on-device model is governed by Apple's Apple Intelligence terms.
- **Anthropic, OpenAI-compatible providers, Ollama, LM Studio**: reached over HTTP by `ChirpEngineHTTPLLM` with
  the user's own key and server. No SDK is linked; the adapters are ports of MacParakeet's GPL-3.0 code. Model
  weights run on the provider's or the user's own machine under their own licenses.

## Remote decision service (M6a)

- **Jev** (TypeSafe AI, `https://api.typesafe.ai/v1/systemone`): a proprietary cloud API under TypeSafe's API terms,
  reached over HTTPS by `ChirpEngineJev` with the user's own key. A network service only: no SDK or TypeSafe code is
  linked, so there is no license interaction with GPL-3.0; the wire types are a port of MacParakeet's GPL-3.0
  `JevDecisionClient.swift`. Opt-in, off by default, and never sent clinical items ([ADR-013](spec/adr/013-jev-decision-model.md)).

## Ingest (M5): methods, system frameworks and remote services

M5 adds **no Swift package dependency**. DOCX files are unzipped by ChirpIngest's own Foundation-based
`ZipArchiveReader` instead of ZIPFoundation.

- **youtube-transcript-api** (MIT, <https://github.com/jdepoix/youtube-transcript-api>): the caption-fetching method
  (watch page → `INNERTUBE_API_KEY` → `/youtubei/v1/player` as the ANDROID client → caption `baseUrl`) is re-implemented
  in Swift in `ChirpIngest/Links/YouTubeCaptionFetcher.swift`. No code is copied; credited here and in the file header.
- **PDFKit, Vision** (`RecognizeDocumentsRequest`, `RecognizeTextRequest`), **CoreGraphics** and
  `NSAttributedString` RTF import: Apple system frameworks, not redistributed; used on device for document text.
- **Remote services reached on the person's tap only** (no content sent, only the link or ids from it): the iTunes
  Lookup API (`itunes.apple.com/lookup`), podcast RSS feeds and audio hosts, and YouTube (watch page, player API,
  caption track). YouTube's terms forbid automated access; see the owner decision recorded in plan 014.

## Models downloaded at run time (not in the repo or the app bundle)

The app downloads these from Hugging Face the first time the user asks for them in Settings. They are stored in the
app's container and excluded from device backups.

### NVIDIA Parakeet TDT 0.6B v3 and v2 (Core ML conversions by FluidInference)

- License: CC-BY-4.0 (NVIDIA model cards). Attribution: NVIDIA.
- Sources: <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>, <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2>
  and the FluidInference Core ML repositories that FluidAudio resolves.
- Used for: speech-to-text (v3 multilingual default; v2 English-only option).

### Speaker diarization models (pyannote segmentation, WeSpeaker embeddings, VBx clustering)

- License: per each model card on Hugging Face, **verify before distributing**.
- Source: the FluidInference diarization repositories that FluidAudio 0.16.1 pins to a fixed revision.
- Used for: "Speaker 1 / Speaker 2" labels on transcripts.

## The Mac companion (`companion/`, runs on the owner's Mac; not linked into the app)

A Python service the owner runs with `scripts/companion.sh` (plan 019, [ADR-014](spec/adr/014-mac-companion.md)).
Versions are pinned in `companion/uv.lock`; nothing here ships in the IPA. All licenses below are GPL-3.0-compatible
(checked from each installed package's metadata, 2026-09-22).

| Component | License | Used for |
|---|---|---|
| FastAPI (with Starlette, Pydantic) | MIT (Starlette BSD-3-Clause, Pydantic MIT) | The HTTP API |
| uvicorn | BSD-3-Clause | The HTTP server |
| mlx-audio | MIT | Speech synthesis on Apple silicon (pulls MLX, MIT; transformers and huggingface_hub, Apache-2.0; NumPy and SciPy, BSD) |
| yt-dlp (`default` extra) | Unlicense (yt-dlp-ejs: Unlicense AND MIT AND ISC; mutagen GPL-2.0-or-later; pycryptodomex BSD / public domain) | YouTube audio for videos without captions |
| misaki (optional `kokoro` extra) | Apache-2.0 | Kokoro-82M's phonemizer |
| ffmpeg (Homebrew, run as a separate program, not linked) | LGPL/GPL per its build | MP3 encoding |

Models the companion downloads once into the Hugging Face cache (`scripts/companion.sh --download <model>`):

| Model | License | Source |
|---|---|---|
| Qwen3-TTS 12Hz 1.7B / 0.6B CustomVoice (8-bit MLX) | Apache-2.0 | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit`, `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit` (Alibaba Qwen) |
| Kokoro-82M (MLX bf16) | Apache-2.0 | `mlx-community/Kokoro-82M-bf16` (hexgrad) |

YouTube's terms forbid automated download; the owner accepts that for personal use (ADR-014).

## Planned plug-ins (not linked today)

These are recorded so their license verdicts are not rediscovered each time. Each lands with its own ADR.

| Component | License | Verdict |
|---|---|---|
| Cactus engine | Custom source-available license with company-size limits | Not GPL-compatible for distribution: opt-in personal builds only ([ADR-010](spec/adr/010-plugin-license-gate.md)) |
| Needle 3 (`libneedle.a` runtime) | Weights Apache-2.0; runtime binary-only | Personal builds only ([ADR-010](spec/adr/010-plugin-license-gate.md)) |
| AnyLanguageModel | Apache-2.0 | Compatible, **evaluated and not linked** (ADR-011: 0.9.0 pulls 8 packages incl. swift-nio and swift-syntax; its Ollama adapter omits `num_ctx`) |
| WhisperKit (`argmax-oss-swift`) | MIT | Compatible |
| MLX Swift, llama.cpp | MIT | Compatible |
