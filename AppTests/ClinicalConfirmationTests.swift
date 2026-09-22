import ChirpCore
import ChirpFeatures
import ChirpStore
import Foundation
import Synchronization
import XCTest

@testable import iChirp

/// The M4 core report's concern 1: ChirpKit makes an override token only from `confirmOverride` on a request it
/// issued, but it cannot prove the app calls that only after the user taps Send. These tests prove it for the app:
///
/// 1. **Structure:** in `App/Sources`, `confirmOverride(` is called exactly once, inside
///    `ClinicalConfirmationActions.userTappedSend()`, and `userTappedSend()` is called exactly once, from the
///    dialog's `Button("Send")`. In ChirpKit only `DeliverableRunViewModel` calls the service's `confirmOverride`.
/// 2. **Behavior:** with a synthetic clinical transcript, a recording cloud model and the app's own run host, every
///    other path the screens offer (Stop, closing the sheet, Cancel, a late Send after Cancel, Retry, choosing
///    another template, Ask) sends nothing and writes no override; only Send does, for one run.
@MainActor
final class ClinicalConfirmationTests: XCTestCase {
    static let marker = "SYNTHETIC-CLINICAL-MARKER-4471"

    // MARK: - 1. Structure

    func testOnlyTheSendButtonCallsConfirmOverride() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try Self.codeMatches(pattern: #"confirmOverride\("#, under: repo.appendingPathComponent("App/Sources"))
        XCTAssertGreaterThan(app.scanned, 20, "the scan found the app sources")
        XCTAssertEqual(app.matches.map(\.file), ["ClinicalConfirmation.swift"], "only the dialog's actions confirm")
        XCTAssertTrue(
            app.matches.first?.before.contains("func userTappedSend() async {") == true,
            "confirmOverride is called inside userTappedSend")

        let send = try Self.codeMatches(
            pattern: #"\.userTappedSend\(\)"#, under: repo.appendingPathComponent("App/Sources"))
        XCTAssertEqual(send.matches.map(\.file), ["ClinicalConfirmation.swift"], "userTappedSend has one caller")
        XCTAssertTrue(
            send.matches.first?.before.contains(#"Button("Send") {"#) == true,
            "that caller is the Send button's action")

        let kit = try Self.codeMatches(
            pattern: #"\.confirmOverride\("#, under: repo.appendingPathComponent("ChirpKit/Sources"))
        XCTAssertEqual(kit.matches.map(\.file), ["DeliverableRunViewModel.swift"])
    }

    // MARK: - 2. Behavior

    func testNoPathButSendSendsAClinicalTransformToTheCloud() async throws {
        let harness = try await Harness()
        let host = TransformRunHost(
            service: harness.service, models: harness.models, documents: harness.deliverableStore)
        let request = try await harness.transformRequest(canonicalKey: "summary")

        // Start: routed, waiting for the dialog, nothing sent.
        await host.start(request)
        let first = try XCTUnwrap(host.run)
        guard case .needsConfirmation(let asked) = first.phase else { return XCTFail("\(first.phase)") }
        XCTAssertEqual(asked.title, "Send this clinical transcript to Synthetic Cloud?")
        try await harness.assertNothingSent("after start")

        // Stop / closing the sheet while the dialog is up.
        host.cancel()
        try await harness.assertNothingSent("after Stop")

        // Cancel in the dialog, then a late Send on the answered dialog.
        ClinicalConfirmationActions(run: first).userTappedCancel()
        XCTAssertEqual(first.phase, .idle)
        await ClinicalConfirmationActions(run: first).userTappedSend()
        XCTAssertEqual(first.phase, .idle, "a Send after Cancel does nothing")
        try await harness.assertNothingSent("after Cancel and a late Send")

        // Retry and "choose another" start fresh runs that ask again.
        await host.retry()
        let second = try XCTUnwrap(host.run)
        guard case .needsConfirmation = second.phase else { return XCTFail("Retry must ask again: \(second.phase)") }
        host.reset()
        XCTAssertNil(host.run)
        try await harness.assertNothingSent("after Retry and choosing another template")

        // Only Send sends, once.
        await host.start(request)
        let third = try XCTUnwrap(host.run)
        await ClinicalConfirmationActions(run: third).userTappedSend()
        guard case .completed(let deliverable) = third.phase else { return XCTFail("\(third.phase)") }
        XCTAssertTrue(harness.cloud.everythingReceived.contains(Self.marker), "Send delivered the run")
        XCTAssertEqual(deliverable.privacyClass, .clinical)
        let runs = try await harness.deliverableStore.fetchRuns(limit: 10)
        XCTAssertEqual(runs.map(\.privacyOverride), [true])
        XCTAssertEqual(runs.map(\.status), [.succeeded])

        // The confirmation is not remembered: the next run asks again and sends nothing until then.
        let sentBefore = harness.cloud.requestCount
        await host.start(request)
        guard case .needsConfirmation = host.run?.phase else { return XCTFail("the next run must ask again") }
        XCTAssertEqual(harness.cloud.requestCount, sentBefore)
    }

    func testSOAPFromAPersonalTranscriptAsksToo() async throws {
        let harness = try await Harness(privacy: .personal)
        let host = TransformRunHost(
            service: harness.service, models: harness.models, documents: harness.deliverableStore)
        await host.start(try await harness.transformRequest(canonicalKey: "soap-note"))
        guard case .needsConfirmation(let asked) = host.run?.phase else { return XCTFail("SOAP output is clinical") }
        XCTAssertEqual(asked.route.privacyClass, .clinical)
        try await harness.assertNothingSent("SOAP before Send")
    }

    func testAskWaitsForSendAsWell() async throws {
        let harness = try await Harness()
        let session = AskSessionViewModel(service: harness.service, transcriptionID: harness.transcriptID)
        let model = try harness.models.makeModel(for: harness.cloudChoice)
        await session.ask("What was decided?", model: model, choice: harness.cloudChoice)
        let run = try XCTUnwrap(session.exchanges.last?.run)
        guard case .needsConfirmation = run.phase else { return XCTFail("\(run.phase)") }

        session.cancel()
        await session.ask("A second question while the dialog is up", model: model, choice: harness.cloudChoice)
        XCTAssertEqual(session.exchanges.count, 1)
        ClinicalConfirmationActions(run: run).userTappedCancel()
        try await harness.assertNothingSent("Ask declined")

        await session.ask("What was decided?", model: model, choice: harness.cloudChoice)
        let asked = try XCTUnwrap(session.exchanges.last?.run)
        await ClinicalConfirmationActions(run: asked).userTappedSend()
        guard case .answered = asked.phase else { return XCTFail("\(asked.phase)") }
        XCTAssertTrue(harness.cloud.everythingReceived.contains(Self.marker))
        let runs = try await harness.deliverableStore.fetchRuns(limit: 10)
        XCTAssertEqual(runs.map(\.feature), [.ask])
        XCTAssertEqual(runs.map(\.privacyOverride), [true])
    }

    func testOnDeviceAndTrustedMacNeverAsk() async throws {
        let harness = try await Harness()
        let host = TransformRunHost(
            service: harness.service, models: harness.models, documents: harness.deliverableStore)
        var request = try await harness.transformRequest(canonicalKey: "summary")
        request.choice = .onDevice
        await host.start(request)
        guard case .completed = host.run?.phase else { return XCTFail("on device runs without asking") }
        XCTAssertTrue(harness.onDevice.everythingReceived.contains(Self.marker))
        XCTAssertEqual(harness.cloud.requestCount, 0)
    }

    // MARK: - Helpers

    struct Match {
        var file: String
        /// Code (comments removed) just before the match.
        var before: String
    }

    /// Matches of `pattern` in `.swift` files under `root`, with `//` comments stripped first.
    static func codeMatches(pattern: String, under root: URL) throws -> (matches: [Match], scanned: Int) {
        let regex = try NSRegularExpression(pattern: pattern)
        var matches: [Match] = []
        var scanned = 0
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            let code = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
                .joined(separator: "\n")
            let nsCode = code as NSString
            for result in regex.matches(in: code, range: NSRange(location: 0, length: nsCode.length)) {
                let start = max(0, result.range.location - 400)
                let before = nsCode.substring(with: NSRange(location: start, length: result.range.location - start))
                matches.append(Match(file: file.lastPathComponent, before: before))
            }
        }
        return (matches, scanned)
    }
}

/// A synthetic clinical transcript in a real GRDB database, the real `DeliverableService`, and a Settings → Models
/// state with one cloud provider whose engine is a recording fake. Nothing touches the network or the Keychain.
@MainActor
private struct Harness {
    let transcriptID: UUID
    let service: DeliverableService
    let deliverableStore: GRDBDeliverableStore
    let models: LanguageModelsViewModel
    let cloud: RecordingModel
    let onDevice: RecordingModel
    let cloudChoice: LanguageModelChoice

    init(privacy: PrivacyClass = .clinical) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClinicalConfirmationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try DatabaseManager(url: folder.appendingPathComponent("test.sqlite"))
        let transcripts = GRDBTranscriptionStore(database: database)
        let deliverableStore = GRDBDeliverableStore(database: database)

        var row = Transcription(fileName: "synthetic.m4a", durationMs: 60_000, status: .completed, privacyClass: privacy)
        row.rawTranscript = "Speaker one: the \(ClinicalConfirmationTests.marker) follow-up moves to Thursday."
        try await transcripts.insert(row)

        let suite = "ClinicalConfirmationTests.\(UUID().uuidString)"
        let providers = UserDefaultsLanguageModelProviderStore(
            defaults: UserDefaults(suiteName: suite) ?? .standard, secrets: InMemorySecrets())
        let cloud = RecordingModel(locality: .cloud, host: "api.example.com", name: "Synthetic Cloud")
        let onDevice = RecordingModel(locality: .onDevice, host: nil, name: "Apple on-device model")
        let models = LanguageModelsViewModel(
            store: providers, factory: RecordingFactory(cloud: cloud, onDevice: onDevice))
        var draft = LanguageModelProviderDraft(kind: .anthropic)
        draft.displayName = "Synthetic Cloud"
        draft.baseURLText = "https://api.example.com/v1"
        draft.modelName = "synthetic-model"
        draft.apiKeyText = "synthetic-key"
        try models.save(draft)

        let service = DeliverableService(
            transcripts: transcripts, deliverables: deliverableStore, routingPolicy: { providers.routingPolicy() })
        try await service.installBuiltInTemplates()

        transcriptID = row.id
        self.service = service
        self.deliverableStore = deliverableStore
        self.models = models
        self.cloud = cloud
        self.onDevice = onDevice
        cloudChoice = try XCTUnwrap(models.choices.first { $0.locality == .cloud })
    }

    func transformRequest(canonicalKey: String) async throws -> TransformRunHost.Request {
        let templates = try await deliverableStore.fetchTemplates()
        let template = try XCTUnwrap(templates.first { $0.canonicalKey == canonicalKey })
        return TransformRunHost.Request(template: template, transcriptionID: transcriptID, choice: cloudChoice, notes: nil)
    }

    /// The cloud model received nothing and the ledger holds no row (routing alone writes none).
    func assertNothingSent(_ step: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(cloud.requestCount, 0, "cloud received a request \(step)", file: file, line: line)
        let runs = try await deliverableStore.fetchRuns(limit: 10)
        XCTAssertFalse(runs.contains { $0.privacyOverride }, "an override was recorded \(step)", file: file, line: line)
    }
}

/// A `LanguageModel` that records what it is sent and answers with a short synthetic text.
private final class RecordingModel: LanguageModel {
    let descriptor: EngineDescriptor
    let endpointHost: String?
    private let received = Mutex<[GenerationRequest]>([])

    init(locality: EngineLocality, host: String?, name: String) {
        descriptor = EngineDescriptor(
            id: "test.\(locality.rawValue)", kind: .language, provider: "Test", displayName: name, locality: locality,
            license: "Test")
        endpointHost = host
    }

    var requestCount: Int { received.withLock { $0.count } }
    var everythingReceived: String { received.withLock { $0.map { "\($0.system ?? "")\n\($0.prompt)" }.joined() } }

    func contextWindowTokens() async -> Int? { 8_192 }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        received.withLock { $0.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Synthetic document [00:00]."))
            continuation.yield(.usage(GenerationUsage(model: "synthetic-model")))
            continuation.yield(.finished)
            continuation.finish()
        }
    }
}

private struct RecordingFactory: LanguageModelFactory {
    let cloud: RecordingModel
    let onDevice: RecordingModel

    func makeOnDeviceModel() -> any LanguageModel { onDevice }

    func makeModel(for provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) throws -> any LanguageModel {
        cloud
    }

    func testConnection(to provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws {}

    func listModels(of provider: LanguageModelProviderConfiguration, apiKey: SecretValue?) async throws -> [String] {
        []
    }
}

private final class InMemorySecrets: SecretStoring {
    private let values = Mutex<[String: SecretValue]>([:])

    func secret(forAccount account: String) throws -> SecretValue? { values.withLock { $0[account] } }
    func setSecret(_ secret: SecretValue, forAccount account: String) throws {
        values.withLock { $0[account] = secret }
    }
    func deleteSecret(forAccount account: String) throws { values.withLock { $0[account] = nil } }
}
