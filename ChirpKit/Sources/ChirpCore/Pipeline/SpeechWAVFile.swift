import Foundation

/// Writes 16 kHz mono Float32 samples as a WAV file (IEEE float, format tag 3), with Foundation only, and repairs the
/// header of a WAV whose writer was killed before closing it (`repairHeader(at:)`, review R5-4).
///
/// `write` is used for a meeting's short live-preview chunks (M3), which go through `SpeechEngine.transcribe(fileAt:)`
/// like any file. The header is complete when the call returns; these files are temporary and never user data.
public enum SpeechWAVFile {
    public static func write(_ samples: [Float], sampleRate: Int = SpeechAudio.sampleRate, to url: URL) throws {
        let dataBytes = samples.count * 4
        var data = Data(capacity: 58 + dataBytes)
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF")
        u32(UInt32(50 + dataBytes))
        ascii("WAVE")
        ascii("fmt ")
        u32(18)
        u16(3)  // WAVE_FORMAT_IEEE_FLOAT
        u16(1)  // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 4))  // byte rate
        u16(4)  // block align
        u16(32)  // bits per sample
        u16(0)  // extension size
        ascii("fact")
        u32(4)
        u32(UInt32(samples.count))
        ascii("data")
        u32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer {
                withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Header repair (review R5-4)

extension SpeechWAVFile {
    /// What `repairHeader(at:)` found.
    public struct HeaderRepair: Equatable, Sendable {
        /// Whether the header was rewritten (false: it already described the audio on disk).
        public var didRepair: Bool
        /// Complete frames the file holds.
        public var frameCount: Int
        public var sampleRate: Int

        public var durationMs: Int {
            sampleRate > 0 ? Int((Double(frameCount) * 1_000 / Double(sampleRate)).rounded()) : 0
        }
    }

    public enum HeaderRepairError: Error, Equatable {
        /// Not a RIFF/WAVE file with a `fmt ` and a `data` chunk where they belong. Nothing was changed.
        case notAWAVFile
        /// The audio is too large for a RIFF size field (over 4 GB). Nothing was changed.
        case tooLarge
    }

    /// Makes a WAV that its writer never closed readable to its last complete frame.
    ///
    /// AVFoundation writes a WAV's RIFF and `data` sizes only when the file is closed: a dictation the app was killed
    /// while recording holds every sample it wrote, yet reads as 0 s (measured in
    /// `docs/research/2026-09-22-meeting-crash-format.md`, review R5-4). This rewrites those sizes (and a `fact` chunk's
    /// frame count, when there is one) from the file's length and cuts off a partial last frame, nothing else.
    ///
    /// It changes only a header that cannot be right: a `data` size of 0 or 0xFFFFFFFF ("still being written"), one
    /// larger than the file, or one that ends before the file does with no chunk after it. A finished file, or one
    /// with a chunk after its audio, is left exactly as it is, so this is safe to call before every read.
    @discardableResult
    public static func repairHeader(at url: URL) throws -> HeaderRepair {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: Int(min(fileSize, 65_536))) ?? Data()
        let bytes = [UInt8](header)
        guard bytes.count >= 12, ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else {
            throw HeaderRepairError.notAWAVFile
        }

        var offset = 12
        var blockAlign = 0
        var sampleRate = 0
        var factCountOffset: Int?
        var dataSizeOffset: Int?
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset)
            let size = Int(uint32(bytes, offset + 4))
            if id == "data" {
                dataSizeOffset = offset + 4
                break
            }
            let body = offset + 8
            guard body + size <= bytes.count else { throw HeaderRepairError.notAWAVFile }
            if id == "fmt ", size >= 16 {
                sampleRate = Int(uint32(bytes, body + 4))
                blockAlign = Int(bytes[body + 12]) | Int(bytes[body + 13]) << 8
            } else if id == "fact", size >= 4 {
                factCountOffset = body
            }
            offset = body + size + (size & 1)
        }
        guard let dataSizeOffset, blockAlign > 0 else { throw HeaderRepairError.notAWAVFile }

        let dataStart = UInt64(dataSizeOffset + 4)
        guard fileSize >= dataStart else { throw HeaderRepairError.notAWAVFile }
        let onDisk = fileSize - dataStart
        let complete = onDisk - onDisk % UInt64(blockAlign)
        let declared = UInt64(uint32(bytes, dataSizeOffset))
        let frames = { (byteCount: UInt64) in Int(byteCount / UInt64(blockAlign)) }

        if declared == complete {
            return HeaderRepair(didRepair: false, frameCount: frames(complete), sampleRate: sampleRate)
        }
        if declared & 1 == 1, declared + 1 == onDisk {
            // A finished file whose odd-sized audio ends with RIFF's pad byte.
            return HeaderRepair(didRepair: false, frameCount: frames(declared), sampleRate: sampleRate)
        }
        let stillWriting = declared == 0 || declared == UInt64(UInt32.max)
        if !stillWriting, declared < onDisk,
            try chunkFollows(in: handle, at: dataStart + declared + (declared & 1), fileSize: fileSize)
        {
            // A finished file with more after its audio (a LIST tag, say): well formed, not ours to change.
            return HeaderRepair(didRepair: false, frameCount: frames(declared), sampleRate: sampleRate)
        }
        guard dataStart + complete - 8 <= UInt64(UInt32.max) else { throw HeaderRepairError.tooLarge }

        // Opened for writing only now: a finished file needs no write access at all.
        let writer = try FileHandle(forUpdating: url)
        defer { try? writer.close() }
        try writer.seek(toOffset: 4)
        try writer.write(contentsOf: littleEndian(UInt32(dataStart + complete - 8)))
        try writer.seek(toOffset: UInt64(dataSizeOffset))
        try writer.write(contentsOf: littleEndian(UInt32(complete)))
        if let factCountOffset {
            try writer.seek(toOffset: UInt64(factCountOffset))
            try writer.write(contentsOf: littleEndian(UInt32(frames(complete))))
        }
        if complete < onDisk {
            // Less than one frame: what a kill in the middle of a write can leave. It cannot be played.
            try writer.truncate(atOffset: dataStart + complete)
        }
        try writer.synchronize()
        return HeaderRepair(didRepair: true, frameCount: frames(complete), sampleRate: sampleRate)
    }

    /// Whether a chunk header (four printable characters and a size that fits) starts at `offset`.
    private static func chunkFollows(in handle: FileHandle, at offset: UInt64, fileSize: UInt64) throws -> Bool {
        guard offset + 8 <= fileSize else { return false }
        try handle.seek(toOffset: offset)
        let bytes = [UInt8](try handle.read(upToCount: 8) ?? Data())
        guard bytes.count == 8, bytes[0..<4].allSatisfy({ (0x20...0x7E).contains($0) }) else { return false }
        return offset + 8 + UInt64(uint32(bytes, 4)) <= fileSize
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
