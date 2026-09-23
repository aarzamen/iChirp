import Foundation

#if canImport(NeedleC)
import NeedleC
#endif

/// What this build carries of Needle's runtime (needle-rs `needle-c`, MIT, built by `scripts/build_needle.sh`).
public enum NeedleRuntimeInfo {
    /// The needle-rs commit `scripts/build_needle.sh` pins (a test keeps the two equal).
    public static let pinnedCommit = "4de50494fd60f417b24c37e4d972f95d128f8a0f"

    /// True when `vendor/NeedleC.xcframework` was linked into this build.
    public static var isInBuild: Bool {
        #if canImport(NeedleC)
        true
        #else
        false
        #endif
    }

    /// What the app says when the runtime was not built.
    public static let notInBuildMessage = "Needle is not in this build — run scripts/build_needle.sh, then rebuild."
}

/// Failures of the Needle runtime, in words the Settings screen and the Eval view can show. Messages never carry
/// transcript text: needle-c's errors name files and formats only.
public enum NeedleRuntimeError: Error, Equatable, Sendable, LocalizedError {
    /// The app was built without `vendor/NeedleC.xcframework`.
    case notInBuild
    /// `needle_v3_load` returned NULL (missing file, wrong generation, corrupt container).
    case loadFailed(String)
    /// `needle_v3_generate` returned NULL.
    case generationFailed(String)
    /// The container exports no confidence head, so nothing can be gated.
    case noConfidenceHead
    /// `needle_v3_confidence_for` failed on a model that has a head (for example, the input is too long).
    case confidenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInBuild: NeedleRuntimeInfo.notInBuildMessage
        case .loadFailed(let reason): "Needle could not load its model: \(reason)"
        case .generationFailed(let reason): "Needle could not answer: \(reason)"
        case .noConfidenceHead: "This Needle model has no confidence head, so its answers cannot be gated."
        case .confidenceFailed(let reason): "Needle could not score its answer: \(reason)"
        }
    }
}

/// One loaded Needle 3 model: a thin, synchronous wrapper over needle-c's `needle_v3_*` calls.
///
/// Not thread-safe (the C handle is not `Send`): only `NeedleRuntime`, an actor, owns one. Every returned C string
/// is copied and freed with `needle_free_str`; `needle_last_error` is borrowed and read at once.
final class NeedleCModel {
    #if canImport(NeedleC)
    private let handle: OpaquePointer
    #endif
    /// Read once at load (review L3 minor 3), so a later failure is reported as what it is.
    let hasConfidenceHead: Bool

    /// Loads a `.cact` container from disk.
    init(contentsOf url: URL) throws(NeedleRuntimeError) {
        #if canImport(NeedleC)
        guard let handle = needle_v3_load(url.path) else {
            throw .loadFailed(Self.lastError() ?? "unknown error")
        }
        self.handle = handle
        hasConfidenceHead = needle_v3_has_confidence(handle)
        #else
        throw .notInBuild
        #endif
    }

    deinit {
        #if canImport(NeedleC)
        needle_v3_free(handle)
        #endif
    }

    /// The full completion (reasoning, then the `<tool_call>` block). `constrain` restricts the payload to the tool
    /// schema; greedy decoding (temperature 0), so the same input gives the same output.
    func generate(query: String, toolsJSON: String, maxNewTokens: Int, constrain: Bool) throws(NeedleRuntimeError)
        -> String
    {
        #if canImport(NeedleC)
        guard let raw = needle_v3_generate(handle, query, toolsJSON, maxNewTokens, 0, 0, constrain, false) else {
            throw .generationFailed(Self.lastError() ?? "no output")
        }
        defer { needle_free_str(raw) }
        return String(cString: raw)
        #else
        throw .notInBuild
        #endif
    }

    /// The confidence head's probability that `completion` is the right answer to `query` (it scores the finished
    /// judgement, never the bare query).
    func confidence(query: String, toolsJSON: String, completion: String) throws(NeedleRuntimeError) -> Double {
        #if canImport(NeedleC)
        guard hasConfidenceHead else { throw .noConfidenceHead }
        var value: Float = 0
        guard needle_v3_confidence_for(handle, query, toolsJSON, completion, &value) else {
            throw .confidenceFailed(Self.lastError() ?? "unknown error")
        }
        return Double(value)
        #else
        throw .notInBuild
        #endif
    }

    /// Transformer blocks in the loaded depth.
    var layerCount: Int {
        #if canImport(NeedleC)
        needle_v3_num_layers(handle)
        #else
        0
        #endif
    }

    /// needle-c's thread-local last error, copied (it is borrowed and valid only until the next call).
    static func lastError() -> String? {
        #if canImport(NeedleC)
        guard let pointer = needle_last_error() else { return nil }
        let text = String(cString: pointer)
        return text.isEmpty ? nil : text
        #else
        nil
        #endif
    }
}
