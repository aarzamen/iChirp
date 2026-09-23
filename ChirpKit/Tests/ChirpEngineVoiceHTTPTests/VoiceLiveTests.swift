import AVFoundation
import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineVoiceHTTP

/// Opt-in live checks (plan 020): one synthetic sentence through a running Mac companion and, when the owner supplies
/// a key in the environment, through xAI. Skipped unless `CHIRP_LIVE_VOICE_TESTS=1`. Never reads the Keychain.
///
/// ```bash
/// # Companion (scripts/companion.sh running on this Mac; the token from its start-up line or its token file):
/// CHIRP_LIVE_VOICE_TESTS=1 CHIRP_COMPANION_TOKEN=<token> \
///   swift test --package-path ChirpKit --filter VoiceLiveTests
/// # xAI too (the key only in this shell's environment, never in a file in the repo):
/// read -rs XAI_API_KEY && export XAI_API_KEY   # silent prompt: not echoed, not in shell history
/// CHIRP_LIVE_VOICE_TESTS=1 swift test --package-path ChirpKit --filter VoiceLiveTests
/// ```
///
/// Optional: `CHIRP_COMPANION_HOST` (default `localhost`), `CHIRP_COMPANION_PORT` (8765), `CHIRP_COMPANION_VOICE`
/// (default: the companion's first voice), `XAI_VOICE_ID` (default `eve`), `CHIRP_LIVE_VOICE_OUT` (a folder to save
/// the audio in, to listen to).
final class VoiceLiveTests: XCTestCase {
    static let sentence = "This is Parakeet, reading one synthetic sentence aloud."

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["CHIRP_LIVE_VOICE_TESTS"] == "1", "Set CHIRP_LIVE_VOICE_TESTS=1 to run.")
    }

    func testCompanionSpeaksOneSentence() async throws {
        let token = try companionToken()
        let host = environment["CHIRP_COMPANION_HOST"] ?? "localhost"
        let port = environment["CHIRP_COMPANION_PORT"].flatMap(Int.init) ?? CompanionEndpoint.defaultPort
        let voice = CompanionVoice(
            configuration: FixedCompanionConfiguration(
                endpoint: CompanionEndpoint(host: host, port: port), token: SecretValue(token)))
        let availability = await voice.availability()
        guard availability == .available else {
            throw XCTSkip("The companion is not available: \(availability)")
        }
        let voices = try await voice.voices()
        let voiceID = try XCTUnwrap(environment["CHIRP_COMPANION_VOICE"] ?? voices.first?.id, "no voices")
        let started = Date()
        let audio = try await voice.synthesize(
            SynthesisRequest(text: Self.sentence, voiceID: voiceID, privacyClass: .general))
        let seconds = try duration(of: audio, name: "companion")
        print(
            "VOICE LIVE companion voice=\(voiceID) format=\(audio.format.rawValue) bytes=\(audio.data.count) "
                + "audio=\(String(format: "%.2f", seconds))s took=\(String(format: "%.2f", Date().timeIntervalSince(started)))s"
        )
        XCTAssertGreaterThan(seconds, 0.5)
    }

    func testXAISpeaksOneSentence() async throws {
        guard let key = environment["XAI_API_KEY"], !key.isEmpty else {
            throw XCTSkip("No XAI_API_KEY in the environment.")
        }
        let secrets = EnvironmentSecret(key: key)
        let voice = XAIVoice(secrets: secrets)
        try await voice.validateKey()
        let voiceID = environment["XAI_VOICE_ID"] ?? "eve"
        let started = Date()
        let audio = try await voice.synthesize(
            SynthesisRequest(text: Self.sentence, voiceID: voiceID, privacyClass: .general))
        let seconds = try duration(of: audio, name: "xai")
        print(
            "VOICE LIVE xai format=\(audio.format.rawValue) bytes=\(audio.data.count) "
                + "audio=\(String(format: "%.2f", seconds))s took=\(String(format: "%.2f", Date().timeIntervalSince(started)))s"
        )
        XCTAssertGreaterThan(seconds, 0.5)
    }

    // MARK: - Helpers

    private func companionToken() throws -> String {
        if let token = environment["CHIRP_COMPANION_TOKEN"], !token.isEmpty { return token }
        // The companion's own pairing-token file on this Mac (mac-companion-v1), not the Keychain.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ParakeetCompanion/token")
        guard
            let token = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else { throw XCTSkip("No CHIRP_COMPANION_TOKEN and no companion token file.") }
        return token
    }

    /// Decodes the audio (proves it is real audio) and saves it when `CHIRP_LIVE_VOICE_OUT` is set.
    private func duration(of audio: SynthesizedAudio, name: String) throws -> Double {
        let folder =
            environment["CHIRP_LIVE_VOICE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("voice-live-\(name).\(audio.format == .mp3 ? "mp3" : "wav")")
        try audio.data.write(to: url)
        defer { if environment["CHIRP_LIVE_VOICE_OUT"] == nil { try? FileManager.default.removeItem(at: url) } }
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// The xAI key from the environment, as a `SecretStoring` (read-only).
private struct EnvironmentSecret: SecretStoring {
    let key: String
    func secret(forAccount account: String) throws -> SecretValue? { SecretValue(key) }
    func setSecret(_ secret: SecretValue, forAccount account: String) throws {}
    func deleteSecret(forAccount account: String) throws {}
}
