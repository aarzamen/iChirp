import ChirpCore
import Foundation
import Synchronization

@testable import ChirpFeatures

/// A `DecisionModel` that records every request and answers each question with its first option (by id), or with a
/// scripted confidence / choice / error. Behaves like a conforming engine: cloud, `http.jev`, offline availability.
final class RecordingDecisionModel: DecisionModel {
    struct Script: Sendable {
        var confidence = 0.9
        /// Question id → option id to choose; default: the alphabetically first offered option.
        var choices: [String: String] = [:]
        var error: (any Error & Sendable)?
    }

    let descriptor = EngineDescriptor(
        id: "http.jev", kind: .structure, provider: "TypeSafe AI", displayName: "Jev", locality: .cloud,
        license: "Proprietary (TypeSafe API terms)")
    let endpointHost: String?
    private let hasKey: Bool
    private let state = Mutex<(requests: [DecisionRequest], script: Script)>(([], Script()))

    init(host: String = "api.typesafe.ai", hasKey: Bool = true) {
        endpointHost = host
        self.hasKey = hasKey
    }

    var requests: [DecisionRequest] { state.withLock { $0.requests } }
    var callCount: Int { requests.count }
    func script(_ change: (inout Script) -> Void) { state.withLock { change(&$0.script) } }

    func availability() async -> LanguageModelAvailability {
        hasKey ? .available : .unavailable(.notConfigured("add a Jev API key in Settings → Models"))
    }

    func decide(_ request: DecisionRequest) async throws -> DecisionResult {
        let script = state.withLock { state -> Script in
            state.requests.append(request)
            return state.script
        }
        if let error = script.error { throw error }
        var answers: [String: DecisionAnswer] = [:]
        for question in request.questions {
            let ids = question.options.keys.sorted()
            let choice = script.choices[question.id] ?? ids[0]
            let rest = (1 - 0.7) / Double(ids.count - 1)
            let probabilities = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0 == choice ? 0.7 : rest) })
            answers[question.id] = DecisionAnswer(
                questionID: question.id, choice: choice, confidence: script.confidence, probabilities: probabilities)
        }
        return DecisionResult(
            model: "jev-1.13.0", answers: answers, latencyMs: 42, requestBytes: 1_000, inputTokens: 250, outputTokens: 10)
    }
}

/// The app's factory stand-in: hands out one `RecordingDecisionModel` and records what it was asked for.
final class RecordingDecisionFactory: DecisionModelFactory {
    let engine: RecordingDecisionModel
    private let made = Mutex<[(settings: JevSettings, hadKey: Bool)]>([])
    private let tests = Mutex(0)

    init(engine: RecordingDecisionModel = RecordingDecisionModel()) {
        self.engine = engine
    }

    var makeCount: Int { made.withLock { $0.count } }
    var lastSettings: JevSettings? { made.withLock { $0.last?.settings } }
    var testCount: Int { tests.withLock { $0 } }

    func makeJev(settings: JevSettings, apiKey: SecretValue?) -> any DecisionModel {
        made.withLock { $0.append((settings, apiKey != nil)) }
        return engine
    }

    func testJevConnection(settings: JevSettings, apiKey: SecretValue?) async throws {
        tests.withLock { $0 += 1 }
        if apiKey == nil { throw LanguageModelError.unavailable(.notConfigured("add a Jev API key")) }
    }
}

/// In-memory `JevSettingsStoring`.
final class InMemoryJevSettings: JevSettingsStoring {
    private let state: Mutex<(settings: JevSettings, key: SecretValue?)>

    init(enabled: Bool = true, key: SecretValue? = SecretValue("ts-synthetic-key-0000")) {
        state = Mutex((JevSettings(isEnabled: enabled), key))
    }

    func load() -> JevSettings { state.withLock { $0.settings } }

    func save(_ settings: JevSettings, apiKey: APIKeyChange) throws {
        state.withLock {
            $0.settings = settings
            switch apiKey {
            case .keep: break
            case .set(let key): $0.key = key.isEmpty ? nil : key
            case .remove: $0.key = nil
            }
        }
    }

    func apiKey() throws -> SecretValue? { state.withLock { $0.key } }
}
