# Speech Synthesis Plug-in v1

> Status: ACTIVE (contract committed with the design in plan 018; conformers land in plan 020).
> Code: `ChirpKit/Sources/ChirpCore/Engines/SpeechSynthesis.swift`.
> Semantics from Readback (the owner's macOS read-aloud app), `Sources/TTS/TTSProvider.swift`.

## Purpose

Turn text into speech ("Listen", spoken Ask answers, dictation read-back) with a plug-in engine that runs on the
owner's Mac (the Parakeet companion) or in the cloud (xAI). Engine kind `EngineKind.speechSynthesis`.

## The protocol

```swift
public protocol SpeechSynthesizing: Sendable {
    var descriptor: EngineDescriptor { get }        // kind .speechSynthesis, locality .localNetwork or .cloud
    var endpointHost: String? { get }               // routing input; nil only for an on-device engine
    var maxCharactersPerRequest: Int { get }        // callers chunk above it
    func availability() async -> SpeechSynthesisAvailability
    func voices() async throws -> [SynthesisVoice]
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio
}
```

`SynthesisRequest` carries `text` (one chunk), `voiceID`, optional `style` and `language`, optional
`previousText`/`nextText` for prosody smoothing (never spoken), and `privacyClass`. `SynthesizedAudio` is the encoded
chunk (`mp3`, `wav` or `aac`).

## Rules

1. **Routing before sending.** The caller checks `PrivacyRoutingPolicy.allows(descriptor, for: privacyClass, host:
   endpointHost, userOverride:)` before every call. Clinical text may go to a companion the user marked trusted; a
   cloud voice needs the per-run confirmation M4 uses (`PrivacyOverrideRequest` pattern), never a remembered one.
2. **Only the configured host.** Engines refuse redirects (`SpeechSynthesisError.redirectRefused`).
3. **Keys and voice ids.** API keys live in the Keychain only. Voice ids the user types (for example a cloned voice)
   are stored in settings on the device and never committed to the repository.
4. **No content in logs or the database.** Log engine id, character count, chunk count, duration and
   `SpeechSynthesisError.kindName`. Audio is cached under `tmp/speech-<hash>/` and may be deleted at any time.
5. **Chunking is the caller's job.** Split on sentence boundaries under `maxCharactersPerRequest`; pass the
   neighbouring sentences as `previousText`/`nextText` when the engine uses them.
6. **Honest availability.** `availability()` is cheap (a cached health check, no synthesis) and its `.unavailable`
   sentence is shown as is.

## Conformers (plan 020)

| Engine id | Class | Locality | Transport |
|---|---|---|---|
| `companion.speech` | `CompanionVoice` | localNetwork | `POST /v1/audio/speech` on the companion ([mac-companion-v1](mac-companion-v1.md)) |
| `xai.tts` | `XAIVoice` | cloud | `POST https://api.x.ai/v1/tts`, Bearer key; `GET /v1/api-key` validates |

## Changes

- v1 (2026-09-22): initial.
