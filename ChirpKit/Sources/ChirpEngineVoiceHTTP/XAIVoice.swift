// Ported from Readback (owner's project): Sources/TTS/XAIProvider.swift @ 696cef6
// Changes: conforms to ChirpCore's `SpeechSynthesizing` (id `xai.tts`, locality cloud); the key comes from an injected
// `SecretStoring` (the Keychain) as a `SecretValue`; the owner's cloned voice is NOT a built-in voice (the repository is
// public) — the phone has a free-text Voice ID field instead; the language comes from the request (default "en"); the
// transport refuses redirects and scrubs the key from errors; `availability()` is a local key check (no network).

import ChirpCore
import Foundation

/// Grok voices: xAI text to speech, `POST https://api.x.ai/v1/tts` with a Bearer key. Cloud: clinical text needs the
/// per-run confirmation before the caller may hand it here (`PrivacyRoutingPolicy`).
public struct XAIVoice: SpeechSynthesizing {
    public static let engineID = "xai.tts"
    public static let host = "api.x.ai"
    /// The Keychain account that holds the xAI API key.
    public static let secretAccount = "voice.xai.api-key"

    public static let engineDescriptor = EngineDescriptor(
        id: engineID,
        kind: .speechSynthesis,
        provider: "xAI",
        displayName: "Grok voices",
        locality: .cloud,
        license: "Proprietary (xAI API)"
    )

    /// xAI's stock voices. There is no voice-list endpoint; a cloned voice is typed as a Voice ID on the phone.
    public static let stockVoices: [SynthesisVoice] = [
        SynthesisVoice(id: "eve", name: "Eve"),
        SynthesisVoice(id: "ara", name: "Ara"),
        SynthesisVoice(id: "rex", name: "Rex"),
        SynthesisVoice(id: "sal", name: "Sal"),
        SynthesisVoice(id: "leo", name: "Leo"),
    ]

    /// Synthesis can take a while for a long chunk; the key check is quick.
    static let synthesisTimeout: TimeInterval = 120
    static let validationTimeout: TimeInterval = 15

    public var descriptor: EngineDescriptor { Self.engineDescriptor }
    public var endpointHost: String? { Self.host }
    /// xAI's per-request limit.
    public let maxCharactersPerRequest = 15_000

    private let secrets: any SecretStoring
    private let transport: VoiceHTTPTransport
    private let baseURL = URL(string: "https://api.x.ai/v1")!

    public init(secrets: any SecretStoring) {
        self.init(secrets: secrets, transport: .shared)
    }

    init(secrets: any SecretStoring, transport: VoiceHTTPTransport) {
        self.secrets = secrets
        self.transport = transport
    }

    /// Available when a key is stored. Never calls the network (Settings → Voices has Check key for that).
    public func availability() async -> SpeechSynthesisAvailability {
        do {
            _ = try apiKey()
            return .available
        } catch let error as SpeechSynthesisError {
            return .unavailable(error.errorDescription ?? "Grok voices are not set up.")
        } catch {
            return .unavailable("Grok voices are not set up.")
        }
    }

    public func voices() async throws -> [SynthesisVoice] { Self.stockVoices }

    /// Checks the stored key with `GET /v1/api-key` (no text is sent, nothing is spoken).
    public func validateKey() async throws {
        let key = try apiKey()
        var request = request(path: "api-key", key: key, timeout: Self.validationTimeout)
        request.httpMethod = "GET"
        let (data, response) = try await transport.data(for: request)
        guard (200...299).contains(response.statusCode) else {
            throw VoiceHTTPErrors.map(status: response.statusCode, data: data, secret: key)
        }
    }

    private struct Body: Encodable {
        struct OutputFormat: Encodable {
            let codec: String
            let sample_rate: Int
            let bit_rate: Int
        }
        let text: String
        let voice_id: String
        let language: String
        let output_format: OutputFormat
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        let voiceID = request.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty else { throw SpeechSynthesisError.notConfigured("choose a voice in Settings → Voices.") }
        guard request.text.count <= maxCharactersPerRequest else {
            throw SpeechSynthesisError.server(
                status: 413, message: "The text is longer than \(maxCharactersPerRequest) characters.")
        }
        let key = try apiKey()
        var httpRequest = self.request(path: "tts", key: key, timeout: Self.synthesisTimeout)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Plain text only: speech tags are never injected into the user's content (Readback spec §4.4).
        let body = Body(
            text: request.text,
            voice_id: voiceID,
            language: request.language ?? "en",
            output_format: .init(codec: "mp3", sample_rate: 44_100, bit_rate: 128_000)
        )
        httpRequest.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: httpRequest)
        guard (200...299).contains(response.statusCode) else {
            throw VoiceHTTPErrors.map(status: response.statusCode, data: data, secret: key)
        }
        // The response body is the raw audio.
        guard !data.isEmpty else { throw SpeechSynthesisError.emptyAudio }
        return SynthesizedAudio(data: data, format: .mp3)
    }

    // MARK: - Private

    private func apiKey() throws -> SecretValue {
        let stored: SecretValue?
        do {
            stored = try secrets.secret(forAccount: Self.secretAccount)
        } catch {
            throw SpeechSynthesisError.notConfigured("the xAI key could not be read from the Keychain.")
        }
        guard let stored, !stored.isEmpty else {
            throw SpeechSynthesisError.notConfigured("add your xAI API key in Settings → Voices.")
        }
        return stored
    }

    private func request(path: String, key: SecretValue, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key.reveal())", forHTTPHeaderField: "Authorization")
        return request
    }
}
