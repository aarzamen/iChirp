// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift @ bbae9e0e
// — upstream `send`: encode, size-check, one POST with a 15 s timeout and a bearer key, strict validation of every
// answer. Fresh implementation of ChirpCore's `DecisionModel`: statuses map onto `LanguageModelError` (with key
// artifacts scrubbed), redirects are refused, and a missing key sends nothing.

import ChirpCore
import Foundation

/// Jev (TypeSafe AI) as a `DecisionModel`: one cloud round trip per decision, choice questions only.
///
/// Holds the API key only in memory as a redacted `SecretValue`. Every request goes to `endpointHost` (redirects are
/// refused). Engines do not route: `DecisionService` refuses clinical items before this is ever called.
public actor JevDecisionModel: DecisionModel {
    /// Stable, persisted in the run ledger. Never rename or reuse.
    public static let engineID = "http.jev"
    /// The pinned versioned id (an alias would answer with a different id, which validation rejects).
    public static let defaultModel = "jev-1.13.0"
    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!
    /// Upstream's request timeout.
    static let timeout: TimeInterval = 15

    public nonisolated let descriptor: EngineDescriptor
    public nonisolated let endpointHost: String?
    /// The model id every request asks for.
    public nonisolated let model: String

    private let apiKey: SecretValue?
    private let baseURL: URL
    private let transport: JevHTTPTransport

    init(apiKey: SecretValue?, baseURL: URL, model: String, transport: JevHTTPTransport) {
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 }
        self.apiKey = key
        self.baseURL = baseURL
        self.transport = transport
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
        endpointHost = Self.host(of: baseURL)
        descriptor = JevDecisionModels.descriptor
    }

    /// `https://<host>/v1/systemone` (or the DEBUG stub's address).
    public nonisolated var endpoint: URL {
        baseURL.appending(path: "v1/systemone")
    }

    public func availability() async -> LanguageModelAvailability {
        if let reason = unavailableReason() { return .unavailable(reason) }
        return .available
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        try Task.checkCancellation()
        try request.validate()
        guard let apiKey, unavailableReason() == nil else {
            throw LanguageModelError.unavailable(
                unavailableReason() ?? .notConfigured(JevDecisionModels.missingKeyDetail))
        }

        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            body = try encoder.encode(JevWire.request(for: request, model: model))
        } catch {
            throw LanguageModelError.invalidResponse
        }
        guard body.count <= JevWire.requestByteLimit else { throw LanguageModelError.contextTooLong }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Self.timeout
        urlRequest.setValue("Bearer " + apiKey.reveal(), forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body

        let started = ContinuousClock.now
        let (data, response) = try await transport.data(for: urlRequest)
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now)

        guard response.statusCode == 200 else {
            throw Self.mapStatus(response.statusCode, data: data, apiKey: apiKey)
        }
        guard data.count <= JevWire.responseByteLimit else { throw LanguageModelError.invalidResponse }
        let decoded: JevWire.Response
        do {
            decoded = try JSONDecoder().decode(JevWire.Response.self, from: data)
        } catch {
            throw LanguageModelError.invalidResponse
        }
        guard
            let answers = JevWire.validatedAnswers(decoded, requestedModel: model, questions: request.questions)
        else { throw LanguageModelError.invalidResponse }

        let milliseconds =
            Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return DecisionResult(
            model: decoded.model, answers: answers, latencyMs: milliseconds, requestBytes: body.count,
            inputTokens: decoded.usage?.inputTokens, outputTokens: decoded.usage?.outputTokens)
    }

    // MARK: - Helpers

    private func unavailableReason() -> LanguageModelUnavailableReason? {
        if let problem = JevDecisionModels.problem(with: baseURL) { return .notConfigured(problem) }
        if apiKey == nil { return .notConfigured(JevDecisionModels.missingKeyDetail) }
        return nil
    }

    private static func host(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// Status → `LanguageModelError`. The provider's text is scrubbed of key artifacts (and of this key verbatim),
    /// shown to the user only, never logged or stored.
    static func mapStatus(_ status: Int, data: Data, apiKey: SecretValue) -> LanguageModelError {
        let message = scrubbed(providerMessage(in: data), apiKey: apiKey)
        switch status {
        case 401, 403:
            return .authenticationFailed(message.isEmpty ? nil : message)
        case 429:
            return .rateLimited
        case 413:
            // Not `contextTooLong`: that error means "refused before sending" to the ledger, and this request was sent.
            return .providerError("The request was too large for TypeSafe (HTTP 413).")
        case 529:
            return .providerError("TypeSafe is overloaded (HTTP 529). Try again in a moment.")
        default:
            let detail = message.isEmpty ? "" : ": \(message)"
            return .providerError("TypeSafe answered HTTP \(status)\(detail)")
        }
    }

    /// The first readable message of an error body: `{"error": {"message"}}`, `{"error": "…"}`, `{"message": "…"}`,
    /// `{"detail": "…"}`, else the text itself, capped at 300 characters.
    static func providerMessage(in data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let candidates: [String?] = [
            (object?["error"] as? [String: Any])?["message"] as? String,
            object?["error"] as? String,
            object?["message"] as? String,
            object?["detail"] as? String,
        ]
        let raw =
            candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? String(decoding: data.prefix(2_048), as: UTF8.self)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }

    static func scrubbed(_ message: String, apiKey: SecretValue) -> String {
        var out = JevHTTPTransport.scrubAPIKeyArtifacts(from: message)
        let key = apiKey.reveal()
        if key.count >= 4 { out = out.replacingOccurrences(of: key, with: "<api-key>") }
        return out
    }
}
