# ChirpEngineVoiceHTTP

Text-to-speech engines reached over HTTP (plan 020): **Grok voices** on xAI (`XAIVoice`, cloud) and the owner's
voices on the **Mac companion** (`CompanionVoice`, home network). Both conform to ChirpCore's `SpeechSynthesizing`
(contract [`speech-synthesis-plugin-v1`](../../../spec/contracts/speech-synthesis-plugin-v1.md)). The wire code is
ported from the owner's macOS read-aloud app **Readback** (`~/readback`, `Sources/TTS/`), with the provenance header
`// Ported from Readback (owner's project): <path> @ <sha>`. Depends on ChirpCore only.

## Entry point

`VoiceEngines.swift`: `VoiceEngines.makeXAI(secrets:)`, `VoiceEngines.makeCompanion(configuration:)` and
`VoiceEngines.validateXAIKey(secrets:)` are what the app calls. Then read `VoiceHTTPTransport.swift`.

## What's here

- `VoiceHTTPTransport.swift`: one ephemeral, cache-free, cookie-free `URLSession`; a task delegate that refuses
  every redirect (`SpeechSynthesisError.redirectRefused`); `VoiceHTTPErrors` maps HTTP statuses onto
  `SpeechSynthesisError`, reads the provider's message from the usual JSON shapes and scrubs the key (and anything
  key-shaped) out of it.
- `XAIVoice.swift`: `POST https://api.x.ai/v1/tts` (Bearer key from `SecretStoring`, account
  `voice.xai.api-key`), mp3 44.1 kHz 128 kbps, stock voices eve/ara/rex/sal/leo, `validateKey()` via
  `GET /v1/api-key`, `availability()` = a key is stored (no network).
- `CompanionVoice.swift`: the OpenAI speech shape (ported from Readback's `OpenAIProvider`) to the Mac companion
  (`POST /v1/audio/speech`, `GET /v1/voices`, [mac-companion-v1](../../../spec/contracts/mac-companion-v1.md)):
  address and pairing token from ChirpCore's `CompanionConfiguration`; voice ids `model:Name` are split into
  `model` and `voice`; `style` → `instructions`; WAV requested, the Content-Type decides the format; 400 unknown
  voice → `unsupportedVoice`, 413 and 503 → `server` with the companion's sentence. `availability()` caches
  `GET /v1/companion` (no token) for 30 s. Locality follows the host (`CompanionEndpoint.locality`). `pinned()`
  binds one utterance to the address and token as they are now.
- `VoiceEngines.swift`: the registration entry point.

## What to know before editing

- **No voice id or key in the repository.** Readback hard-codes the owner's cloned xAI voice; this port does not.
  The phone has a free-text Voice ID field (stored in settings on the device). The repo is public.
- **Engines do not route.** `PrivacyRoutingPolicy` runs before every call in ChirpFeatures (`VoicePlayer`); clinical
  text reaches `XAIVoice` only after the per-utterance confirmation.
- **Never follow redirects, never cache**, never log a request, header, body or provider message. Log the engine
  id, counts and `SpeechSynthesisError.kindName` only; associated strings may echo text and are for the screen.
- **One utterance, one host.** `VoicePlayer` speaks through `CompanionVoice.pinned()`, so changing Settings → Mac
  companion mid-utterance cannot redirect the rest of the text; routing still re-checks the host before every chunk.
- **Callers chunk.** `maxCharactersPerRequest` is the hard limit; an overlong request throws before sending.

## How to verify

```bash
cd /Users/ama/Documents/GitHub/iChirp
swift test --package-path ChirpKit --filter ChirpEngineVoiceHTTPTests
```

The tests use a `URLProtocol` stub (`StubURLProtocol`), so nothing leaves the Mac.
