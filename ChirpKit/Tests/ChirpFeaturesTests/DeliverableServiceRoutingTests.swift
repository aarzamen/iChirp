import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Shared setup for the DeliverableService tests. Every transcript is synthetic.
struct DeliverableHarness {
    static let marker = "SYNTHETIC-HERON-7731"
    static let trustedHost = "mac-studio.local"

    let transcripts: FakeStore
    let deliverables: FakeDeliverableStore
    let service: DeliverableService
    let policy: PolicyBox
    let clock: TestClock
    let transcript: Transcription

    init(privacy: PrivacyClass, text: String? = nil) async throws {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: privacy)
        row.rawTranscript = text ?? "Speaker one says the \(Self.marker) meeting moves to Thursday at nine."
        let transcripts = FakeStore(rows: [row])
        let deliverables = FakeDeliverableStore()
        let policy = PolicyBox(PrivacyRoutingPolicy(trustedLocalNetworkHosts: [Self.trustedHost]))
        let clock = TestClock()
        let service = DeliverableService(
            transcripts: transcripts, deliverables: deliverables, routingPolicy: { policy.current },
            now: { clock.now })
        try await service.installBuiltInTemplates()
        self.transcripts = transcripts
        self.deliverables = deliverables
        self.service = service
        self.policy = policy
        self.clock = clock
        transcript = row
    }

    func run(
        _ template: BuiltInPromptTemplate = BuiltInTemplates.summary,
        model: RecordingLanguageModel,
        override: PrivacyOverride? = nil,
        notes: String? = nil
    ) async throws -> [DeliverableRunEvent] {
        var events: [DeliverableRunEvent] = []
        for try await event in service.generate(
            templateID: template.id, transcriptionID: transcript.id, userNotes: notes, model: model,
            override: override)
        {
            events.append(event)
        }
        return events
    }

    /// Asks the router, and when it wants a confirmation, confirms it (the user tapped "Send").
    func confirmIfAsked(
        _ template: BuiltInPromptTemplate? = BuiltInTemplates.summary,
        model: RecordingLanguageModel
    ) async throws -> PrivacyOverride? {
        let decision = try await service.route(transcriptionID: transcript.id, templateID: template?.id, model: model)
        guard case .needsOverride(let request) = decision else { return nil }
        return try await service.confirmOverride(request)
    }
}

enum Destination: String, CaseIterable {
    case onDevice, trustedLAN, untrustedLAN, cloud

    func makeModel(contextTokens: Int? = nil) -> RecordingLanguageModel {
        switch self {
        case .onDevice:
            RecordingLanguageModel(locality: .onDevice, contextTokens: contextTokens)
        case .trustedLAN:
            RecordingLanguageModel(
                locality: .localNetwork, host: DeliverableHarness.trustedHost, engineID: "http.ollama",
                contextTokens: contextTokens)
        case .untrustedLAN:
            RecordingLanguageModel(
                locality: .localNetwork, host: "other-mac.local", engineID: "http.ollama", contextTokens: contextTokens)
        case .cloud:
            RecordingLanguageModel(
                locality: .cloud, host: "api.example.com", engineID: "http.anthropic", displayName: "Claude",
                contextTokens: contextTokens)
        }
    }

    /// Clinical content may go here without a per-run override.
    var acceptsClinicalWithoutOverride: Bool { self == .onDevice || self == .trustedLAN }
}

/// The routing matrix at the one call site (`DeliverableService`): general / personal / clinical × on device /
/// trusted LAN / untrusted LAN / cloud × override confirmed or not, with a fake model that records what it received.
final class DeliverableServiceRoutingTests: XCTestCase {
    func testFullPrivacyMatrix() async throws {
        var rows: [String] = []
        for privacy in PrivacyClass.allCases {
            for destination in Destination.allCases {
                for userConfirms in [false, true] {
                    let outcome = try await check(privacy, destination, userConfirms)
                    rows.append("\(privacy.rawValue) × \(destination.rawValue) × override \(userConfirms): \(outcome)")
                }
            }
        }
        XCTAssertEqual(rows.count, 24)
        // Printed so the report can quote the matrix as executed.
        print("ROUTING MATRIX\n" + rows.joined(separator: "\n"))
    }

    private func check(_ privacy: PrivacyClass, _ destination: Destination, _ userConfirms: Bool) async throws
        -> String
    {
        let label = "\(privacy) × \(destination) × override \(userConfirms)"
        let harness = try await DeliverableHarness(privacy: privacy)
        let model = destination.makeModel()
        let needsOverride = privacy == .clinical && !destination.acceptsClinicalWithoutOverride

        let decision = try await harness.service.route(
            transcriptionID: harness.transcript.id, templateID: BuiltInTemplates.summary.id, model: model)
        switch decision {
        case .allowed: XCTAssertFalse(needsOverride, label)
        case .needsOverride(let request):
            XCTAssertTrue(needsOverride, label)
            XCTAssertEqual(request.route.privacyClass, .clinical, label)
            XCTAssertTrue(request.title.contains("clinical"), label)
        }
        XCTAssertTrue(model.requests.isEmpty, "routing alone sends nothing: \(label)")

        var token: PrivacyOverride?
        if userConfirms, case .needsOverride(let request) = decision {
            token = try await harness.service.confirmOverride(request)
        }

        let shouldSend = !needsOverride || token != nil
        do {
            let events = try await harness.run(model: model, override: token)
            XCTAssertTrue(shouldSend, "sent without a required override: \(label)")
            XCTAssertFalse(model.requests.isEmpty, label)
            XCTAssertTrue(model.everythingReceived.contains(DeliverableHarness.marker), label)
            XCTAssertTrue(model.requests.allSatisfy { $0.privacyClass == privacy }, label)
            guard case .completed(let deliverable) = events.last else {
                XCTFail("no deliverable: \(label)")
                return "?"
            }
            XCTAssertEqual(deliverable.privacyClass, privacy, label)
            let routedFlags = events.compactMap { event -> Bool? in
                if case .routed(_, let used) = event { return used }
                return nil
            }
            XCTAssertEqual(routedFlags, [token != nil], label)
        } catch DeliverableError.privacyOverrideRequired(let request) {
            XCTAssertFalse(shouldSend, "refused a run that should go: \(label)")
            XCTAssertTrue(model.requests.isEmpty, "clinical text reached the model without an override: \(label)")
            XCTAssertEqual(request.route.locality, model.descriptor.locality, label)
        }

        let runs = await harness.deliverables.runs
        let stored = await harness.deliverables.deliverables
        XCTAssertEqual(runs.count, 1, "one ledger row per run: \(label)")
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.status, shouldSend ? .succeeded : .refused, label)
        XCTAssertEqual(run.privacyOverride, needsOverride && token != nil, label)
        XCTAssertEqual(run.privacyClass, privacy, label)
        XCTAssertEqual(run.callCount, shouldSend ? model.requests.count : 0, label)
        XCTAssertEqual(stored.count, shouldSend ? 1 : 0, label)
        for field in stringFields(of: run) {
            XCTAssertFalse(field.contains(DeliverableHarness.marker), "content in the ledger: \(label)")
            XCTAssertFalse(field.contains("Generated document"), "output in the ledger: \(label)")
        }

        if !shouldSend { return "refused, nothing sent" }
        return needsOverride ? "sent with override (logged)" : "sent"
    }

    func testAskFollowsTheSameRouting() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let cloud = Destination.cloud.makeModel()
        do {
            for try await _ in harness.service.ask(
                question: "When is the meeting?", transcriptionID: harness.transcript.id, model: cloud)
            {}
            XCTFail("clinical Ask to the cloud must need an override")
        } catch DeliverableError.privacyOverrideRequired {}
        XCTAssertTrue(cloud.requests.isEmpty)

        let token = try await harness.confirmIfAsked(nil, model: cloud)
        var answer: AskAnswer?
        for try await event in harness.service.ask(
            question: "When is the meeting?", transcriptionID: harness.transcript.id, model: cloud, override: token)
        {
            if case .answered(let value) = event { answer = value }
        }
        XCTAssertNotNil(answer)
        XCTAssertTrue(cloud.everythingReceived.contains("When is the meeting?"))
        let runs = await harness.deliverables.runs
        XCTAssertEqual(runs.map(\.status), [.refused, .succeeded])
        XCTAssertEqual(runs.map(\.feature), [.ask, .ask])
        XCTAssertEqual(runs.last?.privacyOverride, true)
        let stored = await harness.deliverables.deliverables
        XCTAssertTrue(stored.isEmpty, "Ask answers are not stored as deliverables")
    }

    func testOverrideIsSingleUse() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let cloud = Destination.cloud.makeModel()
        let token = try await harness.confirmIfAsked(model: cloud)
        _ = try await harness.run(model: cloud, override: token)
        let sentFirst = cloud.requests.count
        XCTAssertGreaterThan(sentFirst, 0)

        do {
            _ = try await harness.run(model: cloud, override: token)
            XCTFail("a used override must not work twice")
        } catch DeliverableError.privacyOverrideRequired {}
        XCTAssertEqual(cloud.requests.count, sentFirst, "the second run sent nothing")
    }

    func testOverrideIsBoundToTheTranscriptAndTheDestination() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let cloud = Destination.cloud.makeModel()
        let token = try await harness.confirmIfAsked(model: cloud)

        // Another cloud host.
        let otherCloud = RecordingLanguageModel(locality: .cloud, host: "api.other.example", engineID: "http.anthropic")
        do {
            _ = try await harness.run(model: otherCloud, override: token)
            XCTFail("an override for one host must not open another")
        } catch DeliverableError.privacyOverrideRequired {}
        XCTAssertTrue(otherCloud.requests.isEmpty)

        // Another transcript, same destination.
        let harness2 = try await DeliverableHarness(privacy: .clinical)
        let token2 = try await harness2.confirmIfAsked(model: cloud)
        var other = Transcription(fileName: "other.m4a", status: .completed, privacyClass: .clinical)
        other.rawTranscript = "Another synthetic clinical note."
        try await harness2.transcripts.insert(other)
        do {
            for try await _ in harness2.service.generate(
                templateID: BuiltInTemplates.summary.id, transcriptionID: other.id, model: cloud, override: token2)
            {}
            XCTFail("an override for one transcript must not open another")
        } catch DeliverableError.privacyOverrideRequired {}
        XCTAssertFalse(cloud.everythingReceived.contains("Another synthetic clinical note."))
    }

    func testOverrideExpires() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let cloud = Destination.cloud.makeModel()
        let token = try await harness.confirmIfAsked(model: cloud)
        harness.clock.advance(by: DeliverableService.overrideLifetime + 1)
        do {
            _ = try await harness.run(model: cloud, override: token)
            XCTFail("an expired override must not work")
        } catch DeliverableError.privacyOverrideRequired {}
        XCTAssertTrue(cloud.requests.isEmpty)
    }

    func testOverrideRequestCanBeConfirmedOnlyOnce() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let cloud = Destination.cloud.makeModel()
        let decision = try await harness.service.route(
            transcriptionID: harness.transcript.id, templateID: BuiltInTemplates.summary.id, model: cloud)
        guard case .needsOverride(let request) = decision else { return XCTFail("expected needsOverride") }
        _ = try await harness.service.confirmOverride(request)
        do {
            _ = try await harness.service.confirmOverride(request)
            XCTFail("a request is answered once")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .unknownOverrideRequest)
        }
        let forged = PrivacyOverrideRequest(id: UUID(), route: request.route)
        do {
            _ = try await harness.service.confirmOverride(forged)
            XCTFail("a request the service did not issue cannot be confirmed")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .unknownOverrideRequest)
        }
    }

    func testSOAPNoteIsClinicalEvenFromAPersonalTranscript() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let cloud = Destination.cloud.makeModel()
        do {
            _ = try await harness.run(BuiltInTemplates.soapNote, model: cloud)
            XCTFail("a SOAP run is clinical, so the cloud needs an override")
        } catch DeliverableError.privacyOverrideRequired(let request) {
            XCTAssertEqual(request.route.privacyClass, .clinical)
        }
        XCTAssertTrue(cloud.requests.isEmpty)

        let onDevice = Destination.onDevice.makeModel()
        let events = try await harness.run(BuiltInTemplates.soapNote, model: onDevice)
        guard case .completed(let deliverable) = events.last else { return XCTFail("no deliverable") }
        XCTAssertEqual(deliverable.privacyClass, .clinical)
        XCTAssertTrue(onDevice.requests.allSatisfy { $0.privacyClass == .clinical })
    }

    /// Review L4 M1: once a transcript has a clinical deliverable (a SOAP note), Ask and Transform treat the transcript
    /// as clinical, even though its own class is still personal.
    func testAClinicalDeliverableMakesItsTranscriptClinicalForAskAndTransform() async throws {
        let harness = try await DeliverableHarness(privacy: .personal)
        let onDevice = Destination.onDevice.makeModel()
        _ = try await harness.run(BuiltInTemplates.soapNote, model: onDevice)
        let stored = await harness.deliverables.deliverables
        XCTAssertEqual(stored.values.map(\.privacyClass), [.clinical])

        let cloud = Destination.cloud.makeModel()
        do {
            _ = try await harness.run(BuiltInTemplates.summary, model: cloud)
            XCTFail("a summary of a transcript with a clinical deliverable is clinical")
        } catch DeliverableError.privacyOverrideRequired(let request) {
            XCTAssertEqual(request.route.privacyClass, .clinical)
        }
        do {
            for try await _ in harness.service.ask(
                question: "When is the meeting?", transcriptionID: harness.transcript.id, model: cloud)
            {}
            XCTFail("Ask about a transcript with a clinical deliverable is clinical")
        } catch DeliverableError.privacyOverrideRequired(let request) {
            XCTAssertEqual(request.route.privacyClass, .clinical)
        }
        XCTAssertTrue(cloud.requests.isEmpty, "nothing reached the cloud")

        // The route the confirmation names is the one the run checks: the token still works for that run.
        let token = try await harness.confirmIfAsked(nil, model: cloud)
        XCTAssertNotNil(token)
        var answered = false
        for try await event in harness.service.ask(
            question: "When is the meeting?", transcriptionID: harness.transcript.id, model: cloud, override: token)
        {
            if case .answered(let answer) = event {
                answered = true
                XCTAssertEqual(answer.route.privacyClass, .clinical)
            }
        }
        XCTAssertTrue(answered)
        XCTAssertTrue(cloud.requests.allSatisfy { $0.privacyClass == .clinical })
    }

    func testAClinicalDeliverableAddedMidRunStopsBeforeTheNextCall() async throws {
        let lines = (1...400).map { "Speaker 1: synthetic line \($0) about the heron survey." }
        let harness = try await DeliverableHarness(privacy: .personal, text: lines.joined(separator: "\n"))
        let cloud = Destination.cloud.makeModel(contextTokens: 4_096)
        let deliverables = harness.deliverables
        let id = harness.transcript.id
        cloud.onEachCall { call in
            guard call == 1 else { return }
            try? await deliverables.insertDeliverable(
                Deliverable(
                    transcriptionID: id, promptID: nil, promptVersionID: nil, title: "SOAP note", engineID: "fake",
                    provider: "Fake", model: nil, locality: .onDevice, text: "Synthetic.", privacyClass: .clinical))
        }
        do {
            _ = try await harness.run(model: cloud)
            XCTFail("the run must stop once the transcript has a clinical deliverable")
        } catch DeliverableError.privacyOverrideRequired(let request) {
            XCTAssertEqual(request.route.privacyClass, .clinical)
        }
        XCTAssertEqual(cloud.requests.count, 1)
    }

    func testEffectivePrivacyClassIsTheStrictestOfTheTranscriptAndItsDeliverables() {
        let transcript = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .general)
        func deliverable(_ privacy: PrivacyClass) -> Deliverable {
            Deliverable(
                transcriptionID: transcript.id, promptID: nil, promptVersionID: nil, title: "Synthetic",
                engineID: "fake", provider: "Fake", model: nil, locality: .onDevice, text: "Synthetic.",
                privacyClass: privacy)
        }
        XCTAssertEqual(EffectivePrivacyClass.of(transcript, deliverables: []), .general)
        XCTAssertEqual(EffectivePrivacyClass.of(transcript, deliverables: [deliverable(.personal)]), .personal)
        XCTAssertEqual(
            EffectivePrivacyClass.of(transcript, deliverables: [deliverable(.general), deliverable(.clinical)]),
            .clinical)
        var clinical = transcript
        clinical.privacyClass = .clinical
        XCTAssertEqual(EffectivePrivacyClass.of(clinical, deliverables: [deliverable(.general)]), .clinical)
    }

    func testLANEngineWithoutAReportedHostIsNeverTrusted() async throws {
        let harness = try await DeliverableHarness(privacy: .clinical)
        let hostless = RecordingLanguageModel(locality: .localNetwork, host: nil, engineID: "http.ollama")
        do {
            _ = try await harness.run(model: hostless)
            XCTFail("a LAN engine that does not say where it sends is untrusted")
        } catch DeliverableError.privacyOverrideRequired {}
        XCTAssertTrue(hostless.requests.isEmpty)
    }

    func testClassRaisedMidRunStopsBeforeTheNextCall() async throws {
        // Long enough for several parts on a 4K window, so the run makes several calls.
        let lines = (1...400).map { "[\(String(format: "%02d", $0 / 60)):\(String(format: "%02d", $0 % 60))] "
            + "Speaker 1: synthetic line \($0) about the heron survey." }
        let harness = try await DeliverableHarness(privacy: .personal, text: lines.joined(separator: "\n"))
        let cloud = Destination.cloud.makeModel(contextTokens: 4_096)
        let transcripts = harness.transcripts
        let id = harness.transcript.id
        cloud.onEachCall { call in
            if call == 1 { await transcripts.setPrivacyClass(.clinical, for: id) }
        }
        do {
            _ = try await harness.run(model: cloud)
            XCTFail("the run must stop once the transcript became clinical")
        } catch DeliverableError.privacyOverrideRequired(let request) {
            XCTAssertEqual(request.route.privacyClass, .clinical)
        }
        XCTAssertEqual(cloud.requests.count, 1, "only the call made while the transcript was personal went out")
        let runs = await harness.deliverables.runs
        XCTAssertEqual(runs.last?.status, .refused)
        let stored = await harness.deliverables.deliverables
        XCTAssertTrue(stored.isEmpty)
    }

    func testUntrustingAHostMidRunStopsBeforeTheNextCall() async throws {
        let lines = (1...400).map { "Speaker 1: synthetic clinical line \($0) about the heron ward round." }
        let harness = try await DeliverableHarness(privacy: .clinical, text: lines.joined(separator: "\n"))
        let lan = Destination.trustedLAN.makeModel(contextTokens: 4_096)
        let policy = harness.policy
        lan.onEachCall { call in
            if call == 1 { policy.set(PrivacyRoutingPolicy()) }
        }
        do {
            _ = try await harness.run(model: lan)
            XCTFail("the run must stop once the host is no longer trusted")
        } catch DeliverableError.privacyOverrideRequired {}
        XCTAssertEqual(lan.requests.count, 1)
    }
}
