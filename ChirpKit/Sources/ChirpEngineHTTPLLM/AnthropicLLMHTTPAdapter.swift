// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/LLM/AnthropicLLMHTTPAdapter.swift @ bbae9e0e
// Changes: one streaming path (upstream's detailed stream) emitting ChirpCore `GenerationEvent`s, plus the one-token
// test call and model listing; `temperature`/`top_p` are never sent (newer Claude models reject them), so the legacy
// sampling allow-list is dropped; OpenCode Go headers are dropped; errors map to `LanguageModelError`.

import ChirpCore
import Foundation

struct AnthropicLLMHTTPAdapter: LLMHTTPAdapter {
    /// Anthropic Messages API version pin (kept in lockstep for chat and model listing).
    static let apiVersion = "2023-06-01"
    static let defaultMaxTokens = 4_096

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

                    var yieldedAnyContent = false
                    var model: String?
                    var stopReason: String?
                    var promptTokens: Int?
                    var completionTokens: Int?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let json = Self.dataPayload(line) else { continue }

                        switch json["type"] as? String {
                        case "message_start":
                            if let message = json["message"] as? [String: Any] {
                                model = message["model"] as? String ?? model
                                if let usage = message["usage"] as? [String: Any] {
                                    promptTokens = usage["input_tokens"] as? Int ?? promptTokens
                                    completionTokens = usage["output_tokens"] as? Int ?? completionTokens
                                }
                            }
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any], let text = delta["text"] as? String,
                                !text.isEmpty
                            {
                                yieldedAnyContent = true
                                continuation.yield(.text(text))
                            }
                        case "message_delta":
                            if let delta = json["delta"] as? [String: Any] {
                                stopReason = delta["stop_reason"] as? String ?? stopReason
                            }
                            if let usage = json["usage"] as? [String: Any] {
                                completionTokens = usage["output_tokens"] as? Int ?? completionTokens
                            }
                        case "message_stop":
                            try LLMHTTPStreamCompletionPolicy.validateStreamCompletion(
                                settings: settings, sawSentinel: true, yieldedAnyContent: yieldedAnyContent)
                            continuation.yield(
                                .usage(
                                    GenerationUsage(
                                        promptTokens: promptTokens, completionTokens: completionTokens, model: model,
                                        stopReason: stopReason)))
                            continuation.yield(.finished)
                            continuation.finish()
                            return
                        case "error":
                            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                                throw LLMHTTPErrorMapper.mapStreamingError(message: message)
                            }
                            throw LanguageModelError.streamingError("the provider reported an error")
                        default:
                            break
                        }
                    }
                    // Anthropic always ends a successful stream with `message_stop`; EOF without it is truncation.
                    try LLMHTTPStreamCompletionPolicy.validateStreamCompletion(
                        settings: settings, sawSentinel: false, yieldedAnyContent: yieldedAnyContent)
                    throw LanguageModelError.streamingError("the Anthropic stream ended without message_stop")
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
    }

    func listModels(settings: HTTPProviderSettings, transport: LLMHTTPTransport) async throws -> [String] {
        var components = URLComponents(
            url: settings.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        guard let url = components?.url else { throw LanguageModelError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let key = settings.apiKey {
            request.setValue(key.reveal(), forHTTPHeaderField: "x-api-key")
        }
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw LLMHTTPErrorMapper.mapError(statusCode: http.statusCode, data: data)
        }
        guard let list = try? JSONDecoder().decode(ModelsListResponse.self, from: data) else {
            throw LanguageModelError.invalidResponse
        }
        return list.data
            .filter { ($0.type?.lowercased() ?? "model") == "model" && $0.id.lowercased().hasPrefix("claude-") }
            .map(\.id)
            .sorted()
    }

    func buildRequest(
        _ request: GenerationRequest,
        settings: HTTPProviderSettings,
        stream: Bool
    ) throws -> URLRequest {
        let url = settings.baseURL.appendingPathComponent("messages")
        var urlRequest = URLRequest(
            url: url, timeoutInterval: stream ? settings.streamTimeout : settings.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let key = settings.apiKey {
            urlRequest.setValue(key.reveal(), forHTTPHeaderField: "x-api-key")
        }

        var body: [String: Any] = [
            "model": settings.modelName,
            "messages": [["role": "user", "content": request.prompt]],
            "max_tokens": request.maxOutputTokens ?? Self.defaultMaxTokens,
            "stream": stream,
        ]
        if let system = request.system, !system.isEmpty {
            body["system"] = system
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// The JSON object of an SSE `data:` line, or nil for `event:` lines, blanks and unparsable payloads.
    static func dataPayload(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
