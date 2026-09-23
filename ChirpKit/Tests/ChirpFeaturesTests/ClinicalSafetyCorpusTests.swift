import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Round 3 (`fix/needle-allowlist`): the clinical-safety corpus (`Fixtures/clinical-safety-corpus.json`, every phrase
/// invented) through the real normalizer, STUB, validator, independent check, allow-list proof and gate, and through
/// the voice-command resolver.
///
/// The invariant is **never clean-and-wrong**: a medication or vital field is either clean (act or provisional, what
/// one tap accepts) and exactly equal to one of the entry's expected fields, or it is needs review. An entry with no
/// expected fields allows no clean medication or vital field at all.
final class ClinicalSafetyCorpusTests: XCTestCase {
    struct Corpus: Decodable {
        let entries: [Entry]
    }

    struct Entry: Decodable {
        let id: String
        let source: String
        let subset: String
        let text: String
        let expect: [Field]?
        let copied: String?
    }

    /// A medication or vital field as the invariant compares it.
    struct Field: Decodable, Equatable, CustomStringConvertible {
        var med: String?
        var dose: String?
        var freq: String?
        var route: String?
        var status: String?
        var vital: String?
        var value: String?

        /// Lowercased drug, "unknown" for a missing route.
        var normalized: Field {
            var field = self
            field.med = med?.lowercased()
            if med != nil, route == nil { field.route = "unknown" }
            return field
        }

        var description: String {
            if let vital { return "\(vital) \(value ?? "—")" }
            return [med, dose, freq, route, status].map { $0 ?? "—" }.joined(separator: " · ")
        }

        init(call: ValidatedCall) {
            if call.tool == "record_vital" {
                vital = call.arguments["kind"]?.stringValue
                value = call.arguments["value"]?["display"]?.stringValue
            } else {
                med = call.arguments["drug"]?.stringValue?.lowercased()
                dose = call.arguments["dose"]?["display"]?.stringValue
                freq = call.arguments["frequency"]?["display"]?.stringValue
                route = call.arguments["route"]?.stringValue ?? "unknown"
                status = call.arguments["status"]?.stringValue
            }
        }
    }

    static let clinicalTools: Set<String> = ["add_medication", "record_vital"]

    static func corpus() throws -> Corpus {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "clinical-safety-corpus", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    /// The entry's sentences, split as a run splits a transcript, then normalized.
    static func sentences(_ text: String) -> [NormalizedText] {
        let source = StructuredSourceText(text: text)
        return source.sentenceRanges().map { NumericNormalizer.normalize(source.substring($0)) }
    }

    static func allowed(_ field: Field, in entry: Entry) -> Bool {
        (entry.expect ?? []).contains { $0.normalized == field }
    }

    static func stubRun(_ sentences: [NormalizedText]) async -> [SentenceCalls] {
        var run: [SentenceCalls] = []
        for sentence in sentences {
            let outcome = await StructuredExtractionService.extract(
                sentence: sentence, engine: StubStructureModel(), catalog: .soapMeds, privacy: .clinical)
            run.append(SentenceCalls(sentence: sentence, calls: outcome.items, confidence: outcome.confidence))
        }
        return run
    }

    /// Clean before round 3: the validator's problems, the gate and the next-sentence correction, without the proof.
    static func cleanBefore(_ run: [SentenceCalls], sentence index: Int, call: ValidatedCall) -> Bool {
        let corrected =
            index + 1 < run.count
            && CrossSentenceCorrection.check(run[index + 1].sentence, tools: run[index + 1].calls.map(\.tool)) != nil
        return call.problems.isEmpty && !corrected
            && StructuredResultGate().verdict(confidence: run[index].confidence) != .needsReview
    }

    struct Tally {
        var fields = 0
        var cleanBefore = 0
        var cleanAfter = 0
        var expected = 0
        var expectedClean = 0

        func line(_ name: String) -> String {
            func pct(_ part: Int, _ whole: Int) -> String {
                whole == 0 ? "–" : String(format: "%.0f%%", Double(part) * 100 / Double(whole))
            }
            return "CORPUS_METRIC \(name): STUB medication+vital fields \(fields); clean before \(cleanBefore) "
                + "(\(pct(cleanBefore, fields))), clean after \(cleanAfter) (\(pct(cleanAfter, fields))); expected "
                + "fields \(expected), recovered clean \(expectedClean) (\(pct(expectedClean, expected)))"
        }
    }

    // MARK: - The STUB

    func testNoPhraseEverGivesACleanWrongFieldThroughTheStub() async throws {
        let corpus = try Self.corpus()
        XCTAssertGreaterThanOrEqual(corpus.entries.count, 150)
        XCTAssertEqual(Set(corpus.entries.map(\.id)).count, corpus.entries.count, "ids are unique")
        var failures: [String] = []
        var tallies: [String: Tally] = [:]
        for entry in corpus.entries where entry.copied == nil {
            let run = await Self.stubRun(Self.sentences(entry.text))
            let reviewed = StructuredResultGate().review(run, engineID: StubStructureModel.engineID)
            var tally = tallies[entry.subset, default: Tally()]
            var outcomes: [String] = []
            var cleanFields: [Field] = []
            for (index, items) in reviewed.enumerated() {
                for item in items where Self.clinicalTools.contains(item.call.tool) {
                    let field = Field(call: item.call)
                    let clean = item.verdict != .needsReview
                    tally.fields += 1
                    if Self.cleanBefore(run, sentence: index, call: item.call) { tally.cleanBefore += 1 }
                    if clean {
                        tally.cleanAfter += 1
                        cleanFields.append(field)
                        if !Self.allowed(field, in: entry) {
                            failures.append(
                                "\(entry.id): “\(entry.text)” gave a clean \(field) (\(item.verdict.rawValue)); "
                                    + "allowed: \((entry.expect ?? []).map(\.description))")
                        }
                    }
                    let proof = item.reasons.first { $0.hasPrefix(ClinicalFieldProof.reasonPrefix) }
                    outcomes.append(
                        "\(field): "
                            + (clean
                                ? "clean (\(item.verdict.rawValue))"
                                : "review — \(proof ?? item.reasons.first ?? "low confidence")"))
                }
            }
            tally.expected += entry.expect?.count ?? 0
            tally.expectedClean += (entry.expect ?? []).filter { expected in
                cleanFields.contains(expected.normalized)
            }.count
            tallies[entry.subset] = tally
            print("CORPUS_ROW | \(entry.id) | \(entry.text) | \(outcomes.isEmpty ? "no medication or vital field" : outcomes.joined(separator: "; ")) |")
        }
        for (name, tally) in tallies.sorted(by: { $0.key < $1.key }) { print(tally.line(name)) }
        XCTAssertEqual(failures, [], "clean and wrong:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - Needle, simulated

    /// Hand-built Needle answers at confidence 0.9, right and deliberately wrong: every pairing of a drug the sentence
    /// names with every number it says (and none), every status and route, and every number as every vital sign. A
    /// wrong answer is never clean.
    func testAWrongNeedleAnswerIsNeverClean() throws {
        let corpus = try Self.corpus()
        var failures: [String] = []
        var asked = 0
        var clean = 0
        var cleanRight = 0
        for entry in corpus.entries where entry.copied == nil {
            let sentences = Self.sentences(entry.text)
            let before = (asked, clean)
            defer { print("CORPUS_NEEDLE | \(entry.id) | \(asked - before.0) answers | \(clean - before.1) clean |") }
            for (index, sentence) in sentences.enumerated() {
                let following = sentences[(index + 1)..<min(index + 3, sentences.count)]
                for candidate in Self.needleAnswers(for: sentence, expected: entry.expect ?? []) {
                    asked += 1
                    let validated = StructuredCallValidator.validate([candidate], sentence: sentence, catalog: .soapMeds)
                    let run =
                        [SentenceCalls(sentence: sentence, calls: validated, confidence: 0.9)]
                        + following.map { SentenceCalls(sentence: $0, calls: [], confidence: 0.9) }
                    for item in StructuredResultGate().review(run, engineID: "needle.needle3")[0]
                    where item.verdict != .needsReview && Self.clinicalTools.contains(item.call.tool) {
                        clean += 1
                        let field = Field(call: item.call)
                        if Self.allowed(field, in: entry) {
                            cleanRight += 1
                        } else {
                            failures.append(
                                "\(entry.id): Needle \(candidate.name)(\(candidate.arguments.keys.sorted().map { "\($0)=\(candidate.arguments[$0]!.stringValue ?? "?")" }.joined(separator: ", "))) on “\(sentence.original)” was clean as \(field)"
                            )
                        }
                    }
                }
            }
        }
        print("CORPUS_METRIC needle-simulated: \(asked) answers at 0.9; \(clean) clean, all of them right: \(cleanRight)")
        XCTAssertGreaterThan(asked, 1000)
        XCTAssertEqual(failures, [], "a wrong Needle answer was clean:\n" + failures.prefix(40).joined(separator: "\n"))
    }

    static func needleAnswers(for sentence: NormalizedText, expected: [Field]) -> [StructuredCall] {
        let tags = sentence.tags.filter { $0.kind != .laterality }
        let doseOptions: [String?] = [nil] + tags.map(\.tag)
        let frequencyOptions: [String?] = [nil] + tags.filter { $0.kind == .frequency }.map(\.tag)
        let lower = sentence.original.lowercased()
        var drugs = ClinicalLexicon.names(in: sentence.original)
        for field in expected {
            if let med = field.med?.lowercased(), lower.contains(med), !drugs.contains(med) { drugs.append(med) }
        }
        func medication(_ drug: String, dose: String?, frequency: String?, route: String, status: String)
            -> StructuredCall
        {
            var arguments: [String: JSONValue] = [
                "drug": .string(drug), "route": .string(route), "status": .string(status),
            ]
            if let dose { arguments["dose_tag"] = .string(dose) }
            if let frequency { arguments["frequency_tag"] = .string(frequency) }
            return StructuredCall(name: "add_medication", arguments: arguments)
        }
        var answers: [StructuredCall] = []
        for drug in drugs {
            let right = expected.first { $0.med?.lowercased() == drug }?.normalized
            let status = right?.status ?? "taking"
            let route = right?.route ?? "unknown"
            // Every number pairing (the C-A family: a dose or frequency given to the wrong drug).
            for dose in doseOptions {
                for frequency in frequencyOptions {
                    answers.append(medication(drug, dose: dose, frequency: frequency, route: route, status: status))
                }
            }
            // Every status and route with the natural pairing (M3: "hold" answered "taking").
            let naturalDose = tags.first { $0.kind == .dose && (right?.dose == nil || $0.display == right?.dose) }?.tag
            let naturalFrequency = tags.first { $0.kind == .frequency }?.tag
            for status in ["taking", "started", "stopped", "considering"] {
                for route in ["unknown", "PO", "IV", "IM", "SC", "SL", "inhaled", "topical"] {
                    answers.append(
                        medication(drug, dose: naturalDose, frequency: naturalFrequency, route: route, status: status))
                }
            }
        }
        // Every number as every vital sign (I-4, I-5: a threshold as a vital, pulse ox as a heart rate).
        for tag in tags {
            for kind in ["BP", "HR", "RR", "SpO2", "temp"] {
                answers.append(
                    StructuredCall(
                        name: "record_vital", arguments: ["kind": .string(kind), "value_tag": .string(tag.tag)]))
            }
        }
        return answers
    }

    // MARK: - Voice commands

    func testScratchThatNeverDropsAnEarlierOrderOrKeepsPartOfOne() async throws {
        let corpus = try Self.corpus()
        let resolver = VoiceCommandResolver(engine: StubStructureModel(), gate: StructuredResultGate())
        var failures: [String] = []
        var applied = 0
        var marked = 0
        for entry in corpus.entries {
            guard let copied = entry.copied else { continue }
            let result = await resolver.resolve(entry.text, privacyClass: .clinical)
            let dictated = VoiceCommandResolver.sentences(in: entry.text).filter { resolver.candidate(for: $0) == nil }
            let untouched =
                !result.unresolved.isEmpty && dictated.allSatisfy(result.text.contains)
                && result.text.contains("Scratch that.")
            if result.text == copied {
                applied += 1
            } else if untouched {
                marked += 1
            } else {
                failures.append("\(entry.id): “\(entry.text)” copied “\(result.text)”; allowed: “\(copied)” or unchanged")
            }
            print(
                "CORPUS_VOICE | \(entry.id) | \(entry.text) | "
                    + (result.text == copied
                        ? "applied: “\(result.text)”" : "not applied, text unchanged: \(VoiceCommandResult.unresolvedMessage)")
                    + " |")
        }
        print("CORPUS_METRIC voice: \(applied) applied exactly, \(marked) left unchanged and marked")
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
    }
}
