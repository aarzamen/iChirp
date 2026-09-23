# ChirpUI

> Parakeet's shared visual vocabulary: design tokens and reusable SwiftUI components,
> converted from the owner's design canvas
> (`docs/design/2026-09-21-iphone-canvas/*.dc.html`, text version at
> `docs/plans/2026-09-22-001-feat-iphone-app-design-handoff.md`). No screens live here —
> screens (Capture, Library, Transcript, Settings, Transforms) are Task 12b, built in `App/` on
> top of this module.

## Entry point

`Tokens` — the single source of truth for color, radius and type. Every other file in this
module, and every screen built on top of it, reads from `Tokens` instead of hardcoding a value
from the canvas.

## What's here

- `Tokens.swift` — `Tokens.Color` (hex-derived `SwiftUI.Color`s, the four-pair speaker palette
  via `Tokens.Color.speaker(at:)`, and adaptive light/dark surface colors), `Tokens.Radius`
  (`s`/`m`/`l`/`xl` plus the canvas's supporting radii), `Tokens.Font.rounded(_:_:)`.
- `Components/ParakeetMark.swift` — `ParakeetMark` (a `Shape` built by parsing the logo's raw
  SVG path data from `Home.dc.html` at runtime) and `ParakeetMarkView` (the shape pre-filled
  with the `evenodd` rule the silhouette's negative space needs).
- `Components/SeedOfLifeCover.swift` — `SeedOfLifeCover`, the night-field seven-circle cover
  for meeting rows (Capture's Recent list, Library). `seed` picks the rotation angle and which
  circle(s) are highlighted, so two covers next to each other don't look identical.
- `Components/RosetteMark.swift` — `RosetteMark`, the green sacred-geometry flower (with stem
  and leaves) used for meeting capture (Capture's "Record Meeting" row, the Meeting recording
  card's `halo` variant).
- `Components/Card.swift` — `ChirpCardStyle` and the `.chirpCard(...)` view modifier: the
  surface/border/radius treatment every grouped card on the canvas uses.
- `Components/StatusChip.swift` — `StatusChip`, a capsule icon+label chip, with static
  factories for the recurring cases (`.onDevice()`, `.cleanTextOnCopy()`, `.notBuiltYet(milestone:)`,
  `.transcribing(percent:)`, `.partialAudio()`).
- `Components/SpeakerDot.swift` — `SpeakerDot`, the colored-dot + label + timestamp row used
  above every transcript paragraph.
- `Components/NotBuiltYetView.swift` — `NotBuiltYetView`, the honest not-built-yet placeholder
  content (title, milestone badge, one-sentence summary, SF Symbol). The app's
  `NotBuiltYetSheet` (Task 12b) wraps this in a sheet.

## What to know before editing

**`Tokens` is the single source of truth for color, radius and type.** Never hardcode a hex
literal, a radius number, or a rounded-font call in `App/` — read it from `Tokens` instead. If a
screen needs a color or radius the canvas uses that isn't in `Tokens` yet, add it there (with a
comment on which artboard it came from) rather than inlining it. Colors ultimately come from
`Tokens.Color.hex(_:)`, a thin wrapper over the pure `Tokens.Color.rgbComponents(fromHex:)`
parser — that function has no SwiftUI/UIKit dependency by design, so it can be lifted into a
standalone script and checked without building the package (see "How to verify" below).

**The canvas is light-only; `ground`/`surface`/`border`/`ink`/`secondary` are adaptive
anyway.** Those five read the canvas's light value in light mode and a chosen dark variant in
dark mode (via `UIColor`'s dynamic-provider initializer on iOS; a plain light value on macOS,
where there's no UIKit dynamic provider). Every other token (accent, tint, success, the speaker
palette, the night/cover-night backgrounds, etc.) is intentionally identical in both modes —
they're either already dark-appropriate (the night surfaces) or brand colors the canvas never
varies. `successInk` (added by polish lane u1-design) is the one exception among the "brand
colors" group: it's built with the same `adaptive(light:dark:)` two-value pattern as the five
surfaces above even though its dark value is currently identical to `success`'s — that keeps the
door open for the owner's dark palette (plan 023, ux-audit-2b9ad612 F6) to give it a real dark
value later without any call site changing.

**Some tokens read Increase Contrast, in light mode only.** `border`, `secondary`, `accentInk`
and `mutedText` swap to a higher-contrast light value while the system's Increase Contrast
setting is on (`adaptive(...highContrastLight:)` and the private `contrastAwareLight(...)`
helper in `Tokens.swift`, ux-audit-2b9ad612 F5). Dark mode never reads the contrast trait —
that's deliberately left to the owner's dark palette pass rather than guessed at here.

**Not every color that *looks* like it should be text-safe is.** `success` and `mutedText` are
icon/dot-fill colors only — 3.06:1 and 2.75:1 as text, both below WCAG's 4.5:1. Text needs
`successInk` (new) or `secondary` instead; see each token's doc comment in `Tokens.swift`, and
`ChirpKit/Tests/ChirpUITests/ContrastTests.swift` for the numbers.

**`ParakeetMark` parses real SVG path data at runtime**, via a small private `SVGPathParser` in
the same file (supports `M`/`m`, `L`/`l`, `H`/`h`, `V`/`v`, `C`/`c`, `Z`/`z`, including SVG's
implicit-repeated-argument shorthand). The four path strings are transcribed verbatim from
`Home.dc.html`'s `<svg viewBox="0 0 1024 1024">`; if the canvas logo ever changes, replace those
strings rather than hand-editing geometry. Draw it with `FillStyle(eoFill: true)` (or just use
`ParakeetMarkView`) — the silhouette's negative space depends on the evenodd fill rule the
source path was authored with.

**`SeedOfLifeCover` and `RosetteMark` are hand-transcribed geometry, not parsed SVG.** Both
source shapes (seven circles in a Seed-of-Life ring, a stem, two leaf blades) are simple enough
that copying their center points and cubic-curve control points directly from the canvas SVGs
was clearer than routing them through `SVGPathParser`. If you need to adjust their proportions,
cross-check against the `<svg>` blocks in `Home.dc.html` / `Library.dc.html` / `Meeting.dc.html`
rather than eyeballing new numbers.

## How to verify

- `swift build --package-path ChirpKit` — builds the whole package (macOS host target);
  confirms `ChirpUI` compiles clean.
- From the repo root: `scripts/gen.sh && xcodebuild build -project iChirp.xcodeproj -scheme
  iChirp -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode
  CODE_SIGNING_ALLOWED=NO -quiet` — confirms the iOS target (which `App/` links against)
  builds too.
- `swift format lint --strict --recursive ChirpKit/Sources/ChirpUI` — style/lint gate.
- Every public view has a `#Preview`; open this package in Xcode and check them, or
  temporarily render a component in the app's root view and run it on the simulator
  (`scripts/run_sim.sh`) for a real-device screenshot — revert the temporary App change
  afterward, since screens are Task 12b's job, not this module's.
- `swift test --package-path ChirpKit --filter ChirpUITests` —
  `ChirpKit/Tests/ChirpUITests/ContrastTests.swift` (polish lane u1-design) computes WCAG contrast
  ratios for the text-safe tokens
  (`successInk`, `secondary`, `accentInk`, the Increase Contrast values) straight from
  `Tokens.Color.rgbComponents(fromHex:)`, the same pure function this section used to point at for a
  throwaway spot-check script — now it's a real, always-run test instead.
