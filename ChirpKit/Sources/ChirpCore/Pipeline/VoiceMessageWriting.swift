import Foundation

// Plan 022 Step 5: the seam between ChirpFeatures' `VoiceMessageExporter` and the audio encoder (ChirpAudio's
// `VoiceMessageWriter`, AVFoundation). Contract: spec/contracts/media-storage-layout-v1.md (`voice-<n>.m4a`).

/// Joins synthesized speech chunks into one voice message: AAC in an MPEG-4 container (`.m4a`).
public protocol VoiceMessageWriting: Sendable {
    /// Decodes each chunk file (mp3, wav or m4a, as a voice engine returned it), in order, puts `pausesAfterMs[i]`
    /// milliseconds of silence after chunk `i`, and writes one `.m4a` at `url`. Returns its length in milliseconds.
    /// Throws when a chunk cannot be read or the file cannot be written; nothing is left at `url` then.
    func writeVoiceMessage(chunks: [URL], pausesAfterMs: [Int], to url: URL) async throws -> Int
}

extension SynthesizedAudio.Format {
    /// The file extension a chunk of this format is stored with: `mp3`, `wav`, `m4a`.
    public var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .wav: "wav"
        case .aac: "m4a"
        }
    }
}
