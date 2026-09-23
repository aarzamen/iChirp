import ChirpCore
import XCTest

@testable import ChirpStore

/// spec/contracts/decision-model-plugin-v1.md, store side: a `decision` ledger row persists as that feature through
/// `LanguageModelRunRecord` with no schema change (the ChirpCore half is `DecisionModelContractTests` there).
final class DecisionModelContractTests: XCTestCase {
    func testDecisionFeaturePersistsThroughTheRunRecord() async throws {
        let run = LanguageModelRun(
            feature: .decision, status: .succeeded, transcriptionID: nil, engineID: "http.jev", provider: "TypeSafe AI",
            model: "jev-1.13.0", locality: .cloud, privacyClass: .personal, privacyOverride: false, promptTokens: 700,
            completionTokens: 20, latencyMs: 180, inputCharacters: 2_900, callCount: 1)
        XCTAssertEqual(LanguageModelRunRecord(run).feature, "decision")
        XCTAssertEqual(LanguageModelRunRecord(run).toRun().feature, .decision)

        let store = GRDBDeliverableStore(database: try DatabaseManager.inMemory())
        try await store.recordRun(run)
        let stored = try await store.fetchRuns(limit: 5)
        XCTAssertEqual(stored.map(\.feature), [.decision])
        XCTAssertEqual(stored.first?.engineID, "http.jev")
        XCTAssertEqual(stored.first?.promptTokens, 700)
    }
}
