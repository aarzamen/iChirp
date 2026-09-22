---
title: Cactus, Needle, Jev (and Laya) for iChirp
date: 2026-09-22
status: RESEARCH SNAPSHOT (owner-supplied report, condensed to what iChirp needs, cross-checked by the on-device-runtimes research; verify before relying)
---

# Cactus, Needle, Jev (and Laya)

The owner asked for plug-and-play "miscellaneous models like JEV, Cactus, needle". All three are real mid-to-late 2026
releases.

## What each one is

| Name | What it is | Runs where | License | iOS path |
|---|---|---|---|---|
| **Cactus** (Cactus Compute) | C++ on-device inference engine (`.cact` format, CPU and Metal backends) for LLMs, VLMs and STT (Whisper, Parakeet, Moonshine) | On device | **Custom, source-available.** Free for individuals and companies under $2M in funding and revenue; everyone else needs a commercial license. **Not GPL-3.0 compatible for distribution.** | Build it yourself (`cactus build --apple`) into an XCFramework with a JSON-in/JSON-out C API. The community wrapper `mhayes853/swift-cactus` is MIT but bundles an older engine. |
| **Needle 3** (Cactus Compute, 2026-09-17/18) | Tiny laddered model, 8–35 MB, 2-bit. **Tool calling, structured extraction (grammar-constrained JSON) and embeddings**; every result has a calibrated confidence. Not a chat model. | On device, CPU | Weights Apache-2.0. The `libneedle.a` runtime is **binary-only** | Hugging Face `Cactus-Compute/needle3` ships `ios-arm64` and `ios-sim-arm64` `libneedle.a` plus `needle.h`. The C API is `needle_load`/`init`/`complete`/`embed`/`reset`: one model per process, not thread-safe, so call it from a single actor. Wrap it as an XCFramework. Cactus is not needed. |
| **Jev** (TypeSafe AI, 2026-09-15) | Non-autoregressive "System One" typed-decision model: choice, score and yes/no probabilities with confidence, in one pass | **Cloud API only.** No weights, no on-prem | Proprietary | HTTPS only (TypeSafe API, Cloudflare Workers AI, OpenRouter) |
| **Laya** (Convai, 2026-09-18) | Open alternative to Jev: ModernBERT-large (~421M) plus a decision head | Local (PyTorch; community ONNX/MLX ports) | Apache-2.0 | No native iOS runtime yet; needs Core ML or ONNX conversion |

## Community reality check

- **Needle's base model struggles with indirect phrasing.**
  - Documented failures include "25 minute timer" becoming 25 *seconds*, and "my car crashed I need help" becoming `play_music`.
  - One independent rerun had fine-tuned FunctionGemma at about 85–91% versus fine-tuned Needle 3 at about 20–32% on the same task.
  - **In practice: fine-tune it, keep the tool or schema small, gate on confidence, and re-validate every number in code.**
- **Jev is fast and cheap.**
  - Medians around 0.3 s were reported.
  - Confidence-gated cascades matched frontier accuracy at about a quarter of the cost.
  - It is overconfident before calibration.
  - "Can't hallucinate" only means it can't emit values outside your schema. It can still be confidently wrong.

## Where they fit in iChirp (M6, Structure models)

| Use | Candidate | Rule |
|---|---|---|
| Extracting typed fields from a transcript (SOAP sections, action items, agenda items, dates, meds, doses) | Needle 3 (on device) → escalate to an LLM when confidence is low | Numeric fields are re-parsed and validated in code, and clinical output is always reviewed by the user |
| Voice-command routing in dictation ("new paragraph", "make this a list") | Needle 3 tool calling with ≤ 10 tools | Low stakes, a good first place to learn Needle fine-tuning |
| Library semantic search and Ask retrieval | Needle embeddings (lightweight), later a stronger Core ML embedder | Benchmark against lexical FTS before adopting |
| Choosing a template, classifying the kind of recording | Jev (cloud, opt-in) or Laya (local, after conversion) | **Jev may never receive `.clinical` content** (privacy router, ADR-002) |

## License gate (ADR-010)

iChirp is GPL-3.0. Cactus's engine license and Needle's binary-only runtime cannot ship in a distributed GPL build. Both
are allowed only behind an opt-in build flag, in personal builds. Jev is an HTTPS provider, so it has no linking issue; the
issue is privacy, and the router handles that.
