// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/VoiceControl/JevDecisionClient.swift @ bbae9e0e
// Changes: only the wire types (`Question`, `Request`, `Response`, `Answer`) and `validate`, plus the response-level
// checks from upstream `send` (model echo, answer keys equal question keys) and its size and option caps. The state is
// ChirpCore's `DecisionState` instead of voice-control snapshots; the response's documented `usage` object (TypeSafe
// API reference, read 2026-09-22) is decoded as optional token counts. Validation rules are unchanged.

import ChirpCore
import Foundation

/// The TypeSafe `POST /v1/systemone` wire protocol, choice questions only.
enum JevWire {
    /// Upstream's caps: an encoded request over this is never sent; a response over this is rejected.
    static let requestByteLimit = 120_000
    static let responseByteLimit = 1_000_000

    struct Question: Encodable, Equatable {
        var type = "choice"
        let instructions: String
        let criteria: [String: String]
    }

    struct Request: Encodable {
        let model: String
        let state: DecisionState
        let questions: [String: Question]
    }

    struct Response: Decodable {
        let model: String
        let answers: [String: Answer]
        /// Documented but optional here: a missing or odd `usage` never fails a valid decision.
        let usage: Usage?

        private enum CodingKeys: String, CodingKey { case model, answers, usage }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try container.decode(String.self, forKey: .model)
            answers = try container.decode([String: Answer].self, forKey: .answers)
            usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
        }
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct Answer: Decodable {
        let type: String
        let choice: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    /// The wire body for `request` against `model`.
    static func request(for request: DecisionRequest, model: String) -> Request {
        Request(
            model: model, state: request.state,
            questions: Dictionary(
                uniqueKeysWithValues: request.questions.map {
                    ($0.id, Question(instructions: $0.instructions, criteria: $0.options))
                }))
    }

    /// Upstream `validate`, unchanged: `choice` type; the choice is offered; the probability keys are exactly the
    /// offered ids; every probability and the confidence are finite and in 0…1; they sum to 1 within 0.01; the choice
    /// is the argmax.
    static func isValid(_ answer: Answer, offered: Set<String>) -> Bool {
        guard answer.type == "choice", offered.contains(answer.choice), Set(answer.probabilities.keys) == offered,
            answer.confidence.isFinite, (0...1).contains(answer.confidence),
            answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            abs(answer.probabilities.values.reduce(0, +) - 1) <= 0.010001,
            let chosen = answer.probabilities[answer.choice],
            answer.probabilities.values.allSatisfy({ $0 <= chosen + 0.000001 })
        else { return false }
        return true
    }

    /// Upstream `send`'s response checks: the model that answered is the one asked, every question has exactly one
    /// answer, and every answer is valid for the options its question offered. nil means "apply nothing".
    static func validatedAnswers(
        _ response: Response,
        requestedModel: String,
        questions: [DecisionQuestion]
    ) -> [String: DecisionAnswer]? {
        guard response.model == requestedModel, Set(response.answers.keys) == Set(questions.map(\.id)) else {
            return nil
        }
        var answers: [String: DecisionAnswer] = [:]
        for question in questions {
            guard let answer = response.answers[question.id], isValid(answer, offered: Set(question.options.keys))
            else { return nil }
            answers[question.id] = DecisionAnswer(
                questionID: question.id, choice: answer.choice, confidence: answer.confidence,
                probabilities: answer.probabilities)
        }
        return answers
    }
}
