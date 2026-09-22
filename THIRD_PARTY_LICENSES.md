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

## Planned plug-ins (not linked today)

These are recorded so their license verdicts are not rediscovered each time. Each lands with its own ADR.

| Component | License | Verdict |
|---|---|---|
| Cactus engine | Custom source-available license with company-size limits | Not GPL-compatible for distribution: opt-in personal builds only ([ADR-010](spec/adr/010-plugin-license-gate.md)) |
| Needle 3 (`libneedle.a` runtime) | Weights Apache-2.0; runtime binary-only | Personal builds only ([ADR-010](spec/adr/010-plugin-license-gate.md)) |
| Jev | Proprietary cloud API | No linking issue; privacy router keeps clinical content away |
| AnyLanguageModel | Apache-2.0 | Compatible |
| WhisperKit (`argmax-oss-swift`) | MIT | Compatible |
| MLX Swift, llama.cpp | MIT | Compatible |
