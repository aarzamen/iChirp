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
    /// Decodes any AVFoundation-readable audio/video file into 16 kHz mono Float32 WAV at `outputURL`.
    func normalize(sourceURL: URL, outputURL: URL) async throws -> NormalizedAudio
    func durationMs(of sourceURL: URL) async throws -> Int
}
