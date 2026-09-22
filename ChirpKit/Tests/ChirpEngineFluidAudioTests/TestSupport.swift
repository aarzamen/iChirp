import AVFoundation
import ChirpCore
import XCTest

/// A thread-safe append-only log, for recording events from `@Sendable` hooks and progress callbacks.
final class LockedLog<Element: Sendable>: @unchecked Sendable {
    // @unchecked Sendable: `storage` is only touched while `lock` is held.
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A one-shot gate that ignores cancellation, like a CoreML compile that cannot be interrupted.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parties = waiters
        waiters.removeAll()
        for party in parties { party.resume() }
    }
}

/// Releases the first `partyCount` arrivals only once all of them are inside at the same time, which proves
/// overlap without timing assumptions. Later arrivals pass straight through.
actor Rendezvous {
    private let partyCount: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(partyCount: Int) {
        self.partyCount = partyCount
    }

    func arrive() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count >= partyCount else { return }
            released = true
            let parties = waiting
            waiting.removeAll()
            for party in parties { party.resume() }
        }
    }
}

extension XCTestCase {
    /// Polls `condition` until it holds; fails (instead of hanging) after `timeout`.
    func waitUntil(
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Condition not met within \(timeout)", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func assertThrowsModelNotDownloaded(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected SpeechEngineError.modelNotDownloaded", file: file, line: line)
        } catch let error as SpeechEngineError {
            guard case .modelNotDownloaded = error else {
                return XCTFail("Expected .modelNotDownloaded, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected SpeechEngineError, got \(error)", file: file, line: line)
        }
    }

    /// A scratch directory removed after the test.
    func makeScratchDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Writes `seconds` of 16 kHz mono 16-bit silence.
    func writeSilentWAV(seconds: Double, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("silence-\(Int(seconds))s.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let samples = buffer.int16ChannelData?[0] {
            samples.update(repeating: 0, count: Int(frames))
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
        return url
    }

    /// `source` repeated `times` times into a new 16 kHz mono 16-bit WAV.
    func writeLoopedWAV(of source: URL, times: Int, in directory: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = input.processingFormat
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: buffer)
        let url = directory.appendingPathComponent("looped-\(times)x.wav")
        let output = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        for _ in 0..<times {
            try output.write(from: buffer)
        }
        return url
    }
}
