# ADR-014: The Parakeet Companion on the Owner's Mac

> Status: Accepted
> Date: 2026-09-22
> Related: [ADR-002](002-local-first-and-privacy-classes.md), [mac-companion-v1](../contracts/mac-companion-v1.md),
> [plan 019](../../docs/plans/2026-09-22-019-mac-companion-and-m5-finish.md), [plan 020](../../docs/plans/2026-09-22-020-voice-output.md)

## Context

Two things the owner wants are better done on their Mac than on the phone: speech in their local voices (ChoiceVoice
runs Qwen3-TTS and Kokoro through mlx-audio on Apple silicon) and YouTube audio for videos without captions (yt-dlp is
maintained daily; on-phone downloaders break every few weeks). The owner's Mac is already a trusted home-network
engine for language models (Ollama or LM Studio, M4).

## Decision

- A small Python service, the **Parakeet companion** (`companion/`, uv, FastAPI), runs on the Mac and serves the
  [mac-companion-v1](../contracts/mac-companion-v1.md) API: speech (OpenAI speech shape, via mlx-audio) and YouTube
  audio (via yt-dlp), plus a health endpoint.
- Pairing uses a random bearer token generated on the Mac and entered once on the phone (Keychain).
- The phone treats the companion as a `localNetwork` engine: clinical text needs the owner's "trusted" mark on that
  host; links are confirmed once per link before leaving the phone.
- **Home network only (review round 1, 2026-09-22).** The companion speaks plain http, so the phone refuses an
  address that is not a home-network name or address (`LocalNetworkHost.isLocal`) before sending the token or
  anything else. "Home network" and "trusted" are judged by the address form (a `.local` name, a private or
  link-local IP), not by which Wi-Fi the Mac is on: a MacBook on a café or hospital network is still reached as
  `my-mac.local`. The companion's banner says it listens on every network the Mac joins and suggests
  `--host <home IP>`. Tailscale (100.64/10, encrypted) would be an explicit, separate exception if it is ever wanted.
- The companion stores nothing it receives and logs no content.
- App Store review is not a constraint (Parakeet is never submitted, owner, 2026-09-22); YouTube's terms still forbid
  automated download, which the owner accepts for personal use.

## Alternatives considered

- **Point the phone at mlx-audio's own server directly.** Works for speech but adds no auth and no YouTube; one
  companion gives one host, one token and one trust decision.
- **YouTubeKit on the phone.** Kept as a possible later addition for use away from home.
- **Change the ChoiceVoice app.** Not needed: the companion reuses the same model weights through mlx-audio.

## Consequences

- Speech in the owner's voices and YouTube audio need the Mac awake on the same network; the app says so when it is
  not reachable.
- The companion is new code with a network surface: its tests cover auth, input limits and no-content logging.
