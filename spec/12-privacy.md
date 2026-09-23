# 12 - Privacy

> Status: ACTIVE — privacy classes, the routing rule, every network surface, PHI rules for code and repo, and key
> storage. Decision: [ADR-002](adr/002-local-first-and-privacy-classes.md).

## The promise

Audio and transcripts stay on the iPhone. There is no account and no iChirp server. Anything that uses the network
is a named, user-visible surface in the table below; adding a new one means adding a row here in the same commit.

## Privacy classes

Every `Transcription` (and later every document and deliverable) carries a `PrivacyClass`:

| Class | Meaning | Default for |
|---|---|---|
| `general` | Nothing sensitive (a public podcast, a lecture) | Nothing automatically; user choice |
| `personal` | Private but not clinical | **Every new item** |
| `clinical` | Contains or may contain PHI (protected health information): patient encounters, SOAP notes, anything with a patient identifier | SOAP-note deliverables (M4); user choice |

The class is shown on the item and can be changed by the user. Deliverables inherit the class of their source.

## The routing rule (`PrivacyRoutingPolicy`)

Before any engine processes an item, the caller asks
`PrivacyRoutingPolicy.allows(descriptor, for: privacyClass, host:, userOverride:)`:

| Engine locality | `general` / `personal` | `clinical` |
|---|---|---|
| `onDevice` | allowed | allowed |
| `localNetwork` (e.g. Ollama on the owner's Mac) | allowed | allowed only if the host is in the user's trusted list, or with a per-run override |
| `cloud` | allowed (the user configured the provider) | **only with an explicit per-run override** |

- An override is a deliberate, per-run confirmation ("Send this clinical transcript to <provider>?"), never a
  remembered setting. The app logs that an override happened (engine, time, item id; host private) and records it in
  the run ledger (`llm_runs.privacyOverride`), **never the content**. In code it is a `PrivacyOverride` token that
  only `DeliverableService.confirmOverride` mints, bound to one transcript, engine, host, locality and class, used
  once, valid 10 minutes (M4).
- **Locality is derived, not chosen.** A language provider is `localNetwork` only when its host is a LAN name or
  address (`.local`, `.home.arpa`, `.internal`, `.lan`, private or link-local IP); anything else is `cloud`, and a
  cloud host can never be trusted. Cloud providers must use HTTPS. The HTTP engine refuses every redirect, so a
  trusted LAN host cannot forward a clinical request elsewhere, and keeps no URL cache.
- **One effective class per transcript.** Every router uses `EffectivePrivacyClass`: the stricter of the
  transcript's own class and the class of every deliverable made from it. A personal transcript that already has a
  clinical deliverable (a SOAP note) is routed as clinical by Transform, Ask, Jev and Listen. Lowering the
  transcript's class does not lower it while that deliverable exists (deliverables are never lowered).
- **Routing is re-checked before every model call** of a run (long transcripts make several), against the effective
  class stored at that moment and the trust settings as they are then. Running the SOAP note template routes as
  clinical.
- **Jev is cloud-only** and, in M6a, **never receives a clinical item, not even with a per-run override**
  (`DecisionService` refuses it before reading the key and writes a `refused` ledger row, and checks the effective
  class again just before sending; [ADR-013](adr/013-jev-decision-model.md)).
- Speech engines follow the same rule. Every speech engine planned through M8 is on-device.
- **Voices (plan 020)** follow the same rule, in `VoicePlayer`, before the first chunk, every later chunk and every
  retry of a reading, with the item's effective class **as stored at that moment** (marking a transcript clinical
  while it is read, or making a clinical deliverable from it, counts at the next chunk; a reading's class only
  rises): clinical text may go to the Mac companion only when the owner marked that Mac trusted in Settings → Mac
  companion (hosts trusted for language models in Settings → Models do not count for voices); Grok voices (xAI,
  cloud) and an untrusted Mac need the per-reading confirmation "Read this clinical text aloud with <voice>?", whose
  Read aloud button is the only caller of `VoicePlayer.confirmPendingSpeech(requestID:)` (enforced by
  `AppTests/VoiceListenTests`) and confirms only the question it showed. When the class rises or the Mac loses its
  trust mid-reading, the audio stops before the next chunk is sent and the question is asked again. A confirmation
  covers that reading's engine, locality, host and class only and is never remembered; declining sends nothing. The
  voice engines refuse every redirect, and one reading stays pinned to the companion address routing approved.

## Network surfaces

| Surface | When | What is sent | Milestone |
|---|---|---|---|
| Model downloads (Parakeet, diarizer) from Hugging Face | User taps Download in Settings (or the DEBUG smoke runner, or the DEBUG device benchmark `-ChirpBenchmarkDevice`, both started by the controller's scripts) | HTTP requests for model files; no user content | M1 |
| Podcast lookup and media downloads | User pastes a link and taps Transcribe, or taps Retry | Apple Podcasts: the show id to `itunes.apple.com/lookup` (and, for an older episode, a GET of the show's RSS feed); feeds: a GET of the feed; other web links: a HEAD (or one-byte GET) to learn the content type; then a GET of the audio/video file (with `Range` on a resume). A fixed `Parakeet/1.0` user agent; no cookies kept; **no user content** | M5 (built) |
| YouTube captions | User pastes a YouTube link and taps Transcribe | The video id: a GET of the watch page, a POST to YouTube's player API (`{"context": {"client": ANDROID}, "videoId": …}`), a GET of the caption track. A consent cookie only on that one retried request; nothing stored; **no user content** | M5 (built) |
| YouTube audio (through the Mac companion) | A video has no usable captions, a companion is set up, the user taps "Get the audio from your Mac" and confirms (once per link), or taps Retry (which asks again when the companion is not the Mac the link was confirmed for in this launch) | **Only the video's canonical link** `https://www.youtube.com/watch?v=<id>`, rebuilt from the validated id (share parameters such as `si=` and `list=` never leave the phone), to the companion on the owner's Mac (`POST /v1/youtube/audio`, Bearer pairing token, plain http on the home network, redirects refused); the Mac's yt-dlp fetches the audio from YouTube and streams it back; the Mac stores nothing and logs no link or title | Plan 019 (built) |
| Mac companion "Test connection" (Settings → Mac companion) | User taps Test connection | `GET /v1/companion` without the token, then `GET /v1/voices` with it (the saved token only to the saved address; a typed, unsaved address needs the token typed); home-network addresses only; **no user content** | Plan 019 (built) |
| Documents (PDF, text, RTF, HTML, DOCX) | User imports or shares a document | **Nothing leaves the iPhone**: PDFKit, Vision OCR and the text readers run on device; HTML images and styles are never fetched | M5 (built) |
| Cloud language models (Anthropic, OpenAI-compatible, Gemini) | User runs a template or Ask with a cloud provider | Transcript or document **text**, the template and any notes the user typed; **never audio** | M4 |
| Home-network providers (Ollama, LM Studio) | Same, with a LAN provider | Same, over the local network | M4 |
| Provider "Test connection" and model list (Settings → Models) | User taps Test or refreshes models | The API key in a header, a one-token "Hi" request, a model-list request; **no user content** | M4 |
| Apple Foundation Models | User runs a template or Ask with the on-device model | Nothing leaves the iPhone | M4 |
| Jev (TypeSafe AI, `api.typesafe.ai/v1/systemone`) | Jev is turned on in Settings → Models and the user picks Classify recording, Suggest a template or Tag paragraphs on a general or personal transcript | The API key in a header; **an excerpt of the transcript text of at most 3,000 characters** (cut back to a sentence end; for tags, the first paragraphs with their `p01`… ids under the same limit); the facts `duration_seconds`, `speaker_count`, `paragraph_count` and `source` (audio / document / link); the recipe's question texts and options; plus the request metadata URLSession adds to every request (`User-Agent` with the app's executable name and build number and the CFNetwork and Darwin versions, `Accept-Language` with the device's language list, `Accept-Encoding`), which is no content. **Never audio, titles, notes, or any clinical item** (override or not; a transcript with a clinical deliverable counts as clinical). Test connection sends only a fixed pangram. Key: Keychain account `structure.provider.jev.api-key` | M6a (built) |
| Grok voices (xAI text to speech) | User taps Listen, Test voice or turns on Speak answers with Grok voices chosen | The text being read, in chunks (≤ 2 500 characters), with the voice id, to `POST https://api.x.ai/v1/tts` (Bearer key); **never audio**; clinical text only after the per-reading confirmation. Check key: `GET /v1/api-key`, no text | Plan 020 (built) |
| Mac companion voices | Same, with the Mac companion chosen | The text being read, in chunks, to the owner's Mac over the home network (`POST /v1/audio/speech`, pairing token; plain http, so an address that is not on the home network is refused before anything is sent, the health check included); `GET /v1/companion` (no token, no text) for status, `GET /v1/voices` for the voice list. The companion stores nothing ([mac-companion-v1](contracts/mac-companion-v1.md)) | Plan 020 (built) |
| Apple Speech model (iOS `AssetInventory`) | User taps Download on Apple Speech in Settings → Speech engines (or the DEBUG device benchmark, only once Speech Recognition is already allowed) | iOS downloads its own speech model for the device's language from Apple and reserves it for Parakeet; Parakeet sends nothing. Transcription then runs in iOS's on-device speech service: **no audio or text leaves the iPhone**. iOS asks once for Speech Recognition permission, only from that Download tap (never mid-job) | M7 (built) |
| WhisperKit model download from Hugging Face | User taps Download on a Whisper engine in Settings → Speech engines (or the DEBUG device benchmark `-ChirpBenchmarkDevice`) | The Core ML model files from `argmaxinc/whisperkit-coreml` and the tokenizer files from `openai/whisper-*`: file-list and file requests only, **no user content**. Transcription then runs on the iPhone | M7 (built) |
| Needle 3 model download from Hugging Face | User taps Download in Settings → Structure models | A GET of the pinned `needle3.cact` (35 MB, SHA-256 checked); no user content | M6 (built) |
| Needle 3 and the STUB (structure models) | Extract fields, dictation voice commands, Eval | **Nothing leaves the iPhone**: both run on device; clinical items may only reach an `.onDevice` structure engine, and "Use in SOAP note" runs the SOAP template on the Apple on-device model | M6 (built) |
| Small language model downloads (Qwen3.5 2B, Qwen3 4B Instruct) from Hugging Face | User taps Download in Settings → Models → Small models on this iPhone | A GET of the pinned GGUF file (`huggingface.co/<repo>/resolve/<revision>/<file>`, 1.28 GB / 2.50 GB; Hugging Face redirects the file to its CDN), size and SHA-256 checked before it is kept; **no user content** | M7 (built) |
| Small language models on this iPhone (llama.cpp, `llamacpp.gguf`) | User runs a template or Ask with a downloaded small model | **Nothing leaves the iPhone**: the model runs in the app's process on the GPU (foreground only); clinical items may use it with no confirmation, still routed through `DeliverableService` ([ADR-015](adr/015-on-device-llm-llama-cpp.md)). llama.cpp's own log lines are dropped except errors, which are logged private; prompts are never logged | M7 (built) |

There is no telemetry and no crash reporting service. If one is ever proposed, it needs an ADR, an opt-in, and a
contract that proves no content or identifiers leave the device.

## Keys and secrets

- API keys live in the **Keychain** (never `UserDefaults`, never files, never logs). The Gemini port's plaintext
  `@AppStorage` key is a rejected pattern. M4: `ChirpKeychain.KeychainSecretStore`, service
  `com.aarzamen.ichirp.language-models`, one item per provider, `AfterFirstUnlockThisDeviceOnly`, never synced.
  Provider settings in `UserDefaults` hold no key (tested); in memory a key is a redacted `SecretValue`.
- The Mac companion's pairing token (plan 019) is a Keychain item too (the same service, account
  `companion.pairing-token`), sent only as `Authorization: Bearer` to the configured companion; its host, port and
  "trusted" flag sit in `UserDefaults` (`ichirp.companion`, tested to hold no token). The form never shows it again.
  The companion speaks plain http, so it must have a home-network address (`LocalNetworkHost.isLocal`): Settings
  refuses any other address, and `CompanionClient` and `CompanionVoice` refuse one saved earlier before any request,
  so neither the token nor text crosses the internet in the clear. The trust is judged by the address form (a
  `.local` name or a private IP), not by which Wi-Fi the Mac is on.
  "Trusted for clinical text" counts only for a home-network address (`CompanionEndpoint.isTrusted`) and feeds the
  routing policy for text sent to the companion (plan 020's voices); M4's language-model routing is unchanged.
- Settings → Models never loads a stored key into the form: the key field says "Stored in the Keychain" and a blank
  field keeps it. The app-hosted `KeychainSecretStoreAppTests` checks the real iOS Keychain item is
  this-device-only and never synchronizable (it needs a signed host; unsigned `CODE_SIGNING_ALLOWED=NO` runs skip it).
- **Voices (plan 020):** the xAI key is a Keychain item (account `voice.xai.api-key`, same service); Settings → Voices
  never shows it back. Voice ids the owner types (a cloned xAI voice) are settings on the device (`UserDefaults`
  `ichirp.voiceSettings`) and never in the repository. Synthesized audio lives only in `tmp/speech-<utterance id>/`,
  deleted chunk by chunk as it plays and on stop, and swept at launch; nothing is stored in the database. Logs carry the
  source kind, engine id, class, counts and `SpeechSynthesisError.kindName`, never text.
- Provider error text is scrubbed of key artifacts; it can still echo prompt text, so it is shown to the user but
  never logged or stored (logs and the ledger carry `LanguageModelError.kindName`).
- The Apple Developer team id may appear in `Config/Signing.local.xcconfig.example` while the repo is private.
  Certificates, `.p12`, `.p8`, `.mobileprovision` and keychains never enter the repo.

## PHI rules for code, tests and the repo

- **No real recordings, transcripts or patient data in the repo**, including "anonymized" ones. All fixtures are
  synthetic (`say`).
- **Logs never contain transcript text, prompts, generated documents, or user file names.** Log ids, stages,
  durations, sizes and error types.
- Debugging with real audio happens on the owner's phone with their own data; nothing from it is copied into the repo,
  issues, or chat transcripts.
- Exports and shares are user actions; the app never shares automatically. Copy of a transcript or a generated
  document is local-only (`UIPasteboard` `.localOnly`), so it never reaches Universal Clipboard.
- The clinical confirmation (M4) is shown per run, titled "Send this clinical transcript to <provider>?"; only its
  Send button mints the override (enforced by `AppTests/ClinicalConfirmationTests`). Lowering a transcript from
  Clinical asks first. The first contact with a Mac shows iOS's local-network prompt (`NSLocalNetworkUsageDescription`);
  App Transport Security allows plain http only to local hosts (`NSAllowsLocalNetworking`).
- Clinical output from language or structure models is a draft; numbers (doses, dates, durations) are re-validated
  in code and the clinician reviews before use.

## On-device storage

- The database and media live in the app's Application Support folder under iOS Data Protection's default class
  (files are unreadable until the phone is first unlocked after a restart), and are included in device backups.
  A stricter class for clinical items is an M3/M4 decision (it would stop background work while locked).
- Deleting a transcript removes its row and its `media/<id>/` folder.
- Downloaded models are excluded from backups because they can be downloaded again.
