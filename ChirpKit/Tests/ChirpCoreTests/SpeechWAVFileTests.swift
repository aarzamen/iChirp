import AVFoundation
import XCTest

@testable import ChirpCore

/// The Foundation-only WAV writer for meeting live chunks (M3) produces a file AVFoundation reads back exactly.
final class SpeechWAVFileTests: XCTestCase {
    func testWritesSixteenKilohertzMonoFloatThatAVAudioFileReadsBackExactly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples: [Float] = (0..<16_000).map { sinf(Float($0) * 0.05) * 0.5 }
        try SpeechWAVFile.write(samples, to: url)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
        try file.read(into: buffer)
        let read = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        XCTAssertEqual(read, samples)
    }
}
