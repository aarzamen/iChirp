import ChirpCore
import CryptoKit
import Foundation
import Synchronization
import XCTest

@testable import ChirpEngineLlamaCpp

/// What the fake runtime saw, shared between the test and every session the fake loader makes.
final class FakeRuntimeLog: Sendable {
    struct State {
        var loads: [URL] = []
        var freed = 0
        var resets = 0
        /// The sampler each request asked for, in order.
        var samplings: [LlamaSampling] = []
        var tokenized: [(text: String, parseSpecial: Bool)] = []
        var decodedBatches: [Int] = []
        var samples = 0
    }

    private let state = Mutex(State())
    var loads: [URL] { state.withLock { $0.loads } }
    var freed: Int { state.withLock { $0.freed } }
    var resets: Int { state.withLock { $0.resets } }
    var samplings: [LlamaSampling] { state.withLock { $0.samplings } }
    var tokenized: [(text: String, parseSpecial: Bool)] { state.withLock { $0.tokenized } }
    var decodedBatches: [Int] { state.withLock { $0.decodedBatches } }
    var decodeCalls: Int { state.withLock { $0.decodedBatches.count } }

    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
}

/// How the fake model answers: one entry per generated token (its bytes), then end of generation — or the same piece
/// forever.
struct FakeReply: Sendable {
    var pieces: [[UInt8]]
    var repeatsForever = false
    /// Called before each decode with the number of decodes so far (a delay, a failure, a side effect).
    var onDecode: (@Sendable (Int) throws -> Void)?
    /// A decode of exactly these tokens fails with llama.cpp's code -3, as a Metal command-buffer failure does.
    var decodeFailsFor: [Int32]?
    /// Every decode fails with code -3 (a backend in its sticky error state).
    var decodeAlwaysFails = false
    /// Tokenizing fails.
    var tokenizeFails = false

    static func text(_ pieces: [String]) -> FakeReply {
        FakeReply(pieces: pieces.map { Array($0.utf8) })
    }

    static func forever(_ piece: String, onDecode: (@Sendable (Int) throws -> Void)? = nil) -> FakeReply {
        FakeReply(pieces: [Array(piece.utf8)], repeatsForever: true, onDecode: onDecode)
    }
}

/// The reply the fake model gives next; read at every `reset(sampling:)` (the start of each request).
final class FakeReplyBox: Sendable {
    private let value = Mutex(FakeReply.text(["Hello", " there."]))
    var current: FakeReply { value.withLock { $0 } }
    func set(_ reply: FakeReply) { value.withLock { $0 = reply } }
}

/// One byte = one token; the reply is scripted. Records everything in the shared log; its deinit counts as freeing
/// the model.
final class FakeLlamaSession: LlamaSession {
    static let endOfGeneration: Int32 = -1

    let contextTokens: Int
    let batchSize: Int
    private let replies: FakeReplyBox
    private var reply: FakeReply
    private let log: FakeRuntimeLog
    private var next = 0

    init(contextTokens: Int, batchSize: Int, replies: FakeReplyBox, log: FakeRuntimeLog) {
        self.contextTokens = contextTokens
        self.batchSize = batchSize
        self.replies = replies
        self.reply = replies.current
        self.log = log
    }

    deinit { log.update { $0.freed += 1 } }

    func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [Int32] {
        if reply.tokenizeFails { throw LlamaSessionError.tokenizeFailed }
        log.update { $0.tokenized.append((text, parseSpecial)) }
        return Array(repeating: 7, count: text.utf8.count)
    }

    func reset(sampling: LlamaSampling) {
        next = 0
        reply = replies.current
        log.update {
            $0.resets += 1
            $0.samplings.append(sampling)
        }
    }

    func decode(_ tokens: [Int32]) throws {
        precondition(tokens.count <= batchSize, "a decode larger than the batch")
        let calls = log.decodeCalls
        try reply.onDecode?(calls)
        if reply.decodeAlwaysFails || reply.decodeFailsFor == tokens { throw LlamaSessionError.decodeFailed(-3) }
        log.update { $0.decodedBatches.append(tokens.count) }
    }

    func sample() -> Int32 {
        defer { next += 1 }
        log.update { $0.samples += 1 }
        if reply.repeatsForever { return 0 }
        return next < reply.pieces.count ? Int32(next) : Self.endOfGeneration
    }

    func isEndOfGeneration(_ token: Int32) -> Bool { token == Self.endOfGeneration }

    func piece(_ token: Int32) -> [UInt8] { reply.pieces[Int(token)] }
}

/// Makes fake sessions with the current reply.
final class FakeLlamaLoader: LlamaSessionLoading {
    let log = FakeRuntimeLog()
    let isRuntimeInBuild: Bool
    private let replies = FakeReplyBox()
    private let loadError = Mutex<LlamaSessionError?>(nil)

    init(isRuntimeInBuild: Bool = true) {
        self.isRuntimeInBuild = isRuntimeInBuild
    }

    func script(_ reply: FakeReply) { replies.set(reply) }
    func failLoads(with error: LlamaSessionError?) { loadError.withLock { $0 = error } }

    func loadSession(modelAt url: URL, options: LlamaLoadOptions) throws -> any LlamaSession {
        if let error = loadError.withLock({ $0 }) { throw error }
        log.update { $0.loads.append(url) }
        return FakeLlamaSession(
            contextTokens: options.contextTokens, batchSize: options.batchSize, replies: replies, log: log)
    }
}

/// Serves fixed bytes as a "download", counting calls.
final class FakeFileFetcher: LlamaFileFetching {
    private let bytes: Data
    private let calls = Mutex(0)
    var fetchCount: Int { calls.withLock { $0 } }

    init(bytes: Data) {
        self.bytes = bytes
    }

    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        calls.withLock { $0 += 1 }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).gguf")
        try bytes.write(to: file)
        progress(0.5)
        progress(1)
        return file
    }
}

enum LlamaTestSupport {
    /// A catalog-shaped spec whose "weights" are `bytes`, with a small window.
    static func spec(
        id: String = "test-model", bytes: Data = Data("synthetic gguf".utf8), contextTokens: Int = 4_096,
        format: LlamaPromptFormat = .chatML(emptyThinkBlock: false)
    ) -> LlamaCppModelSpec {
        var spec = LlamaCppModelCatalog.qwen35_2B
        spec.id = id
        spec.displayName = "Test \(id)"
        spec.byteCount = Int64(bytes.count)
        spec.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        spec.contextTokens = contextTokens
        spec.promptFormat = format
        return spec
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "llamacpp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Assets for `spec` with the file already downloaded (through the real download path and a fake fetcher).
    static func readyAssets(spec: LlamaCppModelSpec, bytes: Data = Data("synthetic gguf".utf8), directory: URL)
        async throws -> LlamaCppModelAssets
    {
        let assets = LlamaCppModelAssets(
            spec: spec, modelsDirectory: directory, fetcher: FakeFileFetcher(bytes: bytes), freeSpace: { _ in nil })
        try await assets.downloadAssets { _ in }
        return assets
    }

    /// Collects a stream: the text, the usage, whether it finished, and the error if it threw.
    static func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async -> (
        text: String, deltas: [String], usage: GenerationUsage?, finished: Bool, error: Error?
    ) {
        var deltas: [String] = []
        var usage: GenerationUsage?
        var finished = false
        do {
            for try await event in stream {
                switch event {
                case .text(let delta): deltas.append(delta)
                case .usage(let value): usage = value
                case .finished: finished = true
                }
            }
            return (deltas.joined(), deltas, usage, finished, nil)
        } catch {
            return (deltas.joined(), deltas, usage, finished, error)
        }
    }

    /// Polls `condition` for up to `seconds`.
    static func waitUntil(seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
