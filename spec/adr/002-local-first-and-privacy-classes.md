# ADR-002: Local-First Processing with Privacy Classes and a Routing Rule

> Status: Accepted
> Date: 2026-09-22
> Related: [spec/12-privacy.md](../12-privacy.md), [ADR-004](004-engine-plugin-architecture.md), upstream
> MacParakeet ADR-002 (local-first)

## Context

The owner is a physician. Some of what they record is clinical: encounters, handoffs, SOAP notes. That is PHI
(protected health information) and must not reach a third-party server by accident. At the same time, the end goal
asks for plug-and-play engines, including cloud language models and cloud decision models (Jev), which are useful
for non-clinical work.

MacParakeet's rule is "local processing with optional, explicit external AI surfaces; audio never leaves the
device". iChirp needs that plus a finer rule, because one app will hold both a public podcast and a patient note.

## Decision

- **Local-first.** Capture, speech recognition, diarization, text processing, storage and search run on the iPhone.
  Every network use is a named surface in [`spec/12-privacy.md`](../12-privacy.md).
- **Every item has a `PrivacyClass`**: `general`, `personal` (the default for new items) or `clinical`.
  Deliverables inherit their source's class.
- **Every engine declares an `EngineLocality`**: `onDevice`, `localNetwork` or `cloud`.
- **The routing rule** (`ChirpCore.PrivacyRoutingPolicy.allows`):
  - `general` and `personal`: any locality.
  - `clinical`: `onDevice` always; `localNetwork` only for a host the user marked trusted, or with a per-run
    override; `cloud` only with an explicit per-run override.
- An override is a per-run confirmation, never a remembered setting, and is logged without content.
- Jev is cloud-only, so it never sees clinical content by default.
- Logs never contain transcript text, prompts, documents or user file names. API keys live in the Keychain.

## Alternatives considered

- **On-device only, no cloud at all.** Rejected: the owner wants cloud and home-network models for non-clinical
  deliverables, and a trusted Mac on the LAN is a strong private option.
- **A global "cloud allowed" switch.** Rejected: one switch cannot express "cloud is fine for this podcast but never
  for that patient note".
- **Automatic PHI detection to set the class.** Deferred: detection can miss; the default is `personal` and the
  user marks clinical items. A structure model may *suggest* `clinical` in M6, never downgrade it.

## Consequences

- Every language, structure or speech call site must pass the item's class through the router; tests pin the
  policy (`PrivacyRoutingPolicyTests`).
- UI must show the class and ask before a clinical override.
- Adding a network surface requires a row in the privacy spec in the same commit.
