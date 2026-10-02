import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

final class FileTranscriptionPipelineTests: XCTestCase {
    /// Review R4-13: Settings has no "Speech model" row any more; Parakeet's Download is under Speech engines.
    private let missingModelMessage = "Download the Parakeet speech model in Settings → Speech engines"

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
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: h.staging.path), [],
            "the import's journal goes once the row exists")
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(transcribeCalls, 0, "import does not transcribe")
        XCTAssertEqual(h.recorder.progress(for: id).first?.stage, .importing)
    }

    /// Plan 022 review I1: Create imports a file with the class the person chose, from the row's first write.
    func testImportCanCreateTheRowClinicalFromTheStart() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.pipeline.importFile(from: h.makeSourceFile(named: "Visit.m4a"), privacyClass: .clinical)
        let row = await h.store.row(id)
        XCTAssertEqual(row?.privacyClass, .clinical)
        let history = await h.store.classHistory(id)
        XCTAssertEqual(history, [.clinical], "never stored Personal first")
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

    /// fix/speech-memory-fit: an engine that refuses a load that would not fit (instead of iOS terminating the app)
    /// fails the job with a sentence naming both numbers, keeps the source, and Retry runs it again.
    func testAModelThatDoesNotFitFailsWithBothNumbersAndRetryRunsItAgain() async throws {
        let h = try PipelineHarness(testCase: self)
        let turbo = SpeechEngineVariantKey(
            engineID: SpeechEngineCapabilityRegistry.whisperKitEngineID, variant: "large-v3-turbo")
        await h.speech.failPrepare(
            with: SpeechEngineError.insufficientMemory(turbo, needed: 3_500_000_000, available: 2_100_000_000))
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(
            row.errorMessage,
            "Whisper Large v3 Turbo needs about 3.5 GB of memory while it loads, and Parakeet can use about 2.1 GB "
                + "right now. Close other apps or use Whisper Base.")
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(transcribeCalls, 0)
        XCTAssertTrue(fileExists(h.sourceURL(for: id)))

        await h.speech.failPrepare(with: nil)
        let retried = await h.pipeline.retry(id: id)
        XCTAssertEqual(retried?.status, .completed)
        XCTAssertEqual(retried?.rawTranscript, FakeSpeech.helloText)
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

    // MARK: - Privacy routing

    func testClinicalItemIsRefusedByACloudSpeechEngine() async throws {
        let h = try PipelineHarness(testCase: self, speech: FakeSpeech(locality: .cloud))
        let id = try await h.importSample()
        await h.store.setPrivacyClass(.clinical, for: id)

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(
            row.errorMessage,
            FileTranscriptionPipeline.PipelineError.privacyRoutingRefused(engineName: "Fake Parakeet").errorDescription)
        let prepareCalls = await h.speech.prepareCalls
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(prepareCalls, 0)
        XCTAssertEqual(transcribeCalls, 0, "clinical audio never reaches a cloud engine")
        let started = await h.normalizer.startedOutputURLs
        XCTAssertTrue(started.isEmpty, "the audio is not even prepared for an engine that may not have it")
        XCTAssertTrue(fileExists(h.sourceURL(for: id)))
    }

    func testPrivacyClassChangedWhileTheJobWaitsIsCheckedBeforeTheEngineGetsAudio() async throws {
        let (entered, sink) = AsyncStream.makeStream(of: Void.self)
        let h = try PipelineHarness(testCase: self, speech: FakeSpeech(locality: .cloud))
        await h.normalizer.parkNormalizations { sink.yield() }
        let id = try await h.importSample()
        let job = Task { await h.pipeline.process(id: id) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // The user marks the item clinical while its audio is being prepared (M4 adds the control).
        await h.store.setPrivacyClass(.clinical, for: id)
        await h.normalizer.releaseParked()
        let result = await job.value

        XCTAssertEqual(result?.status, .failed)
        XCTAssertEqual(
            result?.errorMessage,
            FileTranscriptionPipeline.PipelineError.privacyRoutingRefused(engineName: "Fake Parakeet").errorDescription)
        let prepareCalls = await h.speech.prepareCalls
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(prepareCalls, 0)
        XCTAssertEqual(transcribeCalls, 0)
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
    }

    func testClinicalItemRunsOnAnOnDeviceEngine() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        await h.store.setPrivacyClass(.clinical, for: id)

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.privacyClass, .clinical)
        XCTAssertEqual(row.speakerCount, 2, "the on-device diarizer runs too")
    }

    func testPersonalItemMayUseACloudSpeechEngine() async throws {
        let h = try PipelineHarness(testCase: self, speech: FakeSpeech(locality: .cloud))
        let id = try await h.importSample()

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .completed)
    }

    func testClinicalItemSkipsACloudDiarizer() async throws {
        let h = try PipelineHarness(testCase: self, diarizer: FakeDiarizer(locality: .cloud))
        let id = try await h.importSample()
        await h.store.setPrivacyClass(.clinical, for: id)

        let fetchedRow = await h.pipeline.process(id: id)
        let row = try XCTUnwrap(fetchedRow)

        XCTAssertEqual(row.status, .completed, "speaker labels are optional, so the job still completes")
        XCTAssertNil(row.speakerCount)
        let diarizeCalls = await h.diarizer.diarizeCalls
        XCTAssertEqual(diarizeCalls, 0, "clinical audio never reaches a cloud diarizer")
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

    // MARK: - Learned rules (plan 025 B4)

    func testLearnedRuleBecomesACorrectionInRawMode() async throws {
        let rule = CustomWord(word: "kenobi", replacement: "Kenobi-sama", source: .learned)
        let h = try PipelineHarness(testCase: self, learnedRules: [rule])
        let id = try await h.importSample()

        let result = await h.pipeline.process(id: id)
        let stored = await h.store.row(id)
        let row = try XCTUnwrap(stored)

        XCTAssertEqual(result, row, "the job returns the row with its rule corrections")
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.rawTranscript, FakeSpeech.helloText, "the words as heard are kept")
        XCTAssertEqual(row.wordTimestamps?.map(\.word), FakeSpeech.helloWords.map(\.word))
        XCTAssertNil(row.cleanTranscript, "Raw mode: no clean text")
        XCTAssertEqual(row.textCorrections?.items.map(\.origin), [.rule])
        XCTAssertEqual(row.textCorrections?.items.map(\.ruleID), [rule.id])
        XCTAssertEqual(row.textCorrections?.items.map(\.heard), ["Kenobi."])
        XCTAssertEqual(row.plainText(.shown(.raw)), "Hello there. General Kenobi-sama.")
        XCTAssertEqual(row.text(.heard).lines.map(\.text).joined(separator: " "), "Hello there. General Kenobi-sama.")
    }

    func testManualWordsStillApplyOnlyInClean() async throws {
        let manual = [CustomWord(word: "Kenobi", replacement: "Kenobi-sama")]
        let raw = try PipelineHarness(testCase: self, customWords: manual)
        let rawID = try await raw.importSample()
        let rawRow = await raw.pipeline.process(id: rawID)
        XCTAssertNil(rawRow?.cleanTranscript, "Raw: manual words do nothing")
        XCTAssertNil(rawRow?.textCorrections, "manual words never become corrections")
        XCTAssertEqual(rawRow?.plainText(.shown(.raw)), FakeSpeech.helloText)

        var settings = TranscriptionSettings()
        settings.cleanupMode = .clean
        let clean = try PipelineHarness(testCase: self, settings: settings, customWords: manual)
        let cleanID = try await clean.importSample()
        let cleanRow = await clean.pipeline.process(id: cleanID)
        XCTAssertEqual(cleanRow?.cleanTranscript?.contains("Kenobi-sama"), true)
        XCTAssertNil(cleanRow?.textCorrections)
        XCTAssertEqual(cleanRow?.text(.heard).lines.map(\.text).joined(separator: " "), FakeSpeech.helloText)
    }

    // MARK: - Concurrency with the user and the job owner

    func testUserTitleEditedDuringProcessingIsPreserved() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let hold = await h.speech.holdNextTranscription()

        let job = Task { await h.pipeline.process(id: id) }
        await hold.entered.wait()
        _ = try await h.store.updateTitleOverride(id: id, titleOverride: "Budget review")
        _ = try await h.store.updateFavorite(id: id, isFavorite: true)
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

    func testDeleteRightBeforeCompletionSaveIsNotResurrected() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let save = await h.store.holdNext([.savePreservingUserMetadata])

        let job = Task { await h.pipeline.process(id: id) }
        await save.entered.wait()
        try await h.store.delete(id: id)
        save.release.fire()
        let result = await job.value

        XCTAssertNil(result)
        let row = await h.store.row(id)
        XCTAssertNil(row, "the completion save never re-inserts a row the user deleted")
        let all = try await h.store.fetchAll()
        XCTAssertTrue(all.isEmpty)
        XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
    }

    func testFailureKeepsRenameAndFavoriteMadeDuringJob() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let hold = await h.speech.holdNextTranscription()

        let job = Task { await h.pipeline.process(id: id) }
        await hold.entered.wait()
        _ = try await h.store.updateTitleOverride(id: id, titleOverride: "Board call")
        _ = try await h.store.updateFavorite(id: id, isFavorite: true)
        await h.speech.failTranscription(with: FakeError(message: "engine hiccup"))
        hold.release.fire()
        let result = await job.value

        let fetchedRow = await h.store.row(id)
        let row = try XCTUnwrap(fetchedRow)
        XCTAssertEqual(result, row)
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.errorMessage, "engine hiccup")
        XCTAssertEqual(row.titleOverride, "Board call", "marking the failure changes only status and message")
        XCTAssertTrue(row.isFavorite)
        let wholeRowUpdates = await h.store.wholeRowUpdates
        XCTAssertEqual(wholeRowUpdates, 0, "the pipeline never writes a whole stale row")
    }

    func testProcessOfARowThatIsNotProcessingDoesNotRun() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let completed = await h.pipeline.process(id: id)
        XCTAssertEqual(completed?.status, .completed)

        let again = await h.pipeline.process(id: id)

        XCTAssertEqual(again, completed, "a finished row is returned unchanged")
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(transcribeCalls, 1)
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

    // MARK: - Audio preparation limit

    func testConcurrentProcessCallsNeverExceedTheAudioPreparationLimit() async throws {
        let (events, sink) = AsyncStream.makeStream(of: String.self)
        let h = try PipelineHarness(
            testCase: self,
            onProgress: { _, progress in
                if progress.stage == .queued { sink.yield("queued") }
            })
        await h.normalizer.parkNormalizations { sink.yield("normalizing") }
        var ids: [UUID] = []
        for index in 0..<5 {
            ids.append(try await h.importSample(named: "file-\(index).m4a"))
        }

        let jobs = ids.map { id in Task { await h.pipeline.process(id: id) } }
        // Every job either starts normalizing or reports that it is queued; wait until all five have done one.
        var iterator = events.makeAsyncIterator()
        var seen: [String] = []
        while seen.count < ids.count, let event = await iterator.next() {
            seen.append(event)
        }

        let limit = FileTranscriptionPipeline.maxConcurrentAudioPreparations
        XCTAssertEqual(limit, 2)
        XCTAssertEqual(seen.filter { $0 == "normalizing" }.count, limit, "\(seen)")
        XCTAssertEqual(seen.filter { $0 == "queued" }.count, ids.count - limit, "\(seen)")
        let activeWhileParked = await h.normalizer.active
        XCTAssertEqual(activeWhileParked, limit)

        await h.normalizer.releaseParked()
        var statuses: [Transcription.Status?] = []
        for job in jobs {
            statuses.append(await job.value?.status)
        }

        XCTAssertEqual(statuses, Array(repeating: .completed, count: ids.count))
        let maxActive = await h.normalizer.maxActive
        XCTAssertEqual(maxActive, limit, "never more than \(limit) normalizations at once")
        for id in ids {
            XCTAssertFalse(fileExists(h.normalizedURL(for: id)))
        }
    }

    func testCancellingAJobQueuedForAudioPreparationMarksItCancelledWithoutNormalizing() async throws {
        let (queued, sink) = AsyncStream.makeStream(of: UUID.self)
        let h = try PipelineHarness(
            testCase: self,
            onProgress: { id, progress in
                if progress.stage == .queued { sink.yield(id) }
            })
        await h.normalizer.parkNormalizations {}
        var jobs: [UUID: Task<Transcription?, Never>] = [:]
        for index in 0..<3 {
            let id = try await h.importSample(named: "file-\(index).m4a")
            jobs[id] = Task { await h.pipeline.process(id: id) }
        }
        var iterator = queued.makeAsyncIterator()
        let queuedValue = await iterator.next()
        let queuedID = try XCTUnwrap(queuedValue)
        let queuedJob = try XCTUnwrap(jobs[queuedID])

        queuedJob.cancel()
        let cancelled = await queuedJob.value

        XCTAssertEqual(cancelled?.status, .cancelled)
        let started = await h.normalizer.startedOutputURLs
        XCTAssertFalse(started.contains(h.normalizedURL(for: queuedID)), "a queued job never starts normalizing")
        XCTAssertTrue(fileExists(h.sourceURL(for: queuedID)), "cancel never deletes the source")

        await h.normalizer.releaseParked()
        for (id, job) in jobs where id != queuedID {
            let status = await job.value?.status
            XCTAssertEqual(status, .completed)
        }
        // The cancelled waiter left no permit behind: a later job still runs.
        let late = try await h.importSample(named: "late.m4a")
        let lateResult = await h.pipeline.process(id: late)
        XCTAssertEqual(lateResult?.status, .completed)
    }

    func testFileWorkRunsOnTheFileQueue() async throws {
        let label = try await PipelineJobSupport.runOnFileQueue {
            String(cString: __dispatch_queue_get_label(nil))
        }
        XCTAssertEqual(label, PipelineJobSupport.fileQueueLabel)
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

    func testRetryOfACompletedRowIsRefused() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let completed = await h.pipeline.process(id: id)

        let result = await h.pipeline.retry(id: id)

        XCTAssertNil(result, "retry only moves failed, cancelled or interrupted rows back to processing")
        let row = await h.store.row(id)
        XCTAssertEqual(row, completed)
        let transcribeCalls = await h.speech.transcribeCalls
        XCTAssertEqual(transcribeCalls, 1)
    }

    func testRetryOfAnInterruptedRowRuns() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let interruptedCount = try await h.store.markStaleProcessingAsInterrupted()
        XCTAssertEqual(interruptedCount, 1)

        let result = await h.pipeline.retry(id: id)

        XCTAssertEqual(result?.status, .completed)
        let wholeRowUpdates = await h.store.wholeRowUpdates
        XCTAssertEqual(wholeRowUpdates, 0)
    }

    /// Plan 025 D7: the one path that re-runs the engine over a completed row (a status a newer build wrote reads as
    /// interrupted, which offers Retry) keeps the person's corrections when the words come back the same, and detaches
    /// them (kept, listed, never applied) when they do not.
    func testRetryOfACorrectedRowKeepsOrDetachesCorrections() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample()
        let completed = await h.pipeline.process(id: id)
        let words = try XCTUnwrap(completed?.wordTimestamps)
        let now = Date(timeIntervalSinceReferenceDate: 790_000_000)
        let corrected = try await h.store.updateTextCorrections(id: id) { row in
            row.textCorrections = try (row.textCorrections ?? .empty).applying(
                TranscriptCorrectionPlan(add: [
                    TranscriptCorrection(
                        wordRange: 0..<1, heard: "", text: "Howdy", origin: .edit, createdAt: now, updatedAt: now)
                ]), words: row.wordTimestamps ?? [], now: now
            ).corrections
            row.derivedTitle = "Corrected title"
            return true
        }
        let items = try XCTUnwrap(corrected?.textCorrections?.items)
        XCTAssertEqual(items.count, 1)

        _ = try await h.store.transitionStatus(id: id, from: [.completed], to: .interrupted, errorMessage: nil)
        let same = await h.pipeline.retry(id: id)
        XCTAssertEqual(same?.status, .completed)
        XCTAssertEqual(same?.wordTimestamps, words)
        XCTAssertEqual(same?.textCorrections?.items, items, "same words: the corrections stay applied")
        XCTAssertEqual(same?.derivedTitle, "Corrected title")

        _ = try await h.store.transitionStatus(id: id, from: [.completed], to: .interrupted, errorMessage: nil)
        await h.speech.setTranscript(
            text: "Different words.",
            words: [
                WordTimestamp(word: "Different", startMs: 0, endMs: 300, confidence: 0.9),
                WordTimestamp(word: "words.", startMs: 300, endMs: 700, confidence: 0.9),
            ])
        let changed = await h.pipeline.retry(id: id)
        XCTAssertEqual(changed?.status, .completed)
        XCTAssertEqual(changed?.textCorrections?.items, [], "other words: nothing applied")
        XCTAssertEqual(changed?.textCorrections?.detached, items, "and nothing is lost")
        XCTAssertNotEqual(changed?.derivedTitle, "Corrected title")
    }

    // MARK: - Orphaned temporary audio

    func testSweepDeletesOnlyOrphanedNormalizedAudio() async throws {
        let h = try PipelineHarness(testCase: self)
        let fileManager = FileManager.default
        // A leftover from a killed process: its row is interrupted, its WAV is an orphan.
        let orphan = try await h.importSample(named: "old.m4a")
        try Data([1, 2, 3]).write(to: h.normalizedURL(for: orphan))
        // A folder whose name is not a transcription id is never touched.
        let stranger = h.root.appendingPathComponent("media/not-an-id", isDirectory: true)
        try fileManager.createDirectory(at: stranger, withIntermediateDirectories: true)
        let strangerWAV = stranger.appendingPathComponent("normalized-16k.wav")
        try Data([1]).write(to: strangerWAV)
        // A job running in this process keeps its WAV.
        let running = try await h.importSample(named: "live.m4a")
        let hold = await h.speech.holdNextTranscription()
        let job = Task { await h.pipeline.process(id: running) }
        await hold.entered.wait()

        let removed = await h.pipeline.sweepOrphanedTemporaryAudio()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fileExists(h.normalizedURL(for: orphan)))
        XCTAssertTrue(fileExists(h.sourceURL(for: orphan)), "the sweep never touches source files")
        XCTAssertTrue(fileExists(h.normalizedURL(for: running)), "a running job's WAV is not an orphan")
        XCTAssertTrue(fileExists(strangerWAV))
        hold.release.fire()
        let result = await job.value
        XCTAssertEqual(result?.status, .completed)
    }

    func testSweepWithNoMediaFolderReturnsZero() async throws {
        let h = try PipelineHarness(testCase: self)
        let removed = await h.pipeline.sweepOrphanedTemporaryAudio()
        XCTAssertEqual(removed, 0)
    }

    // MARK: - Interrupted imports (review R4-8)

    /// The moment a kill can strike between the copy and the row: the copy is complete in `media/<id>/` and the
    /// journal says what it is; nothing half-copied ever reaches `media/`. Once the row exists the journal is gone.
    func testAnImportJournalsTheFileBeforeItsRowAndClearsItOnceTheRowExists() async throws {
        let h = try PipelineHarness(testCase: self)
        let source = try h.makeMediaFile(named: "Synthetic visit.mov", audioTracks: 2)
        let hold = await h.store.holdNext([.insert])

        let job = Task {
            try await h.pipeline.importFile(from: source, audioTrackOrdinal: 1, privacyClass: .clinical)
        }
        await hold.entered.wait()

        let staged = try FileManager.default.contentsOfDirectory(atPath: h.staging.path)
        XCTAssertEqual(staged.count, 1, "one import in progress: \(staged)")
        let folderName = try XCTUnwrap(staged.first)
        let id = try XCTUnwrap(UUID(uuidString: String(folderName.dropFirst(PipelineJobSupport.stagingPrefix.count))))
        let folder = PipelineJobSupport.stagingFolder(for: id, in: h.staging)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path), [PipelineJobSupport.journalFileName],
            "the copy left the staging folder whole, in one move")
        let journal = try JSONDecoder().decode(
            ImportJournal.self,
            from: Data(contentsOf: folder.appendingPathComponent(PipelineJobSupport.journalFileName)))
        XCTAssertEqual(
            journal,
            ImportJournal(
                fileName: "Synthetic visit.mov", sourceType: .file, privacyClass: .clinical, audioTrackOrdinal: 1,
                documentFormat: nil))
        let copy = h.sourceURL(for: id, ext: "mov")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source), "the copy is complete")
        let rowWhileHeld = await h.store.row(id)
        XCTAssertNil(rowWhileHeld)

        hold.release.fire()
        let imported = try await job.value
        XCTAssertEqual(imported, id)
        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .processing)
        XCTAssertFalse(fileExists(folder), "the journal goes once the row exists")
    }

    /// A kill after the copy reached `media/<id>/` but before the row was written: the next launch adopts the file
    /// as an Interrupted item, as the import described it, and Retry transcribes it with the chosen track.
    func testAKilledImportWhoseCopyWasInComesBackAsAnInterruptedItemWithRetry() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = UUID()
        try writeJournal(
            ImportJournal(
                fileName: "Synthetic visit.mov", sourceType: .file, privacyClass: .clinical, audioTrackOrdinal: 1,
                documentFormat: nil),
            id: id, h: h)
        let copy = h.sourceURL(for: id, ext: "mov")
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyntheticMedia.write(to: copy, audioTracks: 2)

        let adopted = await h.pipeline.recoverInterruptedImports()

        XCTAssertEqual(adopted, 1)
        let stored = await h.store.row(id)
        let row = try XCTUnwrap(stored, "the file is never lost")
        XCTAssertEqual(row.status, .interrupted)
        XCTAssertEqual(row.sourceType, .file)
        XCTAssertEqual(row.fileName, "Synthetic visit.mov")
        XCTAssertEqual(row.privacyClass, .clinical, "the class the import was given")
        XCTAssertEqual(row.audioTrackOrdinal, 1, "the person's track choice")
        XCTAssertEqual(row.mediaRelativePath, "media/\(id.uuidString)/source.mov")
        XCTAssertEqual(row.fileSizeBytes, 64)
        XCTAssertNotNil(row.errorMessage)
        XCTAssertTrue(fileExists(copy), "the file is kept")
        XCTAssertFalse(fileExists(PipelineJobSupport.stagingFolder(for: id, in: h.staging)))

        let retried = await h.pipeline.retry(id: id)
        XCTAssertEqual(retried?.status, .completed)
        XCTAssertEqual(retried?.rawTranscript, FakeSpeech.helloText)
        let ordinals = await h.normalizer.requestedOrdinals
        XCTAssertEqual(ordinals, [1])
    }

    /// A kill in the middle of the copy: the incomplete copy never reached `media/`. It is deleted (the person's own
    /// file was only ever read) and nothing is adopted.
    func testACopyCutOffByAKillIsDeletedAndNothingIsAdopted() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = UUID()
        try writeJournal(
            ImportJournal(
                fileName: "Synthetic visit.m4a", sourceType: .file, privacyClass: .personal, audioTrackOrdinal: nil,
                documentFormat: nil),
            id: id, h: h)
        let folder = PipelineJobSupport.stagingFolder(for: id, in: h.staging)
        try Data(repeating: 7, count: 10).write(to: folder.appendingPathComponent("source.m4a"))

        let adopted = await h.pipeline.recoverInterruptedImports()

        XCTAssertEqual(adopted, 0)
        XCTAssertFalse(fileExists(folder), "the incomplete copy and its journal are gone")
        let rows = try await h.store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(fileExists(h.paths.mediaDirectory(for: id)))
    }

    /// A kill after the row was written but before its journal was removed: the row stands, only the journal goes.
    func testAJournalLeftAfterTheRowWasWrittenIsOnlyRemoved() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = try await h.importSample(named: "Synthetic memo.m4a")
        try writeJournal(
            ImportJournal(
                fileName: "Synthetic memo.m4a", sourceType: .file, privacyClass: .personal, audioTrackOrdinal: nil,
                documentFormat: nil),
            id: id, h: h)
        let before = await h.store.row(id)

        let adopted = await h.pipeline.recoverInterruptedImports()

        XCTAssertEqual(adopted, 0)
        let after = await h.store.row(id)
        XCTAssertEqual(after, before, "the row is not touched")
        XCTAssertFalse(fileExists(PipelineJobSupport.stagingFolder(for: id, in: h.staging)))
        XCTAssertTrue(fileExists(h.sourceURL(for: id)))
    }

    /// A media folder with no journal and no row (a deleted item whose folder could not be removed) is never brought
    /// back, and never deleted here either.
    func testAMediaFolderWithoutAJournalIsNeverAdopted() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = UUID()
        let copy = h.sourceURL(for: id)
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 32).write(to: copy)

        let adopted = await h.pipeline.recoverInterruptedImports()

        XCTAssertEqual(adopted, 0)
        let rows = try await h.store.fetchAll()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(fileExists(copy))
    }

    /// Ruling: when the journal cannot be read, the copy is still adopted, named neutrally and marked Clinical (the
    /// class the import was given is unknown, and Clinical is the safe side, as for any unknown class).
    func testAnUnreadableJournalStillAdoptsTheCopyAsClinical() async throws {
        let h = try PipelineHarness(testCase: self)
        let id = UUID()
        let folder = PipelineJobSupport.stagingFolder(for: id, in: h.staging)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: folder.appendingPathComponent(PipelineJobSupport.journalFileName))
        let copy = h.sourceURL(for: id)
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 16).write(to: copy)

        let adopted = await h.pipeline.recoverInterruptedImports()

        XCTAssertEqual(adopted, 1)
        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .interrupted)
        XCTAssertEqual(row?.sourceType, .file)
        XCTAssertEqual(row?.privacyClass, .clinical)
        XCTAssertEqual(row?.fileName, "Recovered file.m4a")
        XCTAssertNil(row?.audioTrackOrdinal)
    }

    /// A document cut off the same way comes back as a document, and Retry reads it.
    func testAKilledDocumentImportComesBackAsAnInterruptedDocument() async throws {
        let h = try PipelineHarness(testCase: self)
        let documents = DocumentImportPipeline(
            paths: h.paths, store: h.store, extractor: FakeExtractor(.succeed(DocumentImportPipelineTests.extracted)),
            stagingDirectory: h.staging, onProgress: { _, _ in })
        let id = UUID()
        try writeJournal(
            ImportJournal(
                fileName: "Synthetic handout.PDF", sourceType: .document, privacyClass: .personal,
                audioTrackOrdinal: nil, documentFormat: .pdf),
            id: id, h: h)
        let copy = h.sourceURL(for: id, ext: "pdf")
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: 128).write(to: copy)

        let adopted = await h.pipeline.recoverInterruptedImports()

        XCTAssertEqual(adopted, 1)
        let row = await h.store.row(id)
        XCTAssertEqual(row?.status, .interrupted)
        XCTAssertEqual(row?.sourceType, .document)
        XCTAssertEqual(row?.documentFormat, .pdf)
        XCTAssertEqual(row?.privacyClass, .personal)
        XCTAssertEqual(row?.fileName, "Synthetic handout.PDF")
        let retried = await documents.retry(id: id)
        XCTAssertEqual(retried?.status, .completed)
        XCTAssertEqual(retried?.rawTranscript, DocumentImportPipelineTests.extracted.text)
    }

    /// An import still running in this process is never taken for one a kill cut short.
    func testAnImportStillRunningIsLeftAlone() async throws {
        let h = try PipelineHarness(testCase: self)
        let hold = await h.store.holdNext([.insert])
        let job = Task { try await h.pipeline.importFile(from: h.makeSourceFile(named: "Synthetic live.m4a")) }
        await hold.entered.wait()

        let adopted = await h.pipeline.recoverInterruptedImports()

        XCTAssertEqual(adopted, 0)
        hold.release.fire()
        let id = try await job.value
        let rows = try await h.store.fetchAll()
        XCTAssertEqual(rows.map(\.id), [id], "one row, the import's own")
        XCTAssertEqual(rows.first?.status, .processing)
    }

    /// A failed import leaves no staging folder behind (and, as before, no row and no media folder).
    func testAFailedImportLeavesNoStagingFolder() async throws {
        let h = try PipelineHarness(testCase: self)
        do {
            _ = try await h.pipeline.importFile(from: h.inbox.appendingPathComponent("gone.m4a"))
            XCTFail("expected import to throw")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.staging.path), [])
    }

    private func writeJournal(_ journal: ImportJournal, id: UUID, h: PipelineHarness) throws {
        let folder = PipelineJobSupport.stagingFolder(for: id, in: h.staging)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: folder.appendingPathComponent(PipelineJobSupport.journalFileName))
    }
}
