# ChirpUI

> Parakeet's shared visual vocabulary: design tokens and reusable SwiftUI components,
> converted from the owner's design canvas
> (`docs/design/2026-09-21-iphone-canvas/*.dc.html`, text version at
> `docs/plans/2026-09-22-001-feat-iphone-app-design-handoff.md`). No screens live here —
> screens (Capture, Library, Transcript, Settings, Transforms and the rest) are built in `App/` on
> top of this module.

## Entry point

`Tokens` — the single source of truth for color, radius, spacing, control sizes and type. Every other file in this
module, and every screen built on top of it, reads from `Tokens` instead of hardcoding a value
from the canvas.

## What's here

- `Tokens.swift` — `Tokens.Palette` (every color token's hex in four appearances: light, dark, and each with
  Increase Contrast, as a `Tokens.ColorValue`), `Tokens.Color` (the same tokens as SwiftUI colors that follow the
  appearance, the four-pair speaker palette via `Tokens.Color.speaker(at:)`, `raisedShadow`), `Tokens.Radius`
  (`s`/`m`/`l`/`xl`, the small and component radii `xs`/`track`/`inset`/`bubble`/`input`, and the canvas's supporting
  radii), `Tokens.Spacing` (the 4/8/12/16/20/24/32 scale and `sheetGutter`), `Tokens.Metric` (the 44 pt tap target,
  the 50 pt primary button, the 32 pt compact pill, the 58 pt action bar, the hairline, the raised shadow),
  `Tokens.Scale.capped(_:base:maxScale:)`, `Tokens.Font.rounded(_:_:)` and `Tokens.Font.textStyle(forCanvasSize:)`.
- `Components/ParakeetMark.swift` — `ParakeetMark` (a `Shape` built by parsing the logo's raw
  SVG path data from `Home.dc.html` at runtime, aspect-fitted to the frame it is given) and `ParakeetMarkView` (the
  shape pre-filled with the `evenodd` rule the silhouette's negative space needs).
- `Components/ScaledMetrics.swift` — `.chirpGlyph(_:_:design:relativeTo:maxScale:)` (an SF Symbol at a canvas size
  that follows Dynamic Type; use it instead of `.font(.system(size:))` on icons) and
  `.chirpScaledFrame(width:height:relativeTo:maxScale:alignment:)` (a fixed frame that grows with Dynamic Type: the
  mark, icon tiles, dots).
- `Components/Buttons.swift` — `ChirpButtonStyle`: the one capsule button. `.chirpPrimary` (accent fill),
  `.chirpSecondary` (tint), `.chirp(.quiet / .destructive / .stop)`, each `.large` (full width, 50 pt, 16 pt bold) or
  `.compact` (a 32 pt pill in a 44 pt target, 13.5 pt bold); disabled is a quiet capsule with a `secondary` label.
- `Components/ActionBar.swift` — `ChirpBottomBar` (a sheet's bar of buttons), `ChirpActionBar` with
  `ChirpActionBarItem` / `ChirpActionBarLabel` (a screen's Copy / Share / Listen / Transform bar; one row, else two
  columns, else one, so labels never shrink or truncate; `ChirpActionBarLayout` does the re-flow), and
  `.chirpBarBackground()`: opaque `ground` with a hairline on top, for both.
- `Components/SegmentedControl.swift` — `ChirpSegmentedControl`: a `quietFill` track with a raised `selectedSegment`
  pill, titles that scale with Dynamic Type, 44 pt segments, `.fit` or `.fill` width, disabled and icon-only segments,
  and a vertical list with a check when the titles no longer fit side by side.
- `Components/ToggleStyle.swift` — `ChirpToggleStyle` (`.toggleStyle(.chirp)`): `success` when on, `toggleOffTrack`
  when off, a white knob, growing with Dynamic Type up to 1.5×, On/Off for VoiceOver.
- `Components/Placeholder.swift` — one placeholder style: `ChirpTextField` (a `TextField` whose prompt reads
  `Tokens.Color.placeholder`), `Text.chirpPlaceholder(_:)` (the prompt for any `TextField` or `SecureField`) and
  `ChirpPlaceholder` (the overlay on an empty `TextEditor`).
- `Components/SeedOfLifeCover.swift` — `SeedOfLifeCover`, the night-field seven-circle cover
  for meeting rows (Capture's Recent list, Library). `seed` picks the rotation angle and which
  circle(s) are highlighted, so two covers next to each other don't look identical.
- `Components/RosetteMark.swift` — `RosetteMark`, the green sacred-geometry flower (with stem
  and leaves) used for meeting capture (Capture's "Record Meeting" row, the Meeting recording
  card's `halo` variant).
- `Components/Card.swift` — the one card: `ChirpCardBackground(radius:fill:stroke:)` (a token fill with an inset
  hairline, the app's former `CardBackground` with the same parameters) and `ChirpCardStyle` / `.chirpCard(...)`,
  which add padding and draw the same background.
- `Components/StatusChip.swift` — `StatusChip`, a capsule icon+label chip, with static
  factories for the recurring cases (`.onDevice()`, `.cleanTextOnCopy()`, `.notBuiltYet(milestone:)`,
  `.transcribing(percent:)`, `.partialAudio()`).
- `Components/SpeakerDot.swift` — `SpeakerDot`, the colored-dot + label + timestamp row used
  above every transcript paragraph.
- `Components/NotBuiltYetView.swift` — `NotBuiltYetView`, the honest not-built-yet placeholder
  content (title, milestone badge, one-sentence summary, SF Symbol). The app's
  `NotBuiltYetSheet` (`App/Sources/Screens/Shared/NotBuiltYetSheet.swift`) wraps this in a sheet.

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
reads `userInterfaceStyle` and `accessibilityContrast` (macOS, with no UIKit, gets the plain light value). The owner
approved the palette on 2026-09-23 with two changes: five canvas glyph colors below 3:1 in light mode moved to the
nearest same-hue value that passes (`favorite`, `mutedText`, `success`, `accent`, the amber speaker dot; each token's
comment gives the canvas value), and the Dictating screen's tentative words went from 42% to 46% white
(`Palette.dictationTentativeOpacity`, `Color.dictationTentative`). Every other light value is the canvas. The dark
palette: warm near-black surfaces (`ground` `#15120F`, `surface`
`#1F1B18`), warm off-white `ink`, a slightly desaturated coral, deep tinted pills (`tint`, `privacyBadgeFill`,
`partialAudioFill`) instead of light patches, and light inks for text on them. The night tokens (`night`,
`coverNight`, the seed strokes, `dictationAccent`) are `ColorValue.fixed`: the same in every appearance, because the
Dictating screen and the covers are dark by design (the Dictating screen also forces the dark scheme, so every token
inside it resolves to its dark value in either system scheme).

**Text, fills and glyphs are separate roles.** In dark mode accent *text* is a light coral that a white label cannot
sit on, so filled buttons read `accentFill` (with `onAccent` white), not `accentInk`; error *text* is `errorInk` (light
red in dark mode) while destructive *fills* are `stopRed`; `success` is a glyph green and `successInk` its text green;
accent text on a `tint` fill is `accentInkPressed`. Plan 025 Part B's `findMatchFill` and `findCurrentFill` are amber
fills behind Find in transcript's matches (ink text on both; a correction's dotted underline inside a match is drawn in
`ink`, because `secondary` is below 3:1 on the dark current fill). Adding a token means adding its `Palette` entry (with a dark value),
its `Color` line, and its name to `Palette.named` — `ContrastTests` fails for a named token that no pair measures.

**Shared controls come from here (plan 024 Task 11).** A primary button, a bottom bar, a card, a segmented control,
a switch or a text field in `App/` uses the ChirpUI component above rather than a hand-rolled copy: one height, one
font, one fill per kind, one bar background, one placeholder color. Screens adopt them in plan 024 wave 3 (Tasks 9
and 10). Spacing and radii come from `Tokens.Spacing` and `Tokens.Radius`; a component's own canvas geometry (a chip's
padding, artwork line widths) is a named constant in that component, not a shared token.

**Dynamic Type.** Text in ChirpUI uses text styles or `@ScaledMetric` sizes; glyphs use `chirpGlyph` and fixed frames
use `chirpScaledFrame`, relative to the text style of the label beside them. `maxScale` stops bar icons (1.6×) and the
switch (1.5×) short of body text's growth. Controls that run out of width re-flow rather than shrink: the action bar
goes to two columns, the segmented control to a vertical list.

**Not every color that *looks* like it should be text-safe is.** `success` and `mutedText` are
icon/dot-fill colors only — 3.16:1 and 3.19:1 as text, both below WCAG's 4.5:1. Text needs
`successInk` (new) or `secondary` instead; see each token's doc comment in `Tokens.swift`, and
`ChirpKit/Tests/ChirpUITests/ContrastTests.swift` for the numbers. Placeholders read `placeholder` (the `secondary`
values), never `mutedText` or the system grey (1.72:1 on white).

**`ParakeetMark` parses real SVG path data at runtime**, via a small private `SVGPathParser` in
the same file (supports `M`/`m`, `L`/`l`, `H`/`h`, `V`/`v`, `C`/`c`, `Z`/`z`, including SVG's
implicit-repeated-argument shorthand). The four path strings are transcribed verbatim from
`Home.dc.html`'s `<svg viewBox="0 0 1024 1024">`; if the canvas logo ever changes, replace those
strings rather than hand-editing geometry. Draw it with `FillStyle(eoFill: true)` (or just use
`ParakeetMarkView`) — the silhouette's negative space depends on the evenodd fill rule the
source path was authored with. `path(in:)` aspect-fits the drawing's own bounds (about 0.82 wide per tall) into the
rect and centres it, so the frame you give is the mark you see: beside the 22 pt wordmark, a 24 pt frame scaled with
`chirpScaledFrame(…, relativeTo: .title2)`. (Until plan 024 it scaled the whole 1024 viewBox, whose margins left the
bird at 40% × 49% of its frame, R7-9.)

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
  afterward, since screens live in `App/`, not in this module.
- `swift test --package-path ChirpKit --filter ChirpUITests` —
  `ChirpKit/Tests/ChirpUITests/ContrastTests.swift` measures WCAG contrast for every foreground × background pair the
  app draws (the table mirrors the call sites) in all four appearances, straight from `Tokens.Palette`: 4.5:1 for text,
  3:1 for glyphs, with no exceptions (the last six were removed by the owner's choices of 2026-09-23). It also checks that
  Increase Contrast never lowers contrast, that dark surfaces are warm near-black, that dark pills do not glare, that
  the four speaker colors stay distinct (CIE76 ΔE ≥ 25) and that every token is measured or listed as decorative.
  The pair table includes the placeholder on every field background, every `ChirpButtonStyle` kind (and disabled),
  the segmented control's selected and unselected titles and the action bar's labels; separate tests check that the
  selected segment is raised above its track and that the switch's off track reads at least as clearly as a card's
  hairline (more with Increase Contrast).
- `swift test --package-path ChirpKit --filter ComponentTests` — `ChirpKit/Tests/ChirpUITests/ComponentTests.swift`: the mark fills its frame, the
  action bar's column choice, the scale caps, the spacing and radius scales, and a default-size render of every new
  component (`ImageRenderer` on the Mac). The Mac does not apply Dynamic Type, so the accessibility-size renders are
  app-hosted (next item).
- `AppTests/ChirpUIComponentRenderTests.swift` (app-hosted, iPhone simulator) renders every new component in light and
  dark at the default size and at AX3, checks that each grows with the text and that the action bar re-flows to two
  columns at AX3, and samples the `ChirpTextField` placeholder's pixels; with `TEST_RUNNER_CHIRP_RENDER_DIR=<dir>` the
  images are written there.
- `AppTests/PaletteScreenRenderTests.swift` (app-hosted) renders the Dictating and Meeting covers over a light and a
  dark window and checks that the Dictating screen draws the same pixels in both.
