import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Polish lane u2 (UX audit, Create and Transforms): the words for the effective privacy class (F51 and the voice
/// question), why a run asks (F33), where things run (F13), the `<document>` wrapper never saved (F32), and every
/// generated document reachable past the first page (F43). Everything is synthetic.
@MainActor
final class PolishCreateLaneTests: XCTestCase {
    // MARK: - Effective class in words

    private func document(_ title: String, _ privacyClass: PrivacyClass, of transcription: Transcription) -> Deliverable
    {
        Deliverable(
            transcriptionID: transcription.id, promptID: nil, promptVersionID: nil, title: title,
            engineID: "apple.fm", provider: "Apple on-device model", model: nil, locality: .onDevice,
            text: "Synthetic.", privacyClass: privacyClass)
    }

    func testAPersonalItemWithASOAPNoteSaysWhyItIsClinical() {
        let item = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .personal)
        let explanation = EffectivePrivacyExplanation(
            item, deliverables: [document("SOAP note", .clinical, of: item), document("Summary", .personal, of: item)])
        XCTAssertEqual(explanation.stored, .personal)
        XCTAssertEqual(explanation.effective, .clinical)
        XCTAssertTrue(explanation.isRaised)
        XCTAssertEqual(explanation.raisedBy, ["SOAP note"], "only the documents that raise it")
        XCTAssertEqual(explanation.label, "Clinical (it has a SOAP note)")
        XCTAssertEqual(
            explanation.sentence, "Marked Personal, but it counts as clinical because a SOAP note was made from it.")
    }

    func testAnItemMarkedClinicalOrNotRaisedNeedsNoReason() {
        let clinical = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .clinical)
        let marked = EffectivePrivacyExplanation(
            clinical, deliverables: [document("SOAP note", .clinical, of: clinical)])
        XCTAssertFalse(marked.isRaised)
        XCTAssertEqual(marked.label, "Clinical")
        XCTAssertNil(marked.sentence)

        let personal = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .personal)
        let plain = EffectivePrivacyExplanation(personal, deliverables: [document("Summary", .personal, of: personal)])
        XCTAssertEqual(plain.label, "Personal")
        XCTAssertNil(plain.sentence)
    }

    func testSeveralRaisingDocumentsAreNamedOnce() {
        let item = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .general)
        let docs = ["SOAP note", "SOAP note", "Intake note", "Referral", "Allergy list"].map {
            document($0, .clinical, of: item)
        }
        let explanation = EffectivePrivacyExplanation(item, deliverables: docs)
        XCTAssertEqual(explanation.raisedBy, ["SOAP note", "Intake note", "Referral", "Allergy list"])
        XCTAssertEqual(explanation.label, "Clinical (it has a SOAP note, Intake note and 2 more)")
        XCTAssertEqual(
            explanation.sentence,
            "Marked General, but it counts as clinical because a SOAP note, Intake note and 2 more were made from it.")
    }

    func testTheRunReasonNamesTheDocumentsTheTemplateOrTheEditedDocument() {
        let item = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .personal)
        let raised = EffectivePrivacyExplanation(item, deliverables: [document("SOAP note", .clinical, of: item)])
        XCTAssertEqual(
            ClinicalRunReason.sentence(raised, output: (.personal, "Summary", false)),
            raised.sentence)

        let plain = EffectivePrivacyExplanation(item, deliverables: [])
        XCTAssertEqual(
            ClinicalRunReason.sentence(plain, output: (.clinical, "SOAP note", false)),
            "The SOAP note template makes clinical documents.")
        XCTAssertEqual(
            ClinicalRunReason.sentence(plain, output: (.clinical, "Referral letter", true)),
            "This Referral letter is clinical.")
        XCTAssertNil(ClinicalRunReason.sentence(plain, output: (.personal, "Summary", false)))
        XCTAssertNil(ClinicalRunReason.sentence(plain, output: nil))

        let marked = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .clinical)
        XCTAssertNil(
            ClinicalRunReason.sentence(
                EffectivePrivacyExplanation(marked, deliverables: []), output: (.clinical, "SOAP note", false)),
            "the title already says clinical")
    }

    // MARK: - The per-run question (F33, F51)

    func testTheQuestionSaysTextAndWhyAPersonalTranscriptCountsAsClinical() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        _ = try await harness.run(BuiltInTemplates.soapNote, model: Destination.onDevice.makeModel())
        let cloud = Destination.cloud.makeModel()
        let decision = try await harness.service.route(
            transcriptionID: harness.transcript.id, templateID: BuiltInTemplates.summary.id, model: cloud)
        guard case .needsOverride(let request) = decision else { return XCFailRouted(decision) }
        XCTAssertTrue(request.title.hasPrefix("Send this clinical text to "), request.title)
        XCTAssertEqual(
            request.reason, "Marked Personal, but it counts as clinical because a SOAP note was made from it.")
        XCTAssertTrue(request.message.hasPrefix(request.reason ?? "-"), request.message)
        XCTAssertTrue(request.message.contains("over the internet"))
        XCTAssertTrue(cloud.requests.isEmpty, "asking sends nothing")
    }

    func testASOAPNoteOnAPersonalTranscriptSaysTheTemplateIsClinical() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let decision = try await harness.service.route(
            transcriptionID: harness.transcript.id, templateID: BuiltInTemplates.soapNote.id,
            model: Destination.cloud.makeModel())
        guard case .needsOverride(let request) = decision else { return XCFailRouted(decision) }
        XCTAssertEqual(request.reason, "The SOAP note template makes clinical documents.")
    }

    func testAClinicalTranscriptAsksWithoutAReason() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let decision = try await harness.service.route(
            transcriptionID: harness.transcript.id, templateID: BuiltInTemplates.summary.id,
            model: Destination.cloud.makeModel())
        guard case .needsOverride(let request) = decision else { return XCFailRouted(decision) }
        XCTAssertNil(request.reason)
        XCTAssertTrue(request.message.hasPrefix("It will leave this iPhone"), request.message)
    }

    private func XCFailRouted(_ decision: RouteDecision, file: StaticString = #filePath, line: UInt = #line) {
        XCTFail("expected a question, got \(decision)", file: file, line: line)
    }

    // MARK: - Edit by voice never saves the prompt's wrapper (F32)

    func testTheDocumentWrapperIsRemovedOnlyAtTheEnds() {
        XCTAssertEqual(
            DeliverablePromptAssembler.unwrappedEdit("<document>\nShorter synthetic note.\n</document>\n"),
            "Shorter synthetic note.")
        XCTAssertEqual(
            DeliverablePromptAssembler.unwrappedEdit("  <DOCUMENT>Shorter.</Document>  "), "Shorter.", "any case")
        XCTAssertEqual(
            DeliverablePromptAssembler.unwrappedEdit("<document>\nOnly an opening tag."), "Only an opening tag.")
        XCTAssertEqual(
            DeliverablePromptAssembler.unwrappedEdit("Only a closing tag.\n</document>"), "Only a closing tag.")
        XCTAssertEqual(
            DeliverablePromptAssembler.unwrappedEdit("Keep the <document> tag in the middle."),
            "Keep the <document> tag in the middle.")
        XCTAssertEqual(DeliverablePromptAssembler.unwrappedEdit("<document>\n</document>"), "")
    }

    func testAnEchoedWrapperNeverReachesTheSavedVersion() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let events = try await harness.run(BuiltInTemplates.summary, model: RecordingLanguageModel(locality: .onDevice))
        guard case .completed(let document)? = events.last else { return XCTFail("no document") }
        let model = RecordingLanguageModel(locality: .onDevice)
        model.script([.text("<document>\nA shorter synthetic summary.\n</document>")])
        var edited: Deliverable?
        for try await event in harness.service.edit(
            deliverableID: document.id, instruction: "Make it shorter", spoken: false, model: model)
        {
            if case .completed(let deliverable) = event { edited = deliverable }
        }
        XCTAssertEqual(edited?.text, "A shorter synthetic summary.")
        let versions = try await harness.deliverables.fetchDeliverableVersions(deliverableID: document.id)
        XCTAssertEqual(versions.last?.text, "A shorter synthetic summary.")
        XCTAssertFalse(versions.contains { $0.text.contains("<document>") || $0.text.contains("</document>") })
    }

    // MARK: - Where things run (F13)

    private let claude = LanguageModelChoice(
        source: .provider(UUID()), name: "Claude", locality: .cloud, host: "api.example.com",
        isTrustedForClinical: false)
    private let mac = LanguageModelChoice(
        source: .provider(UUID()), name: "mac-studio (Ollama)", locality: .localNetwork, host: "mac-studio.local",
        isTrustedForClinical: true)

    func testOnDeviceOnlyWhenEveryDefaultRouteIsOnThisIPhone() {
        let reach = ContentReach.current(
            speechEngineName: "Parakeet", defaultModel: .onDevice, otherProviders: [], voice: nil,
            companionTrusted: false, jevEnabled: false)
        XCTAssertEqual(reach.level, .onDevice)
        XCTAssertEqual(reach.chipTitle, "On device")
        XCTAssertEqual(
            reach.routes.map(\.feature),
            [
                "Speech to text", "Ask, Transforms and Create", "Read aloud and voice messages", "Jev",
            ])
        XCTAssertEqual(
            reach.routes.map(\.place),
            [
                "Parakeet on this iPhone", "Apple on-device model on this iPhone", "Not set up", "Off",
            ])
    }

    func testACloudModelVoiceOrJevTurnsTheChipToCloud() {
        let cloudModel = ContentReach.current(
            speechEngineName: "Parakeet", defaultModel: claude, otherProviders: [claude], voice: nil,
            companionTrusted: false, jevEnabled: false)
        XCTAssertEqual(cloudModel.level, .cloud)
        XCTAssertEqual(cloudModel.chipTitle, "Cloud on")
        XCTAssertEqual(cloudModel.routes[1].place, "Claude, over the internet")
        XCTAssertEqual(cloudModel.routes[1].note, "Asks before it sends clinical text.")
        XCTAssertEqual(cloudModel.otherCloudModels, [], "the default is not listed twice")

        let grok = ContentReach.current(
            speechEngineName: "Parakeet", defaultModel: .onDevice, otherProviders: [], voice: .xai,
            companionTrusted: false, jevEnabled: false)
        XCTAssertEqual(grok.level, .cloud)
        XCTAssertEqual(grok.routes[2].place, "Grok voices (xAI), over the internet")

        let jev = ContentReach.current(
            speechEngineName: "Parakeet", defaultModel: .onDevice, otherProviders: [], voice: nil,
            companionTrusted: false, jevEnabled: true)
        XCTAssertEqual(jev.level, .cloud)
        XCTAssertEqual(jev.routes[3].note, "Never sees clinical items.")
    }

    func testAMacOnTheHomeNetworkIsNotOnDeviceAndNotCloud() {
        let reach = ContentReach.current(
            speechEngineName: "Parakeet", defaultModel: mac, otherProviders: [mac, claude], voice: .companion,
            companionTrusted: true, jevEnabled: false)
        XCTAssertEqual(reach.level, .homeNetwork)
        XCTAssertEqual(reach.chipTitle, "Home network")
        XCTAssertEqual(reach.routes[1].note, "Trusted for clinical text.")
        XCTAssertEqual(reach.routes[2].place, "Your Mac, over your home network")
        XCTAssertEqual(reach.otherCloudModels, ["Claude"], "a cloud provider a run could pick is named")

        let untrusted = ContentReach.current(
            speechEngineName: "Parakeet", defaultModel: .onDevice, otherProviders: [], voice: .companion,
            companionTrusted: false, jevEnabled: false)
        XCTAssertEqual(untrusted.level, .homeNetwork)
        XCTAssertEqual(untrusted.routes[2].note, "Asks before it sends clinical text.")
    }

    // MARK: - Every document stays reachable (F43)

    func testShowMoreReachesEveryDocumentPastTheFirstPage() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        var made: [UUID] = []
        for _ in 0..<5 {
            let events = try await harness.run(
                BuiltInTemplates.summary, model: RecordingLanguageModel(locality: .onDevice))
            guard case .completed(let document)? = events.last else { return XCTFail("no document") }
            made.append(document.id)
        }
        let library = DeliverableLibraryViewModel(store: harness.deliverables, recentLimit: 2)
        await library.load()
        XCTAssertEqual(library.recent.count, 2)
        XCTAssertTrue(library.hasMore)
        await library.showMore()
        XCTAssertEqual(library.recent.count, 4)
        XCTAssertTrue(library.hasMore)
        await library.showMore()
        XCTAssertEqual(Set(library.recent.map(\.id)), Set(made), "every document is reachable")
        XCTAssertFalse(library.hasMore)
        await library.load()
        XCTAssertEqual(library.recent.count, 5, "a reload keeps the pages already shown")
        await library.showMore()
        XCTAssertEqual(library.recent.count, 5, "nothing more to show")
    }

    func testExactlyAPageHasNoMore() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        for _ in 0..<2 {
            _ = try await harness.run(BuiltInTemplates.summary, model: RecordingLanguageModel(locality: .onDevice))
        }
        let library = DeliverableLibraryViewModel(store: harness.deliverables, recentLimit: 2)
        await library.load()
        XCTAssertEqual(library.recent.count, 2)
        XCTAssertFalse(library.hasMore)
    }
}
