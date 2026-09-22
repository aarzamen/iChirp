import Foundation

/// Writes 16 kHz mono Float32 samples as a WAV file (IEEE float, format tag 3), with Foundation only.
///
/// Used for a meeting's short live-preview chunks (M3), which go through `SpeechEngine.transcribe(fileAt:)` like
/// any file. The header is complete when the call returns; these files are temporary and never user data.
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
