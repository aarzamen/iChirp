import ChirpCore
import ChirpFeatures
import ChirpStore
import ChirpText
import Foundation
import Synchronization
import XCTest

@testable import iChirp

/// Plan 024 Task 10 (full review 2026-10-01, R6b / R5 / R7 on the Create, Transforms, Ask, Structure, Decisions and
/// Settings screens): privacy wording that matches the router, no typed text or user row lost, Edit by voice on the
/// draft on screen, and the helpers behind the screens. Synthetic content only.
@MainActor
final class ReviewFixesTask10AppTests: XCTestCase {
    // MARK: - R6b-8: one clinical heads-up, matching the router

    private static func choice(_ locality: EngineLocality, trusted: Bool, name: String = "Synthetic Model")
        -> LanguageModelChoice
    {
        LanguageModelChoice(
            source: .provider(UUID()), name: name, locality: locality, host: locality == .onDevice ? nil : "host",
            isTrustedForClinical: trusted)
    }

    func testTheClinicalHeadsUpSaysWhatTheRouterDoes() {
        let cloud = Self.choice(.cloud, trusted: false, name: "Claude")
        let untrustedMac = Self.choice(.localNetwork, trusted: false, name: "Mac Studio (Ollama)")
        let trustedMac = Self.choice(.localNetwork, trusted: true, name: "Mac Studio (Ollama)")

        // On this iPhone: nothing to say, clinical or not.
        for subject in [ModelRunSubject.item, .transcript, .document] {
            for clinical in [false, true] {
                XCTAssertNil(
                    ModelClinicalNote.text(for: .onDevice, subject: subject, isClinical: clinical, makesDocuments: true)
                )
            }
        }
        // Cloud and an untrusted home-network host ask for clinical text.
        for model in [cloud, untrustedMac] {
            XCTAssertEqual(
                ModelClinicalNote.text(for: model, subject: .transcript, isClinical: true, makesDocuments: true),
                "This transcript is clinical, so Parakeet asks before sending it to \(model.name).")
            XCTAssertEqual(
                ModelClinicalNote.text(for: model, subject: .transcript, isClinical: false, makesDocuments: true),
                "Clinical transcripts and SOAP notes ask before anything is sent to \(model.name).")
            XCTAssertEqual(
                ModelClinicalNote.text(for: model, subject: .transcript, isClinical: false, makesDocuments: false),
                "Clinical transcripts ask before anything is sent to \(model.name).", "Ask makes no SOAP note")
        }
        // A trusted home-network host takes clinical text without a question, and says so.
        XCTAssertEqual(
            ModelClinicalNote.text(for: trustedMac, subject: .document, isClinical: true, makesDocuments: false),
            "This document is clinical. You trust Mac Studio (Ollama) for clinical text, so it goes there without asking."
        )
        XCTAssertNil(
            ModelClinicalNote.text(for: trustedMac, subject: .document, isClinical: false, makesDocuments: false))
    }

    func testEveryModelChooserUsesTheSharedHeadsUp() throws {
        for file in [
            "Create/CreateSheet.swift", "Create/EditByVoiceSheet.swift", "Transforms/TransformSheet.swift",
            "Ask/AskView.swift",
        ] {
            let source = try Self.source("App/Sources/Screens/\(file)")
            XCTAssertTrue(source.contains("ModelRunNotes("), "\(file) shows the shared heads-up")
            XCTAssertFalse(source.contains("Parakeet will ask before"), "\(file) has no wording of its own")
        }
    }

    // MARK: - R6b-21, R7-10: one glyph per place

    func testALockOnlyWhereClinicalTextGoesWithoutAQuestion() {
        XCTAssertEqual(LocalityGlyph.symbol(locality: .onDevice, trustedForClinical: true), "lock.fill")
        XCTAssertEqual(LocalityGlyph.symbol(locality: .localNetwork, trustedForClinical: true), "lock.fill")
        XCTAssertEqual(
            LocalityGlyph.symbol(locality: .localNetwork, trustedForClinical: false), "network",
            "an untrusted home-network host is not a lock in the menu and a cloud in the chip")
        XCTAssertEqual(LocalityGlyph.symbol(locality: .cloud, trustedForClinical: false), "icloud")
        XCTAssertEqual(Self.choice(.localNetwork, trusted: false).localitySymbol, "network")
        XCTAssertFalse(LocalityGlyph.staysPrivate(locality: .cloud, trustedForClinical: true))
        XCTAssertEqual(
            LocalityGlyph.unbroken("Answering on this iPhone · Apple on-device model"),
            "Answering on this iPhone · Apple on\u{2011}device model", "the chip never breaks at the hyphen")
    }

    // MARK: - R6b-3: the Create voice line

    func testTheCreateVoiceLineMatchesTheVoiceRouter() {
        let trusted = CreateVoiceNote.text(provider: .companion, isClinical: true, companionTrusted: true)
        XCTAssertTrue(trusted.contains("without asking"), trusted)
        XCTAssertFalse(trusted.contains("asks"), "a trusted Mac is never said to ask")
        let untrusted = CreateVoiceNote.text(provider: .companion, isClinical: true, companionTrusted: false)
        XCTAssertTrue(untrusted.contains("Parakeet asks before it is sent"), untrusted)
        let grok = CreateVoiceNote.text(provider: .xai, isClinical: true, companionTrusted: true)
        XCTAssertTrue(grok.contains("asks before it is sent"), "Grok voices always ask for clinical text")
        XCTAssertTrue(
            CreateVoiceNote.text(provider: .companion, isClinical: false, companionTrusted: false)
                .hasSuffix("Saved with the item as an audio file."))
    }

    // MARK: - R6b-9: lowering a clinical mark

    func testLoweringSaysAClinicalDocumentStillCounts() {
        let message = PrivacyClassControl.loweringMessage
        XCTAssertTrue(message.contains("unless a clinical document made from it"), message)
        XCTAssertFalse(message.contains("no longer ask"), "no promise the routers do not keep")
        XCTAssertFalse(message.contains("transcript"), "the control is also on typed text and imported documents")
    }

    // MARK: - R6b-5: custom words and snippets

    func testTheRuleEditorKnowsWhenClosingWouldLoseTyping() {
        let snippet = TextSnippet(trigger: "normal exam", expansion: "Synthetic normal exam text.")
        XCTAssertFalse(TextRuleEditorSheet.hasChanges(.newSnippet, first: "", second: "  "))
        XCTAssertTrue(TextRuleEditorSheet.hasChanges(.newSnippet, first: "", second: "Synthetic expansion"))
        XCTAssertFalse(
            TextRuleEditorSheet.hasChanges(
                .snippet(snippet), first: "normal exam", second: "Synthetic normal exam text."))
        XCTAssertTrue(
            TextRuleEditorSheet.hasChanges(.snippet(snippet), first: "normal exam", second: "Synthetic edited text."))
        XCTAssertEqual(
            TextRulesScreen.Deletion.snippet(snippet).question, "Delete the snippet “normal exam”?")
    }

    func testASwipeOnARuleAsksBeforeDeleting() throws {
        let source = try Self.source("App/Sources/Screens/Settings/TextRulesScreen.swift")
        XCTAssertFalse(source.contains("Task { await model.deleteWords(ids) }"), "a swipe no longer deletes at once")
        XCTAssertTrue(source.contains("deleting = .word("))
        XCTAssertTrue(source.contains("deleting = .snippet("))
        XCTAssertTrue(source.contains(".discardInputConfirmation("), "the editor asks before dropping typed text")
    }

    // MARK: - R5-15, R5-9, R6b-11: Edit by voice

    func testSpeakingAddsToATypedInstruction() {
        XCTAssertEqual(
            InstructionField.appending("Add a follow-up.", to: "Make it shorter and"),
            "Make it shorter and add a follow-up.")
        XCTAssertEqual(
            InstructionField.appending("Add a follow-up.", to: "Make it shorter."), "Make it shorter. Add a follow-up.")
        XCTAssertEqual(
            InstructionField.appending("SOAP format.", to: "Rewrite the plan and"), "Rewrite the plan and SOAP format.",
            "an acronym keeps its capitals")
        var field = InstructionField()
        field.text = "  "
        field.appendHeard("Fix the grammar.")
        XCTAssertEqual(field.text, "Fix the grammar.")
        XCTAssertTrue(field.isSpoken, "every word was heard")
    }

    /// Fix round 1 (review Important 1): a second speech used to drop the typed part, because the whole field counted as
    /// "heard" after the first one.
    func testTypedThenSpokenTwiceKeepsEveryWordAndIsNotMarkedSpoken() {
        var field = InstructionField()
        field.text = "Make it shorter"
        field.appendHeard("add a follow-up")
        XCTAssertEqual(field.text, "Make it shorter add a follow-up")
        field.appendHeard("and fix the grammar")
        XCTAssertEqual(field.text, "Make it shorter add a follow-up and fix the grammar", "the typed words stay")
        XCTAssertTrue(field.isUnchangedSinceSpeech, "the Heard line shows")
        XCTAssertFalse(field.isSpoken, "typed and spoken words: not recorded as a spoken edit")
    }

    func testSpokenThenEditedThenSpokenKeepsTheEditAndIsMixed() {
        var field = InstructionField()
        field.appendHeard("Make it shorter")
        XCTAssertTrue(field.isSpoken)
        field.text = "Make it much shorter"  // the person fixes a word
        XCTAssertFalse(field.isUnchangedSinceSpeech)
        field.appendHeard("add a follow-up")
        XCTAssertEqual(field.text, "Make it much shorter add a follow-up", "the edit is kept")
        XCTAssertFalse(field.isSpoken, "an edited word makes it mixed")
    }

    func testSpokenTwiceIsStillSpokenAndASuggestionIsNot() {
        var field = InstructionField()
        field.appendHeard("Make it shorter.")
        field.appendHeard("Add a follow-up.")
        XCTAssertEqual(field.text, "Make it shorter. Add a follow-up.", "a second speech adds, never replaces")
        XCTAssertTrue(field.isSpoken)
        field.choose("Fix the grammar")
        XCTAssertFalse(field.isSpoken, "a suggestion chip's words were picked, not heard")
        field.text = ""
        field.appendHeard("Make it shorter")
        XCTAssertTrue(field.isSpoken, "a cleared field starts over")
    }

    func testEditByVoiceRewritesTheDraftOnScreenAndShowsTheResult() async throws {
        let harness = try await EditHarness()
        let document = DeliverableDocumentViewModel(id: harness.documentID, store: harness.store)
        await document.load()
        document.draft = "Synthetic hand edited plan."
        XCTAssertEqual(EditByVoiceSheet.baseText(of: document), "Synthetic hand edited plan.")

        let host = EditRunHost(service: harness.service, models: harness.models)
        let current = try XCTUnwrap(document.deliverable)
        await host.start(
            document: current, instruction: "Make it shorter", spoken: false, choice: .onDevice,
            baseText: EditByVoiceSheet.baseText(of: document))
        guard case .completed(let edited) = host.run?.phase else {
            return XCTFail("\(String(describing: host.run?.phase))")
        }
        XCTAssertTrue(
            harness.model.everythingReceived.contains("Synthetic hand edited plan."),
            "the model rewrote the text on screen, not the stored one")
        XCTAssertFalse(harness.model.everythingReceived.contains("Synthetic generated plan."))

        document.applyEdit(edited)
        XCTAssertEqual(document.draft, edited.text, "the rewrite is what the screen shows")
        XCTAssertFalse(document.hasUnsavedChanges, "Save cannot write the stale draft over it")
        let versions = try await harness.store.fetchDeliverableVersions(deliverableID: harness.documentID)
        XCTAssertEqual(
            versions.map(\.text), ["Synthetic generated plan.", "Synthetic hand edited plan.", edited.text],
            "the original, the draft and the rewrite are all kept")
    }

    func testANoDraftEditRewritesTheStoredText() async throws {
        let harness = try await EditHarness()
        let document = DeliverableDocumentViewModel(id: harness.documentID, store: harness.store)
        await document.load()
        XCTAssertNil(EditByVoiceSheet.baseText(of: document), "no unsaved edits: the stored text")
    }

    // MARK: - R7-16, Task 8's quotations: Ask

    func testACitedMomentShowsOnceAsItsChip() {
        XCTAssertEqual(
            AskAnswerText.withoutCitations(
                "They moved the follow-up to Thursday [00:02]. The owner is Sam [01:10].", labels: ["00:02", "01:10"]),
            "They moved the follow-up to Thursday. The owner is Sam.")
        XCTAssertEqual(
            AskAnswerText.withoutCitations("Agreed ([00:02]) on the plan.", labels: ["00:02"]), "Agreed on the plan.")
        XCTAssertEqual(
            AskAnswerText.withoutCitations("A made-up time [09:59] stays.", labels: []),
            "A made-up time [09:59] stays.", "a time that is not a chip stays in the text")
    }

    func testATypedItemIsAnsweredWithQuotationsNotTimestamps() {
        var typed = Transcription(fileName: "typed.txt", status: .completed, privacyClass: .personal)
        typed.sourceType = .text
        typed.rawTranscript = "Synthetic typed note about the plan."
        XCTAssertFalse(AskView.citesTimestamps(typed), "no word timings: no \"No timestamp found\" line")
        let source = try? Self.source("App/Sources/Screens/Ask/AskView.swift")
        XCTAssertTrue(source?.contains("if answer.citations.isEmpty, citesTimestamps {") == true)
    }

    // MARK: - K4, R7-6: the document screen

    func testTheDocumentSaysTheClassTheRulesUse() {
        let document = Deliverable(
            transcriptionID: UUID(), promptID: nil, promptVersionID: nil, title: "Summary", engineID: "test",
            provider: "Synthetic", model: nil, locality: .onDevice, text: "Synthetic summary.", privacyClass: .personal)
        let rows = DeliverableDetailScreen.metadata(
            document, versionNumber: 1, sourceTitle: "Synthetic visit", effectiveClass: .clinical)
        XCTAssertEqual(
            rows.first { $0.0 == "Privacy" }?.1, "Clinical (from its transcript; marked Personal)",
            "a summary of a clinical transcript says clinical, as its Library row does")
        let plain = DeliverableDetailScreen.metadata(document, versionNumber: 1, sourceTitle: "Synthetic visit")
        XCTAssertEqual(plain.first { $0.0 == "Privacy" }?.1, "Personal")
    }

    func testMakeItAgainOffersTheModelTheDocumentWasWrittenWith() {
        let document = Deliverable(
            transcriptionID: UUID(), promptID: nil, promptVersionID: nil, title: "SOAP note", engineID: "test",
            provider: "Mac Studio (Ollama)", model: nil, locality: .localNetwork, text: "Synthetic.",
            privacyClass: .clinical, isCutOff: true)
        let mac = Self.choice(.localNetwork, trusted: true, name: "Mac Studio (Ollama)")
        XCTAssertEqual(TransformSheet.originalChoice(of: document, in: [.onDevice, mac]), mac)
        XCTAssertNil(TransformSheet.originalChoice(of: document, in: [.onDevice]), "gone: the default is offered")
    }

    // MARK: - R7-1, R7-18, R6b-12: Settings rows

    func testASettingsRowKeepsItsControlBesideTheTitleUnlessTheControlIsWide() {
        XCTAssertTrue(SettingsRowLayout.sideBySide(width: 330, trailingWidth: 51), "a switch stays beside the title")
        XCTAssertTrue(SettingsRowLayout.sideBySide(width: 330, trailingWidth: 0), "no control: one column")
        XCTAssertTrue(SettingsRowLayout.sideBySide(width: 330, trailingWidth: 170))
        XCTAssertFalse(
            SettingsRowLayout.sideBySide(width: 330, trailingWidth: 200),
            "a wide control drops under the title instead of squeezing it")
    }

    func testDeletingAModelNamesTheModel() {
        XCTAssertEqual(ModelAssetRow.deleteQuestion(title: "Qwen3.5 2B"), "Delete Qwen3.5 2B?")
        let source = try? Self.source("App/Sources/Screens/Settings/SpeechEnginesScreen.swift")
        XCTAssertTrue(source?.contains("ModelAssetRow.deleteQuestion(") == true, "one wording for every model")
    }

    // MARK: - R6b-14: the confidence gate

    func testProvisionalNeverGoesAboveAct() {
        var settings = StructureSettings()
        settings.actThreshold = 0.85
        settings.provisionalThreshold = 0.60
        let raised = StructureGateScreen.settingProvisional(0.95, in: settings)
        XCTAssertEqual(raised.provisionalThreshold, 0.85, accuracy: 0.0001, "clamped to Act")
        let lowered = StructureGateScreen.settingAct(0.70, in: raised)
        XCTAssertEqual(lowered.actThreshold, 0.70, accuracy: 0.0001)
        XCTAssertEqual(lowered.provisionalThreshold, 0.70, accuracy: 0.0001, "follows Act down")
        XCTAssertEqual(StructureGateScreen.summary(lowered), "70 / 70", "the row shows the gate that applies")
    }

    // MARK: - R6b-6: Jev bars at large text

    func testJevOptionNamesGoAboveTheirBarFromXLarge() {
        XCTAssertFalse(OptionBar.stacksName(at: .large))
        XCTAssertTrue(OptionBar.stacksName(at: .xLarge))
        XCTAssertTrue(OptionBar.stacksName(at: .accessibility2))
    }

    // MARK: - R6b-7: Run a template → Choose a transcript

    func testTheTranscriptPickerSearchesTitlesAndKeepsOnlyFinishedItems() {
        var visit = Transcription(fileName: "visit.m4a", status: .completed)
        visit.titleOverride = "Synthetic clinic visit"
        var team = Transcription(fileName: "team.m4a", status: .completed)
        team.titleOverride = "Team sync"
        var running = Transcription(fileName: "running.m4a", status: .processing)
        running.titleOverride = "Synthetic clinic follow-up"
        let items = [visit, team, running].map(TranscriptionSummary.init)
        XCTAssertEqual(
            TemplateLaunchSheet.transcripts(items, matching: "").map(\.displayTitle),
            ["Synthetic clinic visit", "Team sync"])
        XCTAssertEqual(
            TemplateLaunchSheet.transcripts(items, matching: "CLINIC vis").map(\.displayTitle),
            ["Synthetic clinic visit"])
        let source = try? Self.source("App/Sources/Screens/Transforms/TransformSheet.swift")
        XCTAssertTrue(source?.contains("LazyVStack(spacing: 8) {") == true, "rows are built as they scroll in")
    }

    // MARK: - R6b-4: the SOAP hand-off's bar

    func testTheSOAPHandOffHasNoTemplatesBackItem() throws {
        let source = try Self.source("App/Sources/Screens/Structure/ExtractFieldsSheet.swift")
        XCTAssertTrue(source.contains("onChooseAnother: nil, onDone: { dismiss() })"))
        XCTAssertTrue(source.contains("if host?.run == nil {"), "the outer Close goes once the run view shows")
    }

    // MARK: - R6b-20: the provider form

    func testTheProviderFormKnowsWhenClosingWouldLoseTyping() {
        let original = LanguageModelProviderDraft(kind: .anthropic)
        var typed = original
        XCTAssertFalse(ProviderEditorSheet.hasChanges(typed, from: original))
        typed.apiKeyText = "synthetic-key"
        XCTAssertTrue(ProviderEditorSheet.hasChanges(typed, from: original))
    }

    // MARK: - R3-15: no engine SDK in a screen

    func testNoSettingsScreenImportsAnEngineTarget() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["Settings", "Structure", "Create", "Transforms", "Ask", "Decisions"] {
            let root = repo.appendingPathComponent("App/Sources/Screens/\(folder)")
            // Recursive (fix round 1): a screen in a subfolder counts too.
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                XCTAssertNil(
                    text.range(of: #"(?m)^\s*import\s+ChirpEngine"#, options: .regularExpression),
                    "\(folder)/\(file.lastPathComponent) imports an engine target")
            }
        }
    }

    /// Fix round 1: Ask's class-specific heads-up waits for the effective class instead of first saying the stored one.
    func testAskWaitsForTheEffectiveClassBeforeTheClinicalLine() throws {
        let source = try Self.source("App/Sources/Screens/Ask/AskView.swift")
        XCTAssertTrue(source.contains("if let effectiveClass {"))
        XCTAssertFalse(source.contains("effectiveClass ?? transcription.privacyClass"))
    }

    // MARK: - Helpers

    static func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }
}

/// A synthetic personal transcript and one generated document in a real GRDB database, the real `DeliverableService`,
/// and an on-device model that records what it is sent. Nothing touches the network.
@MainActor
private struct EditHarness {
    let service: DeliverableService
    let store: GRDBDeliverableStore
    let models: LanguageModelsViewModel
    let model: Task10RecordingModel
    let documentID: UUID

    init() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReviewFixesTask10AppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try DatabaseManager(url: folder.appendingPathComponent("test.sqlite"))
        let transcripts = GRDBTranscriptionStore(database: database)
        store = GRDBDeliverableStore(database: database)
        var row = Transcription(
            fileName: "synthetic.m4a", durationMs: 60_000, status: .completed, privacyClass: .personal)
        row.rawTranscript = "Speaker one: the synthetic follow-up moves to Thursday."
        try await transcripts.insert(row)
        let document = Deliverable(
            transcriptionID: row.id, promptID: nil, promptVersionID: nil, title: "Summary", engineID: "test.onDevice",
            provider: "Apple on-device model", model: nil, locality: .onDevice, text: "Synthetic generated plan.",
            privacyClass: .personal)
        try await store.insertDeliverable(document)
        documentID = document.id

        let suite = "ReviewFixesTask10AppTests.\(UUID().uuidString)"
        let providers = UserDefaultsLanguageModelProviderStore(
            defaults: UserDefaults(suiteName: suite) ?? .standard, secrets: Task10Secrets())
        let model = Task10RecordingModel()
        self.model = model
        models = LanguageModelsViewModel(store: providers, factory: Task10Factory(model: model))
        service = DeliverableService(
            transcripts: transcripts, deliverables: store, routingPolicy: { providers.routingPolicy() })
    }
}

private final class Task10RecordingModel: LanguageModel {
    let descriptor = EngineDescriptor(
        id: "test.onDevice", kind: .language, provider: "Test", displayName: "Apple on-device model",
        locality: .onDevice, license: "Test")
    let endpointHost: String? = nil
    private let received = Mutex<[GenerationRequest]>([])

    var everythingReceived: String { received.withLock { $0.map { "\($0.system ?? "")\n\($0.prompt)" }.joined() } }

    func contextWindowTokens() async -> Int? { 8_192 }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        received.withLock { $0.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Synthetic shorter plan."))
            continuation.yield(.usage(GenerationUsage(model: "synthetic-model")))
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}

private struct Task10Factory: LanguageModelFactory {
    let model: Task10RecordingModel

    func makeOnDeviceModel() -> any LanguageModel { model }

    func makeModel(for provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) throws -> any LanguageModel {
        model
    }

    func testConnection(to provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws {}

    func listModels(of provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws -> [String] {
        []
    }
}

private final class Task10Secrets: SecretStoring {
    private let values = Mutex<[String: SecretValue]>([:])

    func secret(forAccount account: String) throws -> SecretValue? { values.withLock { $0[account] } }
    func setSecret(_ secret: SecretValue, forAccount account: String) throws {
        values.withLock { $0[account] = secret }
    }
    func deleteSecret(forAccount account: String) throws { values.withLock { $0[account] = nil } }
}
