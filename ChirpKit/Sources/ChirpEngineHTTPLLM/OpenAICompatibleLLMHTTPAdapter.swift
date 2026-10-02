// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/OpenAICompatibleLLMHTTPAdapter.swift @ bbae9e0e
// Changes: one streaming path (upstream's detailed stream) emitting ChirpCore `GenerationEvent`s, plus the one-token
// test call and model listing. Kept: `parseSSELine` (including LM Studio's mid-stream error frames), the `[DONE]`
// sentinel policy, `max_completion_tokens` for OpenAI reasoning / GPT-5+ model ids (from upstream `OpenAIModelPolicy`),
// `stream_options.include_usage` for api.openai.com only. Dropped: upstream's sampling allow-list, thinking and
// JSON-schema options (no caller in M4 core), OpenCode Go headers, Gemini-specific model listing; a clinical request
// to a LAN server sends ChirpCore's faithful sampling instead (review R3-2). The lab wire policy applies to cloud hosts
// only; LAN servers (LM Studio, llama.cpp) keep `max_tokens`, as upstream does for LM Studio. Stop words and safety
// stops: review R3-1.

import ChirpCore
import Foundation

struct OpenAICompatibleLLMHTTPAdapter: LLMHTTPAdapter {
    func stream(
        _ request: GenerationRequest,
        settings: HTTPProviderSettings,
        transport: LLMHTTPTransport
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try buildRequest(request, settings: settings, stream: true)
                    let (bytes, http) = try await transport.bytes(for: urlRequest)
                    guard (200...299).contains(http.statusCode) else {
                        let body = try await bytes.collectErrorBody()
                        throw LLMHTTPErrorMapper.mapError(
                            statusCode: http.statusCode, data: body, secret: settings.apiKey)
                    }

                    // Each `data:` line is parsed as it arrives: some servers (Gemini) send no blank separators.
                    var sawDone = false
                    var yieldedAnyContent = false
                    var model: String?
                    var stopReason: String?
                    var usage: OpenAIStreamChunk.StreamUsage?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let chunk = Self.decodeStreamChunk(line) {
                            model = chunk.model ?? model
                            stopReason = chunk.choices.first?.finish_reason ?? stopReason
                            usage = chunk.usage ?? usage
                        }
                        switch Self.parseSSELine(line) {
                        case .content(let text):
                            yieldedAnyContent = true
                            continuation.yield(.text(text))
                        case .done:
                            sawDone = true
                        case .error(let message):
                            throw LLMHTTPErrorMapper.mapStreamingError(message: message, secret: settings.apiKey)
                        case .skip:
                            break
                        }
                        if sawDone { break }
                    }
                    if let refusal = LLMHTTPStopReason.refusal(stopReason) { throw refusal }
                    // Strict hosts (OpenAI, OpenRouter) must send `[DONE]`; lenient servers may just close.
                    try LLMHTTPStreamCompletionPolicy.validateStreamCompletion(
                        settings: settings, sawSentinel: sawDone, yieldedAnyContent: yieldedAnyContent)
                    // `length` reaches the consumer as a length-capped usage (review R3-1).
                    let reason = LLMHTTPStopReason.resolved(
                        stopReason, completionTokens: usage?.completion_tokens,
                        maxOutputTokens: request.maxOutputTokens)
                    continuation.yield(
                        .usage(
                            GenerationUsage(
                                promptTokens: usage?.prompt_tokens, completionTokens: usage?.completion_tokens,
                                model: model, stopReason: reason)))
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LLMHTTPTransport.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func testConnection(settings: HTTPProviderSettings, transport: LLMHTTPTransport) async throws {
        // Reasoning models spend tokens before any visible output, so they need a larger budget than 1.
        let needsMoreTokens =
            Self.usesLabWirePolicy(settings)
            && Self.requiresMaxCompletionTokens(settings.modelName)
        let probe = GenerationRequest(
            prompt: "Hi", privacyClass: .general, maxOutputTokens: needsMoreTokens ? 128 : 1)
        let request = try buildRequest(probe, settings: settings, stream: false)
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: data, secret: settings.apiKey)
        }
    }

    func listModels(settings: HTTPProviderSettings, transport: LLMHTTPTransport) async throws -> [String] {
        var request = URLRequest(url: settings.baseURL.appendingPathComponent("models"), timeoutInterval: 15)
        request.httpMethod = "GET"
        if let key = settings.apiKey {
            request.setValue("Bearer \(key.reveal())", forHTTPHeaderField: "Authorization")
        }
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: data, secret: settings.apiKey)
        }
        guard let list = try? JSONDecoder().decode(ModelsListResponse.self, from: data) else {
            throw LanguageModelError.invalidResponse
        }
        return list.data
            .map { $0.id.hasPrefix("models/") ? String($0.id.dropFirst(7)) : $0.id }
            .filter { !LLMHTTPModelCatalog.isClearlyNonTextModelID($0) }
            .sorted()
    }

    func buildRequest(
        _ request: GenerationRequest,
        settings: HTTPProviderSettings,
        stream: Bool
    ) throws -> URLRequest {
        let url = settings.baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(
            url: url, timeoutInterval: stream ? settings.streamTimeout : settings.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = settings.apiKey {
            urlRequest.setValue("Bearer \(key.reveal())", forHTTPHeaderField: "Authorization")
        }

        var messages: [OpenAIMessage] = []
        if let system = request.system, !system.isEmpty {
            messages.append(OpenAIMessage(role: "system", content: system))
        }
        messages.append(OpenAIMessage(role: "user", content: request.prompt))

        let needsNewTokenParameter =
            Self.usesLabWirePolicy(settings)
            && Self.requiresMaxCompletionTokens(settings.modelName)
        var body = OpenAIRequestBody(
            model: settings.modelName,
            messages: messages,
            stream: stream,
            stream_options: stream && settings.host == "api.openai.com"
                ? OpenAIStreamOptions(include_usage: true) : nil,
            max_tokens: needsNewTokenParameter ? nil : request.maxOutputTokens,
            max_completion_tokens: needsNewTokenParameter ? request.maxOutputTokens : nil
        )
        // Review R3-2: a clinical request to a server on the owner's network (LM Studio, llama.cpp) overrides its
        // preset's random sampling and repeat penalty (LM Studio: 1.1), which can change a repeated digit in a dose.
        // Cloud hosts keep their defaults: OpenAI's GPT-5 and o-series reject a non-default temperature, and cloud
        // APIs reject unknown fields such as `repeat_penalty`; their penalties already default to 0.
        if request.requiresFaithfulSampling, !Self.usesLabWirePolicy(settings) {
            body.sampleFaithfully()
        }
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    // MARK: - Model policy (upstream OpenAIModelPolicy)

    /// The OpenAI wire quirks apply to cloud hosts; LAN servers keep the classic parameters.
    static func usesLabWirePolicy(_ settings: HTTPProviderSettings) -> Bool {
        settings.locality == .cloud
    }

    /// o-series reasoning models and GPT-5+ reject `max_tokens`. Accepts gateway prefixes (`openai/gpt-5.5`).
    static func requiresMaxCompletionTokens(_ model: String) -> Bool {
        let id = canonicalModelID(model)
        if isReasoningModel(id) { return true }
        return gptMajorVersion(id).map { $0 >= 5 } ?? false
    }

    static func canonicalModelID(_ model: String) -> String {
        let lowered = model.lowercased()
        guard let slash = lowered.lastIndex(of: "/") else { return lowered }
        return String(lowered[lowered.index(after: slash)...])
    }

    static func gptMajorVersion(_ id: String) -> Int? {
        guard id.hasPrefix("gpt-") else { return nil }
        return Int(id.dropFirst(4).prefix(while: \.isNumber))
    }

    private static func isReasoningModel(_ id: String) -> Bool {
        guard id.hasPrefix("o") else { return false }
        let suffix = id.dropFirst()
        guard let generation = suffix.first, generation.isNumber else { return false }
        let prefix = "o\(generation)"
        let boundary = id.dropFirst(prefix.count).first
        return id.hasPrefix(prefix) && (boundary == nil || boundary == "-")
    }

    // MARK: - SSE parsing

    enum SSEResult: Equatable {
        case content(String)
        case done
        case skip
        case error(String)
    }

    static func parseSSELine(_ line: String) -> SSEResult {
        guard !line.isEmpty else { return .skip }
        guard line.hasPrefix("data:") else { return .skip }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8) else { return .skip }

        // Local servers can report errors mid-stream instead of a non-2xx status (LM Studio: `event: error` then a
        // `data:` object with `error` and a human-readable `message`). Surface them instead of accepting an empty EOF.
        if let streamError = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
            let errorMessage = streamError.error
        {
            return .error(errorMessage)
        }

        guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
            let content = chunk.choices.first?.delta?.content,
            !content.isEmpty
        else {
            return .skip
        }
        return .content(content)
    }

    private static func decodeStreamChunk(_ line: String) -> OpenAIStreamChunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return try? JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(payload.utf8))
    }
}

// MARK: - Wire types

/// The sampling fields are sent only for a clinical request to a server on the local network (`sampleFaithfully()`;
/// `top_k`, `min_p` and `repeat_penalty` are llama.cpp / LM Studio extensions); absent, the server's preset applies.
struct OpenAIRequestBody: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool
    let stream_options: OpenAIStreamOptions?
    let max_tokens: Int?
    let max_completion_tokens: Int?
    var temperature: Double?
    var top_k: Int?
    var top_p: Double?
    var min_p: Double?
    var repeat_penalty: Double?
    var presence_penalty: Double?
    var frequency_penalty: Double?

    init(
        model: String, messages: [OpenAIMessage], stream: Bool, stream_options: OpenAIStreamOptions?,
        max_tokens: Int?, max_completion_tokens: Int?
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.stream_options = stream_options
        self.max_tokens = max_tokens
        self.max_completion_tokens = max_completion_tokens
    }

    /// ChirpCore's `FaithfulSampling` (ADR-015, review R3-2): greedy, no penalty on tokens already written.
    mutating func sampleFaithfully() {
        temperature = FaithfulSampling.temperature
        top_k = FaithfulSampling.topK
        top_p = FaithfulSampling.topP
        min_p = FaithfulSampling.minP
        repeat_penalty = FaithfulSampling.repeatPenalty
        presence_penalty = FaithfulSampling.presencePenalty
        frequency_penalty = FaithfulSampling.frequencyPenalty
    }
}

struct OpenAIStreamOptions: Encodable {
    let include_usage: Bool
}

struct OpenAIMessage: Encodable {
    let role: String
    let content: String
}

struct OpenAIStreamChunk: Decodable {
    let model: String?
    let choices: [StreamChoice]
    let usage: StreamUsage?

    private enum CodingKeys: String, CodingKey {
        case model, choices, usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        // A usage-only final chunk may carry no `choices` at all; its usage still counts (review R3-1).
        choices = try container.decodeIfPresent([StreamChoice].self, forKey: .choices) ?? []
        usage = try container.decodeIfPresent(StreamUsage.self, forKey: .usage)
    }

    struct StreamChoice: Decodable {
        let delta: StreamDelta?
        let finish_reason: String?
    }

    struct StreamDelta: Decodable {
        let content: String?
    }

    struct StreamUsage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
    }
}
