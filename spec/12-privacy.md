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
- **Routing is re-checked before every model call** of a run (long transcripts make several), against the class
  stored at that moment and the trust settings as they are then. Running the SOAP note template routes as clinical.
- **Jev is cloud-only**, so it never sees clinical content unless the user overrides a single run.
- Speech engines follow the same rule. Every speech engine planned through M8 is on-device.

## Network surfaces

| Surface | When | What is sent | Milestone |
|---|---|---|---|
| Model downloads (Parakeet, diarizer) from Hugging Face | User taps Download in Settings (or the DEBUG smoke runner) | HTTP requests for model files; no user content | M1 |
| Podcast lookup and media downloads | User pastes a link | The link / show id; no user content | M5 |
| YouTube captions or audio | User pastes a YouTube link | Requests to YouTube; no user content | M5 |
| Cloud language models (Anthropic, OpenAI-compatible, Gemini) | User runs a template or Ask with a cloud provider | Transcript or document **text**, the template and any notes the user typed; **never audio** | M4 |
| Home-network providers (Ollama, LM Studio) | Same, with a LAN provider | Same, over the local network | M4 |
| Provider "Test connection" and model list (Settings → Models) | User taps Test or refreshes models | The API key in a header, a one-token "Hi" request, a model-list request; **no user content** | M4 |
| Apple Foundation Models | User runs a template or Ask with the on-device model | Nothing leaves the iPhone | M4 |
| Jev | User opts in | Short text for a decision; never clinical by default | M6 |

There is no telemetry and no crash reporting service. If one is ever proposed, it needs an ADR, an opt-in, and a
contract that proves no content or identifiers leave the device.

## Keys and secrets

- API keys live in the **Keychain** (never `UserDefaults`, never files, never logs). The Gemini port's plaintext
  `@AppStorage` key is a rejected pattern. M4: `ChirpKeychain.KeychainSecretStore`, service
  `com.aarzamen.ichirp.language-models`, one item per provider, `AfterFirstUnlockThisDeviceOnly`, never synced.
  Provider settings in `UserDefaults` hold no key (tested); in memory a key is a redacted `SecretValue`.
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
- Exports and shares are user actions; the app never shares automatically.
- Clinical output from language or structure models is a draft; numbers (doses, dates, durations) are re-validated
  in code and the clinician reviews before use.

## On-device storage

- The database and media live in the app's Application Support folder under iOS Data Protection's default class
  (files are unreadable until the phone is first unlocked after a restart), and are included in device backups.
  A stricter class for clinical items is an M3/M4 decision (it would stop background work while locked).
- Deleting a transcript removes its row and its `media/<id>/` folder.
- Downloaded models are excluded from backups because they can be downloaded again.
