import AVFoundation
import XCTest

@testable import ChirpCore

/// The Foundation-only WAV writer for meeting live chunks (M3) produces a file AVFoundation reads back exactly; the
/// header repair (review R5-4) makes a WAV a killed writer never closed read back whole, and touches nothing else.
final class SpeechWAVFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechWAVFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesSixteenKilohertzMonoFloatThatAVAudioFileReadsBackExactly() throws {
        let url = directory.appendingPathComponent("chunk.wav")
        let samples: [Float] = (0..<16_000).map { sinf(Float($0) * 0.05) * 0.5 }
        try SpeechWAVFile.write(samples, to: url)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 16_000)
        XCTAssertEqual(try Self.samples(of: url), samples)
    }

    // MARK: - Header repair (review R5-4)

    /// What a kill leaves: AVAudioFile writes the RIFF and data sizes only on close, so the copy taken before
    /// `close()` holds every sample but reads as 0 s. After the repair it reads back exactly what was written.
    func testAWAVAKilledWriterLeftOpenReadsBackWholeAfterTheRepair() throws {
        let samples: [Float] = (0..<20_000).map { sinf(Float($0) * 0.03) * 0.4 }
        let killed = try Self.killedRecording(samples, in: directory)
        XCTAssertEqual(try AVAudioFile(forReading: killed).length, 0, "the measured problem: it reads as 0 s")

        let repair = try SpeechWAVFile.repairHeader(at: killed)
        XCTAssertTrue(repair.didRepair)
        XCTAssertEqual(repair.frameCount, samples.count)
        XCTAssertEqual(repair.sampleRate, 16_000)
        XCTAssertEqual(repair.durationMs, 1_250)
        XCTAssertEqual(try AVAudioFile(forReading: killed).length, AVAudioFramePosition(samples.count))
        XCTAssertEqual(try Self.samples(of: killed), samples, "every sample, in place")

        let again = try SpeechWAVFile.repairHeader(at: killed)
        XCTAssertFalse(again.didRepair, "a repaired file is left as it is")
        XCTAssertEqual(again.frameCount, samples.count)
    }

    func testAClosedWAVIsNotTouched() throws {
        let url = directory.appendingPathComponent("closed.wav")
        let samples: [Float] = (0..<4_000).map { Float($0 % 100) / 200 }
        try SpeechWAVFile.write(samples, to: url)
        let before = try Data(contentsOf: url)

        let repair = try SpeechWAVFile.repairHeader(at: url)
        XCTAssertFalse(repair.didRepair)
        XCTAssertEqual(repair.frameCount, samples.count)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// A kill in the middle of a write can leave part of a frame: only that partial frame goes.
    func testOnlyAPartialLastFrameIsCutOff() throws {
        let samples: [Float] = (0..<1_600).map { Float($0) / 3_200 }
        let killed = try Self.killedRecording(samples, in: directory)
        let handle = try FileHandle(forWritingTo: killed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x12, 0x34]))
        try handle.close()

        let repair = try SpeechWAVFile.repairHeader(at: killed)
        XCTAssertTrue(repair.didRepair)
        XCTAssertEqual(repair.frameCount, samples.count)
        XCTAssertEqual(try Self.samples(of: killed), samples)
    }

    /// SpeechWAVFile's own layout has a `fact` chunk: its frame count is repaired with the sizes.
    func testAFactChunkIsRepairedWithTheSizes() throws {
        let url = directory.appendingPathComponent("fact.wav")
        let samples: [Float] = (0..<3_000).map { Float($0) / 6_000 }
        try SpeechWAVFile.write(samples, to: url)
        var bytes = try Data(contentsOf: url)
        // As if never closed: RIFF size covers the header only, fact and data say 0.
        bytes.replaceSubrange(4..<8, with: Self.littleEndian(UInt32(50)))
        bytes.replaceSubrange(46..<50, with: Self.littleEndian(UInt32(0)))
        bytes.replaceSubrange(54..<58, with: Self.littleEndian(UInt32(0)))
        try bytes.write(to: url)

        let repair = try SpeechWAVFile.repairHeader(at: url)
        XCTAssertTrue(repair.didRepair)
        XCTAssertEqual(repair.frameCount, samples.count)
        let repaired = try Data(contentsOf: url)
        XCTAssertEqual(Self.uint32(repaired, at: 4), UInt32(50 + samples.count * 4))
        XCTAssertEqual(Self.uint32(repaired, at: 46), UInt32(samples.count), "fact frame count")
        XCTAssertEqual(Self.uint32(repaired, at: 54), UInt32(samples.count * 4), "data size")
        XCTAssertEqual(try Self.samples(of: url), samples)
    }

    /// A finished WAV with a chunk after its audio (a LIST tag) is well formed: its audio is not stretched over it.
    func testAChunkAfterTheAudioIsNotMistakenForAudio() throws {
        let url = directory.appendingPathComponent("tagged.wav")
        try SpeechWAVFile.write([Float](repeating: 0.25, count: 800), to: url)
        var bytes = try Data(contentsOf: url)
        let tag = Data("LIST".utf8) + Self.littleEndian(UInt32(4)) + Data("INFO".utf8)
        bytes.append(tag)
        bytes.replaceSubrange(4..<8, with: Self.littleEndian(UInt32(bytes.count - 8)))
        try bytes.write(to: url)

        let repair = try SpeechWAVFile.repairHeader(at: url)
        XCTAssertFalse(repair.didRepair)
        XCTAssertEqual(repair.frameCount, 800)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testAFileThatIsNotAWAVIsNotTouched() throws {
        let url = directory.appendingPathComponent("dictation.wav")
        let bytes = Data(repeating: 1, count: 64)
        try bytes.write(to: url)
        XCTAssertThrowsError(try SpeechWAVFile.repairHeader(at: url)) { error in
            XCTAssertEqual(error as? SpeechWAVFile.HeaderRepairError, .notAWAVFile)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // MARK: - Helpers

    /// Writes `samples` the way the dictation recorder does (AVAudioFile, 16 kHz mono Float32 WAV) and returns a copy
    /// taken before `close()`: exactly what a killed process leaves on disk.
    static func killedRecording(_ samples: [Float], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("open-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        var written = 0
        while written < samples.count {
            let count = min(1_365, samples.count - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count { buffer.floatChannelData![0][index] = samples[written + index] }
            try file.write(from: buffer)
            written += count
        }
        let killed = directory.appendingPathComponent("killed-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: url, to: killed)
        file.close()
        return killed
    }

    /// Every sample, read in 4096-frame steps (one large `read(into:)` can return fewer frames than the file holds).
    static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var all: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 4_096)
            guard buffer.frameLength > 0 else { break }
            all.append(
                contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return all
    }

    static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
}
