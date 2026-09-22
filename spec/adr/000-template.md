# ADR-NNN: Title in Sentence Case

> Status: Proposed | Accepted | Accepted (direction; phases land through their own plans) | Superseded by ADR-NNN | Historical
> Date: YYYY-MM-DD
> Related: `[ADR-NNN](NNN-slug.md)`, `[spec/NN-name.md](../NN-name.md)` (replace with real links)

<!--
How to use this template
- Copy to spec/adr/NNN-kebab-slug.md with the next free number; add a row to the ADR index in spec/README.md.
- Keep it to about one page. Link to specs and research instead of repeating them.
- Never delete history. To change a decision, append a dated section:
    ## YYYY-MM-DD amendment: <what changed>
  and add "> Amended: YYYY-MM-DD — <one line>" under the Date line.
- Put guardrails a future agent must not undo in the header (e.g. "> Guardrail: do not remove X as dead code").
-->

## Context

What forces are at play: the problem, the constraints (platform, license, privacy, the owner's devices), and the
evidence (measurements, research snapshots, upstream precedent). Two or three short paragraphs.

## Decision

What we will do, stated so an agent can check code against it. Use bullets for rules. Name the files, targets,
flags or contracts that carry the decision.

## Alternatives considered

- **Alternative A.** Why not: one or two sentences with the deciding reason.
- **Alternative B.** Why not.

## Consequences

- What becomes easier.
- What becomes harder, or what we accept as a cost.
- What must be kept true from now on (tests, contracts, docs that enforce it).
