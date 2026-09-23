import Dispatch
import Foundation

/// One finished Needle answer: the whole completion (reasoning, then the `<tool_call>` block) and the confidence
/// head's score of that completion.
public struct NeedleCompletion: Sendable, Equatable {
    public var text: String
    public var confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

/// The loaded-model calls `NeedleStructureModel` needs. `NeedleRuntime` in the app; a fake in tests.
public protocol NeedleInferring: Sendable {
    /// Loads the model file (no-op when that file is already loaded).
    func load(modelAt url: URL) async throws
    /// Frees the loaded model (memory pressure, or before the file is deleted).
    func unload() async
    /// Generates an answer for `query` against `toolsJSON` and scores it.
    func complete(query: String, toolsJSON: String) async throws -> NeedleCompletion
}

/// The one Needle model of the process.
///
/// needle-c handles are not thread-safe, so exactly one actor owns the loaded `NeedleCModel`. The actor runs on its
/// own serial dispatch queue: a generation blocks for up to a few seconds of CPU, and that must not hold a thread of
/// Swift's cooperative pool.
public actor NeedleRuntime: NeedleInferring {
    /// New tokens per answer: Needle 3 reasons in a `<think>` block before the call, and a SOAP sentence can carry a
    /// medication with five arguments.
    public static let maxNewTokens = 384

    private let queue = DispatchSerialQueue(label: "com.aarzamen.ichirp.needle", qos: .userInitiated)
    private var model: NeedleCModel?
    private var loadedURL: URL?

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init() {}

    public func load(modelAt url: URL) async throws {
        if loadedURL == url, model != nil { return }
        model = nil
        loadedURL = nil
        model = try NeedleCModel(contentsOf: url)
        loadedURL = url
    }

    public func unload() async {
        model = nil
        loadedURL = nil
    }

    public func complete(query: String, toolsJSON: String) async throws -> NeedleCompletion {
        guard let model else { throw NeedleRuntimeError.loadFailed("the model is not loaded") }
        try Task.checkCancellation()
        let text = try model.generate(
            query: query, toolsJSON: toolsJSON, maxNewTokens: Self.maxNewTokens, constrain: true)
        let confidence = try model.confidence(query: query, toolsJSON: toolsJSON, completion: text)
        return NeedleCompletion(text: text, confidence: confidence)
    }
}

/// Pulls the tool-call payload out of a Needle completion (port of needle-rs `extract_tool_call`, MIT).
public enum NeedleToolCallParser {
    static let open = "<tool_call>"
    static let close = "</tool_call>"

    /// The trimmed text between `<tool_call>` and `</tool_call>`; an unterminated block returns what the model got
    /// to before its budget ran out. Nil when there is no `<tool_call>` at all (a degenerate generation).
    public static func payload(from completion: String) -> String? {
        guard let start = completion.range(of: open) else { return nil }
        let rest = completion[start.upperBound...]
        let body = rest.range(of: close).map { rest[..<$0.lowerBound] } ?? rest
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
