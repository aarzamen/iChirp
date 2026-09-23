import Foundation

// M6 contract: spec/contracts/structure-model-plugin-v1.md. Conformers: ChirpEngineNeedle's `NeedleStructureModel`
// and ChirpFeatures' rule-based `StubStructureModel` (always labelled STUB).

/// JSON extracted by a `StructureModel`, with the model's confidence in 0...1.
///
/// For a tool catalog (`jsonSchema` is a JSON array of tool definitions), `json` is the array of calls
/// (`[{"name": …, "arguments": {…}}]`). `"[]"` is a deliberate abstention: the engine considered every tool and chose
/// none. That is a decision to act on, never an error.
public struct StructuredOutput: Sendable, Equatable {
    public var json: String
    public var confidence: Double
    /// SHA-256 of the model file that produced this output; nil for a rule-based engine (the STUB).
    public var modelSHA256: String?

    public init(json: String, confidence: Double, modelSHA256: String? = nil) {
        self.json = json
        self.confidence = confidence
        self.modelSHA256 = modelSHA256
    }

    /// True for `"[]"`: the engine looked at the tools and deliberately chose none.
    public var isAbstention: Bool {
        json.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "") == "[]"
    }
}

/// A structured-extraction and embedding engine plug-in.
public protocol StructureModel: Sendable {
    var descriptor: EngineDescriptor { get }
    /// Runs one extraction. Callers route first (`PrivacyRoutingPolicy`); clinical text only ever reaches an
    /// `.onDevice` structure engine. Throws `StructureModelError`.
    func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws -> StructuredOutput
    func embed(_ text: String) async throws -> [Float]
}

/// Why a structure engine could not answer. Each case maps to one user-facing sentence (`errorDescription`) and
/// never carries the text that was being read.
public enum StructureModelError: Error, Equatable, Sendable, LocalizedError {
    /// The engine's runtime is not compiled into this build (Needle without `scripts/build_needle.sh`).
    case notInThisBuild(String)
    /// The engine's model file is not on this iPhone yet; carries the engine id.
    case modelNotDownloaded(String)
    /// The router refused this engine for the item's privacy class; carries the engine's display name.
    case privacyRoutingRefused(String)
    /// The engine cannot do this at all (Needle 3 has no embedding head).
    case unsupported(String)
    /// The model produced no tool call at all: a degenerate generation, unlike a deliberate `"[]"`.
    case noToolCall
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInThisBuild(let message): message
        case .modelNotDownloaded: "The model is not downloaded yet. Download it in Settings → Structure models."
        case .privacyRoutingRefused(let name): "\(name) may not read this item's text (privacy class)."
        case .unsupported(let what): "Not supported: \(what)"
        case .noToolCall: "The model gave no answer for this sentence."
        case .failed(let reason): reason
        }
    }
}
