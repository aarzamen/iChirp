// Fresh implementation (M7, plan 016 Step 5; ADR-015). The small language models iChirp offers on the iPhone through
// llama.cpp, each pinned to one GGUF file (repository, revision, SHA-256, size) with Apache-2.0 or MIT weights.

import ChirpCore
import Foundation

/// One piece of a chat prompt before tokenization. Control pieces (the chat template's role markers) are tokenized
/// with special tokens recognised; content pieces (instructions, transcript text) never are, so text that happens to
/// contain `<|im_end|>` stays text and cannot open a new turn. (llama.cpp still matches *user-defined* tokens such as
/// Qwen's `<think>` in content; only control tokens are kept out, and those are the ones that delimit turns.)
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

/// One stage of llama.cpp's sampler chain, in order. None of them looks at the tokens already written.
public enum LlamaSamplerStage: Sendable, Equatable {
    case topK(Int32)
    case topP(Float)
    case minP(Float)
    case temperature(Float)
    /// A random draw from what is left (a new seed per request).
    case draw
    /// Always the most likely token.
    case greedy
}

/// Sampler settings for one model.
///
/// **Numbers are never penalized (review I2).** Qwen's tokenizers write every number one digit at a time, so a
/// presence, frequency or repetition penalty over recent tokens punishes the second "0" of "500", the second "1" of
/// "1 1/2" and a unit already written, and pushes the model to "50", "1½" or a dropped dose (measured on the Mac: the
/// Qwen3.5 2B with presence penalty 1.0 lost a dose or rewrote "1 1/2" in 2 of 5 notes of the synthetic visit). llama.cpp's
/// DRY sampler is no fix: it penalizes a token that continues a sequence already written, which is exactly a dose
/// restated in Plan after Subjective. Excluding digit tokens is incomplete: units ("mg", "mcg", "units"), "/" and "."
/// carry the number too. So there is no token-history penalty in any profile, and this type cannot express one.
///
/// What else can move a number, and the settings used:
/// - **Temperature above 0** can draw a digit that is not the model's first choice. Clinical requests use `faithful`
///   (greedy: always the most likely token, and the same note on every run).
/// - **top-k, top-p and min-p** only remove unlikely tokens; they never promote one, so they cannot introduce a digit.
/// - Never add XTC (it removes the most likely tokens), Mirostat or a logit bias to a profile used for documents.
/// - Outside the sampler: the prompt is never truncated (`contextTooLong`), the key/value cache stays f16, and the
///   weights are Q4_K_M (the quantization is the quality floor the real-model number test measures).
public struct LlamaSampling: Sendable, Equatable {
    /// 0 means greedy.
    public var temperature: Float
    public var topK: Int32
    public var topP: Float
    public var minP: Float

    public init(temperature: Float, topK: Int32, topP: Float, minP: Float) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
    }

    /// For clinical requests with every model: the most likely token every time, no randomness, no penalty.
    public static let faithful = LlamaSampling(temperature: 0, topK: 1, topP: 1, minP: 0)

    /// The chain `LlamaCppContext` builds, stage by stage.
    public var stages: [LlamaSamplerStage] {
        guard temperature > 0 else { return [.greedy] }
        var stages: [LlamaSamplerStage] = [.topK(topK), .topP(topP)]
        if minP > 0 { stages.append(.minP(minP)) }
        return stages + [.temperature(temperature), .draw]
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
    /// For general and personal requests; clinical requests always use `LlamaSampling.faithful`.
    public var sampling: LlamaSampling
    /// True only once the model's load time, speed and peak memory on an iPhone are recorded in the research note
    /// (`scripts/device_llm_smoke.sh`, review I3). Until then Settings says "Not yet measured on iPhone".
    public var isMeasuredOnIPhone = false

    public var remoteURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    /// The sampler for one request: `faithful` for clinical content (review I2), the model's own settings otherwise.
    public func sampling(for privacyClass: PrivacyClass) -> LlamaSampling {
        privacyClass == .clinical ? .faithful : sampling
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
        // Qwen's non-thinking settings (temperature 0.7, top-p 0.8, top-k 20) without Qwen's suggested presence penalty,
        // which alters repeated digits (review I2; see `LlamaSampling`).
        sampling: LlamaSampling(temperature: 0.7, topK: 20, topP: 0.8, minP: 0))

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
        // Qwen's recommended instruct settings for the 2507 release (no penalty).
        sampling: LlamaSampling(temperature: 0.7, topK: 20, topP: 0.8, minP: 0))

    public static let all: [LlamaCppModelSpec] = [qwen35_2B, qwen3_4BInstruct2507]

    public static func spec(id: String) -> LlamaCppModelSpec? {
        all.first { $0.id == id }
    }
}
