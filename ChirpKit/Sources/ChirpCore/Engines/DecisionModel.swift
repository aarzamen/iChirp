import Foundation

// M6a contract: spec/contracts/decision-model-plugin-v1.md. Conformer: ChirpEngineJev (plan 021).

/// One typed question: choose exactly one of `options` (option id → one-line description). `choice` only in v1; a v2
/// can add score and yes/no questions additively.
public struct DecisionQuestion: Sendable, Equatable, Codable {
    /// Fewest options a question may offer.
    public static let minimumOptions = 2
    /// Most options a question may offer (the provider documents 255; iChirp keeps upstream's 250).
    public static let maximumOptions = 250
    /// Option ids reserved for a caller's own fallbacks (upstream MacParakeet). A recipe may add one deliberately,
    /// only when it defines what the UI does with it.
    public static let reservedOptionIDs: Set<String> = ["none", "clarify", "insufficient_evidence"]

    /// The caller's key for this question; the answer comes back under it. Never shown to the model.
    public var id: String
    public var instructions: String
    /// Option id → description. 2…250 entries.
    public var options: [String: String]

    public init(id: String, instructions: String, options: [String: String]) {
        self.id = id
        self.instructions = instructions
        self.options = options
    }

    /// Checks the shape before anything is sent: a non-empty id, 2…250 options, no empty option id.
    public func validate() throws(DecisionRequestError) {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyQuestionID }
        guard options.count >= Self.minimumOptions else { throw .tooFewOptions(questionID: id) }
        guard options.count <= Self.maximumOptions else { throw .tooManyOptions(questionID: id) }
        guard !options.keys.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw .emptyOptionID(questionID: id)
        }
    }
}

/// What the model sees. `text` is an excerpt the caller already windowed; `facts` are short, content-free strings
/// (duration, speaker count, source kind). Encoded as the wire `state` object.
public struct DecisionState: Sendable, Equatable, Codable {
    public var text: String
    public var facts: [String: String]

    public init(text: String, facts: [String: String] = [:]) {
        self.text = text
        self.facts = facts
    }
}

/// One decision call: a state and the questions to answer about it.
public struct DecisionRequest: Sendable, Equatable, Codable {
    public var state: DecisionState
    public var questions: [DecisionQuestion]
    /// Routing input, as on `GenerationRequest`: the caller must only hand this request to an engine
    /// `PrivacyRoutingPolicy` allows. Never sent.
    public var privacyClass: PrivacyClass

    public init(state: DecisionState, questions: [DecisionQuestion], privacyClass: PrivacyClass) {
        self.state = state
        self.questions = questions
        self.privacyClass = privacyClass
    }

    /// At least one question, unique question ids, and every question valid.
    public func validate() throws(DecisionRequestError) {
        guard !questions.isEmpty else { throw .noQuestions }
        guard Set(questions.map(\.id)).count == questions.count else { throw .duplicateQuestionID }
        for question in questions { try question.validate() }
    }
}

/// The model's answer to one question: the chosen option, the model's confidence (0…1, derived by the provider from
/// how the probabilities are spread; not the chosen option's probability) and the probability of every offered option.
public struct DecisionAnswer: Sendable, Equatable, Codable {
    public var questionID: String
    public var choice: String
    public var confidence: Double
    public var probabilities: [String: Double]

    public init(questionID: String, choice: String, confidence: Double, probabilities: [String: Double]) {
        self.questionID = questionID
        self.choice = choice
        self.confidence = confidence
        self.probabilities = probabilities
    }

    /// Options from most to least likely; ties by option id, so the order is stable.
    public var rankedOptions: [(id: String, probability: Double)] {
        probabilities.map { (id: $0.key, probability: $0.value) }
            .sorted { $0.probability != $1.probability ? $0.probability > $1.probability : $0.id < $1.id }
    }
}

/// A validated decision: every question answered, every answer checked against the options it was offered.
public struct DecisionResult: Sendable, Equatable, Codable {
    /// The versioned model id that answered (equals the requested one; engines reject anything else).
    public var model: String
    /// Question id → answer.
    public var answers: [String: DecisionAnswer]
    public var latencyMs: Int
    /// Size of the encoded request body; the cost estimate when the provider reports no token count.
    public var requestBytes: Int
    /// Token counts the provider reported, when it did. Metadata only.
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(
        model: String,
        answers: [String: DecisionAnswer],
        latencyMs: Int,
        requestBytes: Int,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.model = model
        self.answers = answers
        self.latencyMs = latencyMs
        self.requestBytes = requestBytes
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A malformed request: a caller bug caught before anything is sent. Content-free by construction (ids only).
public enum DecisionRequestError: Error, Sendable, Equatable, LocalizedError {
    case noQuestions
    case duplicateQuestionID
    case emptyQuestionID
    case emptyOptionID(questionID: String)
    case tooFewOptions(questionID: String)
    case tooManyOptions(questionID: String)

    /// A stable, content-free name for logs and the run ledger.
    public var kindName: String {
        switch self {
        case .noQuestions: "decision_no_questions"
        case .duplicateQuestionID: "decision_duplicate_question_id"
        case .emptyQuestionID: "decision_empty_question_id"
        case .emptyOptionID: "decision_empty_option_id"
        case .tooFewOptions: "decision_too_few_options"
        case .tooManyOptions: "decision_too_many_options"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noQuestions: "The decision request has no questions."
        case .duplicateQuestionID: "Two questions in the decision request share an id."
        case .emptyQuestionID: "A question in the decision request has no id."
        case .emptyOptionID(let id): "Question \(id) offers an option without an id."
        case .tooFewOptions(let id):
            "Question \(id) offers fewer than \(DecisionQuestion.minimumOptions) options."
        case .tooManyOptions(let id):
            "Question \(id) offers more than \(DecisionQuestion.maximumOptions) options."
        }
    }
}

/// A typed-decision engine plug-in ("System One": choose one of N options with calibrated probabilities).
/// Contract: `spec/contracts/decision-model-plugin-v1.md`.
///
/// Engines do not enforce privacy; the caller routes every request through `PrivacyRoutingPolicy` first
/// (ChirpFeatures' `DecisionService` is the only caller that hands transcript text to a `DecisionModel`).
public protocol DecisionModel: Sendable {
    var descriptor: EngineDescriptor { get }
    /// The lowercased host every request goes to (engines refuse redirects); nil on device.
    var endpointHost: String? { get }
    /// Checked before any content is handed over. Never touches the network.
    func availability() async -> LanguageModelAvailability
    /// One round trip. Throws `DecisionRequestError` for a malformed request (nothing sent), `LanguageModelError`
    /// for everything else, and `CancellationError` when cancelled. Every answer is validated before it returns.
    func decide(_ request: DecisionRequest) async throws -> DecisionResult
}
