import ChirpCore
import ChirpExport
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

@MainActor
final class TranscriptViewModelTests: XCTestCase {
    private func makePaths() -> AppPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptVM-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AppPaths(root: root)
    }

    private func completedRow(words: [WordTimestamp]? = nil) -> Transcription {
        let id = UUID()
        var row = Transcription(
            id: id,
            fileName: "Interview.m4a",
            mediaRelativePath: "media/\(id.uuidString)/source.m4a",
            durationMs: 3_000,
            status: .completed
        )
        row.rawTranscript = "um hello there general kenobi"
        row.cleanTranscript = "Hello there, General Kenobi."
        row.wordTimestamps =
            words ?? [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 1, speakerId: "S1"),
                WordTimestamp(word: "there.", startMs: 400, endMs: 1_000, confidence: 1, speakerId: "S1"),
                WordTimestamp(word: "General", startMs: 1_300, endMs: 1_900, confidence: 1, speakerId: "S2"),
                WordTimestamp(word: "Kenobi.", startMs: 1_900, endMs: 2_800, confidence: 1, speakerId: "S2"),
            ]
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Ben")]
        row.speakerCount = 2
        row.derivedTitle = "General Kenobi"
        return row
    }

    private func makeViewModel(
        _ row: Transcription,
        cleanupMode: CleanupMode = .raw,
        paths: AppPaths? = nil
    ) async -> (TranscriptViewModel, FakeStore, InMemorySettingsStore) {
        let store = FakeStore(rows: [row])
        var settingsValue = TranscriptionSettings()
        settingsValue.cleanupMode = cleanupMode
        let settings = InMemorySettingsStore(settingsValue)
        let viewModel = TranscriptViewModel(
            id: row.id, store: store, paths: paths ?? makePaths(), settings: settings)
        await viewModel.load()
        return (viewModel, store, settings)
    }

    func testLoadBuildsParagraphsFromWords() async {
        let (viewModel, _, _) = await makeViewModel(completedRow())

        XCTAssertNotNil(viewModel.transcription)
        XCTAssertEqual(viewModel.paragraphs.map(\.speakerId), ["S1", "S2"])
        XCTAssertEqual(viewModel.paragraphs.map(\.text), ["Hello there.", "General Kenobi."])
        XCTAssertEqual(viewModel.paragraphs.last?.startMs, 1_300)
    }

    func testParagraphsFallBackToDisplayTextWithoutWords() async {
        var row = completedRow()
        row.wordTimestamps = nil
        let (viewModel, _, _) = await makeViewModel(row)

        XCTAssertEqual(viewModel.paragraphs.count, 1)
        XCTAssertEqual(viewModel.paragraphs.first?.text, row.displayText)
        XCTAssertNil(viewModel.paragraphs.first?.speakerId)
    }

    func testSpeakerLabelFallsBackToIdThenSpeaker() async {
        let (viewModel, _, _) = await makeViewModel(completedRow())

        XCTAssertEqual(viewModel.speakerLabel(for: "S1"), "Speaker 1")
        XCTAssertEqual(viewModel.speakerLabel(for: "S2"), "Ben")
        XCTAssertEqual(viewModel.speakerLabel(for: "S7"), "S7")
        XCTAssertEqual(viewModel.speakerLabel(for: nil), "Speaker")
    }

    func testPlainTextFollowsCleanupMode() async {
        let row = completedRow()
        let (rawViewModel, _, _) = await makeViewModel(row, cleanupMode: .raw)
        XCTAssertEqual(rawViewModel.plainText, "um hello there general kenobi")

        let (cleanViewModel, _, _) = await makeViewModel(row, cleanupMode: .clean)
        XCTAssertEqual(cleanViewModel.plainText, "Hello there, General Kenobi.")

        var rawOnly = row
        rawOnly.cleanTranscript = nil
        let (fallbackViewModel, _, _) = await makeViewModel(rawOnly, cleanupMode: .clean)
        XCTAssertEqual(fallbackViewModel.plainText, "um hello there general kenobi")
    }

    func testMediaURLResolvesTheStoredSource() async throws {
        let paths = makePaths()
        let row = completedRow()
        let source = paths.mediaDirectory(for: row.id).appendingPathComponent("source.m4a")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: source)

        let (viewModel, _, _) = await makeViewModel(row, paths: paths)

        XCTAssertEqual(viewModel.mediaURL?.standardizedFileURL, source.standardizedFileURL)
    }

    func testMediaURLIsNilWhenTheFileIsMissing() async {
        let (viewModel, _, _) = await makeViewModel(completedRow())
        XCTAssertNil(viewModel.mediaURL)
    }

    func testExportFileWritesIntoPerTranscriptTemporaryFolder() async throws {
        let row = completedRow()
        let (viewModel, _, _) = await makeViewModel(row)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(row.id.uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        for format in ExportFormat.allCases {
            let url = try viewModel.exportFile(format)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
            XCTAssertEqual(url.pathExtension, format.fileExtension)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(contents.isEmpty, "\(format)")
        }
    }

    func testRenamePersistsTitleOverrideAndBlankClearsIt() async throws {
        let row = completedRow()
        let (viewModel, store, _) = await makeViewModel(row)

        try await viewModel.rename("  Jedi council  ")
        let renamed = await store.row(row.id)
        XCTAssertEqual(renamed?.titleOverride, "Jedi council")
        XCTAssertEqual(viewModel.transcription?.displayTitle, "Jedi council")

        try await viewModel.rename("   ")
        let cleared = await store.row(row.id)
        XCTAssertNil(cleared?.titleOverride)
        XCTAssertEqual(viewModel.transcription?.displayTitle, "General Kenobi")
    }

    func testToggleFavoritePersists() async throws {
        let row = completedRow()
        let (viewModel, store, _) = await makeViewModel(row)

        try await viewModel.toggleFavorite()

        let stored = await store.row(row.id)
        XCTAssertEqual(stored?.isFavorite, true)
        XCTAssertEqual(viewModel.transcription?.isFavorite, true)
    }

    func testRenameAndFavoriteLandingAfterCompletionKeepTranscript() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let viewModel = TranscriptViewModel(id: id, store: h.store, paths: h.paths, settings: h.settings)
        await viewModel.load()
        XCTAssertEqual(viewModel.transcription?.status, .processing)
        let write = await h.store.holdNext([.updateTitleOverride, .update])

        let rename = Task { try await viewModel.rename("Budget review") }
        await write.entered.wait()
        let completed = await h.pipeline.process(id: id)
        XCTAssertEqual(completed?.status, .completed)
        write.release.fire()
        try await rename.value
        try await viewModel.toggleFavorite()

        let fetched = await h.store.row(id)
        let row = try XCTUnwrap(fetched)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.titleOverride, "Budget review")
        XCTAssertTrue(row.isFavorite)
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertEqual(viewModel.transcription, row, "the screen shows the row as stored, transcript included")
        XCTAssertFalse(viewModel.paragraphs.isEmpty)
        let wholeRowUpdates = await h.store.wholeRowUpdates
        XCTAssertEqual(wholeRowUpdates, 0)
    }

    func testRenameOfDeletedRowThrowsNotLoaded() async throws {
        let row = completedRow()
        let (viewModel, store, _) = await makeViewModel(row)
        try await store.delete(id: row.id)

        do {
            try await viewModel.rename("Anything")
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? TranscriptViewModel.TranscriptError, .notLoaded)
        }
    }

    func testLoadOfMissingRowLeavesTranscriptionNil() async {
        let store = FakeStore()
        let viewModel = TranscriptViewModel(
            id: UUID(), store: store, paths: makePaths(), settings: InMemorySettingsStore())
        await viewModel.load()

        XCTAssertNil(viewModel.transcription)
        XCTAssertTrue(viewModel.paragraphs.isEmpty)
        XCTAssertEqual(viewModel.plainText, "")
        XCTAssertThrowsError(try viewModel.exportFile(.txt))
    }
}
