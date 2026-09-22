# ADR-010: License Gate for Plug-ins That Conflict with GPL-3.0

> Status: Accepted
> Date: 2026-09-22
> Related: [ADR-001](001-port-with-pinned-upstream-reference.md), [ADR-004](004-engine-plugin-architecture.md),
> [`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md),
> [Cactus/Needle/Jev research](../../docs/research/2026-09-22-cactus-needle-jev.md)

## Context

iChirp is GPL-3.0 because it derives from MacParakeet. The owner wants plug-and-play engines, and some candidates
cannot be combined with GPL-3.0 in a distributed build (this is an engineering reading, not legal advice):

- **Cactus** (engine): a custom source-available license that restricts use by company size and revenue. The
  extra restrictions conflict with GPL-3.0's terms for distribution.
- **Needle 3**: Apache-2.0 weights, but the `libneedle.a` runtime is a binary-only static library; GPL-3.0 requires
  corresponding source for what is distributed.

Upstream MacParakeet uses the same shape for its MLX runtime: an opt-in build flag
(`MACPARAKEET_ENABLE_MLX_LOCAL_LLM=1`) keeps it out of default builds. Cloud APIs such as Jev are not linked, so they
raise a privacy question (handled by [ADR-002](002-local-first-and-privacy-classes.md)), not a licensing one.

## Decision

- A plug-in whose license or binary-only runtime conflicts with GPL-3.0 is **compiled only when its build flag is
  set**: `CHIRP_ENABLE_<PLUGIN>=1` (for example `CHIRP_ENABLE_NEEDLE=1`, `CHIRP_ENABLE_CACTUS=1`). The flag adds the
  engine target and its registration line; without it, the code and binary are not in the build.
- Such plug-ins are **off by default** and allowed **only in personal builds** installed on the owner's own
  devices. They are **never** included in a distributed IPA (SideStore, TestFlight or otherwise). The commit that
  adds the first gate flag also makes `scripts/build_ipa.sh` refuse to package while any gate flag is set.
- Each plug-in's ADR records its license verdict, and `THIRD_PARTY_LICENSES.md` lists it.
- A license-compatible alternative is always preferred when one exists (e.g. llama.cpp or MLX instead of Cactus).

## Alternatives considered

- **Exclude these plug-ins entirely.** Rejected: the owner explicitly wants Needle and Cactus available for personal
  use.
- **Relicense iChirp.** Not possible: a GPL-3.0 derivative cannot be relicensed without the copyright holders.
- **Ship them and hope.** Rejected: a license violation in a distributed build.

## Consequences

- Plug-in code must be fully isolated in its own `ChirpEngine<Provider>` target so the gate is a clean on/off.
- Features built on a gated plug-in need a working fallback (an ungated engine or a "not available in this build"
  state), and the UI must say which.
- CI builds the default (ungated) configuration only.
