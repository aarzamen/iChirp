import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

final class FileTranscriptionPipelineTests: XCTestCase {
    private let missingModelMessage = "Download the Parakeet speech model in Settings → Speech model"

    // MARK: - Import

    func testImportCopiesSourceIntoMediaFolderAndInsertsProcessingRow() async throws {
        let h = try PipelineHarness(testCase: self)
        let source = try h.makeSourceFile(named: "Interview.m4a", bytes: 1_024)

        let id = try await h.pipeline.importFile(from: source)

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(row.status, .processing)
        XCTAssertEqual(row.sourceType, .file)
        XCTAssertEqual(row.fileName, "Interview.m4a")
        XCTAssertEqual(row.mediaRelativePath, "media/\(id.uuidString)/source.m4a")
        XCTAssertEqual(row.fileSizeBytes, 1_024)
        XCTAssertEqual(row.durationMs, FakeNormalizer.durationMs)
        XCTAssertTrue(fileExists(h.sourceURL(for: id)), "the source is copied into media/<id>/")
        XCTAssertTrue(fileExists(source), "import copies, it never moves the user's file")
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(transcribeCalls, 0, "import does not transcribe")
        XCTAssertEqual(h.recorder.progress(for: id).first?.stage, .importing)
    }

    func testImportKeepsSourceTypeParameter() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.pipeline.importFile(from: h.makeSourceFile(named: "clip.mov"), sourceType: .document)

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(row.sourceType, .document)
        XCTAssertEqual(row.mediaRelativePath, "media/\(id.uuidString)/source.mov")
    }

    func testImportDurationFailureIsNonFatal() async throws {
        let h = try PipelineHarness(testCase: self)
        await h.normalizer.failDuration(with: FakeError(message: "unreadable header"))

        let id = try await h.importSample()

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(row.status, .processing)
        XCTAssertNil(row.durationMs)
    }

    func testImportOfMissingFileThrowsAndLeavesNoRowOrFolder() async throws {
        let h = try PipelineHarness(testCase: self)
        let missing = h.inbox.appendingPathComponent("gone.m4a")

        do {
            _ = try await h.pipeline.importFile(from: missing)
            XCTFail("expected import to throw")
        } catch {}

        let rows = try await h.store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
        let media = h.root.appendingPathComponent("media", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "a failed import removes the folder it created: \(leftovers)")
    }

    // MARK: - Process

    func testProcessProducesCompletedTranscriptWithSpeakersAndSegments() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()

        let result = await h.pipeline.process(id: id)

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(result, row)
        XCTAssertEqual(row.status, .completed)
        XCTAssertNil(row.errorMessage)
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertEqual(row.language, "en")
        XCTAssertEqual(row.durationMs, FakeNormalizer.durationMs)
        XCTAssertEqual(row.speakerCount, 2)
        XCTAssertEqual(row.speakers, FakeDiarizer.twoSpeakers)
        XCTAssertEqual(row.diarizationSegments, FakeDiarizer.twoSpeakerSegments)
        XCTAssertEqual(row.wordTimestamps?.map(\.speakerId), ["S1", "S1", "S2", "S2"])
        let segments = try XCTUnwrap(row.transcriptSegments)
        XCTAssertEqual(segments.first?.speakerId, "S1")
        XCTAssertEqual(segments.first?.speakerLabel, "Speaker 1")
        XCTAssertEqual(segments.last?.speakerId, "S2")
        XCTAssertFalse((row.derivedTitle ?? "").isEmpty)
        XCTAssertNotNil(row.derivedSnippet)
        XCTAssertEqual(row.engine, "fake.parakeet", "engine is the descriptor id")
        XCTAssertEqual(row.engineVariant, "v3")

        XCTAssertFalse(fileExists(h.normalizedURL(for: id)), "the normalized WAV is a temp artifact")
        XCTAssertTrue(fileExists(h.sourceURL(for: id)), "the source file is kept")
        let transcribedURLs = await h.speech.transcribedURLs
        XCTAssertEqual(transcribedURLs, [h.normalizedURL(for: id)], "the engine reads the normalized WAV")
        let inputExisted = await h.speech.inputExistedAtTranscribe
        XCTAssertEqual(inputExisted, [true])
        let prepareCalls = await h.speech.prepareCalls
        XCTAssertEqual(prepareCalls, 1, "models are loaded before transcribing")
    }

    func testSpeakersListOnlyIdsPresentInMergedWords() async throws {
        let h = try PipelineHarness(testCase: self)
        await h.diarizer.setOutput(
            DiarizationOutput(
                segments: FakeDiarizer.twoSpeakerSegments + [
                    DiarizationSegmentRecord(speakerId: "S3", startMs: 2_900, endMs: 3_000)
                ],
                speakers: FakeDiarizer.twoSpeakers + [SpeakerInfo(id: "S3", label: "Speaker 3")]
            ))
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.speakerCount, 2, "S3 owns no word")
        XCTAssertEqual(row.speakers?.map(\.id), ["S1", "S2"])
    }

    func testProgressWalksTheStagesInOrderWithRisingFractions() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        await h.pipeline.process(id: id)

        let events = h.recorder.progress(for: id)
        var stages: [PipelineStage] = []
        for event in events where stages.last != event.stage {
            stages.append(event.stage)
        }
        XCTAssertEqual(
            stages,
            [.importing, .normalizing, .waitingForEngine, .transcribing, .identifyingSpeakers, .finishing]
        )
        let fractions = events.map(\.fraction)
        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards: \(fractions)")
        XCTAssertEqual(events.first, JobProgress(stage: .importing, fraction: 0.02))
        XCTAssertEqual(events.last, JobProgress(stage: .finishing, fraction: 1))
        let transcribing = events.filter { $0.stage == .transcribing }.map(\.fraction)
        XCTAssertEqual(transcribing.first ?? -1, 0.15, accuracy: 0.0001)
        XCTAssertEqual(transcribing.last ?? -1, 0.85, accuracy: 0.0001)
    }

    func testMissingModelFailsWithActionableMessage() async throws {
        let h = try PipelineHarness(testCase: self, speech: FakeSpeech(status: .notDownloaded))
        let id = try await h.importSample()

        let result = await h.pipeline.process(id: id)

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(result, row)
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.errorMessage, missingModelMessage)
        let transcribeCalls = await h.speech.transcribeCalls
        let downloadCalls = await h.speech.downloadCalls
        XCTAssertEqual(transcribeCalls, 0)
        XCTAssertEqual(downloadCalls, 0, "the pipeline never downloads silently")
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
        XCTAssertTrue(fileExists(h.sourceURL(for: id)))
    }

    func testModelNotDownloadedFromPrepareMapsToActionableMessage() async throws {
        let h = try PipelineHarness(testCase: self)
        await h.speech.failPrepare(with: SpeechEngineError.modelNotDownloaded("Parakeet TDT v3"))
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.errorMessage, missingModelMessage)
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
    }

    func testEngineFailureMarksFailedWithErrorMessage() async throws {
        let h = try PipelineHarness(testCase: self)
        await h.speech.failTranscription(with: SpeechEngineError.emptyTranscript)
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.errorMessage, "No speech was recognized in this recording.")
        XCTAssertNil(row.rawTranscript)
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
        XCTAssertTrue(fileExists(h.sourceURL(for: id)))
    }

    func testMissingSourceFileFailsWithReadableMessage() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        try FileManager.default.removeItem(at: h.sourceURL(for: id))

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.errorMessage, FileTranscriptionPipeline.PipelineError.sourceFileMissing.errorDescription)
    }

    func testDiarizationFailureIsNonFatal() async throws {
        let h = try PipelineHarness(testCase: self)
        await h.diarizer.failDiarization(with: FakeError(message: "diarizer exploded"))
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .completed)
        XCTAssertTrue(row.speakerCount == nil || row.speakerCount == 0)
        XCTAssertNil(row.speakers)
        XCTAssertEqual(row.wordTimestamps?.compactMap(\.speakerId), [])
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
    }

    func testSpeakerLabelsOffSkipsDiarizer() async throws {
        var settings = TranscriptionSettings()
        settings.speakerLabelsEnabled = false
        let h = try PipelineHarness(testCase: self, settings: settings)
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .completed)
        XCTAssertNil(row.speakerCount)
        let diarizeCalls = await h.diarizer.diarizeCalls
        XCTAssertEqual(diarizeCalls, 0)
        XCTAssertFalse(h.recorder.progress(for: id).contains { $0.stage == .identifyingSpeakers })
    }

    func testDiarizerNotReadySkipsDiarizationWithoutDownloading() async throws {
        let h = try PipelineHarness(testCase: self, diarizer: FakeDiarizer(status: .notDownloaded))
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .completed)
        XCTAssertNil(row.speakerCount)
        let diarizeCalls = await h.diarizer.diarizeCalls
        let downloadCalls = await h.diarizer.downloadCalls
        XCTAssertEqual(diarizeCalls, 0)
        XCTAssertEqual(downloadCalls, 0)
    }

    func testNoDiarizerStillCompletes() async throws {
        let h = try PipelineHarness(testCase: self, includeDiarizer: false)
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .completed)
        XCTAssertNil(row.speakerCount)
    }

    // MARK: - Clean-up

    func testCleanupRawLeavesCleanTranscriptNil() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
        XCTAssertNil(row.cleanTranscript)
    }

    func testCleanupCleanRemovesUm() async throws {
        var settings = TranscriptionSettings()
        settings.cleanupMode = .clean
        let h = try PipelineHarness(testCase: self, settings: settings)
        await h.speech.setTranscript(
            text: "Um so we start.",
            words: [
                WordTimestamp(word: "Um", startMs: 0, endMs: 300, confidence: 0.9),
                WordTimestamp(word: "so", startMs: 300, endMs: 600, confidence: 0.9),
                WordTimestamp(word: "we", startMs: 600, endMs: 900, confidence: 0.9),
                WordTimestamp(word: "start.", startMs: 900, endMs: 1_400, confidence: 0.9),
            ])
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.rawTranscript, "Um so we start.", "raw keeps the engine's literal text")
        let clean = try XCTUnwrap(row.cleanTranscript)
        let words = clean.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        XCTAssertFalse(words.contains("um"), clean)
        XCTAssertTrue(clean.lowercased().contains("we start"), clean)
    }

    func testCleanupCleanAppliesCustomWords() async throws {
        var settings = TranscriptionSettings()
        settings.cleanupMode = .clean
        let h = try PipelineHarness(
            testCase: self,
            settings: settings,
            customWords: [CustomWord(word: "Kenobi", replacement: "Kenobi-sama")]
        )
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.cleanTranscript?.contains("Kenobi-sama"), true, row.cleanTranscript ?? "nil")
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
    }

    // MARK: - Concurrency with the user and the job owner

    func testUserTitleEditedDuringProcessingIsPreserved() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let hold = await h.speech.holdNextTranscription()

        let job = Task { await h.pipeline.process(id: id) }
        await hold.entered.wait()
        let stored = await h.store.row(id)
        var edited = try XCTUnwrap(stored)
        edited.titleOverride = "Budget review"
        edited.isFavorite = true
        try await h.store.update(edited)
        hold.release.fire()
        let result = await job.value

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(result, row)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.titleOverride, "Budget review")
        XCTAssertTrue(row.isFavorite)
        XCTAssertEqual(row.displayTitle, "Budget review")
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText)
    }

    func testCancellationMarksCancelled() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let hold = await h.speech.holdNextTranscription()

        let job = Task { await h.pipeline.process(id: id) }
        await hold.entered.wait()
        job.cancel()
        let result = await job.value

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(result, row)
        XCTAssertEqual(row.status, .cancelled, "the terminal status is written even though the task is cancelled")
        XCTAssertNil(row.errorMessage)
        XCTAssertNil(row.rawTranscript)
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)), "the temp WAV is deleted on cancel")
        XCTAssertTrue(fileExists(h.sourceURL(for: id)), "cancel never deletes the source")
    }

    func testCancellationBeforeProcessStartsMarksCancelled() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let gate = Signal()

        let job = Task {
            await gate.wait()
            return await h.pipeline.process(id: id)
        }
        job.cancel()
        let result = await job.value

        XCTAssertEqual(result?.status, .cancelled)
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(transcribeCalls, 0)
    }

    func testRowDeletedDuringProcessingIsNotRecreated() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let hold = await h.speech.holdNextTranscription()

        let job = Task { await h.pipeline.process(id: id) }
        await hold.entered.wait()
        try await h.store.delete(id: id)
        hold.release.fire()
        let result = await job.value

        XCTAssertNil(result)
        let row = await h.store.row(id)
        XCTAssertNil(row, "a user delete during processing wins")
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
    }

    func testSecondProcessOfARunningIdIsIgnored() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let hold = await h.speech.holdNextTranscription()

        let first = Task { await h.pipeline.process(id: id) }
        await hold.entered.wait()
        let second = await h.pipeline.process(id: id)
        hold.release.fire()
        let firstResult = await first.value

        XCTAssertNil(second)
        XCTAssertEqual(firstResult?.status, .completed)
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(transcribeCalls, 1)
    }

    // MARK: - Retry

    func testRetryReprocessesFailedRowFromStoredSource() async throws {
        let h = try PipelineHarness(testCase: self)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))
        let id = try await h.importSample()
        let fetchedFailed = await h.pipeline.process(id: id)
        let failed = try XCTUnwrap(fetchedFailed)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.errorMessage, "engine hiccup")

        await h.speech.failTranscription(with: nil)
        let fetchedRetried = await h.pipeline.retry(id: id)
        let retried = try XCTUnwrap(fetchedRetried)

        XCTAssertEqual(retried.status, .completed)
        XCTAssertNil(retried.errorMessage)
        XCTAssertEqual(retried.rawTranscript, FakeSpeech.helloText)
        let transcribedURLs = await h.speech.transcribedURLs
        XCTAssertEqual(transcribedURLs, [h.normalizedURL(for: id), h.normalizedURL(for: id)])
        XCTAssertTrue(fileExists(h.sourceURL(for: id)))
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
    }

    func testRetryResetsStatusToProcessingBeforeWork() async throws {
        let h = try PipelineHarness(testCase: self)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))
        let id = try await h.importSample()
        await h.pipeline.process(id: id)
        await h.speech.failTranscription(with: nil)
        let hold = await h.speech.holdNextTranscription()

        let job = Task { await h.pipeline.retry(id: id) }
        await hold.entered.wait()
        let fetchedDuring = await h.store.row(id)
        let during = try XCTUnwrap(fetchedDuring)
        hold.release.fire()
        _ = await job.value

        XCTAssertEqual(during.status, .processing)
        XCTAssertNil(during.errorMessage)
    }

    func testRetryOfUnknownIdReturnsNil() async throws {
        let h = try PipelineHarness(testCase: self)
        let result = await h.pipeline.retry(id: UUID())
        XCTAssertNil(result)
    }
}
