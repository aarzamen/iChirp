import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 020 Step 4: Settings → Voices.
@MainActor
final class VoiceSettingsViewModelTests: XCTestCase {
    private let stock = [SynthesisVoice(id: "eve", name: "Eve"), SynthesisVoice(id: "rex", name: "Rex")]
    private let ryan = SynthesisVoice(id: "qwen3-tts-1.7b:Ryan", name: "Ryan", detail: "Dynamic male")
    private let heart = SynthesisVoice(id: "kokoro-82m:af_heart", name: "Heart")

    private func make(
        _ settings: VoiceSettings = VoiceSettings(), secrets: FakeSecretStore = FakeSecretStore(),
        engines: FakeVoiceEngines = FakeVoiceEngines()
    ) -> (VoiceSettingsViewModel, MemoryVoiceSettingsStore, FakeVoiceEngines, FakeSpeechPlayer) {
        let store = MemoryVoiceSettingsStore(settings)
        let output = FakeSpeechPlayer()
        let player = VoicePlayer(
            player: output, selection: { try store.load().selection(engines: engines) },
            routingPolicy: { PrivacyRoutingPolicy() }, currentPrivacyClass: { _ in nil }, retryDelays: [])
        let model = VoiceSettingsViewModel(
            store: store, secrets: secrets, engines: engines, player: player, stockXAIVoices: stock)
        return (model, store, engines, output)
    }

    func testNothingChosenSaysSo() {
        let (model, _, _, _) = make()
        XCTAssertEqual(model.summary, "Not chosen")
        XCTAssertEqual(model.setupProblem, "Choose Mac companion or Grok voices in Settings → Voices.")
    }

    func testChoicesAreSavedAtOnce() {
        let (model, store, _, _) = make()
        model.choose(.xai)
        model.chooseStockXAIVoice("rex")
        XCTAssertEqual(store.load().provider, .xai)
        XCTAssertEqual(store.load().xaiStockVoiceID, "rex")
        model.settings.companionStyle = "calm and slow"
        XCTAssertEqual(store.load().companionStyle, "calm and slow")
    }

    func testCompanionVoicesLoadAndTheFirstIsPickedWhenNoneIs() async {
        let engines = FakeVoiceEngines()
        engines.companion.setVoices([ryan, heart])
        let (model, store, _, _) = make(VoiceSettings(provider: .companion), engines: engines)
        await model.refresh()
        XCTAssertEqual(model.companionState, .ready)
        XCTAssertEqual(model.companionVoices, [ryan, heart])
        XCTAssertEqual(store.load().companionVoiceID, "qwen3-tts-1.7b:Ryan")
        XCTAssertEqual(model.summary, "Mac companion · Ryan")
        XCTAssertNil(model.setupProblem)

        model.chooseCompanionVoice(heart.id)
        XCTAssertEqual(model.summary, "Mac companion · Heart")
        XCTAssertTrue(engines.companion.requests.isEmpty, "Settings sends no text")
    }

    func testCompanionNotSetUpOrUnreachableIsShownAsIs() async {
        let engines = FakeVoiceEngines()
        engines.companion.setAvailability(.unavailable("Set up the Mac companion in Settings → Mac companion."))
        let (model, _, _, _) = make(VoiceSettings(provider: .companion, companionVoiceID: "x:Ryan"), engines: engines)
        await model.refresh()
        XCTAssertEqual(model.companionState, .unavailable("Set up the Mac companion in Settings → Mac companion."))
        XCTAssertEqual(model.setupProblem, "Set up the Mac companion in Settings → Mac companion.")
        XCTAssertEqual(model.summary, "Mac companion · Ryan", "the saved choice still shows")

        await model.recheckCompanion()
        XCTAssertEqual(engines.refreshes, 1)
    }

    func testKeyIsStoredOnlyInTheSecretStoreAndCleanedOfPasteArtifacts() {
        let secrets = FakeSecretStore()
        let (model, store, _, _) = make(VoiceSettings(provider: .xai), secrets: secrets)
        XCTAssertEqual(model.keyState, .missing)
        XCTAssertEqual(model.setupProblem, "Add your xAI API key in Settings → Voices.")

        model.keyDraft = "  XAI_API_KEY=\"xai-TESTKEY-0123456789\"  "
        model.saveKey()
        XCTAssertEqual(try secrets.secret(forAccount: VoiceSecrets.xaiAccount)?.reveal(), "xai-TESTKEY-0123456789")
        XCTAssertEqual(model.keyDraft, "", "the field is cleared")
        XCTAssertEqual(model.keyState, .saved)
        XCTAssertNil(model.setupProblem)
        let encoded = String(decoding: try! JSONEncoder().encode(store.load()), as: UTF8.self)
        XCTAssertFalse(encoded.contains("TESTKEY"), "no key in settings")

        model.removeKey()
        XCTAssertNil(try secrets.secret(forAccount: VoiceSecrets.xaiAccount))
        XCTAssertEqual(model.keyState, .missing)
    }

    func testKeychainFailureIsReported() {
        let secrets = FakeSecretStore()
        secrets.setFailWrites(true)
        let (model, _, _, _) = make(secrets: secrets)
        model.keyDraft = "xai-TESTKEY-0123456789"
        model.saveKey()
        XCTAssertEqual(model.lastError, "The key could not be saved in the Keychain.")
        XCTAssertEqual(model.keyState, .missing)
    }

    func testCheckKey() async throws {
        let secrets = FakeSecretStore()
        try secrets.setSecret(SecretValue("xai-TESTKEY-0123456789"), forAccount: VoiceSecrets.xaiAccount)
        let engines = FakeVoiceEngines()
        let (model, _, _, _) = make(VoiceSettings(provider: .xai), secrets: secrets, engines: engines)
        XCTAssertEqual(model.keyState, .saved)
        await model.checkKey()
        XCTAssertEqual(model.keyState, .valid)

        engines.keyError = .unauthorized
        await model.checkKey()
        XCTAssertEqual(model.keyState, .invalid(SpeechSynthesisError.unauthorized.errorDescription!))
        XCTAssertEqual(engines.validations, 2)
        XCTAssertTrue(engines.xai.requests.isEmpty, "Check key speaks nothing")
    }

    func testATypedVoiceIDWinsAndPickingAStockVoiceClearsIt() {
        let (model, store, _, _) = make(VoiceSettings(provider: .xai))
        model.settings.xaiCustomVoiceID = "  owner-typed-voice-id "
        XCTAssertEqual(store.load().effectiveXAIVoiceID, "owner-typed-voice-id")
        XCTAssertEqual(model.summary, "Grok voices · Voice ID")
        model.chooseStockXAIVoice("rex")
        XCTAssertEqual(store.load().effectiveXAIVoiceID, "rex")
        XCTAssertEqual(model.summary, "Grok voices · Rex")
    }

    func testTestVoiceSpeaksTheFixedSyntheticSentenceWithTheChosenVoice() async throws {
        let secrets = FakeSecretStore()
        try secrets.setSecret(SecretValue("xai-TESTKEY-0123456789"), forAccount: VoiceSecrets.xaiAccount)
        let engines = FakeVoiceEngines()
        let (model, _, _, output) = make(
            VoiceSettings(provider: .xai, xaiCustomVoiceID: "owner-typed-voice-id"), secrets: secrets,
            engines: engines)
        await model.testVoice()
        await eventually { output.enqueued == [0] }
        XCTAssertEqual(engines.xai.texts, [VoiceSettingsViewModel.testSentence])
        XCTAssertEqual(engines.xai.requests.first?.voiceID, "owner-typed-voice-id")
        XCTAssertEqual(engines.xai.requests.first?.privacyClass, .general)
    }

    func testSelectionNeedsAChoiceAndACompanionThatIsSetUp() throws {
        let engines = FakeVoiceEngines()
        XCTAssertThrowsError(try VoiceSettings().selection(engines: engines))
        XCTAssertThrowsError(try VoiceSettings(provider: .companion).selection(engines: engines), "no voice")
        engines.companionSetUp = false
        XCTAssertThrowsError(
            try VoiceSettings(provider: .companion, companionVoiceID: "x:Ryan").selection(engines: engines))
        engines.companionSetUp = true
        let selection = try VoiceSettings(
            provider: .companion, companionVoiceID: "qwen3-tts-1.7b:Ryan", companionStyle: " calm "
        ).selection(engines: engines)
        XCTAssertEqual(selection.voiceID, "qwen3-tts-1.7b:Ryan")
        XCTAssertEqual(selection.style, "calm")
        XCTAssertEqual(selection.engine.descriptor.id, "companion.speech")
    }

    func testSettingsDecodeForgivingly() throws {
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"provider":"martian"}"#.utf8))
        XCTAssertEqual(decoded, VoiceSettings())
        let suite = "VoiceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsVoiceSettingsStore(defaults: defaults)
        XCTAssertEqual(store.load(), VoiceSettings())
        store.save(VoiceSettings(provider: .companion, speakAskAnswers: true))
        XCTAssertEqual(store.load().provider, .companion)
        XCTAssertTrue(store.load().speakAskAnswers)
    }

    func testCleanedKey() {
        XCTAssertEqual(VoiceSettingsViewModel.cleanedKey(" Bearer xai-abc "), "xai-abc")
        XCTAssertEqual(VoiceSettingsViewModel.cleanedKey("'xai-abc'"), "xai-abc")
        XCTAssertEqual(VoiceSettingsViewModel.cleanedKey("xai-abc"), "xai-abc")
    }
}
