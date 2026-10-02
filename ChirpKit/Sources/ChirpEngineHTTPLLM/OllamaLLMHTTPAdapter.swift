// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/OllamaLLMHTTPAdapter.swift @ bbae9e0e
// Changes: one streaming path (upstream's detailed stream) emitting ChirpCore `GenerationEvent`s, plus the one-token
// test call and native `/api/tags` listing (the `/v1/models` fallback is dropped). `num_ctx` is always sent and equals
// the context window the planner budgets for (`HTTPProviderSettings.contextWindowTokens`, default 8192 as upstream), so
// Ollama never silently drops the start of a long prompt; `num_predict` carries `maxOutputTokens`. `think` is always
// false (no thinking mode in M4 core). A clinical request also sends ChirpCore's faithful sampling (review R3-2), and
// `done_reason` is reported as the stop word (review R3-1).

import ChirpCore
import Foundation

struct OllamaLLMHTTPAdapter: LLMHTTPAdapter {
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
                        throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: body)
                    }

                    // Ollama streams NDJSON: one JSON object per line; `done: true` ends it.
                    var yieldedAnyContent = false
                    var lastChunk: OllamaChatResponse?
                    var sawDone = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        if let envelope = try? JSONDecoder().decode(StreamErrorResponse.self, from: data),
                            let error = envelope.error
                        {
                            throw LLMHTTPErrorMapper.mapStreamingError(message: error)
                        }
                        guard let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                            continue
                        }
                        lastChunk = chunk
                        if let content = chunk.message?.content, !content.isEmpty {
                            yieldedAnyContent = true
                            continuation.yield(.text(content))
                        }
                        if chunk.done == true {
                            sawDone = true
                            break
                        }
                    }
                    try LLMHTTPStreamCompletionPolicy.validateStreamCompletion(
                        settings: settings, sawSentinel: sawDone, yieldedAnyContent: yieldedAnyContent)
                    // `done_reason: "length"` (the `num_predict` cap) reaches the consumer as a length-capped usage
                    // (review R3-1).
                    let reason = LLMHTTPStopReason.resolved(
                        lastChunk?.done_reason, completionTokens: lastChunk?.eval_count,
                        maxOutputTokens: request.maxOutputTokens)
                    continuation.yield(
                        .usage(
                            GenerationUsage(
                                promptTokens: lastChunk?.prompt_eval_count, completionTokens: lastChunk?.eval_count,
                                model: lastChunk?.model, stopReason: reason)))
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
        let probe = GenerationRequest(prompt: "Hi", privacyClass: .general, maxOutputTokens: 1)
        let request = try buildRequest(probe, settings: settings, stream: false)
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: data)
        }
        if let envelope = try? JSONDecoder().decode(StreamErrorResponse.self, from: data), let error = envelope.error {
            throw LLMHTTPErrorMapper.mapStreamingError(message: error)
        }
    }

    func listModels(settings: HTTPProviderSettings, transport: LLMHTTPTransport) async throws -> [String] {
        var request = URLRequest(url: try Self.nativeURL(settings.baseURL, path: "api/tags"), timeoutInterval: 15)
        request.httpMethod = "GET"
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: data)
        }
        guard let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) else {
            throw LanguageModelError.invalidResponse
        }
        return tags.models.map(\.name).filter { !LLMHTTPModelCatalog.isClearlyNonTextModelID($0) }.sorted()
    }

    func buildRequest(
        _ request: GenerationRequest,
        settings: HTTPProviderSettings,
        stream: Bool
    ) throws -> URLRequest {
        let url = try Self.nativeURL(settings.baseURL, path: "api/chat")
        var urlRequest = URLRequest(
            url: url, timeoutInterval: stream ? settings.streamTimeout : settings.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = settings.apiKey {
            urlRequest.setValue("Bearer \(key.reveal())", forHTTPHeaderField: "Authorization")
        }

        var messages: [OllamaMessage] = []
        if let system = request.system, !system.isEmpty {
            messages.append(OllamaMessage(role: "system", content: system))
        }
        messages.append(OllamaMessage(role: "user", content: request.prompt))

        var options = OllamaRequestOptions(
            num_ctx: settings.contextWindowTokens,
            num_predict: request.maxOutputTokens
        )
        // Review R3-2: a clinical request overrides Ollama's random sampling (temperature 0.8) and its repeat penalty
        // (1.1 over the last 64 tokens), which can change a repeated digit in a dose; other requests keep the server's.
        if request.requiresFaithfulSampling {
            options.sampleFaithfully()
        }
        let body = OllamaChatRequest(
            model: settings.modelName,
            messages: messages,
            stream: stream,
            think: false,
            options: options
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    /// The native API lives at the server root: a base URL ending in `/v1` (the OpenAI-compatible path) is trimmed.
    static func nativeURL(_ baseURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw LanguageModelError.connectionFailed("The Ollama address is not a valid URL.")
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == "v1" { segments.removeLast() }
        segments.append(contentsOf: path.split(separator: "/").map(String.init))
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        guard let url = components.url else {
            throw LanguageModelError.connectionFailed("The Ollama address is not a valid URL.")
        }
        return url
    }
}

// MARK: - Wire types

struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let think: Bool
    let options: OllamaRequestOptions
}

struct OllamaMessage: Encodable {
    let role: String
    let content: String
}

/// `num_ctx` overrides Ollama's small default context window. The sampling fields are sent only for a clinical
/// request (`sampleFaithfully()`); absent, Ollama applies its own (the model's) settings.
struct OllamaRequestOptions: Encodable {
    let num_ctx: Int
    let num_predict: Int?
    var temperature: Double?
    var top_k: Int?
    var top_p: Double?
    var min_p: Double?
    var repeat_penalty: Double?
    var presence_penalty: Double?
    var frequency_penalty: Double?

    init(num_ctx: Int, num_predict: Int?) {
        self.num_ctx = num_ctx
        self.num_predict = num_predict
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

struct OllamaChatResponse: Decodable {
    let model: String?
    let message: OllamaResponseMessage?
    let done: Bool?
    let done_reason: String?
    let prompt_eval_count: Int?
    let eval_count: Int?

    struct OllamaResponseMessage: Decodable {
        let role: String?
        let content: String?
    }
}

struct OllamaTagsResponse: Decodable {
    let models: [ModelEntry]

    struct ModelEntry: Decodable {
        let name: String
    }
}
