import ChirpCore
import ChirpEngineVoiceHTTP
import ChirpFeatures
import Foundation
import Synchronization
import XCTest

@testable import iChirp

/// Plan 020 Step 5: the Listen button states, the voice confirmation's wiring (only the dialog's Read aloud button
/// confirms, and every other path sends nothing), and the Keychain account shared by Settings and the engine.
@MainActor
final class VoiceListenTests: XCTestCase {
    static let marker = "SYNTHETIC-CLINICAL-VOICE-5521"

    // MARK: - Listen button states

    func testListenButtonStates() {
        let id = UUID()
        let mine = VoiceSource.deliverable(id: id)
        let other = VoiceSource.transcript(id: id)
        XCTAssertEqual(ListenButtonState.of(mine, current: nil, state: .idle), .listen)
        XCTAssertEqual(ListenButtonState.of(mine, current: other, state: .speaking(chunk: 1, of: 2)), .listen)
        XCTAssertEqual(ListenButtonState.of(mine, current: mine, state: .preparing), .preparing)
        let request = VoiceConfirmationRequest(
            id: UUID(), engineID: "xai.tts", providerName: "Grok voices", locality: .cloud, host: "api.x.ai")
        XCTAssertEqual(ListenButtonState.of(mine, current: mine, state: .needsConfirmation(request)), .preparing)
        XCTAssertEqual(ListenButtonState.of(mine, current: mine, state: .speaking(chunk: 2, of: 3)), .stop)
        XCTAssertEqual(ListenButtonState.of(mine, current: mine, state: .paused(chunk: 2, of: 3)), .stop)
        XCTAssertEqual(ListenButtonState.of(mine, current: mine, state: .failed("x")), .listen)
        XCTAssertEqual(ListenButtonState.listen.title, "Listen")
        XCTAssertEqual(ListenButtonState.stop.title, "Stop")
    }

    func testStatusWords() {
        XCTAssertNil(VoiceStatus.text(.idle))
        XCTAssertEqual(VoiceStatus.text(.preparing), "Preparing…")
        XCTAssertEqual(VoiceStatus.text(.speaking(chunk: 2, of: 5)), "Reading 2 of 5")
        XCTAssertEqual(VoiceStatus.text(.speaking(chunk: 1, of: 1)), "Reading")
        XCTAssertEqual(VoiceStatus.text(.paused(chunk: 2, of: 5)), "Paused at 2 of 5")
        XCTAssertEqual(
            VoiceStatus.text(.failed("The Mac companion is not reachable.")), "The Mac companion is not reachable.")
    }

    func testSettingsAndTheEngineUseTheSameKeychainAccount() {
        XCTAssertEqual(VoiceSecrets.xaiAccount, XAIVoice.secretAccount)
        XCTAssertEqual(VoiceProviderKind.xai.engineID, XAIVoice.engineID)
        XCTAssertEqual(VoiceProviderKind.companion.engineID, CompanionVoice.engineID)
    }

    // MARK: - The voice confirmation

    func testOnlyTheReadAloudButtonConfirms() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try ClinicalConfirmationTests.codeMatches(
            pattern: #"confirmPendingSpeech\("#, under: repo.appendingPathComponent("App/Sources"))
        XCTAssertGreaterThan(app.scanned, 20, "the scan found the app sources")
        XCTAssertEqual(app.matches.map(\.file), ["VoiceViews.swift"], "only the dialog's actions confirm")
        XCTAssertTrue(
            app.matches.first?.before.contains("func userTappedReadAloud(_ request: VoiceConfirmationRequest) {") == true,
            "confirmPendingSpeech is called inside userTappedReadAloud")

        let tap = try ClinicalConfirmationTests.codeMatches(
            pattern: #"\.userTappedReadAloud\("#, under: repo.appendingPathComponent("App/Sources"))
        XCTAssertEqual(tap.matches.map(\.file), ["VoiceViews.swift"], "userTappedReadAloud has one caller")
        XCTAssertTrue(
            tap.matches.first?.before.contains(#"Button("Read aloud") {"#) == true,
            "that caller is the Read aloud button's action")

        let kit = try ClinicalConfirmationTests.codeMatches(
            pattern: #"\.confirmPendingSpeech\("#, under: repo.appendingPathComponent("ChirpKit/Sources"))
        XCTAssertEqual(kit.matches.map(\.file), [], "ChirpKit never confirms for the user")
    }

    func testNoPathButReadAloudSendsClinicalTextToACloudVoice() async throws {
        let engine = RecordingVoice()
        let output = SilentSpeechOutput()
        let player = VoicePlayer(
            player: output, selection: { VoiceSelection(engine: engine, voiceID: "eve") },
            routingPolicy: { PrivacyRoutingPolicy() }, currentPrivacyClass: { _ in nil }, retryDelays: [])
        let source = VoiceSource.deliverable(id: UUID())
        let text = "SOAP draft \(Self.marker)."

        // Listen: routed, waiting for the dialog, nothing sent.
        player.toggleListening(to: source, privacyClass: .clinical) { text }
        try await waitFor { if case .needsConfirmation = player.state { true } else { false } }
        guard case .needsConfirmation(let request) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertEqual(request.title, "Read this clinical text aloud with Grok voices?")
        XCTAssertEqual(engine.received, [])

        // Cancel, then a late Read aloud on the answered dialog.
        VoiceConfirmationActions(player: player).userTappedCancel()
        VoiceConfirmationActions(player: player).userTappedReadAloud(request)
        XCTAssertEqual(player.state, .idle)
        // Listen again, then Stop on the Listen button while the dialog is up.
        player.toggleListening(to: source, privacyClass: .clinical) { text }
        try await waitFor { if case .needsConfirmation = player.state { true } else { false } }
        player.toggleListening(to: source, privacyClass: .clinical) { text }
        XCTAssertEqual(player.state, .idle)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.received, [], "nothing was sent without Read aloud")

        // Only Read aloud sends, for this reading (and only for the question it showed).
        player.toggleListening(to: source, privacyClass: .clinical) { text }
        try await waitFor { if case .needsConfirmation = player.state { true } else { false } }
        VoiceConfirmationActions(player: player).userTappedReadAloud(request)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.received, [], "an answer to an older question confirms nothing")
        guard case .needsConfirmation(let current) = player.state else { return XCTFail("\(player.state)") }
        VoiceConfirmationActions(player: player).userTappedReadAloud(current)
        try await waitFor { !engine.received.isEmpty }
        XCTAssertTrue(engine.received.joined().contains(Self.marker))
        player.stop()

        // Never remembered: the next reading asks again.
        let sent = engine.received.count
        player.toggleListening(to: source, privacyClass: .clinical) { text }
        try await waitFor { if case .needsConfirmation = player.state { true } else { false } }
        XCTAssertEqual(engine.received.count, sent)
        player.stop()
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out")
    }
}

/// A cloud voice that records what it was sent and answers with a few bytes.
private final class RecordingVoice: SpeechSynthesizing, Sendable {
    private let texts = Mutex<[String]>([])
    var received: [String] { texts.withLock { $0 } }

    let descriptor = EngineDescriptor(
        id: "xai.tts", kind: .speechSynthesis, provider: "xAI", displayName: "Grok voices", locality: .cloud,
        license: "test")
    let endpointHost: String? = "api.x.ai"
    let maxCharactersPerRequest = 15_000

    func availability() async -> SpeechSynthesisAvailability { .available }
    func voices() async throws -> [SynthesisVoice] { [] }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        texts.withLock { $0.append(request.text) }
        return SynthesizedAudio(data: Data([1, 2, 3]), format: .mp3)
    }
}

/// An output that plays nothing.
@MainActor
private final class SilentSpeechOutput: SpeechAudioPlaying {
    var onEvent: ((SpeechPlaybackEvent) -> Void)?
    func beginUtterance() throws {}
    func enqueue(_ audio: SynthesizedAudio, index: Int, pauseAfterMs: Int, isFinal: Bool) throws {}
    func pause() {}
    func resume() throws {}
    func stop() {}
}
