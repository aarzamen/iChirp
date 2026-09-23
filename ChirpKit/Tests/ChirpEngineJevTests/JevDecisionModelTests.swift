import ChirpCore
import Foundation
import XCTest

@testable import ChirpEngineJev

/// `JevDecisionModel` against a `URLProtocol` stub: nothing leaves the Mac. Every text here is synthetic.
final class JevDecisionModelTests: XCTestCase {
    private let key = SecretValue("ts-TESTKEY-0123456789abcdefghij")
    private let base = URL(string: "https://api.typesafe.ai")!

    private func engine(key: SecretValue? = nil, base: URL? = nil, model: String = "jev-1.13.0") -> JevDecisionModel {
        JevDecisionModels.make(
            apiKey: key, baseURL: base ?? self.base, model: model,
            sessionConfiguration: JevStubURLProtocol.configuration())
    }

    private let kindQuestion = DecisionQuestion(
        id: "kind", instructions: "What kind of recording is this?",
        options: ["meeting": "Several people discuss work.", "dictation": "One person dictates a note."])

    private func request(text: String = "Synthetic: the team agreed to ship on Friday.") -> DecisionRequest {
        DecisionRequest(
            state: DecisionState(text: text, facts: ["speaker_count": "2", "source": "audio"]),
            questions: [kindQuestion], privacyClass: .personal)
    }

    private static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func answerBody(
        model: String = "jev-1.13.0",
        answers: [String: Any]? = nil,
        usage: Any? = ["input_tokens": 312, "output_tokens": 20]
    ) -> JevStubResponse {
        var object: [String: Any] = [
            "model": model,
            "answers": answers ?? [
                "kind": [
                    "type": "choice", "choice": "meeting", "probabilities": ["meeting": 0.9, "dictation": 0.1],
                    "confidence": 0.8,
                ]
            ],
        ]
        if let usage { object["usage"] = usage }
        return .body(json(object), contentType: "application/json")
    }

    private func expectError(
        _ engine: JevDecisionModel, _ request: DecisionRequest, file: StaticString = #filePath, line: UInt = #line
    ) async -> Error? {
        do {
            _ = try await engine.decide(request)
            XCTFail("expected an error", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Request shape

    func testRequestURLMethodHeadersAndBodyShape() async throws {
        JevStubURLProtocol.reset { _ in Self.answerBody() }
        let result = try await engine(key: key).decide(request())

        XCTAssertEqual(JevStubURLProtocol.requests.count, 1)
        let sent = try XCTUnwrap(JevStubURLProtocol.requests.first)
        XCTAssertEqual(sent.url.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer ts-TESTKEY-0123456789abcdefghij")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(sent.json)
        XCTAssertEqual(Set(body.keys), ["model", "state", "questions"], "privacyClass is never sent")
        XCTAssertEqual(body["model"] as? String, "jev-1.13.0")
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(state["text"] as? String, "Synthetic: the team agreed to ship on Friday.")
        XCTAssertEqual(state["facts"] as? [String: String], ["speaker_count": "2", "source": "audio"])
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        let kind = try XCTUnwrap(questions["kind"] as? [String: Any])
        XCTAssertEqual(kind["type"] as? String, "choice")
        XCTAssertEqual(kind["instructions"] as? String, "What kind of recording is this?")
        XCTAssertEqual(kind["criteria"] as? [String: String], kindQuestion.options)
        XCTAssertEqual(Set(kind.keys), ["type", "instructions", "criteria"], "the question id is only the map key")

        XCTAssertEqual(result.model, "jev-1.13.0")
        XCTAssertEqual(result.answers["kind"]?.choice, "meeting")
        XCTAssertEqual(result.answers["kind"]?.confidence, 0.8)
        XCTAssertEqual(result.answers["kind"]?.probabilities, ["meeting": 0.9, "dictation": 0.1])
        XCTAssertEqual(result.requestBytes, sent.body.count)
        XCTAssertEqual(result.inputTokens, 312)
        XCTAssertEqual(result.outputTokens, 20)
        XCTAssertGreaterThanOrEqual(result.latencyMs, 0)
    }

    func testUsageIsOptionalAndNeverFailsAValidDecision() async throws {
        JevStubURLProtocol.reset { _ in Self.answerBody(usage: nil) }
        var result = try await engine(key: key).decide(request())
        XCTAssertNil(result.inputTokens)
        JevStubURLProtocol.reset { _ in Self.answerBody(usage: "not an object") }
        result = try await engine(key: key).decide(request())
        XCTAssertEqual(result.answers["kind"]?.choice, "meeting")
        XCTAssertNil(result.outputTokens)
    }

    // MARK: - Validation (upstream `validate` and `send`)

    func testEveryValidationBranchRejectsABadAnswer() async throws {
        func answer(
            type: String = "choice", choice: String = "meeting", probabilities: [String: Double]? = nil,
            confidence: Double = 0.8
        ) -> [String: Any] {
            [
                "type": type, "choice": choice,
                "probabilities": probabilities ?? ["meeting": 0.9, "dictation": 0.1], "confidence": confidence,
            ]
        }
        let cases: [(String, JevStubResponse)] = [
            ("wrong answer type", Self.answerBody(answers: ["kind": answer(type: "noul")])),
            ("choice not offered", Self.answerBody(answers: ["kind": answer(choice: "lecture")])),
            ("missing probability key", Self.answerBody(answers: ["kind": answer(probabilities: ["meeting": 1.0])])),
            (
                "extra probability key",
                Self.answerBody(answers: ["kind": answer(probabilities: ["meeting": 0.8, "dictation": 0.1, "x": 0.1])])
            ),
            (
                "probability above 1",
                Self.answerBody(answers: ["kind": answer(probabilities: ["meeting": 1.5, "dictation": -0.5])])
            ),
            (
                "probabilities do not sum to 1",
                Self.answerBody(answers: ["kind": answer(probabilities: ["meeting": 0.7, "dictation": 0.1])])
            ),
            (
                "choice is not the argmax",
                Self.answerBody(answers: ["kind": answer(probabilities: ["meeting": 0.3, "dictation": 0.7])])
            ),
            ("confidence above 1", Self.answerBody(answers: ["kind": answer(confidence: 1.2)])),
            ("confidence below 0", Self.answerBody(answers: ["kind": answer(confidence: -0.1)])),
            ("another model answered", Self.answerBody(model: "jev-9.9.9")),
            ("an alias answered", Self.answerBody(model: "jev-latest")),
            ("missing answer", Self.answerBody(answers: [:])),
            ("extra answer", Self.answerBody(answers: ["kind": answer(), "other": answer()])),
            ("not JSON", .body("<html>oops</html>", contentType: "text/html")),
            ("wrong JSON", .body(#"{"model": "jev-1.13.0"}"#, contentType: "application/json")),
            (
                "oversize response",
                .body(
                    #"{"model":"jev-1.13.0","pad":""# + String(repeating: "x", count: 1_000_001) + #""}"#,
                    contentType: "application/json")
            ),
        ]
        for (name, response) in cases {
            JevStubURLProtocol.reset { _ in response }
            let error = await expectError(engine(key: key), request())
            XCTAssertEqual(error as? LanguageModelError, .invalidResponse, name)
        }
    }

    func testMalformedRequestFailsBeforeSending() async {
        JevStubURLProtocol.reset { _ in Self.answerBody() }
        let one = DecisionRequest(
            state: DecisionState(text: "Synthetic."),
            questions: [DecisionQuestion(id: "q", instructions: "?", options: ["a": "A"])], privacyClass: .general)
        let error = await expectError(engine(key: key), one)
        XCTAssertEqual(error as? DecisionRequestError, .tooFewOptions(questionID: "q"))
        XCTAssertEqual(JevStubURLProtocol.requests.count, 0)
    }

    // MARK: - Status mapping

    func testStatusesMapOntoLanguageModelErrors() async {
        let expectations: [(Int, (LanguageModelError) -> Bool)] = [
            (401, { if case .authenticationFailed = $0 { true } else { false } }),
            (403, { if case .authenticationFailed = $0 { true } else { false } }),
            (429, { $0 == .rateLimited }),
            (413, { $0 == .contextTooLong }),
            (422, { if case .providerError = $0 { true } else { false } }),
            (500, { if case .providerError = $0 { true } else { false } }),
            (529, { if case .providerError = $0 { true } else { false } }),
        ]
        for (status, matches) in expectations {
            JevStubURLProtocol.reset { _ in
                .body(#"{"detail": "synthetic failure"}"#, status: status, contentType: "application/json")
            }
            let error = await expectError(engine(key: key), request())
            let mapped = error as? LanguageModelError
            XCTAssertTrue(mapped.map(matches) ?? false, "HTTP \(status) → \(String(describing: error))")
        }
    }

    func testRedirectsAreRefusedAndNothingIsForwarded() async {
        JevStubURLProtocol.reset { request in
            if request.url.host == "api.typesafe.ai" {
                return JevStubResponse(redirectTo: URL(string: "https://collector.example.com/steal")!)
            }
            return Self.answerBody()
        }
        let error = await expectError(engine(key: key), request())
        XCTAssertEqual(error as? LanguageModelError, .redirectRefused)
        XCTAssertEqual(JevStubURLProtocol.requests.map(\.url.host), ["api.typesafe.ai"], "the body never reaches the target")
    }

    // MARK: - Nothing sent

    func testOversizeRequestThrowsContextTooLongBeforeAnyRequest() async {
        JevStubURLProtocol.reset { _ in Self.answerBody() }
        let error = await expectError(engine(key: key), request(text: String(repeating: "synthetic ", count: 13_000)))
        XCTAssertEqual(error as? LanguageModelError, .contextTooLong)
        XCTAssertEqual(JevStubURLProtocol.requests.count, 0)
    }

    func testMissingKeyIsNotConfiguredAndSendsNothing() async {
        JevStubURLProtocol.reset { _ in Self.answerBody() }
        for missing in [nil, SecretValue("")] {
            let jev = engine(key: missing)
            guard case .unavailable(.notConfigured) = await jev.availability() else {
                return XCTFail("a missing key must make Jev notConfigured")
            }
            let error = await expectError(jev, request())
            guard case .unavailable(.notConfigured)? = error as? LanguageModelError else {
                return XCTFail("\(String(describing: error))")
            }
        }
        XCTAssertEqual(JevStubURLProtocol.requests.count, 0)
    }

    func testAddressRules() async {
        JevStubURLProtocol.reset { _ in Self.answerBody() }
        let insecure = engine(key: key, base: URL(string: "http://api.typesafe.ai")!)
        guard case .unavailable(.notConfigured) = await insecure.availability() else {
            return XCTFail("plain http to an internet host is refused")
        }
        _ = await expectError(insecure, request())
        XCTAssertEqual(JevStubURLProtocol.requests.count, 0)
        XCTAssertNotNil(JevDecisionModels.problem(with: URL(string: "https://user:pw@api.typesafe.ai")!))
        XCTAssertNil(JevDecisionModels.problem(with: URL(string: "http://127.0.0.1:11998")!), "the DEBUG stub")

        let stub = engine(key: key, base: URL(string: "http://127.0.0.1:11998")!)
        XCTAssertEqual(stub.endpointHost, "127.0.0.1")
        XCTAssertEqual(stub.descriptor.locality, .cloud, "routing stays strict even against the stub")
        let result = try? await stub.decide(request())
        XCTAssertEqual(result?.answers["kind"]?.choice, "meeting")
        XCTAssertEqual(JevStubURLProtocol.requests.first?.url.absoluteString, "http://127.0.0.1:11998/v1/systemone")
    }

    func testTheKeyNeverAppearsInDescriptionsOrErrors() async {
        let jev = engine(key: key)
        var dumped = ""
        dump(jev, to: &dumped)
        for text in [String(describing: jev), String(reflecting: jev), dumped] {
            XCTAssertFalse(text.contains(key.reveal()), text)
        }

        JevStubURLProtocol.reset { _ in
            .body(
                #"{"error": {"message": "bad key ts-TESTKEY-0123456789abcdefghij (Bearer ts-TESTKEY-0123456789abcdefghij)"}}"#,
                status: 401, contentType: "application/json")
        }
        let error = await expectError(jev, request())
        XCTAssertTrue(error is LanguageModelError)
        let text = [error?.localizedDescription ?? "", String(describing: error as Any)].joined()
        XCTAssertFalse(text.contains(key.reveal()), text)
        XCTAssertTrue(text.contains("<api-key>") || text.contains("<token>"), text)
    }

    func testTestConnectionSendsOnlyTheFixedSyntheticSentence() async throws {
        JevStubURLProtocol.reset { _ in
            Self.answerBody(answers: [
                "connection_test": [
                    "type": "choice", "choice": "animal", "probabilities": ["animal": 1.0, "vehicle": 0.0],
                    "confidence": 1.0,
                ]
            ])
        }
        let result = try await engine(key: key).testConnection()
        XCTAssertEqual(result.answers["connection_test"]?.choice, "animal")
        let body = try XCTUnwrap(JevStubURLProtocol.requests.first?.json)
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(state["text"] as? String, "The quick brown fox jumps over the lazy dog.")
        XCTAssertEqual((state["facts"] as? [String: String]) ?? [:], [:])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(Array(questions.keys), ["connection_test"])
        XCTAssertEqual(
            questions["connection_test"]?["criteria"] as? [String: String],
            ["animal": "An animal", "vehicle": "A vehicle"])
    }

    // MARK: - Cancellation

    func testCancellationSurfacesAsCancellationError() async {
        // Before sending: a cancelled task sends nothing.
        JevStubURLProtocol.reset { _ in Self.answerBody() }
        let jev = engine(key: key)
        let request = request()
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await jev.decide(request)
        }
        do {
            _ = try await early.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(JevStubURLProtocol.requests.count, 0)

        // In flight: the server never answers; cancelling the task ends the request.
        JevStubURLProtocol.reset { _ in JevStubResponse(hangs: true) }
        let inFlight = Task { try await jev.decide(request) }
        for _ in 0..<200 where JevStubURLProtocol.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        inFlight.cancel()
        do {
            _ = try await inFlight.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - Registration

    func testDescriptorAndRegistration() {
        let jev = JevDecisionModels.make(apiKey: key, baseURL: URL(string: "https://API.TypeSafe.ai")!)
        XCTAssertEqual(jev.descriptor.id, "http.jev")
        XCTAssertEqual(jev.descriptor.kind, .structure)
        XCTAssertEqual(jev.descriptor.provider, "TypeSafe AI")
        XCTAssertEqual(jev.descriptor.displayName, "Jev")
        XCTAssertEqual(jev.descriptor.locality, .cloud)
        XCTAssertFalse(jev.descriptor.license.isEmpty)
        XCTAssertEqual(jev.endpointHost, "api.typesafe.ai")
        XCTAssertEqual(jev.model, "jev-1.13.0")
        XCTAssertEqual(JevDecisionModels.make(apiKey: nil).endpoint.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(JevDecisionModels.make(apiKey: nil, model: "  ").model, "jev-1.13.0")
    }
}
