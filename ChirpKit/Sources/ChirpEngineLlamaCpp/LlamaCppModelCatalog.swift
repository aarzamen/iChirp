// Fresh implementation (M7, plan 016 Step 5; ADR-015). The small language models iChirp offers on the iPhone through
// llama.cpp, each pinned to one GGUF file (repository, revision, SHA-256, size) with Apache-2.0 or MIT weights.

import ChirpCore
import Foundation

/// One piece of a chat prompt before tokenization. Control pieces (the chat template's role markers) are tokenized
/// with special tokens recognised; content pieces (instructions, transcript text) never are, so text that happens to
/// contain `<|im_end|>` stays text and cannot open a new turn.
public enum LlamaPromptPiece: Sendable, Equatable {
    case control(String)
    case content(String)
}

/// How a model's chat turn is written before tokenization.
public enum LlamaPromptFormat: Sendable, Equatable {
    /// Qwen's ChatML. `emptyThinkBlock` pre-fills an empty `<think></think>` block, exactly as Qwen3.5's own template
    /// does when thinking is off (the default for Qwen3.5-2B), so the model answers directly.
    case chatML(emptyThinkBlock: Bool)

    /// The system turn (when there is one), the user turn and the opening of the assistant turn.
    public func pieces(system: String?, prompt: String) -> [LlamaPromptPiece] {
        switch self {
        case .chatML(let emptyThinkBlock):
            var pieces: [LlamaPromptPiece] = []
            if let system, !system.isEmpty {
                pieces += [.control("<|im_start|>system\n"), .content(system), .control("<|im_end|>\n")]
            }
            pieces += [
                .control("<|im_start|>user\n"), .content(prompt), .control("<|im_end|>\n<|im_start|>assistant\n"),
            ]
            if emptyThinkBlock { pieces.append(.control("<think>\n\n</think>\n\n")) }
            return pieces
        }
    }
}

/// Sampler settings for one model (llama.cpp's sampler chain: penalties, top-k, top-p, min-p, temperature, draw).
public struct LlamaSampling: Sendable, Equatable {
    public var temperature: Float
    public var topK: Int32
    public var topP: Float
    public var minP: Float
    /// Penalizes any token already produced in the last `penaltyLastN` tokens (Qwen's "presence penalty").
    public var presencePenalty: Float
    public var penaltyLastN: Int32

    public init(
        temperature: Float, topK: Int32, topP: Float, minP: Float, presencePenalty: Float, penaltyLastN: Int32 = 64
    ) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.penaltyLastN = penaltyLastN
    }
}

/// One downloadable model: which file, where it comes from, how big it is, and how iChirp runs it.
public struct LlamaCppModelSpec: Sendable, Equatable, Identifiable {
    public enum Tier: String, Sendable, Equatable {
        /// The default: small, fast, fits comfortably next to the rest of the app.
        case standard
        /// Better writing, twice the memory.
        case quality
    }

    /// Stable id, persisted as the default choice and as the run ledger's model. Never rename or reuse.
    public var id: String
    public var displayName: String
    public var tier: Tier
    /// SPDX id of the weights' license. Only Apache-2.0 and MIT are allowed (ADR-015).
    public var license: String
    /// The original model the GGUF was converted from, for attribution.
    public var baseModel: String
    /// Hugging Face repository that hosts the GGUF file.
    public var repository: String
    /// The repository commit the download URL resolves (never `main`).
    public var revision: String
    public var fileName: String
    public var quantization: String
    public var sha256: String
    public var byteCount: Int64
    /// The context window iChirp allocates (instructions, input and output together).
    public var contextTokens: Int
    /// f16 key/value cache per token of context, from the model's attention layout; drives the memory estimate.
    public var kvCacheBytesPerToken: Int64
    /// llama.cpp's compute and output buffers on top of weights and cache (measured on the Mac; see the research note).
    public var computeOverheadBytes: Int64
    public var promptFormat: LlamaPromptFormat
    public var sampling: LlamaSampling

    public var remoteURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    /// About how much memory the loaded model needs: weights, a full context's cache and llama.cpp's buffers.
    public var estimatedMemoryBytes: Int64 {
        byteCount + kvCacheBytesPerToken * Int64(contextTokens) + computeOverheadBytes
    }
}

/// The models offered in Settings → Models (ADR-015). Order is the order shown.
public enum LlamaCppModelCatalog {
    /// Qwen3.5-2B (Apache-2.0), Q4_K_M. Hybrid attention: 6 of its 24 layers keep a key/value cache (2 KV heads of
    /// 256), the rest carry a small fixed state, so a 32K window costs about 0.4 GB.
    public static let qwen35_2B = LlamaCppModelSpec(
        id: "qwen3.5-2b-q4_k_m",
        displayName: "Qwen3.5 2B",
        tier: .standard,
        license: "Apache-2.0",
        baseModel: "Qwen/Qwen3.5-2B",
        repository: "unsloth/Qwen3.5-2B-GGUF",
        revision: "f6d5376be1edb4d416d56da11e5397a961aca8ae",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        quantization: "Q4_K_M",
        sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        byteCount: 1_280_835_840,
        contextTokens: 32_768,
        kvCacheBytesPerToken: 6 * 2 * 256 * 2 * 2,
        computeOverheadBytes: 512 * 1_048_576,
        promptFormat: .chatML(emptyThinkBlock: true),
        // Qwen's non-thinking settings (temperature 0.7, top-p 0.8, top-k 20) with a mild presence penalty: the 2B is
        // prone to repeating itself, and a stronger penalty would push it off words a clinical note must repeat.
        sampling: LlamaSampling(temperature: 0.7, topK: 20, topP: 0.8, minP: 0, presencePenalty: 1.0))

    /// Qwen3-4B-Instruct-2507 (Apache-2.0), Q4_K_M: the quality tier. 36 layers with 8 KV heads of 128, so an 8K
    /// window costs about 1.2 GB on top of 2.5 GB of weights.
    public static let qwen3_4BInstruct2507 = LlamaCppModelSpec(
        id: "qwen3-4b-instruct-2507-q4_k_m",
        displayName: "Qwen3 4B Instruct",
        tier: .quality,
        license: "Apache-2.0",
        baseModel: "Qwen/Qwen3-4B-Instruct-2507",
        repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
        revision: "a06e946bb6b655725eafa393f4a9745d460374c9",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        quantization: "Q4_K_M",
        sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        byteCount: 2_497_281_120,
        contextTokens: 8_192,
        kvCacheBytesPerToken: 36 * 8 * 128 * 2 * 2,
        computeOverheadBytes: 512 * 1_048_576,
        promptFormat: .chatML(emptyThinkBlock: false),
        // Qwen's recommended instruct settings for the 2507 release.
        sampling: LlamaSampling(temperature: 0.7, topK: 20, topP: 0.8, minP: 0, presencePenalty: 0))

    public static let all: [LlamaCppModelSpec] = [qwen35_2B, qwen3_4BInstruct2507]

    public static func spec(id: String) -> LlamaCppModelSpec? {
        all.first { $0.id == id }
    }
}
