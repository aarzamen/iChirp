// Plan 024 Task 11 (design system): the shared ChirpUI components the screen lanes adopt — the Parakeet mark at its
// frame (R7-9), the action bar's layout (R7-12), scaled metrics (R7-4), the spacing and radius scales (R7-22) and a
// default-size render of every new component.
//
// `swift test` runs on the Mac, where SwiftUI does not apply Dynamic Type to `@ScaledMetric` or text styles, so the
// accessibility-size renders (AX3) of the same components live in the app-hosted
// `AppTests/ChirpUIComponentRenderTests.swift`, which runs on the iPhone simulator.

import SwiftUI
import XCTest

@testable import ChirpUI

@MainActor
final class ComponentTests: XCTestCase {

    // MARK: - R7-9: the Parakeet mark fills its frame

    func testParakeetMarkFillsItsFrameInsteadOfFortyPercentOfIt() {
        // Before the fix the 1024 viewBox was scaled whole, so the silhouette covered about 40% × 49% of the frame
        // (an 11 × 13 pt squiggle in a 27 pt frame). Now the drawing's own bounds are aspect-fitted to the frame.
        let frame = CGRect(x: 0, y: 0, width: 27, height: 27)
        let bounds = ParakeetMark().path(in: frame).boundingRect
        XCTAssertEqual(bounds.height, 27, accuracy: 0.5, "the mark is as tall as its frame")
        XCTAssertGreaterThan(bounds.width, 27 * 0.75, "the mark keeps its proportions (about 0.82 wide per tall)")
        XCTAssertLessThanOrEqual(bounds.width, 27.5)
        XCTAssertEqual(bounds.midX, frame.midX, accuracy: 0.5, "centred across")
        XCTAssertEqual(bounds.midY, frame.midY, accuracy: 0.5, "centred down")
    }

    func testParakeetMarkAspectFitsAWideFrameAtItsOrigin() {
        let frame = CGRect(x: 40, y: 10, width: 120, height: 30)
        let bounds = ParakeetMark().path(in: frame).boundingRect
        XCTAssertEqual(bounds.height, 30, accuracy: 0.5)
        XCTAssertLessThan(bounds.width, 30)
        XCTAssertEqual(bounds.midX, frame.midX, accuracy: 0.5)
        XCTAssertEqual(bounds.minY, frame.minY, accuracy: 0.5)
    }

    func testParakeetMarkAspectFitsATallFrame() {
        let frame = CGRect(x: 0, y: 0, width: 20, height: 80)
        let bounds = ParakeetMark().path(in: frame).boundingRect
        XCTAssertEqual(bounds.width, 20, accuracy: 0.5, "width-limited in a tall frame")
        XCTAssertEqual(bounds.midY, frame.midY, accuracy: 0.5)
    }

    // MARK: - R7-12: the action bar never truncates; it goes to a grid instead

    func testActionBarKeepsOneRowWhenEveryItemFits() {
        XCTAssertEqual(ChirpActionBarLayout.columnCount(itemWidths: [60, 60, 70, 80], available: 402), 4)
    }

    func testActionBarGoesTwoByTwoWhenOneLabelNoLongerFitsAQuarter() {
        // "Transform" at an accessibility size is wider than a quarter of the bar: two columns, never "Transfor…".
        XCTAssertEqual(ChirpActionBarLayout.columnCount(itemWidths: [90, 90, 90, 150], available: 402), 2)
    }

    func testActionBarStacksWhenEvenHalfIsTooNarrow() {
        XCTAssertEqual(ChirpActionBarLayout.columnCount(itemWidths: [90, 250, 90], available: 402), 1)
        XCTAssertEqual(ChirpActionBarLayout.columnCount(itemWidths: [90, 150, 90], available: 402), 2)
        XCTAssertEqual(ChirpActionBarLayout.columnCount(itemWidths: [], available: 402), 1)
    }

    func testActionBarLaysOutRowsOfTheChosenColumnCount() {
        XCTAssertEqual(ChirpActionBarLayout.rowCount(items: 4, columns: 2), 2)
        XCTAssertEqual(ChirpActionBarLayout.rowCount(items: 3, columns: 2), 2)
        XCTAssertEqual(ChirpActionBarLayout.rowCount(items: 4, columns: 4), 1)
        XCTAssertEqual(ChirpActionBarLayout.rowCount(items: 0, columns: 1), 0)
    }

    // MARK: - R7-4: scaled metrics

    func testScaledValuesAreCappedOnlyWhenAskedTo() {
        XCTAssertEqual(Tokens.Scale.capped(40, base: 20, maxScale: 1.5), 30)
        XCTAssertEqual(Tokens.Scale.capped(25, base: 20, maxScale: 1.5), 25)
        XCTAssertEqual(Tokens.Scale.capped(80, base: 20, maxScale: nil), 80)
        XCTAssertEqual(Tokens.Scale.capped(18, base: 20, maxScale: 1.5), 18, "smaller text sizes still shrink")
    }

    func testCanvasSizesMapToTheTextStyleTheAppScalesThemBy() {
        // The same table as the app's `chirpFont`, so a glyph beside a label grows at the label's rate.
        XCTAssertEqual(Tokens.Font.textStyle(forCanvasSize: 11), .caption)
        XCTAssertEqual(Tokens.Font.textStyle(forCanvasSize: 12), .footnote)
        XCTAssertEqual(Tokens.Font.textStyle(forCanvasSize: 13.5), .subheadline)
        XCTAssertEqual(Tokens.Font.textStyle(forCanvasSize: 16), .body)
        XCTAssertEqual(Tokens.Font.textStyle(forCanvasSize: 19), .headline)
        XCTAssertEqual(Tokens.Font.textStyle(forCanvasSize: 22), .title2)
        XCTAssertEqual(Tokens.Font.textStyle(forCanvasSize: 27), .largeTitle)
    }

    // MARK: - R7-22: spacing and radius scales

    func testSpacingScaleIsAFourPointStepScale() {
        let scale = [
            Tokens.Spacing.xxs, Tokens.Spacing.xs, Tokens.Spacing.s, Tokens.Spacing.m, Tokens.Spacing.l,
            Tokens.Spacing.xl, Tokens.Spacing.xxl,
        ]
        XCTAssertEqual(scale, [4, 8, 12, 16, 20, 24, 32])
        XCTAssertEqual(Tokens.Spacing.sheetGutter, Tokens.Spacing.xl, "one sheet gutter (R7-22: 20 vs 24 pt)")
    }

    func testEveryLiteralRadiusTheReviewFoundHasAToken() {
        // R7-22's literals: 8 (rate chip, Stop square, selected segment), 10 (segment track), 12 (inset panels),
        // 18 (Ask's question bubble), 22 (Ask's input). The existing scale is unchanged.
        XCTAssertEqual(Tokens.Radius.xs, 8)
        XCTAssertEqual(Tokens.Radius.track, 10)
        XCTAssertEqual(Tokens.Radius.inset, 12)
        XCTAssertEqual(Tokens.Radius.bubble, 18)
        XCTAssertEqual(Tokens.Radius.input, 22)
        XCTAssertEqual([Tokens.Radius.s, Tokens.Radius.m, Tokens.Radius.l, Tokens.Radius.xl], [14, 16, 20, 24])
    }

    func testControlMetricsAreOneSetForTheWholeApp() {
        XCTAssertEqual(Tokens.Metric.minTapTarget, 44)
        XCTAssertEqual(Tokens.Metric.primaryButtonHeight, 50, "R6a-15 / R6b-18: one primary height, not 44–54")
        XCTAssertEqual(Tokens.Metric.compactButtonHeight, 32)
        XCTAssertEqual(Tokens.Metric.actionBarHeight, 58)
    }

    // MARK: - Default-size renders (the AX3 renders are app-hosted)

    func testPrimaryButtonsAreOneHeightWithAFullWidthCapsule() throws {
        for kind in ChirpButtonStyle.Kind.allCases {
            let size = try renderedSize(
                Button("Create") {}.buttonStyle(.chirp(kind)).frame(width: 340))
            XCTAssertEqual(size.width, 340, accuracy: 0.5, "\(kind) fills the width it is given")
            XCTAssertEqual(size.height, Tokens.Metric.primaryButtonHeight, accuracy: 0.5, "\(kind)")
        }
    }

    func testCompactButtonsKeepA44PointTarget() throws {
        let size = try renderedSize(Button("Retry") {}.buttonStyle(.chirp(.tinted, size: .compact)))
        XCTAssertEqual(size.height, Tokens.Metric.minTapTarget, accuracy: 0.5)
        XCTAssertLessThan(size.width, 120, "a compact button hugs its label")
    }

    func testButtonRowKeepsTwoButtonsSideBySideWhenTheyFit() throws {
        let size = try renderedSize(
            ChirpButtonRow {
                Button("Create another") {}.buttonStyle(.chirpSecondary)
                Button("Done") {}.buttonStyle(.chirpPrimary)
            }
            .frame(width: 354))
        XCTAssertEqual(size.height, Tokens.Metric.primaryButtonHeight, accuracy: 0.5, "one row")
        let narrow = try renderedSize(
            ChirpButtonRow {
                Button("Create another") {}.buttonStyle(.chirpSecondary)
                Button("Done") {}.buttonStyle(.chirpPrimary)
            }
            .frame(width: 160))
        XCTAssertGreaterThanOrEqual(
            narrow.height, 2 * Tokens.Metric.primaryButtonHeight, "stacked rather than wrapped side by side")
    }

    func testDisabledPrimaryButtonStillRenders() throws {
        let size = try renderedSize(
            Button("Create") {}.buttonStyle(.chirpPrimary).disabled(true).frame(width: 300))
        XCTAssertEqual(size.height, Tokens.Metric.primaryButtonHeight, accuracy: 0.5)
    }

    func testActionBarRendersOneRowAtTheDefaultSize() throws {
        let size = try renderedSize(
            ChirpActionBar {
                ChirpActionBarItem("Copy", systemImage: "doc.on.doc") {}
                ChirpActionBarItem("Share", systemImage: "square.and.arrow.up") {}
                ChirpActionBarItem("Listen", systemImage: "speaker.wave.2") {}
                ChirpActionBarItem("Transform", systemImage: "sparkles", emphasized: true) {}
            }
            .frame(width: 402))
        XCTAssertEqual(size.height, Tokens.Metric.actionBarHeight, accuracy: 1, "one row of four")
    }

    func testBottomBarAndCardRender() throws {
        let bar = try renderedSize(
            ChirpBottomBar { Button("Create") {}.buttonStyle(.chirpPrimary) }.frame(width: 402))
        XCTAssertGreaterThanOrEqual(bar.height, Tokens.Metric.primaryButtonHeight)
        let card = try renderedSize(Text("Card").chirpCard().frame(width: 300))
        XCTAssertGreaterThanOrEqual(card.height, Tokens.Spacing.m * 2)
        let background = try renderedSize(ChirpCardBackground(radius: Tokens.Radius.s).frame(width: 80, height: 40))
        XCTAssertEqual(background.width, 80, accuracy: 0.5)
    }

    func testSegmentedControlRendersEverySegmentInATapTarget() throws {
        let size = try renderedSize(
            ChirpSegmentedControl(
                "View", selection: .constant(1),
                segments: [.init("Notes", value: 1), .init("Live transcript", value: 2)]))
        XCTAssertGreaterThanOrEqual(size.height, Tokens.Metric.minTapTarget - 0.5)
        XCTAssertGreaterThan(size.width, 100)
    }

    func testSegmentedControlFillsItsWidthWhenAsked() throws {
        let size = try renderedSize(
            ChirpSegmentedControl(
                "Document view", selection: .constant("a"),
                segments: [.init("Formatted", value: "a"), .init("Edit", value: "b", isEnabled: false)],
                width: .fill
            )
            .frame(width: 360))
        XCTAssertEqual(size.width, 360, accuracy: 0.5)
    }

    func testToggleStyleRendersAtLeastATapTargetTall() throws {
        let size = try renderedSize(
            Toggle("Keep dictation audio", isOn: .constant(false)).toggleStyle(.chirp).frame(width: 340))
        XCTAssertGreaterThanOrEqual(size.height, Tokens.Metric.minTapTarget - 0.5)
        let on = try renderedSize(
            Toggle("Keep dictation audio", isOn: .constant(true)).toggleStyle(.chirp).frame(width: 340))
        XCTAssertEqual(on, size, "on and off take the same room")
    }

    func testPlaceholderViewsRender() throws {
        let placeholder = try renderedSize(ChirpPlaceholder("Agenda, decisions, action items…"))
        XCTAssertGreaterThan(placeholder.width, 0)
        _ = ChirpTextField("Search titles, text and speakers", text: .constant(""))
        _ = Text.chirpPlaceholder("Ask about this transcript")
    }

    func testScaledFrameAndGlyphRenderAtTheirBaseSizeOnTheMac() throws {
        let frame = try renderedSize(
            ParakeetMarkView().chirpScaledFrame(width: 24, height: 24, relativeTo: .title2))
        XCTAssertEqual(frame.width, 24, accuracy: 0.5)
        XCTAssertEqual(frame.height, 24, accuracy: 0.5)
        let glyph = try renderedSize(Image(systemName: "sparkles").chirpGlyph(19, .medium))
        XCTAssertGreaterThan(glyph.height, 10)
    }

    // MARK: - Helpers

    private func renderedSize(_ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view.fixedSize(horizontal: false, vertical: true))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "nothing rendered")
        return CGSize(width: image.width, height: image.height)
    }
}
