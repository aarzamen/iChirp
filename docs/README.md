# Documentation map

Start with [`AGENTS.md`](../AGENTS.md) (commands, boundaries, rules) and the [spec index](../spec/README.md)
(decisions, milestones, release channels). This page maps everything else.

| Need | Read |
|---|---|
| Product direction and behavior | [Vision](../spec/00-vision.md), [features](../spec/02-features.md), [ADRs](../spec/README.md#architecture-decision-records) |
| Architecture, modules, data flow | [Architecture](../spec/03-architecture.md), module READMEs under `ChirpKit/Sources/<Module>/README.md` |
| Stored data and public boundaries | [Data model](../spec/01-data-model.md), [contracts](../spec/contracts/README.md) |
| Speech engines and the FluidAudio pin | [Speech engines](../spec/06-speech-engines.md) |
| UI and the design canvas | [UI spec](../spec/04-ui.md), [design handoff](plans/2026-09-22-001-feat-iphone-app-design-handoff.md), [canvas files](design/2026-09-21-iphone-canvas/canvas.json) |
| Privacy and PHI | [Privacy](../spec/12-privacy.md) |
| Testing and the agent test loop | [Testing](../spec/09-testing.md) |
| Installing on the iPhone, IPA, SideStore | [Distribution](distribution.md), [`APPLE_DEVELOPER_WARNING.md`](../APPLE_DEVELOPER_WARNING.md) |
| Development and review | [Agent working method](../spec/10-ai-coding-method.md), [review workflow](pr-review-workflow.md), [commit guidelines](commit-guidelines.md), [human QA](human-qa-guide.md) |
| Keeping agent instructions lean | [Agent memory governance](agent-memory-governance.md), [research behind it](research/coding-agent-instructions-2026-06.md) |
| Planned and in-progress work | [Plans board](plans/README.md), [executor-plan template](plans/TEMPLATE-executor-plan.md) |
| Why the first iOS attempt was rebuilt | [Gemini port review](reviews/2026-09-22-gemini-ios-review.md) |
| Porting from MacParakeet | [Pipeline map](research/2026-09-22-macparakeet-pipeline-map.md), [`upstream/README.md`](../upstream/README.md) |
| Recurring problems and their fixes | [Solutions](solutions/README.md) |

## Folders

| Folder | What lives there | Status of its contents |
|---|---|---|
| `plans/` | The single plan location: the approved design, the M0+M1 implementation plan, the design handoff, milestone executor plans, the board | Plans are working memory; the board says which are current |
| `reviews/` | Dated code reviews | Final once written; not edited later |
| `research/` | Dated research snapshots (platform limits, runtimes, upstream maps) | Facts drift: verify before relying on them |
| `design/` | The owner's design canvas source (HTML artboards plus `canvas.json`) | The design intent; the handoff translates it to text |
| `solutions/` | Short write-ups of problems that cost real time, with frontmatter | Current until marked otherwise |

## Precedence

ADRs record why a decision was made; a dated amendment overrides older text. ACTIVE specs and contracts describe
intended current behavior; when code disagrees, check tests and fix one or the other deliberately. A plan checkbox or
a research note does not prove that something works. What is on a given phone is whatever its Settings → About says.

## Design canvas files

`design/2026-09-21-iphone-canvas/` holds the eight 390 × 844 artboards (`Home`, `Dictating`, `Meeting`, `Library`,
`Transcript`, `Ask`, `Transform`, `Settings`) and `canvas.json` (layout, titles and the Mac → iPhone mapping note).
They load a canvas runtime (`support.js`) that is not in the repo, so open them through the live canvas
("MacParakeet for iPhone", <https://claude.ai/artifact/3KyBVG6YkYwGA97kW1nmiZ>) or read their HTML directly. The
text version is the [design handoff](plans/2026-09-22-001-feat-iphone-app-design-handoff.md).
