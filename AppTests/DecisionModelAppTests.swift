import ChirpCore
import ChirpFeatures
import ChirpStore
import Foundation
import Synchronization
import XCTest

@testable import iChirp

/// M6a (plan 021) in the app: only the factory imports the Jev engine, the Jev menu follows the Settings toggle, a
/// clinical item disables the menu and sends nothing, and the key field never loads the stored key. Nothing here
/// touches the network or the real Keychain; every text is synthetic.
@MainActor
final class DecisionModelAppTests: XCTestCase {
    static let marker = "SYNTHETIC-JEV-APP-MARKER-8820"
    private let key = SecretValue("ts-SYNTHETIC-APP-KEY-0123456789")

    // MARK: - Structure

    func testOnlyAppDecisionModelFactoryImportsChirpEngineJev() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var importers: [String] = []
        var scanned = 0
        for folder in ["App/Sources", "App/Shared", "Widgets"] {
            let root = repo.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                if source.range(of: #"(?m)^\s*(@testable\s+)?import\s+ChirpEngineJev\b"#, options: .regularExpression)
                    != nil
                {
                    importers.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found the app sources")
        XCTAssertEqual(importers, ["AppDecisionModelFactory.swift"])
    }

    // MARK: - Toggle

    func testTheJevMenuIsAbsentWhileTheToggleIsOff() throws {
        let settings = makeSettingsModel()
        XCTAssertFalse(settings.model.isMenuVisible, "Jev is off by default")
        XCTAssertFalse(JevMenuPolicy.isVisible(jevEnabled: settings.model.isMenuVisible, status: .completed))

        try settings.model.setEnabled(true)
        XCTAssertTrue(JevMenuPolicy.isVisible(jevEnabled: settings.model.isMenuVisible, status: .completed))
        XCTAssertFalse(
            JevMenuPolicy.isVisible(jevEnabled: settings.model.isMenuVisible, status: .processing),
            "no menu until the transcript has text")
        XCTAssertTrue(settings.store.load().isEnabled, "the toggle is saved")

        try settings.model.setEnabled(false)
        XCTAssertFalse(JevMenuPolicy.isVisible(jevEnabled: settings.model.isMenuVisible, status: .completed))
    }

    // MARK: - Clinical

    func testAClinicalItemDisablesTheMenuAndARecordingEngineReceivesNothing() async throws {
        XCTAssertFalse(JevMenuPolicy.itemsEnabled(for: .clinical))
        XCTAssertEqual(
            JevMenuPolicy.blockedCaption(for: .clinical), "Jev is a cloud service; clinical items stay on this iPhone.")
        XCTAssertTrue(JevMenuPolicy.itemsEnabled(for: .personal))
        XCTAssertTrue(JevMenuPolicy.itemsEnabled(for: .general))

        // Even if a run were started for a clinical item, the service refuses it and the engine sees nothing.
        let harness = try await ServiceHarness(privacy: .clinical)
        for recipe in DecisionRecipe.allCases {
            let run = DecisionRunViewModel(recipe: recipe, transcriptionID: harness.transcriptID, service: harness.service)
            await run.start()
            XCTAssertEqual(run.phase, .blocked(DecisionRunViewModel.clinicalBlockedMessage))
        }
        XCTAssertEqual(harness.engine.requestCount, 0)
        let runs = try await harness.ledger.fetchRuns(limit: 10)
        XCTAssertEqual(runs.map(\.status), [.refused, .refused, .refused])
        XCTAssertEqual(Set(runs.map(\.feature)), [.decision])
    }

    func testAPersonalItemRunsThroughTheSameHarness() async throws {
        let harness = try await ServiceHarness(privacy: .personal)
        let run = DecisionRunViewModel(
            recipe: .recordingKind, transcriptionID: harness.transcriptID, service: harness.service)
        await run.start()
        guard case .decided(let report) = run.phase else { return XCTFail("\(run.phase)") }
        XCTAssertEqual(report.items.first?.choice, "meeting")
        XCTAssertEqual(harness.engine.requestCount, 1)
        XCTAssertTrue(harness.engine.everythingReceived.contains(Self.marker), "the excerpt went to the engine")
        let runs = try await harness.ledger.fetchRuns(limit: 10)
        XCTAssertEqual(runs.map(\.status), [.succeeded])
    }

    // MARK: - Key field

    func testTheKeyFieldNeverLoadsTheStoredKey() throws {
        let settings = makeSettingsModel()
        try settings.store.save(settings.store.load(), apiKey: .set(key))
        settings.model.refresh()

        XCTAssertTrue(settings.model.hasStoredKey)
        XCTAssertEqual(settings.model.keyText, "", "the field starts empty")
        XCTAssertEqual(settings.model.keyPlaceholder, "Stored in the Keychain · type to replace")
        XCTAssertEqual(settings.model.keyChange, .keep, "a blank field keeps the stored key")
        var dumped = ""
        dump(settings.model, to: &dumped)
        XCTAssertFalse(dumped.contains(key.reveal()), "the key never enters the view model")

        settings.model.keyText = "ts-replacement-key"
        try settings.model.saveKey()
        XCTAssertEqual(settings.model.keyText, "", "saving clears the typed key")
        XCTAssertEqual(try settings.store.apiKey(), SecretValue("ts-replacement-key"))
    }

    // MARK: - Helpers

    private func makeSettingsModel() -> (model: JevSettingsViewModel, store: JevSettingsStore) {
        let suite = "DecisionModelAppTests.\(UUID().uuidString)"
        let store = JevSettingsStore(
            defaults: UserDefaults(suiteName: suite) ?? .standard, secrets: AppTestSecrets())
        return (JevSettingsViewModel(store: store, factory: AppTestDecisionFactory(engine: AppTestDecisionEngine())), store)
    }
}

/// A synthetic transcript in a real GRDB database, the real `DecisionService` and a recording engine.
@MainActor
private struct ServiceHarness {
    let transcriptID: UUID
    let service: DecisionService
    let ledger: GRDBDeliverableStore
    let engine: AppTestDecisionEngine

    init(privacy: PrivacyClass) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DecisionModelAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try DatabaseManager(url: folder.appendingPathComponent("test.sqlite"))
        let transcripts = GRDBTranscriptionStore(database: database)
        let ledger = GRDBDeliverableStore(database: database)
        var row = Transcription(fileName: "synthetic.m4a", durationMs: 60_000, status: .completed, privacyClass: privacy)
        row.rawTranscript = "Speaker one: the \(DecisionModelAppTests.marker) review moves to Thursday. Speaker two: agreed."
        try await transcripts.insert(row)

        let secrets = AppTestSecrets()
        let settings = JevSettingsStore(
            defaults: UserDefaults(suiteName: "DecisionModelAppTests.\(UUID().uuidString)") ?? .standard,
            secrets: secrets)
        try settings.save(JevSettings(isEnabled: true), apiKey: .set(SecretValue("ts-synthetic-key")))
        let engine = AppTestDecisionEngine()
        service = DecisionService(
            transcripts: transcripts, ledger: ledger, routingPolicy: { PrivacyRoutingPolicy() }, settings: settings,
            factory: AppTestDecisionFactory(engine: engine))
        transcriptID = row.id
        self.ledger = ledger
        self.engine = engine
    }
}

/// A cloud `DecisionModel` that records what it is sent and answers every question with its first option id.
private final class AppTestDecisionEngine: DecisionModel {
    let descriptor = EngineDescriptor(
        id: "http.jev", kind: .structure, provider: "TypeSafe AI", displayName: "Jev", locality: .cloud,
        license: "Proprietary (TypeSafe API terms)")
    let endpointHost: String? = "api.typesafe.ai"
    private let received = Mutex<[DecisionRequest]>([])

    var requestCount: Int { received.withLock { $0.count } }
    var everythingReceived: String { received.withLock { $0.map(\.state.text).joined(separator: "\n") } }

    func availability() async -> LanguageModelAvailability { .available }

    func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        received.withLock { $0.append(request) }
        var answers: [String: DecisionAnswer] = [:]
        for question in request.questions {
            let ids = question.options.keys.sorted()
            let choice = ids.first { $0 == "meeting" } ?? ids[0]
            let rest = 0.1 / Double(ids.count - 1)
            answers[question.id] = DecisionAnswer(
                questionID: question.id, choice: choice, confidence: 0.85,
                probabilities: Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == choice ? 0.9 : rest) }))
        }
        return DecisionResult(model: "jev-1.13.0", answers: answers, latencyMs: 12, requestBytes: 500)
    }
}

private struct AppTestDecisionFactory: DecisionModelFactory {
    let engine: AppTestDecisionEngine

    func makeJev(settings: JevSettings, apiKey: SecretValue?) -> any DecisionModel { engine }
    func testJevConnection(settings: JevSettings, apiKey: SecretValue?) async throws {}
}

private final class AppTestSecrets: SecretStoring {
    private let values = Mutex<[String: SecretValue]>([:])

    func secret(forAccount account: String) throws -> SecretValue? { values.withLock { $0[account] } }
    func setSecret(_ secret: SecretValue, forAccount account: String) throws {
        values.withLock { $0[account] = secret }
    }
    func deleteSecret(forAccount account: String) throws { values.withLock { $0[account] = nil } }
}
