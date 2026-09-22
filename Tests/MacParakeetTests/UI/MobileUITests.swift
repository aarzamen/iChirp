import XCTest
import SwiftUI
@testable import MacParakeetCore
@testable import MacParakeetViewModels
@testable import MacParakeetMobileUI

final class MobileUITests: XCTestCase {

    func testDesignSystemSpeakerColorsRotateCorrectly() {
        let color0 = MobileDesignSystem.Colors.speakerColor(for: 0)
        let color6 = MobileDesignSystem.Colors.speakerColor(for: 6)
        XCTAssertEqual(color0, color6, "Speaker colors should wrap modulo the palette count")

        let color1 = MobileDesignSystem.Colors.speakerColor(for: 1)
        XCTAssertNotEqual(color0, color1, "Adjacent speakers should have different colors")
    }

    func testDesignSystemSpacingIsConsistent() {
        XCTAssertEqual(MobileDesignSystem.Spacing.xs, 4)
        XCTAssertEqual(MobileDesignSystem.Spacing.sm, 8)
        XCTAssertEqual(MobileDesignSystem.Spacing.md, 16)
        XCTAssertEqual(MobileDesignSystem.Spacing.lg, 24)
        XCTAssertEqual(MobileDesignSystem.Spacing.xl, 32)
        XCTAssertEqual(MobileDesignSystem.Spacing.xxl, 48)
    }

    func testMobileTabEnumProperties() {
        XCTAssertEqual(IOSMainTabView.Tab.allCases.count, 5)
        XCTAssertEqual(IOSMainTabView.Tab.record.title, "Record")
        XCTAssertEqual(IOSMainTabView.Tab.library.title, "Library")
        XCTAssertEqual(IOSMainTabView.Tab.transcribe.title, "Transcribe")
        XCTAssertEqual(IOSMainTabView.Tab.transforms.title, "AI & Rewrites")
        XCTAssertEqual(IOSMainTabView.Tab.settings.title, "Settings")

        for tab in IOSMainTabView.Tab.allCases {
            XCTAssertFalse(tab.iconName.isEmpty, "Tab icon should be defined for \(tab)")
        }
    }

    func testRecordModeEnum() {
        XCTAssertEqual(IOSRecordView.CaptureMode.allCases.count, 2)
        XCTAssertEqual(IOSRecordView.CaptureMode.dictate.rawValue, "Dictate")
        XCTAssertEqual(IOSRecordView.CaptureMode.meeting.rawValue, "Meeting")
    }

    func testSpeakerBubbleViewInstantiation() {
        let segment = TranscriptSegmentRecord(
            startMs: 12000,
            endMs: 25000,
            speakerId: "spk_1",
            speakerLabel: "Alice",
            text: "Welcome to the mobile design review.",
            wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 6)
        )

        var didSeekMs: Int?
        let view = IOSSpeakerBubbleView(
            segment: segment,
            speakerIndex: 0,
            isPlaying: true,
            onSeek: { targetMs in
                didSeekMs = targetMs
            }
        )

        XCTAssertNotNil(view)
        view.onSeek(12000)
        XCTAssertEqual(didSeekMs, 12000)
    }

    func testMeetingRowViewInstantiation() {
        var didCopy = false
        var didShare = false
        var didDelete = false

        let row = IOSMeetingRowView(
            title: "Sprint Planning",
            previewText: "We discussed Phase 3 implementation.",
            date: Date(),
            durationMs: 185000,
            speakerCount: 3,
            isMeeting: true,
            onCopy: { didCopy = true },
            onShare: { didShare = true },
            onDelete: { didDelete = true }
        )

        XCTAssertNotNil(row)
        row.onCopy()
        row.onShare()
        row.onDelete()

        XCTAssertTrue(didCopy)
        XCTAssertTrue(didShare)
        XCTAssertTrue(didDelete)
    }

    func testMeetingDetailViewInstantiation() {
        let transcription = Transcription(
            createdAt: Date(),
            fileName: "Sync.m4a",
            durationMs: 60000,
            cleanTranscript: "Hello world",
            status: .completed,
            sourceType: .meeting,
            titleOverride: "Sync",
            derivedTitle: "Sync"
        )

        let detail = IOSMeetingDetailView(transcription: transcription)
        XCTAssertNotNil(detail)
    }

    func testMainTabViewInstantiation() {
        let tabView = IOSMainTabView()
        XCTAssertNotNil(tabView)
    }

    func testTranscribeViewInstantiation() {
        let transcribeView = IOSTranscribeView()
        XCTAssertNotNil(transcribeView)
    }

    func testTransformsViewInstantiation() {
        let transformsView = IOSTransformsView()
        XCTAssertNotNil(transformsView)
    }

    func testSettingsViewInstantiation() {
        let settingsView = IOSSettingsView()
        XCTAssertNotNil(settingsView)
    }
}
