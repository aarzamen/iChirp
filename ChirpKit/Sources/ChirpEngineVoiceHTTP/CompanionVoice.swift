// Ported from Readback (owner's project): Sources/TTS/OpenAIProvider.swift @ 696cef6
// Changes: the OpenAI speech shape goes to the owner's Mac companion (spec/contracts/mac-companion-v1.md) instead of
// api.openai.com: base URL, port and pairing token come from `CompanionConfiguration`; voices come from
// `GET /v1/voices` ("model:Name" ids split into `model` and `voice`); `style` becomes `instructions`; WAV by default
// (the Content-Type decides the format); `availability()` caches `GET /v1/companion` for 30 s; locality follows the
// host (a non-local address counts as cloud); redirects refused, token scrubbed from errors.

import ChirpCore
import Foundation
import Synchronization

/// The owner's voices (ChoiceVoice's Qwen3-TTS, Kokoro) on the Mac companion, `POST /v1/audio/speech`. Home network:
/// clinical text may reach it only when the owner trusts this Mac (`PrivacyRoutingPolicy`).
public final class CompanionVoice: SpeechSynthesizing, Sendable {
    public static let engineID = "companion.speech"
    /// The companion refuses longer input with 413.
    public static let maxInputCharacters = 4_000
    /// How long a health answer is reused by `availability()`.
    public static let availabilityLifetime: TimeInterval = 30

    static let synthesisTimeout: TimeInterval = 120
    static let requestTimeout: TimeInterval = 10
    static let healthTimeout: TimeInterval = 4

    /// What the companion reports at `GET /v1/companion` (no token needed).
    public struct Status: Sendable, Equatable {
        public var version: String?
        public var api: String?
        public var speech: Bool
        public var models: [String]
    }

    private struct CachedStatus {
        var baseURL: URL
        var checkedAt: Date
        var result: Result<Status, SpeechSynthesisError>
    }

    private let configuration: any CompanionConfiguration
    private let transport: VoiceHTTPTransport
    private let now: @Sendable () -> Date
    /// Requested audio format; the Content-Type of the answer wins.
    private let responseFormat: SynthesizedAudio.Format
    private let cache = Mutex<CachedStatus?>(nil)

    public convenience init(configuration: any CompanionConfiguration) {
        self.init(configuration: configuration, transport: .shared)
    }

    init(
        configuration: any CompanionConfiguration,
        transport: VoiceHTTPTransport,
        responseFormat: SynthesizedAudio.Format = .wav,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.responseFormat = responseFormat
        self.now = now
    }

    // MARK: - SpeechSynthesizing

    public var descriptor: EngineDescriptor {
        EngineDescriptor(
            id: Self.engineID,
            kind: .speechSynthesis,
            provider: "Parakeet companion",
            displayName: "Mac companion",
            locality: configuration.companionEndpoint()?.locality ?? .localNetwork,
            license: "Apache-2.0 (Qwen3-TTS, Kokoro weights)"
        )
    }

    public var endpointHost: String? {
        guard let host = configuration.companionEndpoint()?.normalizedHost, !host.isEmpty else { return nil }
        return host
    }

    public var maxCharactersPerRequest: Int { Self.maxInputCharacters }

    /// Not set up, not paired, not reachable, or no voice models: a sentence to show. A health answer is reused for
    /// 30 s; nothing but `GET /v1/companion` is sent.
    public func availability() async -> SpeechSynthesisAvailability {
        guard let endpoint = configuration.companionEndpoint(), let baseURL = endpoint.baseURL else {
            return .unavailable("Set up the Mac companion in Settings → Mac companion.")
        }
        do {
            guard let token = try configuration.companionPairingToken(), !token.isEmpty else {
                return .unavailable("Pair this iPhone with the Mac companion in Settings → Mac companion.")
            }
        } catch {
            return .unavailable("The Mac companion's pairing token could not be read from the Keychain.")
        }
        switch await status(at: baseURL) {
        case .success(let status):
            return status.speech
                ? .available
                : .unavailable(
                    "The Mac companion is running but has no voice model ready. Load one on the Mac, then try again.")
        case .failure(.connectionFailed), .failure(.redirectRefused):
            return .unavailable(
                "The Mac companion is not reachable at \(endpoint.normalizedHost). Start it on the Mac "
                    + "(scripts/companion.sh) and use the same Wi-Fi.")
        case .failure(let error):
            return .unavailable(error.errorDescription ?? "The Mac companion did not answer.")
        }
    }

    /// Forgets the cached health answer (Settings' Check again).
    public func invalidateAvailability() {
        cache.withLock { $0 = nil }
    }

    /// The companion's health answer, from the 30-second cache when fresh.
    public func status() async throws -> Status {
        guard let baseURL = configuration.companionEndpoint()?.baseURL else {
            throw SpeechSynthesisError.notConfigured("set up the Mac companion in Settings → Mac companion.")
        }
        return try await status(at: baseURL).get()
    }

    public func voices() async throws -> [SynthesisVoice] {
        let (baseURL, token) = try connection()
        var request = URLRequest(url: baseURL.appending(path: "v1/voices"))
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token.reveal())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, data: data, token: token, voiceID: nil)
        }
        do {
            return try JSONDecoder().decode(VoicesResponse.self, from: data).voices.map {
                SynthesisVoice(id: $0.id, name: $0.name, detail: $0.detail, languages: $0.languages ?? [])
            }
        } catch {
            throw SpeechSynthesisError.server(status: response.statusCode, message: "The voice list was not readable.")
        }
    }

    private struct Body: Encodable {
        let model: String?
        let input: String
        let voice: String
        let instructions: String?
        let response_format: String
        let language: String?
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        guard let (model, voice) = Self.split(voiceID: request.voiceID) else {
            throw SpeechSynthesisError.notConfigured("choose a voice in Settings → Voices.")
        }
        guard request.text.count <= Self.maxInputCharacters else {
            throw SpeechSynthesisError.server(
                status: 413, message: "The text is longer than \(Self.maxInputCharacters) characters.")
        }
        let (baseURL, token) = try connection()
        var httpRequest = URLRequest(url: baseURL.appending(path: "v1/audio/speech"))
        httpRequest.httpMethod = "POST"
        httpRequest.timeoutInterval = Self.synthesisTimeout
        httpRequest.setValue("Bearer \(token.reveal())", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let style = request.style?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = Body(
            model: model,
            input: request.text,
            voice: voice,
            instructions: style?.isEmpty == false ? style : nil,
            response_format: responseFormat == .mp3 ? "mp3" : "wav",
            language: request.language
        )
        httpRequest.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: httpRequest)
        guard (200...299).contains(response.statusCode) else {
            throw Self.mapError(status: response.statusCode, data: data, token: token, voiceID: request.voiceID)
        }
        guard !data.isEmpty else { throw SpeechSynthesisError.emptyAudio }
        return SynthesizedAudio(data: data, format: Self.format(of: response) ?? responseFormat)
    }

    /// An engine bound to the companion as configured now (address and token read once), so one utterance keeps
    /// talking to exactly the host routing approved. Throws when the companion is not set up or not paired.
    public func pinned() throws -> CompanionVoice {
        let (_, token) = try connection()
        return CompanionVoice(
            configuration: FixedCompanionConfiguration(endpoint: configuration.companionEndpoint(), token: token),
            transport: transport, responseFormat: responseFormat, now: now)
    }

    // MARK: - Private

    private func connection() throws -> (URL, SecretValue) {
        guard let baseURL = configuration.companionEndpoint()?.baseURL else {
            throw SpeechSynthesisError.notConfigured("set up the Mac companion in Settings → Mac companion.")
        }
        let token: SecretValue?
        do {
            token = try configuration.companionPairingToken()
        } catch {
            throw SpeechSynthesisError.notConfigured("the pairing token could not be read from the Keychain.")
        }
        guard let token, !token.isEmpty else {
            throw SpeechSynthesisError.notConfigured(
                "pair this iPhone with the Mac companion in Settings → Mac companion.")
        }
        return (baseURL, token)
    }

    private func status(at baseURL: URL) async -> Result<Status, SpeechSynthesisError> {
        let current = now()
        let cached = cache.withLock { $0 }
        if let cached, cached.baseURL == baseURL,
            current.timeIntervalSince(cached.checkedAt) < Self.availabilityLifetime,
            current >= cached.checkedAt
        {
            return cached.result
        }
        let result = await fetchStatus(baseURL)
        cache.withLock { $0 = CachedStatus(baseURL: baseURL, checkedAt: current, result: result) }
        return result
    }

    private func fetchStatus(_ baseURL: URL) async -> Result<Status, SpeechSynthesisError> {
        var request = URLRequest(url: baseURL.appending(path: "v1/companion"))
        request.timeoutInterval = Self.healthTimeout
        do {
            let (data, response) = try await transport.data(for: request)
            guard (200...299).contains(response.statusCode) else {
                return .failure(Self.mapError(status: response.statusCode, data: data, token: nil, voiceID: nil))
            }
            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
            return .success(
                Status(
                    version: decoded.version, api: decoded.api, speech: decoded.features?.speech ?? false,
                    models: decoded.speech?.models ?? []))
        } catch let error as SpeechSynthesisError {
            return .failure(error)
        } catch is DecodingError {
            return .failure(.server(status: 200, message: "This does not look like the Parakeet companion."))
        } catch {
            return .failure(.connectionFailed(error.localizedDescription))
        }
    }

    /// "qwen3-tts-1.7b:Ryan" → ("qwen3-tts-1.7b", "Ryan"); "Ryan" → (nil, "Ryan") so the companion's default model
    /// speaks it. Nil for an empty id.
    static func split(voiceID: String) -> (model: String?, voice: String)? {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return (nil, trimmed) }
        let model = String(trimmed[..<colon])
        let voice = String(trimmed[trimmed.index(after: colon)...])
        guard !voice.isEmpty else { return nil }
        return (model.isEmpty ? nil : model, voice)
    }

    static func format(of response: HTTPURLResponse) -> SynthesizedAudio.Format? {
        let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if type.contains("mpeg") || type.contains("mp3") { return .mp3 }
        if type.contains("wav") || type.contains("wave") { return .wav }
        if type.contains("aac") || type.contains("mp4") { return .aac }
        return nil
    }

    /// mac-companion-v1 errors: 401 bad token, 400 unknown voice or model, 413 text too long, 503 model not loaded
    /// (its message says which command loads it).
    static func mapError(status: Int, data: Data, token: SecretValue?, voiceID: String?) -> SpeechSynthesisError {
        let message = VoiceHTTPErrors.message(from: data, secret: token)
        switch status {
        case 400:
            let code = VoiceHTTPErrors.code(from: data) ?? ""
            if let voiceID, code.contains("voice") || message.lowercased().contains("voice") {
                return .unsupportedVoice(voiceID)
            }
            return .server(status: status, message: message)
        case 413:
            return .server(status: status, message: "The text is too long for the Mac companion.")
        default:
            return VoiceHTTPErrors.map(status: status, data: data, secret: token)
        }
    }
}

// MARK: - Wire types (mac-companion-v1)

private struct StatusResponse: Decodable {
    struct Features: Decodable { let speech: Bool? }
    struct Speech: Decodable { let models: [String]? }
    let version: String?
    let api: String?
    let features: Features?
    let speech: Speech?
}

private struct VoicesResponse: Decodable {
    struct Voice: Decodable {
        let id: String
        let name: String
        let detail: String?
        let languages: [String]?
    }
    let voices: [Voice]
}
