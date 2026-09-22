/// Download state of an engine's model files.
public enum ModelAssetStatus: Sendable, Equatable {
    case notDownloaded
    case downloading(fraction: Double)
    case ready(bytesOnDisk: Int64)
    case failed(message: String)
}

/// Anything whose models must be downloaded before use (speech, diarization, later LLMs).
public protocol ModelAssetManaging: Sendable {
    func assetStatus() async -> ModelAssetStatus
    /// Downloads every model file; `progress` reports 0...1. Throws on network or disk failure.
    func downloadAssets(progress: @escaping @Sendable (Double) -> Void) async throws
    func deleteAssets() async throws
}
