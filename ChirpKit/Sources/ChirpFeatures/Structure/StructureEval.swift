import ChirpCore
import ChirpText
import Foundation

// Plan 015 Step 8 (port of the owner's Needle Bench Eval view): synthetic cases with ground truth, scored with
// tool-shape accuracy, argument accuracy and a numeric hard-fail count, kept apart; exported as JSON and as a
// "Copy for LLM" Markdown digest. Every case is invented.

// MARK: - Cases

/// A call the ground truth expects. Numbers are the normalizer's display values ("142/88 mmHg", "10 mg").
public struct ExpectedCall: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: [String: String]

    public init(name: String, arguments: [String: String] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct SOAPEvalSentence: Codable, Sendable, Equatable {
    public var text: String
    /// Empty = nothing to record (the engine should abstain or answer `none`).
    public var expected: [ExpectedCall]
}

public struct SOAPEvalCase: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var sentences: [SOAPEvalSentence]
}

public struct SOAPEvalSet: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var catalog: String
    public var cases: [SOAPEvalCase]

    public static func bundled() throws -> SOAPEvalSet {
        guard let url = StructureCatalog.bundledURL("eval-soap-meds.v1") else {
            throw StructureCatalog.LoadError.missing("eval-soap-meds.v1")
        }
        return try JSONDecoder().decode(SOAPEvalSet.self, from: Data(contentsOf: url))
    }
}

public struct CommandEvalUtterance: Codable, Sendable, Equatable {
    public var text: String
    /// The command, or nil for dictated text.
    public var expected: String?
}

public struct CommandEvalSet: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var catalog: String
    public var utterances: [CommandEvalUtterance]

    public static func bundled() throws -> CommandEvalSet {
        guard let url = StructureCatalog.bundledURL("eval-dictation-commands.v1") else {
            throw StructureCatalog.LoadError.missing("eval-dictation-commands.v1")
        }
        return try JSONDecoder().decode(CommandEvalSet.self, from: Data(contentsOf: url))
    }
}

// MARK: - Scores

/// One predicted call after validation, as the scorer compares it.
public struct PredictedCall: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: [String: String]
    public var verdict: StructuredVerdict
    public var numericHardFail: Bool
    public var problems: [String]
}

public struct SOAPSentenceScore: Codable, Sendable, Equatable {
    public var caseID: String
    public var text: String
    /// What the engine read (tagged when the normalizer is on).
    public var input: String
    public var expected: [ExpectedCall]
    public var predicted: [PredictedCall]
    public var confidence: Double?
    public var seconds: Double
    public var error: String?
    public var toolShapeCorrect: Bool
    public var expectedArguments: Int
    public var matchedArguments: Int
    public var expectedFields: Int
    public var exactFields: Int
    public var numericHardFails: Int
}

public struct SOAPEvalSummary: Codable, Sendable, Equatable {
    public var cases: Int
    public var sentences: Int
    /// Sentences whose set of tools (ignoring `none`) equals the expected set.
    public var toolShapeAccuracy: Double
    /// Expected arguments reproduced exactly (numbers through the side table), over all expected arguments.
    public var argumentAccuracy: Double
    /// Expected calls reproduced with every argument right.
    public var fieldExactMatch: Double
    /// Numbers the engine copied wrong or that trace to nothing.
    public var numericHardFails: Int
    /// Predicted calls the gate sent to Needs review.
    public var needsReviewCount: Int
    public var meanSecondsPerSentence: Double
    public var scores: [SOAPSentenceScore]
}

public struct CommandUtteranceScore: Codable, Sendable, Equatable {
    public var text: String
    public var expected: String?
    /// The engine's first tool, before the gate (nil for an abstention or `none`).
    public var engineAnswer: String?
    public var confidence: Double?
    /// The engine's answer after the act threshold.
    public var gatedAnswer: String?
    /// What the dictation feature would do: a whole-sentence phrase **and** the gated engine agreeing.
    public var featureDecision: String?
    public var seconds: Double
}

public struct CommandEvalSummary: Codable, Sendable, Equatable {
    public var utterances: Int
    /// Gated engine answer equals the expected command (or nothing).
    public var engineAccuracy: Double
    public var ungatedEngineAccuracy: Double
    /// The shipped behavior (phrase + engine) equals the expected command (or nothing).
    public var featureAccuracy: Double
    /// Dictated text the feature would have treated as a command (must stay 0).
    public var falseCommands: Int
    public var meanSecondsPerUtterance: Double
    public var scores: [CommandUtteranceScore]
}

/// The exported report (`ichirp.structure-eval/v1`).
public struct StructureEvalReport: Codable, Sendable, Equatable {
    public var schema = "ichirp.structure-eval/v1"
    public var createdAt: Date
    public var appBuild: String
    public var engineID: String
    public var engineName: String
    public var isStub: Bool
    public var modelSHA256: String?
    /// e.g. "needle-rs 4de50494"; nil for the STUB.
    public var runtime: String?
    public var actThreshold: Double
    public var provisionalThreshold: Double
    public var normalizer: Bool
    public var soap: SOAPEvalSummary
    public var commands: CommandEvalSummary

    public init(
        createdAt: Date, appBuild: String, engineID: String, engineName: String, isStub: Bool, modelSHA256: String?,
        runtime: String?, actThreshold: Double, provisionalThreshold: Double, normalizer: Bool,
        soap: SOAPEvalSummary, commands: CommandEvalSummary
    ) {
        self.createdAt = createdAt
        self.appBuild = appBuild
        self.engineID = engineID
        self.engineName = engineName
        self.isStub = isStub
        self.modelSHA256 = modelSHA256
        self.runtime = runtime
        self.actThreshold = actThreshold
        self.provisionalThreshold = provisionalThreshold
        self.normalizer = normalizer
        self.soap = soap
        self.commands = commands
    }

    public var catalogVersion: String { "soap-meds.v1+dictation-commands.v1" }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// "Copy for LLM": one self-describing Markdown digest.
    public var markdown: String {
        func pct(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
        var lines: [String] = [
            "# Parakeet structure-model eval (\(engineName)\(isStub ? ", STUB: rules, not a model" : ""))",
            "",
            "- Schema: `\(schema)`; created \(ISO8601DateFormatter().string(from: createdAt)); app \(appBuild)",
            "- Engine: `\(engineID)`" + (modelSHA256.map { "; model SHA-256 `\($0)`" } ?? "")
                + (runtime.map { "; runtime \($0)" } ?? ""),
            "- Catalogs: `soap-meds.v1`, `dictation-commands.v1`; gate act \(actThreshold), provisional "
                + "\(provisionalThreshold); normalizer \(normalizer ? "on" : "off")",
            "- Cases: invented, synthetic; no real patients.",
            "",
            "## SOAP fields and medications (\(soap.cases) encounters, \(soap.sentences) sentences)",
            "",
            "| Metric | Value |",
            "|---|---|",
            "| Tool-shape accuracy | \(pct(soap.toolShapeAccuracy)) |",
            "| Argument accuracy | \(pct(soap.argumentAccuracy)) |",
            "| Field exact match | \(pct(soap.fieldExactMatch)) |",
            "| Numeric hard fails | \(soap.numericHardFails) |",
            "| Calls sent to Needs review | \(soap.needsReviewCount) |",
            String(format: "| Mean seconds per sentence | %.2f |", soap.meanSecondsPerSentence),
            "",
            "## Dictation commands (\(commands.utterances) utterances)",
            "",
            "| Metric | Value |",
            "|---|---|",
            "| Engine accuracy (gated) | \(pct(commands.engineAccuracy)) |",
            "| Engine accuracy (ungated) | \(pct(commands.ungatedEngineAccuracy)) |",
            "| Feature accuracy (phrase + engine) | \(pct(commands.featureAccuracy)) |",
            "| Dictation eaten as a command | \(commands.falseCommands) |",
            String(format: "| Mean seconds per utterance | %.2f |", commands.meanSecondsPerUtterance),
            "",
            "## SOAP misses",
            "",
            "| Case | Sentence | Expected | Predicted |",
            "|---|---|---|---|",
        ]
        func describe(_ name: String, _ arguments: [String: String]) -> String {
            let args = arguments.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            return args.isEmpty ? name : "\(name)(\(args))"
        }
        for score in soap.scores where !score.toolShapeCorrect || score.matchedArguments < score.expectedArguments {
            let expected = score.expected.map { describe($0.name, $0.arguments) }.joined(separator: "; ")
            let predicted =
                score.error
                ?? score.predicted.map { describe($0.name, $0.arguments) }.joined(separator: "; ")
            lines.append(
                "| \(score.caseID) | \(score.text.replacingOccurrences(of: "|", with: "/")) | \(expected.isEmpty ? "—" : expected) | \(predicted.isEmpty ? "—" : predicted.replacingOccurrences(of: "|", with: "/")) |"
            )
        }
        lines += [
            "", "## Command misses", "", "| Utterance | Expected | Engine | Confidence | Feature |",
            "|---|---|---|---|---|",
        ]
        for score in commands.scores
        where score.featureDecision != score.expected || score.gatedAnswer != score.expected {
            let confidence = score.confidence.map { String(format: "%.2f", $0) } ?? "—"
            lines.append(
                "| \(score.text) | \(score.expected ?? "—") | \(score.engineAnswer ?? "—") | \(confidence) | \(score.featureDecision ?? "—") |"
            )
        }
        lines += [
            "",
            "Reproduce: Settings → Structure models → Eval, same engine and thresholds (or "
                + "`CHIRP_NEEDLE_TESTS=1 swift test --package-path ChirpKit --filter NeedleEvalRealTests`).",
        ]
        return lines.joined(separator: "\n")
    }
}

// MARK: - Scoring

public enum StructureEvalScorer {
    /// Scores one sentence's validated calls against the ground truth.
    public static func score(
        caseID: String, sentence: SOAPEvalSentence, input: String, predicted: [PredictedCall], confidence: Double?,
        seconds: Double, error: String?
    ) -> SOAPSentenceScore {
        let recorded = predicted.filter { $0.name != "none" }
        let shapeCorrect = recorded.map(\.name).sorted() == sentence.expected.map(\.name).sorted()
        var used = Set<Int>()
        var expectedArguments = 0
        var matchedArguments = 0
        var exactFields = 0
        var hardFails = recorded.filter(\.numericHardFail).count
        for expected in sentence.expected {
            expectedArguments += expected.arguments.count
            let candidates = recorded.indices.filter { !used.contains($0) && recorded[$0].name == expected.name }
            guard
                let best = candidates.max(by: {
                    matches(expected, recorded[$0]) < matches(expected, recorded[$1])
                })
            else { continue }
            used.insert(best)
            let matched = matches(expected, recorded[best])
            matchedArguments += matched
            if matched == expected.arguments.count { exactFields += 1 }
            for key in numericKeys {
                if let want = expected.arguments[key], let got = recorded[best].arguments[key],
                    normalized(want) != normalized(got), !recorded[best].numericHardFail
                {
                    hardFails += 1
                }
            }
        }
        return SOAPSentenceScore(
            caseID: caseID, text: sentence.text, input: input, expected: sentence.expected, predicted: predicted,
            confidence: confidence, seconds: seconds, error: error, toolShapeCorrect: shapeCorrect,
            expectedArguments: expectedArguments, matchedArguments: matchedArguments,
            expectedFields: sentence.expected.count, exactFields: exactFields, numericHardFails: hardFails)
    }

    static let numericKeys = ["value", "dose", "frequency"]

    /// How many of the expected arguments the prediction reproduces.
    static func matches(_ expected: ExpectedCall, _ predicted: PredictedCall) -> Int {
        expected.arguments.filter { key, rawWant in
            guard let rawGot = predicted.arguments[key] else { return false }
            let want = normalized(rawWant)
            let got = normalized(rawGot)
            switch key {
            case "text", "drug", "substance", "reaction":
                return got == want || (got.count >= 3 && got.contains(want))
            default:
                return got == want
            }
        }.count
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    public static func summarize(_ scores: [SOAPSentenceScore], cases: Int) -> SOAPEvalSummary {
        let sentences = max(scores.count, 1)
        let expectedArguments = scores.map(\.expectedArguments).reduce(0, +)
        let expectedFields = scores.map(\.expectedFields).reduce(0, +)
        return SOAPEvalSummary(
            cases: cases, sentences: scores.count,
            toolShapeAccuracy: Double(scores.filter(\.toolShapeCorrect).count) / Double(sentences),
            argumentAccuracy: expectedArguments == 0
                ? 0 : Double(scores.map(\.matchedArguments).reduce(0, +)) / Double(expectedArguments),
            fieldExactMatch: expectedFields == 0
                ? 0 : Double(scores.map(\.exactFields).reduce(0, +)) / Double(expectedFields),
            numericHardFails: scores.map(\.numericHardFails).reduce(0, +),
            needsReviewCount: scores.flatMap(\.predicted).filter { $0.name != "none" && $0.verdict == .needsReview }
                .count,
            meanSecondsPerSentence: scores.map(\.seconds).reduce(0, +) / Double(sentences), scores: scores)
    }

    public static func summarize(_ scores: [CommandUtteranceScore]) -> CommandEvalSummary {
        let count = max(scores.count, 1)
        return CommandEvalSummary(
            utterances: scores.count,
            engineAccuracy: Double(scores.filter { $0.gatedAnswer == $0.expected }.count) / Double(count),
            ungatedEngineAccuracy: Double(scores.filter { $0.engineAnswer == $0.expected }.count) / Double(count),
            featureAccuracy: Double(scores.filter { $0.featureDecision == $0.expected }.count) / Double(count),
            falseCommands: scores.filter { $0.expected == nil && $0.featureDecision != nil }.count,
            meanSecondsPerUtterance: scores.map(\.seconds).reduce(0, +) / Double(count), scores: scores)
    }

    /// A validated call as the scorer reads it: tag arguments by their display value. `problems` are the reasons the
    /// gate's review gave (the validator's own when nil).
    static func predicted(_ call: ValidatedCall, verdict: StructuredVerdict, problems: [String]? = nil)
        -> PredictedCall
    {
        var arguments: [String: String] = [:]
        for (key, value) in call.arguments {
            if let display = value["display"]?.stringValue {
                arguments[key] = display
            } else if let unresolved = value["unresolved"]?.stringValue {
                arguments[key] = "?" + unresolved
            } else if let text = value.stringValue {
                arguments[key] = text
            }
        }
        return PredictedCall(
            name: call.tool, arguments: arguments, verdict: verdict, numericHardFail: call.numericHardFail,
            problems: problems ?? call.problems)
    }
}

// MARK: - Runner

/// Runs one engine over both synthetic sets. The SOAP sentences go through the same normalizer, validator and gate as
/// the Extract fields screen; commands through the same phrase check and gate as dictation.
public struct StructureEvalRunner: Sendable {
    let engine: any StructureModel
    let gate: StructuredResultGate
    let normalizer: Bool

    public init(engine: any StructureModel, gate: StructuredResultGate, normalizer: Bool = true) {
        self.engine = engine
        self.gate = gate
        self.normalizer = normalizer
    }

    public func run(
        soap: SOAPEvalSet, commands: CommandEvalSet,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> (soap: SOAPEvalSummary, commands: CommandEvalSummary, modelSHA256: String?) {
        let total = soap.cases.map(\.sentences.count).reduce(0, +) + commands.utterances.count
        var done = 0
        var modelSHA256: String?
        var soapScores: [SOAPSentenceScore] = []
        let catalog = StructureCatalog.soapMeds
        for evalCase in soap.cases {
            var answered: [SentenceCalls] = []
            var asked: [(input: String, confidence: Double?, seconds: Double, error: String?)] = []
            for sentence in evalCase.sentences {
                let normalized = NumericNormalizer.normalize(sentence.text)
                let input = normalizer ? normalized.tagged : sentence.text
                let started = Date()
                var calls: [ValidatedCall] = []
                var confidence: Double?
                var failure: String?
                do {
                    let output = try await engine.extract(
                        jsonSchema: catalog.toolsJSON, from: input, privacyClass: .clinical)
                    confidence = output.confidence
                    modelSHA256 = output.modelSHA256 ?? modelSHA256
                    if !output.isAbstention {
                        if let parsed = StructuredCall.parseArray(output.json) {
                            calls = StructuredCallValidator.validate(parsed, sentence: normalized, catalog: catalog)
                        } else {
                            failure = "not a call array: \(output.json.prefix(80))"
                        }
                    }
                } catch {
                    failure = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
                }
                answered.append(SentenceCalls(sentence: normalized, calls: calls, confidence: confidence ?? 0))
                asked.append((input, confidence, Date().timeIntervalSince(started), failure))
                done += 1
                progress(done, total)
            }
            // Round 3: the same review as the Extract fields screen (allow-list proof, thresholds, STUB cap, a
            // correction in the next sentence), within one encounter.
            for (index, reviewed) in gate.review(answered, engineID: engine.descriptor.id).enumerated() {
                soapScores.append(
                    StructureEvalScorer.score(
                        caseID: evalCase.id, sentence: evalCase.sentences[index], input: asked[index].input,
                        predicted: reviewed.map {
                            StructureEvalScorer.predicted($0.call, verdict: $0.verdict, problems: $0.reasons)
                        },
                        confidence: asked[index].confidence, seconds: asked[index].seconds, error: asked[index].error))
            }
        }
        let resolver = VoiceCommandResolver(engine: engine, gate: gate)
        var commandScores: [CommandUtteranceScore] = []
        for utterance in commands.utterances {
            let started = Date()
            var answer: String?
            var confidence: Double?
            if let output = try? await engine.extract(
                jsonSchema: StructureCatalog.dictationCommands.toolsJSON, from: utterance.text,
                privacyClass: .personal)
            {
                confidence = output.confidence
                modelSHA256 = output.modelSHA256 ?? modelSHA256
                answer = StructuredCall.parseArray(output.json)?.first.map(\.name).flatMap { $0 == "none" ? nil : $0 }
            }
            let gated = confidence.map { gate.verdict(confidence: $0) == .act } == true ? answer : nil
            let candidate = resolver.candidate(for: utterance.text)
            commandScores.append(
                CommandUtteranceScore(
                    text: utterance.text, expected: utterance.expected, engineAnswer: answer, confidence: confidence,
                    gatedAnswer: gated, featureDecision: candidate != nil && gated == candidate ? candidate : nil,
                    seconds: Date().timeIntervalSince(started)))
            done += 1
            progress(done, total)
        }
        return (
            StructureEvalScorer.summarize(soapScores, cases: soap.cases.count),
            StructureEvalScorer.summarize(commandScores), modelSHA256
        )
    }
}
