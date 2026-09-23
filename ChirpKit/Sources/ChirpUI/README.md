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

- `Tokens.swift` — `Tokens.Palette` (every color token's hex in four appearances: light, dark, and each with
  Increase Contrast, as a `Tokens.ColorValue`), `Tokens.Color` (the same tokens as SwiftUI colors that follow the
  appearance, the four-pair speaker palette via `Tokens.Color.speaker(at:)`), `Tokens.Radius`
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

**Every color has a light, a dark and an Increase Contrast value (plan 023, ux-audit-2b9ad612 F6).** The
numbers live in `Tokens.Palette`; `Tokens.Color.color(_:)` turns a `ColorValue` into a `UIColor` dynamic provider that
reads `userInterfaceStyle` and `accessibilityContrast` (macOS, with no UIKit, gets the plain light value). The light
values are the owner's canvas, unchanged. The dark palette: warm near-black surfaces (`ground` `#15120F`, `surface`
`#1F1B18`), warm off-white `ink`, a slightly desaturated coral, deep tinted pills (`tint`, `privacyBadgeFill`,
`partialAudioFill`) instead of light patches, and light inks for text on them. The night tokens (`night`,
`coverNight`, the seed strokes, `dictationAccent`) are `ColorValue.fixed`: the same in every appearance, because the
Dictating screen and the covers are dark by design (the Dictating screen also forces the dark scheme, so every token
inside it resolves to its dark value in either system scheme).

**Text, fills and glyphs are separate roles.** In dark mode accent *text* is a light coral that a white label cannot
sit on, so filled buttons read `accentFill` (with `onAccent` white), not `accentInk`; error *text* is `errorInk` (light
red in dark mode) while destructive *fills* are `stopRed`; `success` is a glyph green and `successInk` its text green;
accent text on a `tint` fill is `accentInkPressed`. Adding a token means adding its `Palette` entry (with a dark value),
its `Color` line, and its name to `Palette.named` — `ContrastTests` fails for a named token that no pair measures.

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
  `ChirpKit/Tests/ChirpUITests/ContrastTests.swift` measures WCAG contrast for every foreground × background pair the
  app draws (the table mirrors the call sites) in all four appearances, straight from `Tokens.Palette`: 4.5:1 for text,
  3:1 for glyphs. Its only accepted exceptions are pinned with their ratios: five canvas glyph colors in default light
  mode (each fixed under Increase Contrast) and the Dictating screen's spec'd 42% tentative text. It also checks that
  Increase Contrast never lowers contrast, that dark surfaces are warm near-black, that dark pills do not glare, that
  the four speaker colors stay distinct (CIE76 ΔE ≥ 25) and that every token is measured or listed as decorative.
- `AppTests/PaletteScreenRenderTests.swift` (app-hosted) renders the Dictating and Meeting covers over a light and a
  dark window and checks that the Dictating screen draws the same pixels in both.
