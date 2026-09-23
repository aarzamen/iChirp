import AVFoundation
import ChirpAudio
import ChirpCore
import ChirpFeatures
import ChirpText
import UniformTypeIdentifiers
import XCTest

@testable import iChirp

@MainActor
final class AppScreenLogicTests: XCTestCase {
    // MARK: - Formatting

    func testClockIsZeroPaddedAndGrowsHours() {
        XCTAssertEqual(Formatting.clock(ms: 0), "00:00")
        XCTAssertEqual(Formatting.clock(ms: 6_400), "00:06")
        XCTAssertEqual(Formatting.clock(ms: 221_000), "03:41")
        XCTAssertEqual(Formatting.clock(ms: 3_723_000), "1:02:03")
        XCTAssertEqual(Formatting.clock(ms: -5), "00:00")
    }

    func testDurationMatchesCanvasMetaStyle() {
        XCTAssertEqual(Formatting.duration(ms: 12_000), "0:12")
        XCTAssertEqual(Formatting.duration(ms: 1_720_000), "28:40")
        XCTAssertEqual(Formatting.duration(ms: 3_723_000), "1:02:03")
    }

    func testSpeakersPercentAndSize() {
        XCTAssertEqual(Formatting.speakers(1), "1 speaker")
        XCTAssertEqual(Formatting.speakers(4), "4 speakers")
        XCTAssertEqual(Formatting.percent(0.623), 62)
        XCTAssertEqual(Formatting.percent(1.4), 100)
        XCTAssertEqual(Formatting.percent(-1), 0)
        XCTAssertEqual(Formatting.size(bytes: 492_000_000), "492 MB")
        XCTAssertEqual(Formatting.size(bytes: 1_234_000_000), "1.2 GB")
    }

    func testDayLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 15)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let older = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 9)))
        XCTAssertEqual(Formatting.day(now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(Formatting.day(yesterday, now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(Formatting.day(older, now: now, calendar: calendar), "Sep 19")
    }

    func testMetaLineForAFinishedFile() {
        var item = Transcription(fileName: "memo.m4a", durationMs: 5_300, status: .completed)
        item.speakerCount = 2
        XCTAssertEqual(Formatting.meta(for: item), "File · 0:05 · 2 speakers")
        item.speakerCount = nil
        XCTAssertEqual(Formatting.meta(for: item), "File · 0:05")
    }

    func testStatusLines() {
        var item = Transcription(fileName: "memo.m4a", status: .processing)
        XCTAssertEqual(
            Formatting.statusLine(for: item, progress: JobProgress(stage: .transcribing, fraction: 0.62)),
            "Transcribing · 62%")
        XCTAssertEqual(Formatting.statusLine(for: item, progress: nil), "Waiting to start")

        item.status = .failed
        item.errorMessage = FileTranscriptionPipeline.modelMissingMessage
        XCTAssertEqual(Formatting.statusLine(for: item, progress: nil), FileTranscriptionPipeline.modelMissingMessage)
        XCTAssertTrue(Formatting.canRetry(.failed))
        XCTAssertTrue(Formatting.canRetry(.interrupted))
        XCTAssertTrue(Formatting.canRetry(.cancelled))
        XCTAssertFalse(Formatting.canRetry(.processing))
        XCTAssertFalse(Formatting.canRetry(.completed))

        item.status = .completed
        XCTAssertNil(Formatting.statusLine(for: item, progress: nil))
    }

    // MARK: - Transcript

    func testCurrentParagraphFollowsThePlayhead() {
        let paragraphs = [
            TranscriptParagraph(startMs: 500, endMs: 2_400, text: "One", speakerId: "S1"),
            TranscriptParagraph(startMs: 2_880, endMs: 5_000, text: "Two", speakerId: "S2"),
        ]
        XCTAssertNil(TranscriptTiming.currentParagraphIndex(in: paragraphs, atMs: 100))
        XCTAssertEqual(TranscriptTiming.currentParagraphIndex(in: paragraphs, atMs: 500), 0)
        XCTAssertEqual(TranscriptTiming.currentParagraphIndex(in: paragraphs, atMs: 2_700), 0)
        XCTAssertEqual(TranscriptTiming.currentParagraphIndex(in: paragraphs, atMs: 2_880), 1)
        XCTAssertEqual(TranscriptTiming.currentParagraphIndex(in: paragraphs, atMs: 60_000), 1)
    }

    func testSpeakerColorsFollowFirstSpeech() {
        let paragraphs = [
            TranscriptParagraph(startMs: 0, endMs: 1, text: "a", speakerId: "S2"),
            TranscriptParagraph(startMs: 1, endMs: 2, text: "b", speakerId: nil),
            TranscriptParagraph(startMs: 2, endMs: 3, text: "c", speakerId: "S1"),
            TranscriptParagraph(startMs: 3, endMs: 4, text: "d", speakerId: "S2"),
        ]
        XCTAssertEqual(TranscriptScreen.speakerOrder(paragraphs), ["S2": 0, "S1": 1])
    }

    /// Review L2 M9: the transcript's media and a reading never play at once: starting the media pauses the reading.
    func testStartingTheMediaTellsTheReadingToPause() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        var pausedReadings = 0
        let model = AudioPlayerModel(
            session: AudioSessionController(platform: LiveAudioSessionPlatform.shared),
            willPlay: { pausedReadings += 1 })
        model.load(url)
        XCTAssertTrue(model.isAvailable)
        model.play()
        XCTAssertEqual(pausedReadings, 1)
        model.stop()
    }

    func testSpeedLabelsCycleInCanvasOrder() {
        XCTAssertEqual(AudioPlayerModel.rates, [1, 1.5, 2, 0.75])
        XCTAssertEqual(AudioPlayerModel.rates.map(AudioPlayerModel.label(for:)), ["1×", "1.5×", "2×", "0.75×"])
    }

    // MARK: - Capture and placeholders

    func testImporterAcceptsAudioAndVideo() {
        XCTAssertEqual(CaptureScreen.importTypes, [.audio, .movie, .mpeg4Movie, .quickTimeMovie])
    }

    func testPlaceholdersNameTheirMilestones() {
        XCTAssertEqual(Placeholder.gridLayout.badge, "Not built yet — milestone M8")
        XCTAssertEqual(Placeholder.gridLayout.milestone, "M8")
    }

    /// M2: a dictation row being finalized says "Transcribing" (it never queues); a file still says it waits.
    func testProcessingDictationRowSaysTranscribing() {
        let dictation = Transcription(sourceType: .dictation, fileName: "Dictation.wav", status: .processing)
        let file = Transcription(sourceType: .file, fileName: "Memo.m4a", status: .processing)
        XCTAssertEqual(Formatting.statusLine(for: dictation, progress: nil), "Transcribing")
        XCTAssertEqual(Formatting.statusLine(for: file, progress: nil), "Waiting to start")
    }

    /// M4: every built-in template has an icon and a line in the Transforms lists; the canvas set is all there.
    func testEveryBuiltInTemplateHasAStyle() {
        let keys = Set(BuiltInTemplates.all.map(\.canonicalKey))
        XCTAssertEqual(Set(TemplateStyle.builtIns.keys), keys)
        let names = Set(BuiltInTemplates.all.map(\.name))
        for canvasItem in ["Polish", "Distill", "Decide", "Brief", "Meeting notes", "SOAP note", "Agenda", "Action items"] {
            XCTAssertTrue(names.contains(canvasItem), canvasItem)
        }
    }

    /// M4: no "Milestone M4" placeholder is left in the app sources (M5+ placeholders stay).
    func testNoM4PlaceholdersRemain() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("milestone: \"M4\"") || source.contains("Milestone M4") || source.contains("milestone M4") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [])
    }

    // MARK: - Build identity and diagnostics

    func testBuildInfoCarriesTheStamp() {
        let build = BuildIdentity.current
        let info = AboutSection.buildInfo(build)
        XCTAssertTrue(info.contains(build.commit))
        XCTAssertTrue(info.contains(build.buildDateUTC))
    }

    func testMemoryFootprintIsReadable() throws {
        let bytes = try XCTUnwrap(MemoryProbe.physicalFootprintBytes())
        XCTAssertGreaterThan(bytes, 1_000_000)
        XCTAssertEqual(MemoryProbe.megabytes(10_485_760), 10)
    }

    #if DEBUG
    func testSmokeArgumentParsing() {
        XCTAssertTrue(SmokeTestRunner.isRequested(in: ["iChirp", "-ChirpSmoke", "transcribe-sample"]))
        XCTAssertFalse(SmokeTestRunner.isRequested(in: ["iChirp", "-ChirpSmoke"]))
        XCTAssertFalse(SmokeTestRunner.isRequested(in: ["iChirp", "transcribe-sample"]))
        XCTAssertFalse(SmokeTestRunner.isRequested(in: ["iChirp", "-ChirpSmoke", "other"]))
    }

    /// `scripts/device_smoke.sh` reads exactly these keys; `build` must contain `ChirpBuildDateUTC`.
    func testSmokeResultJSONMatchesTheDeviceScript() throws {
        let build = BuildIdentity.current.summary
        XCTAssertTrue(build.contains(BuildIdentity.current.buildDateUTC))
        let result = SmokeTestRunner.SmokeResult(
            status: "completed", text: "The quick brown fox jumps over the lazy dog.", wordCount: 9, speakerCount: 2,
            elapsedMs: 1200, modelLoadMs: 300, peakMemoryMB: 512, build: build, error: nil)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: SmokeTestRunner.encode(result)) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["status", "text", "wordCount", "speakerCount", "elapsedMs", "modelLoadMs", "peakMemoryMB", "build"])
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["build"] as? String, build)

        var failed = SmokeTestRunner.placeholderResult(build: build)
        failed.status = "failed"
        failed.error = "boom"
        let failedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: SmokeTestRunner.encode(failed)) as? [String: Any])
        XCTAssertEqual(failedObject["error"] as? String, "boom")
        XCTAssertEqual(SmokeTestRunner.placeholderResult(build: build).status, "running")
    }

    func testBundledSampleIsInTheApp() {
        XCTAssertNotNil(Bundle.main.url(forResource: "sample-two-voices", withExtension: "m4a"))
    }
    #endif
}
