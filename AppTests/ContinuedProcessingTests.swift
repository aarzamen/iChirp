import ChirpCore
import ChirpFeatures
import Foundation
import XCTest

@testable import iChirp

/// M1.5 Step 2: the identifiers the app submits at run time are permitted by the built Info.plist's wildcards, and
/// the document types that put Parakeet in the Share sheet are declared.
@MainActor
final class ContinuedProcessingTests: XCTestCase {
    func testEveryKindsIdentifierIsPermittedByAWildcard() throws {
        let bundleIdentifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let permitted = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        let wildcardPrefixes = permitted.filter { $0.hasSuffix(".*") }.map { String($0.dropLast()) }
        XCTAssertEqual(wildcardPrefixes.count, ContinuedProcessingKind.allCases.count, "\(permitted)")

        for kind in ContinuedProcessingKind.allCases {
            let identifier = SystemContinuedProcessingScheduler.identifier(
                bundleIdentifier: bundleIdentifier, kind: kind, suffix: UUID())
            XCTAssertTrue(identifier.hasPrefix(bundleIdentifier + "."), identifier)
            XCTAssertTrue(
                wildcardPrefixes.contains { identifier.hasPrefix($0) && identifier.count > $0.count },
                "\(identifier) is not permitted by \(permitted)")
        }
    }

    func testIdentifiersAreNeverReused() throws {
        let first = SystemContinuedProcessingScheduler.identifier(
            bundleIdentifier: "com.aarzamen.ichirp", kind: .transcription, suffix: UUID())
        let second = SystemContinuedProcessingScheduler.identifier(
            bundleIdentifier: "com.aarzamen.ichirp", kind: .transcription, suffix: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix("com.aarzamen.ichirp.transcribe."))
    }

    /// Continued-processing tasks (M1.5) need no background mode. The only one declared is `audio`, for M2 dictation
    /// (plan 011 Step 8: a dictation started in the foreground keeps recording when the phone locks). Anything else,
    /// `processing` included, is an owner decision.
    func testOnlyTheDictationAudioBackgroundModeIsDeclared() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertEqual(modes, ["audio"], "adding a background mode is an owner decision")
    }

    func testAudioAndVideoDocumentTypesAreDeclared() throws {
        let types = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let contentTypes = types.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] }
        XCTAssertEqual(Set(contentTypes), ["public.audio", "public.movie"])
        XCTAssertTrue(types.allSatisfy { ($0["LSHandlerRank"] as? String) == "Alternate" })
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, false)
    }

    /// The Simulator does not run background tasks: the request is refused and the job runs in the foreground.
    func testSimulatorRefusesTheRequestWithoutCrashing() throws {
        #if targetEnvironment(simulator)
        let scheduler = try XCTUnwrap(SystemContinuedProcessingScheduler())
        let requestID = scheduler.submit(.transcription, title: "Test", subtitle: "Waiting to start") { _ in
            XCTFail("the Simulator never starts a continued-processing task")
        }
        XCTAssertNil(requestID)
        #else
        throw XCTSkip("Simulator-only check")
        #endif
    }

    // MARK: - Audio-track picker copy (M1.5 Step 4)

    func testPickerMessageNamesTheFileAndTheBatchRule() {
        let tracks = [AudioTrackDescriptor(ordinal: 0), AudioTrackDescriptor(ordinal: 1)]
        let single = TranscriptionJobCenter.AudioTrackSelectionRequest(
            id: UUID(), fileName: "Talk.mov", fileCount: 1, tracks: tracks)
        XCTAssertEqual(
            AudioTrackPickerSheet.message(for: single), "“Talk.mov” has 2 audio tracks. Parakeet transcribes one.")
        let batch = TranscriptionJobCenter.AudioTrackSelectionRequest(
            id: UUID(), fileName: "Talk.mov", fileCount: 3, tracks: tracks)
        XCTAssertTrue(AudioTrackPickerSheet.message(for: batch).contains("every file in this import"))
    }
}
