import AVFoundation
import ChirpCore
import XCTest

@testable import ChirpAudio

/// Plan 022 Step 5: chunks at any rate become one AAC `.m4a` with the pauses in it. Synthetic tones only.
final class VoiceMessageWriterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceMessageWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func tone(seconds: Double, sampleRate: Int, name: String) throws -> URL {
        let count = Int(seconds * Double(sampleRate))
        let samples = (0..<count).map { Float(sin(Double($0) * 2 * .pi * 440 / Double(sampleRate)) * 0.3) }
        let url = folder.appendingPathComponent(name)
        try SpeechWAVFile.write(samples, sampleRate: sampleRate, to: url)
        return url
    }

    func testChunksAtDifferentRatesBecomeOneAACFileWithThePauses() async throws {
        let first = try tone(seconds: 0.5, sampleRate: 16_000, name: "chunk-0.wav")
        let second = try tone(seconds: 0.25, sampleRate: 24_000, name: "chunk-1.wav")
        let output = folder.appendingPathComponent("voice-1.m4a")

        let durationMs = try await VoiceMessageWriter().writeVoiceMessage(
            chunks: [first, second], pausesAfterMs: [350, 0], to: output)

        XCTAssertEqual(Double(durationMs), 1_100, accuracy: 5, "0.5 s + 0.35 s of silence + 0.25 s")
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, VoiceMessageWriter.sampleRate)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, 1.1, accuracy: 0.1)
    }

    func testAnUnreadableChunkFailsAndLeavesNoFile() async throws {
        let good = try tone(seconds: 0.2, sampleRate: 16_000, name: "chunk-0.wav")
        let bad = folder.appendingPathComponent("chunk-1.mp3")
        try Data("not audio".utf8).write(to: bad)
        let output = folder.appendingPathComponent("voice-1.m4a")
        do {
            _ = try await VoiceMessageWriter().writeVoiceMessage(
                chunks: [good, bad], pausesAfterMs: [0, 0], to: output)
            XCTFail("an unreadable chunk was accepted")
        } catch {
            XCTAssertEqual(error as? VoiceMessageWriterError, .unreadableChunk(1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// Review R2-7: cancelling the export stops the encoding between chunks and leaves no half-written file.
    func testCancellingStopsTheEncodingAndLeavesNoFile() async throws {
        let chunk = try tone(seconds: 0.5, sampleRate: 16_000, name: "chunk.wav")
        let output = folder.appendingPathComponent("voice-cancelled.m4a")
        let chunks = Array(repeating: chunk, count: 200)
        let task = Task {
            try await VoiceMessageWriter().writeVoiceMessage(
                chunks: chunks, pausesAfterMs: Array(repeating: 100, count: chunks.count), to: output)
        }
        task.cancel()
        do {
            let durationMs = try await task.value
            XCTFail("the cancelled export finished anyway (\(durationMs) ms)")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// The check runs before every chunk: a cancellation seen after the first chunk stops the second.
    func testCancellationIsCheckedBetweenChunks() throws {
        let chunk = try tone(seconds: 0.2, sampleRate: 16_000, name: "chunk.wav")
        let output = folder.appendingPathComponent("voice-2.m4a")
        var checks = 0
        XCTAssertThrowsError(
            try VoiceMessageWriter.write(chunks: [chunk, chunk, chunk], pausesAfterMs: [0, 0, 0], to: output) {
                checks += 1
                return checks > 1
            }
        ) { error in
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(checks, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testEncodingRunsOnItsOwnQueue() async throws {
        let label = try await VoiceMessageWriter.runOnEncodeQueue { _ in
            String(cString: __dispatch_queue_get_label(nil))
        }
        XCTAssertEqual(label, VoiceMessageWriter.encodeQueueLabel)
    }

    func testNoChunksIsNoAudio() async {
        do {
            _ = try await VoiceMessageWriter().writeVoiceMessage(
                chunks: [], pausesAfterMs: [], to: folder.appendingPathComponent("x.m4a"))
            XCTFail("nothing was written from nothing")
        } catch {
            XCTAssertEqual(error as? VoiceMessageWriterError, .noAudio)
        }
    }
}
