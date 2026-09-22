import ChirpCore
import XCTest

@testable import ChirpFeatures

/// M3 Step 4: live chunks become `.meetingLiveChunk` jobs, in order, display-only; silence is skipped; the chunk
/// files are temporary.
final class MeetingLiveTranscriberTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingLiveTranscriberTests-\(UUID().uuidString)/chunks", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private func collect(_ updates: AsyncStream<MeetingLiveUpdate>) -> Task<[MeetingLiveUpdate], Never> {
        Task {
            var all: [MeetingLiveUpdate] = []
            for await update in updates { all.append(update) }
            return all
        }
    }

    func testChunksAreTranscribedInOrderIntoParagraphsAndTheirFilesRemoved() async throws {
        let speech = FakeSpeech()
        let live = MeetingLiveTranscriber(
            chunker: FixedMeetingLiveAudioChunker(), speech: speech, scheduler: SpeechJobScheduler(),
            chunkFolder: folder)
        let updates = collect(live.updates)
        for _ in 0..<9 { await live.append(toneSamples()) }  // 9 s: chunks 0–5 s and 4–9 s
        await live.drain()

        let urls = await speech.transcribedURLs
        XCTAssertEqual(urls.map(\.lastPathComponent), ["chunk-0-5000.wav", "chunk-4000-9000.wav"])
        let existed = await speech.inputExistedAtTranscribe
        XCTAssertEqual(existed, [true, true], "each chunk is on disk while it is transcribed")
        XCTAssertTrue(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "and removed after")
        let transcribed = await live.transcribedCount
        XCTAssertEqual(transcribed, 2)

        await live.finish()
        let all = await updates.value
        let last = try XCTUnwrap(all.last)
        XCTAssertEqual(last.paragraphs.first?.startMs, 0)
        XCTAssertEqual(last.paragraphs.first?.text, "Hello there. General Kenobi. Hello there. General Kenobi.")
        XCTAssertFalse(last.isLagging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "finish removes the chunk folder")
    }

    func testSilentChunksAreNotTranscribed() async {
        let speech = FakeSpeech()
        let live = MeetingLiveTranscriber(
            chunker: FixedMeetingLiveAudioChunker(), speech: speech, scheduler: SpeechJobScheduler(),
            chunkFolder: folder)
        await live.append([Float](repeating: 0, count: 6 * 16_000))
        await live.drain()
        let calls = await speech.transcribeCalls
        let silent = await live.silentCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(silent, 1)
        await live.finish()
    }

    func testBackpressureDropsMarkThePreviewLaggingAndFinishCancelsPendingChunks() async throws {
        let speech = FakeSpeech()
        let hold = await speech.holdNextTranscription()
        let scheduler = SpeechJobScheduler(maxPendingLiveChunks: 1)
        let live = MeetingLiveTranscriber(
            chunker: FixedMeetingLiveAudioChunker(), speech: speech, scheduler: scheduler, chunkFolder: folder)
        let updates = collect(live.updates)
        await live.append(toneSamples(seconds: 5))  // chunk 1: runs and is held
        await hold.entered.wait()
        await live.append(toneSamples(seconds: 4))  // chunk 2: pending
        while await scheduler.pendingCount() < 1 { await Task.yield() }
        await live.append(toneSamples(seconds: 4))  // chunk 3: pending; the older chunk 2 is dropped
        while await live.droppedCount < 1 { await Task.yield() }
        hold.release.fire()
        await live.drain()
        let dropped = await live.droppedCount
        XCTAssertEqual(dropped, 1)
        await live.finish()
        let all = await updates.value
        XCTAssertTrue(all.contains { $0.isLagging }, "a dropped chunk marks the preview lagging")
        XCTAssertFalse(try XCTUnwrap(all.last).isLagging, "a later chunk clears it")
    }
}
