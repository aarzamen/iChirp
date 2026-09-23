import ChirpCore
import Foundation

#if canImport(llama)
import llama
#endif

/// Facts about the llama.cpp runtime linked into this build.
public enum LlamaCppRuntimeInfo {
    /// The llama.cpp release `scripts/build_llamacpp.sh` builds (a test keeps the two equal).
    public static let pinnedTag = "b11118"
    public static let pinnedCommit = "e6ab7c1a41054a888ada952eab4c886444c2f5ad"

    /// Whether `vendor/llama.xcframework` was linked (ChirpKit's Package.swift adds it only when it exists).
    public static var isInBuild: Bool {
        #if canImport(llama)
        true
        #else
        false
        #endif
    }

    /// What Settings shows when the runtime is missing.
    public static let notInBuildMessage =
        "The on-device model runtime (llama.cpp) is not in this build. Run scripts/build_llamacpp.sh on the Mac, then "
        + "build the app again."

    static let logger = Log.logger("llamacpp")
}

/// Loads GGUF files with llama.cpp. Every layer runs on the GPU (Metal) on a device and on the Mac; in the Simulator it
/// runs on the CPU (the Simulator's Metal is no stand-in for the phone's GPU, and CPU keeps it predictable there).
public struct LlamaCppLoader: LlamaSessionLoading {
    public init() {}

    public var isRuntimeInBuild: Bool { LlamaCppRuntimeInfo.isInBuild }

    /// GPU unless running in the Simulator.
    public static var defaultUsesGPU: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    public func loadSession(modelAt url: URL, options: LlamaLoadOptions) throws -> any LlamaSession {
        #if canImport(llama)
        return try LlamaCppContext(modelAt: url, options: options)
        #else
        throw LlamaSessionError.notInBuild
        #endif
    }
}

#if canImport(llama)

/// Only llama.cpp's errors are kept, and never their text in a public log line (a failed load can name the path).
private func llamaLogCallback(
    level: ggml_log_level, text: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?
) {
    guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
    let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    LlamaCppRuntimeInfo.logger.error("llamacpp_error \(line, privacy: .private)")
}

private enum LlamaBackend {
    /// Once per process: route llama.cpp's log lines, then initialize its backends.
    static let initialized: Void = {
        llama_log_set(llamaLogCallback, nil)
        llama_backend_init()
    }()
}

/// One llama.cpp model, context and sampler chain. Not thread-safe: `LlamaCppEngine` uses it from one serial executor.
final class LlamaCppContext: LlamaSession {
    let contextTokens: Int
    let batchSize: Int

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private var sampler: UnsafeMutablePointer<llama_sampler>
    private let sampling: LlamaSampling

    init(modelAt url: URL, options: LlamaLoadOptions) throws {
        _ = LlamaBackend.initialized
        var modelParams = llama_model_default_params()
        // Negative means every layer.
        modelParams.n_gpu_layers = options.usesGPU ? -1 : 0
        guard let model = llama_model_load_from_file(url.path, modelParams) else {
            throw LlamaSessionError.loadFailed("llama_model_load_from_file returned no model")
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            throw LlamaSessionError.loadFailed("the model has no vocabulary")
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(options.contextTokens)
        contextParams.n_batch = UInt32(options.batchSize)
        contextParams.n_ubatch = UInt32(options.batchSize)
        contextParams.n_seq_max = 1
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaSessionError.loadFailed("llama_init_from_model returned no context (not enough memory?)")
        }
        self.model = model
        self.vocab = vocab
        self.context = context
        self.sampling = options.sampling
        self.sampler = Self.makeSampler(options.sampling, vocab: vocab)
        self.contextTokens = Int(llama_n_ctx(context))
        self.batchSize = Int(llama_n_batch(context))
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    private static func makeSampler(_ sampling: LlamaSampling, vocab: OpaquePointer) -> UnsafeMutablePointer<
        llama_sampler
    > {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if sampling.presencePenalty != 0 {
            llama_sampler_chain_add(
                chain,
                llama_sampler_init_penalties(
                    llama_vocab_n_tokens(vocab), sampling.penaltyLastN, 1.0, 0.0, sampling.presencePenalty))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(sampling.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(sampling.topP, 1))
        if sampling.minP > 0 { llama_sampler_chain_add(chain, llama_sampler_init_min_p(sampling.minP, 1)) }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(sampling.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        return chain
    }

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [Int32] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        if count < 0, count != Int32.min {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, parseSpecial)
        }
        guard count >= 0 else { throw LlamaSessionError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    func reset() {
        llama_memory_clear(llama_get_memory(context), true)
        // A fresh chain: new random seed, empty penalty history.
        llama_sampler_free(sampler)
        sampler = Self.makeSampler(sampling, vocab: vocab)
    }

    func decode(_ tokens: [Int32]) throws {
        var tokens = tokens
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw LlamaSessionError.decodeFailed(status) }
    }

    func sample() -> Int32 {
        // Samples from the last output and records the token for the penalties.
        llama_sampler_sample(sampler, context, -1)
    }

    func isEndOfGeneration(_ token: Int32) -> Bool {
        llama_vocab_is_eog(vocab, token)
    }

    func piece(_ token: Int32) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(count, 0))).map { UInt8(bitPattern: $0) }
    }
}

#endif
