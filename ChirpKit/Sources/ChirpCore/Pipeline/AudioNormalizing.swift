import Foundation

/// A decoded file ready for a speech engine.
public struct NormalizedAudio: Sendable, Equatable {
    public var url: URL
    public var durationMs: Int
    public var sampleCount: Int

    public init(url: URL, durationMs: Int, sampleCount: Int) {
        self.url = url
        self.durationMs = durationMs
        self.sampleCount = sampleCount
    }
}

/// Turns any user-supplied media into the format speech engines expect.
public protocol AudioNormalizing: Sendable {
    /// Decodes any AVFoundation-readable audio/video file into 16 kHz mono Float32 WAV at `outputURL`, from its first
    /// audio track.
    func normalize(sourceURL: URL, outputURL: URL) async throws -> NormalizedAudio
    /// As `normalize(sourceURL:outputURL:)`, from the audio track with this zero-based ordinal among audio tracks;
    /// nil is the automatic choice (the first track). An ordinal the file lacks throws
    /// `AudioTrackSelectionError.trackMissing`, never falling back to another track (M1.5, additive).
    func normalize(sourceURL: URL, outputURL: URL, audioTrackOrdinal: Int?) async throws -> NormalizedAudio
    func durationMs(of sourceURL: URL) async throws -> Int
}

extension AudioNormalizing {
    /// Default for normalizers that cannot choose a track: automatic selection works, an explicit ordinal throws
    /// `AudioTrackSelectionError.selectionUnsupported` (upstream's additive-overload pattern).
    public func normalize(sourceURL: URL, outputURL: URL, audioTrackOrdinal: Int?) async throws -> NormalizedAudio {
        guard audioTrackOrdinal == nil else { throw AudioTrackSelectionError.selectionUnsupported }
        return try await normalize(sourceURL: sourceURL, outputURL: outputURL)
    }
}
