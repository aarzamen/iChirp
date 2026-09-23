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
- **Voices (plan 020)** follow the same rule, in `VoicePlayer`, before the first and every later chunk of a reading:
  clinical text may go to the Mac companion only when the owner marked that Mac trusted (and its address is on the
  home network: `CompanionEndpoint.locality` makes any other address `cloud`); Grok voices (xAI, cloud) and an
  untrusted Mac need the per-reading confirmation "Read this clinical text aloud with <voice>?", whose Read aloud
  button is the only caller of `VoicePlayer.confirmPendingSpeech()` (enforced by `AppTests/VoiceListenTests`). It
  covers that reading's engine, locality and host only and is never remembered; declining sends nothing. The voice
  engines refuse every redirect, and one reading stays pinned to the companion address routing approved.

## Network surfaces

| Surface | When | What is sent | Milestone |
|---|---|---|---|
| Model downloads (Parakeet, diarizer) from Hugging Face | User taps Download in Settings (or the DEBUG smoke runner) | HTTP requests for model files; no user content | M1 |
| Podcast lookup and media downloads | User pastes a link and taps Transcribe, or taps Retry | Apple Podcasts: the show id to `itunes.apple.com/lookup` (and, for an older episode, a GET of the show's RSS feed); feeds: a GET of the feed; other web links: a HEAD (or one-byte GET) to learn the content type; then a GET of the audio/video file (with `Range` on a resume). A fixed `Parakeet/1.0` user agent; no cookies kept; **no user content** | M5 (built) |
| YouTube captions | User pastes a YouTube link and taps Transcribe | The video id: a GET of the watch page, a POST to YouTube's player API (`{"context": {"client": ANDROID}, "videoId": …}`), a GET of the caption track. A consent cookie only on that one retried request; nothing stored; **no user content** | M5 (built) |
| YouTube audio (through the Mac companion) | A video has no usable captions, a companion is set up, the user taps "Get the audio from your Mac" and confirms (once per link), or taps Retry | **Only the link**, to the companion on the owner's Mac (`POST /v1/youtube/audio`, Bearer pairing token, plain http on the home network, redirects refused); the Mac's yt-dlp fetches the audio from YouTube and streams it back; the Mac stores nothing and logs no link or title | Plan 019 (built) |
| Mac companion "Test connection" (Settings → Mac companion) | User taps Test connection | `GET /v1/companion` without the token, then `GET /v1/voices` with it; **no user content** | Plan 019 (built) |
| Documents (PDF, text, RTF, HTML, DOCX) | User imports or shares a document | **Nothing leaves the iPhone**: PDFKit, Vision OCR and the text readers run on device; HTML images and styles are never fetched | M5 (built) |
| Cloud language models (Anthropic, OpenAI-compatible, Gemini) | User runs a template or Ask with a cloud provider | Transcript or document **text**, the template and any notes the user typed; **never audio** | M4 |
| Home-network providers (Ollama, LM Studio) | Same, with a LAN provider | Same, over the local network | M4 |
| Provider "Test connection" and model list (Settings → Models) | User taps Test or refreshes models | The API key in a header, a one-token "Hi" request, a model-list request; **no user content** | M4 |
| Apple Foundation Models | User runs a template or Ask with the on-device model | Nothing leaves the iPhone | M4 |
| Jev (TypeSafe AI, `api.typesafe.ai/v1/systemone`) | Jev is turned on in Settings → Models and the user picks Classify recording, Suggest a template or Tag paragraphs on a general or personal transcript | The API key in a header; **an excerpt of the transcript text of at most 3,000 characters** (cut back to a sentence end; for tags, the first paragraphs with their `p01`… ids under the same limit); the facts `duration_seconds`, `speaker_count`, `paragraph_count` and `source` (audio / document / link); the recipe's question texts and options. **Never audio, titles, notes, or any clinical item** (override or not). Test connection sends only a fixed pangram. Key: Keychain account `structure.provider.jev.api-key` | M6a (built) |
| Grok voices (xAI text to speech) | User taps Listen, Test voice or turns on Speak answers with Grok voices chosen | The text being read, in chunks (≤ 2 500 characters), with the voice id, to `POST https://api.x.ai/v1/tts` (Bearer key); **never audio**; clinical text only after the per-reading confirmation. Check key: `GET /v1/api-key`, no text | Plan 020 (built) |
| Mac companion voices | Same, with the Mac companion chosen | The text being read, in chunks, to the owner's Mac over the home network (`POST /v1/audio/speech`, pairing token); `GET /v1/companion` (no token, no text) for status, `GET /v1/voices` for the voice list. The companion stores nothing ([mac-companion-v1](contracts/mac-companion-v1.md)) | Plan 020 (built) |

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
