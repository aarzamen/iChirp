import Foundation
import XCTest

@testable import ChirpCore

/// spec/contracts/decision-model-plugin-v1.md: the value types round-trip, malformed questions fail before anything
/// is sent, and the ledger has a `decision` feature. (The store round trip is `DecisionModelContractTests` in
/// ChirpStoreTests.)
final class DecisionModelContractTests: XCTestCase {
    private let question = DecisionQuestion(
        id: "kind", instructions: "What kind of recording is this?",
        options: ["meeting": "Several people discuss work.", "dictation": "One person dictates a note."])

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    func testValueTypesRoundTripThroughJSON() throws {
        try roundTrip(question)
        let state = DecisionState(text: "Synthetic text.", facts: ["speaker_count": "2", "source": "audio"])
        try roundTrip(state)
        let answer = DecisionAnswer(
            questionID: "kind", choice: "meeting", confidence: 0.8, probabilities: ["meeting": 0.9, "dictation": 0.1])
        try roundTrip(answer)
        try roundTrip(
            DecisionResult(
                model: "jev-1.13.0", answers: ["kind": answer], latencyMs: 120, requestBytes: 900, inputTokens: 225,
                outputTokens: 20))
        try roundTrip(DecisionResult(model: "jev-1.13.0", answers: [:], latencyMs: 1, requestBytes: 2))
        try roundTrip(DecisionRequest(state: state, questions: [question], privacyClass: .personal))
    }

    func testAQuestionNeedsTwoToTwoHundredFiftyOptions() throws {
        XCTAssertNoThrow(try question.validate())

        let one = DecisionQuestion(id: "q", instructions: "?", options: ["a": "A"])
        XCTAssertThrowsError(try one.validate()) { XCTAssertEqual($0 as? DecisionRequestError, .tooFewOptions(questionID: "q")) }

        let most = Dictionary(uniqueKeysWithValues: (0..<250).map { ("o\($0)", "Option \($0)") })
        XCTAssertNoThrow(try DecisionQuestion(id: "q", instructions: "?", options: most).validate())

        var tooMany = most
        tooMany["o250"] = "Option 250"
        XCTAssertThrowsError(try DecisionQuestion(id: "q", instructions: "?", options: tooMany).validate()) {
            XCTAssertEqual($0 as? DecisionRequestError, .tooManyOptions(questionID: "q"))
        }

        XCTAssertThrowsError(try DecisionQuestion(id: " ", instructions: "?", options: ["a": "A", "b": "B"]).validate())
        XCTAssertThrowsError(try DecisionQuestion(id: "q", instructions: "?", options: ["a": "A", "": "B"]).validate())
    }

    func testARequestNeedsUniqueValidQuestions() {
        let state = DecisionState(text: "Synthetic.")
        XCTAssertThrowsError(try DecisionRequest(state: state, questions: [], privacyClass: .general).validate()) {
            XCTAssertEqual($0 as? DecisionRequestError, .noQuestions)
        }
        XCTAssertThrowsError(
            try DecisionRequest(state: state, questions: [question, question], privacyClass: .general).validate()
        ) { XCTAssertEqual($0 as? DecisionRequestError, .duplicateQuestionID) }
        XCTAssertNoThrow(try DecisionRequest(state: state, questions: [question], privacyClass: .general).validate())
    }

    func testRequestErrorKindNamesAreDistinctAndContentFree() {
        let errors: [DecisionRequestError] = [
            .noQuestions, .duplicateQuestionID, .emptyQuestionID, .emptyOptionID(questionID: "secret"),
            .tooFewOptions(questionID: "secret"), .tooManyOptions(questionID: "secret"),
        ]
        let names = errors.map(\.kindName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains { $0.contains("secret") })
    }

    func testRankedOptionsAreMostLikelyFirstWithStableTies() {
        let answer = DecisionAnswer(
            questionID: "q", choice: "b", confidence: 0.5, probabilities: ["a": 0.25, "b": 0.5, "c": 0.25])
        XCTAssertEqual(answer.rankedOptions.map(\.id), ["b", "a", "c"])
    }

    func testDecisionIsALedgerFeature() {
        XCTAssertEqual(LanguageModelRun.Feature(rawValue: "decision"), .decision)
        // Plan 022 adds `edit` (Edit by voice) after it; existing raw values never change.
        XCTAssertEqual(LanguageModelRun.Feature.allCases, [.deliverable, .ask, .decision, .edit])
        XCTAssertEqual(LanguageModelRun.Feature(rawValue: "edit"), .edit)
    }
}
