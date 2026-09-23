import ChirpCore
import Foundation

/// How a model is loaded and sampled.
public struct LlamaLoadOptions: Sendable, Equatable {
    public var contextTokens: Int
    /// Tokens per `decode` call while reading the prompt; cancellation is checked between batches.
    public var batchSize: Int
    /// Offloads every layer to the GPU (Metal) when true; CPU only when false (the Simulator).
    public var usesGPU: Bool
    public var sampling: LlamaSampling

    public init(contextTokens: Int, batchSize: Int = 512, usesGPU: Bool, sampling: LlamaSampling) {
        self.contextTokens = contextTokens
        self.batchSize = batchSize
        self.usesGPU = usesGPU
        self.sampling = sampling
    }
}

/// One loaded model and its context: the llama.cpp calls `LlamaCppEngine` makes. `LlamaCppContext` in the app; a fake in
/// tests.
///
/// llama.cpp contexts are not thread-safe, so a session is used only from `LlamaCppEngine`'s serial executor and need
/// not be `Sendable`. Releasing the last reference frees the model and its memory.
public protocol LlamaSession: AnyObject {
    var contextTokens: Int { get }
    var batchSize: Int { get }
    /// `parseSpecial` recognises the chat template's special tokens; content is always tokenized without it.
    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [Int32]
    /// Empties the key/value cache and any recurrent state, and restarts the sampler (new random seed, no penalty
    /// history), so each request starts clean.
    func reset()
    /// Runs the model over `tokens` (at most `batchSize`), after the tokens already in the cache.
    func decode(_ tokens: [Int32]) throws
    /// Draws the next token from the logits of the last `decode`.
    func sample() -> Int32
    func isEndOfGeneration(_ token: Int32) -> Bool
    /// The token's text as UTF-8 bytes (a character can span two tokens). Special tokens render as nothing.
    func piece(_ token: Int32) -> [UInt8]
}

/// Loads sessions. `LlamaCppLoader` (llama.cpp) in the app; a fake in tests.
public protocol LlamaSessionLoading: Sendable {
    /// Whether the llama.cpp runtime is linked into this build (`scripts/build_llamacpp.sh` was run).
    var isRuntimeInBuild: Bool { get }
    /// Loads the GGUF file from disk. Never touches the network. Called on the engine's serial executor.
    func loadSession(modelAt url: URL, options: LlamaLoadOptions) throws -> any LlamaSession
}

/// Failures inside the runtime. Content-free: the texts name llama.cpp's step and return code only.
public enum LlamaSessionError: Error, Equatable, Sendable {
    case notInBuild
    case loadFailed(String)
    case tokenizeFailed
    case decodeFailed(Int32)
}
