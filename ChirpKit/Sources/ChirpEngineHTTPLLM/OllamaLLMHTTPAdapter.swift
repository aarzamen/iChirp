// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/OllamaLLMHTTPAdapter.swift @ bbae9e0e
// Changes: one streaming path (upstream's detailed stream) emitting ChirpCore `GenerationEvent`s, plus the one-token
// test call and native `/api/tags` listing (the `/v1/models` fallback is dropped). `num_ctx` is always sent and equals
// the context window the planner budgets for (`HTTPProviderSettings.contextWindowTokens`, default 8192 as upstream), so
// Ollama never silently drops the start of a long prompt; `num_predict` carries `maxOutputTokens`. `think` is always
// false (no thinking mode in M4 core).

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
                    continuation.yield(
                        .usage(
                            GenerationUsage(
                                promptTokens: lastChunk?.prompt_eval_count, completionTokens: lastChunk?.eval_count,
                                model: lastChunk?.model, stopReason: lastChunk?.done_reason)))
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

        let body = OllamaChatRequest(
            model: settings.modelName,
            messages: messages,
            stream: stream,
            think: false,
            options: OllamaRequestOptions(
                num_ctx: settings.contextWindowTokens,
                num_predict: request.maxOutputTokens
            )
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

/// `num_ctx` overrides Ollama's small default context window.
struct OllamaRequestOptions: Encodable {
    let num_ctx: Int
    let num_predict: Int?
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
