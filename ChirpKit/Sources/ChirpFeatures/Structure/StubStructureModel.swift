import ChirpCore
import Foundation

/// A rule-based stand-in for Needle that implements the same catalogs (`soap-meds.v1`, `dictation-commands.v1`).
///
/// Always available, deterministic, and **always labelled STUB** wherever it appears: its confidence is a
/// pseudo-confidence (how strongly a rule matched), not a model's calibrated score. Port of the Needle Bench "stub"
/// engine idea. It reads the normalizer's tagged text, so it copies tags exactly like the model is asked to.
public struct StubStructureModel: StructureModel {
    public static let engineID = "stub.rules"
    /// The label every screen shows next to STUB results.
    public static let label = "STUB"
    /// Review L3 I6: on the clinical catalog the STUB's pseudo-confidence stays below the default act threshold, and
    /// `StructuredResultGate.verdict(confidence:problems:engineID:)` caps a STUB field at provisional whatever the
    /// thresholds, so a STUB field is never solid or "Confident".
    public static let maxClinicalConfidence = 0.84

    public let descriptor = EngineDescriptor(
        id: StubStructureModel.engineID, kind: .structure, provider: "iChirp", displayName: "STUB (rules)",
        locality: .onDevice, license: "GPL-3.0 (iChirp code)", supportedLanguages: ["en"])

    public init() {}

    public func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws
        -> StructuredOutput
    {
        let calls: [(StructuredCall, Double)]
        if jsonSchema.contains(#""new_paragraph""#) {
            calls = Self.command(in: text).map { [$0] } ?? []
        } else if jsonSchema.contains(#""add_medication""#) {
            calls = Self.soap(in: text).map { ($0.0, min($0.1, Self.maxClinicalConfidence)) }
        } else {
            throw StructureModelError.unsupported("the STUB knows only soap-meds.v1 and dictation-commands.v1")
        }
        guard !calls.isEmpty else { return StructuredOutput(json: "[]", confidence: 0.7) }
        let json = JSONValue.array(
            calls.map { call, _ in .object(["name": .string(call.name), "arguments": .object(call.arguments)]) }
        ).compactJSON
        return StructuredOutput(json: json, confidence: calls.map(\.1).min() ?? 0.7)
    }

    public func embed(_ text: String) async throws -> [Float] {
        throw StructureModelError.unsupported("the STUB has no embeddings")
    }

    // MARK: - Dictation commands

    /// A command only when the whole utterance is one of the command's phrases (optionally after "okay"/"please").
    static func command(in text: String) -> (StructuredCall, Double)? {
        let words = VoiceCommandText.words(text)
        guard !words.isEmpty, words.count <= 8 else { return nil }
        for tool in StructureCatalog.dictationCommands.tools {
            for phrase in tool.phrases ?? [] where VoiceCommandText.matches(words, phrase: phrase) {
                let exact = words.joined(separator: " ") == phrase
                return (StructuredCall(name: tool.name), exact ? 0.95 : 0.88)
            }
        }
        return nil
    }

    // MARK: - SOAP fields and medications

    static func soap(in tagged: String) -> [(StructuredCall, Double)] {
        let lower = tagged.lowercased()
        var calls: [(StructuredCall, Double)] = []
        if lower.range(of: #"ignore (all |any )?(previous|prior) instructions"#, options: .regularExpression) != nil {
            return [(StructuredCall(name: "none", arguments: ["reason": .string("instruction_to_ignore")]), 0.9)]
        }
        calls += vitals(in: lower)
        calls += medications(in: tagged)
        if let allergy = allergy(in: lower) { calls.append(allergy) }
        if let problem = phrase(in: tagged, after: Self.problemLeads) {
            calls.append((StructuredCall(name: "add_problem", arguments: ["text": .string(problem)]), 0.8))
        }
        if let plan = phrase(in: tagged, after: Self.planLeads) {
            calls.append((StructuredCall(name: "add_plan_item", arguments: ["text": .string(plan)]), 0.8))
        }
        if calls.isEmpty {
            let reason: String
            if lower.contains("no known drug allergies") || lower.hasPrefix("denies") || lower.hasPrefix("no ") {
                reason = "negative_finding"
            } else if ["might", "may need", "could", "if "].contains(where: lower.contains) {
                reason = "contingency"
            } else {
                reason = "small_talk"
            }
            calls.append((StructuredCall(name: "none", arguments: ["reason": .string(reason)]), 0.6))
        }
        return calls
    }

    static func vitals(in lower: String) -> [(StructuredCall, Double)] {
        var calls: [(StructuredCall, Double)] = []
        for match in tags(in: lower, prefixes: ["bp", "rate", "spo2", "temp"]) {
            let kind: String
            var confidence = 0.9
            switch match.prefix {
            case "bp": kind = "BP"
            case "spo2": kind = "SpO2"
            case "temp": kind = "temp"
            default:
                let before = String(lower[..<match.range.lowerBound].suffix(30))
                if ["respiratory", "resp", "rr ", "breathing", "respirations"].contains(where: before.contains) {
                    kind = "RR"
                } else if ["heart", "pulse", "hr "].contains(where: before.contains) {
                    kind = "HR"
                } else {
                    kind = "HR"
                    confidence = 0.65
                }
            }
            calls.append(
                (
                    StructuredCall(
                        name: "record_vital", arguments: ["kind": .string(kind), "value_tag": .string(match.tag)]),
                    confidence
                ))
        }
        return calls
    }

    static func medications(in tagged: String) -> [(StructuredCall, Double)] {
        let lower = tagged.lowercased()
        var found: [(drug: String, range: Range<String.Index>)] = []
        for drug in Self.drugs {
            var searchStart = lower.startIndex
            while let range = lower.range(
                of: "\\b\(drug)\\b", options: .regularExpression, range: searchStart..<lower.endIndex)
            {
                found.append((drug, range))
                searchStart = range.upperBound
            }
        }
        // "insulin glargine" wins over "insulin": drop a match inside a longer one.
        found = found.filter { item in
            !found.contains { other in
                other.range != item.range && other.range.contains(item.range.lowerBound)
                    && other.range.upperBound >= item.range.upperBound
                    && lower.distance(from: other.range.lowerBound, to: other.range.upperBound)
                        > lower.distance(from: item.range.lowerBound, to: item.range.upperBound)
            }
        }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        var calls: [(StructuredCall, Double)] = []
        for (index, item) in found.enumerated() {
            let end = index + 1 < found.count ? found[index + 1].range.lowerBound : lower.endIndex
            let window = String(lower[item.range.lowerBound..<end])
            let previousEnd = index > 0 ? found[index - 1].range.upperBound : lower.startIndex
            let before = String(lower[previousEnd..<item.range.lowerBound])
            var arguments: [String: JSONValue] = ["drug": .string(item.drug)]
            var confidence = 0.9
            if let dose = tags(in: window, prefixes: ["dose"]).first { arguments["dose_tag"] = .string(dose.tag) }
            if let frequency = tags(in: window, prefixes: ["freq"]).first {
                arguments["frequency_tag"] = .string(frequency.tag)
            }
            arguments["route"] = .string(route(in: window))
            if let status = status(before: before, window: window) {
                arguments["status"] = .string(status)
            } else {
                arguments["status"] = .string("taking")
                confidence = 0.7
            }
            if arguments["dose_tag"] == nil { confidence = min(confidence, 0.75) }
            calls.append((StructuredCall(name: "add_medication", arguments: arguments), confidence))
        }
        return calls
    }

    static func route(in window: String) -> String {
        if window.contains("by mouth") || window.contains(" po") || window.contains("oral") { return "PO" }
        if window.contains(" iv") || window.contains("intravenous") { return "IV" }
        if window.contains(" im ") || window.contains("intramuscular") { return "IM" }
        if window.contains("subcutaneous") || window.contains("subq") || window.contains(" sc ") { return "SC" }
        if window.contains("sublingual") { return "SL" }
        if window.contains("inhaler") || window.contains("inhaled") || window.contains("puff") { return "inhaled" }
        if window.contains("cream") || window.contains("topical") || window.contains("ointment") { return "topical" }
        return "unknown"
    }

    /// The status word nearest the drug: the last one before it (since the previous drug), else the first after it.
    static func status(before: String, window: String) -> String? {
        let rules: [(String, String)] = [
            ("stopped", #"\b(stopped|stop|discontinued?|hold|held|came off)\b"#),
            ("considering", #"\b(consider|considering|might|may start|could start|thinking about)\b"#),
            ("started", #"\b(started|start|starting|begin|began|initiated?|prescribed|new)\b"#),
            ("taking", #"\b(takes|taking|is on|remains on|continues?|home meds|uses)\b"#),
        ]
        func matches(_ text: String) -> [(status: String, location: Int)] {
            rules.flatMap { status, pattern in
                let regex = try! NSRegularExpression(pattern: pattern)
                return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                    .map { (status, $0.range.location) }
            }
        }
        // A hedge before the drug wins over a later verb: "considering starting metoprolol" is not "started".
        if matches(before).contains(where: { $0.status == "considering" }) { return "considering" }
        if let last = matches(before).max(by: { $0.location < $1.location }) { return last.status }
        return matches(window).min(by: { $0.location < $1.location })?.status
    }

    static func allergy(in lower: String) -> (StructuredCall, Double)? {
        guard let range = lower.range(of: #"allerg(ic|y|ies) to "#, options: .regularExpression) else { return nil }
        let rest = lower[range.upperBound...]
        let substance = rest.prefix { $0.isLetter || $0 == " " || $0 == "-" }
            .split(separator: " ").prefix(2).filter { !["which", "that", "causes", "with", "and"].contains($0) }
            .joined(separator: " ")
        guard !substance.isEmpty else { return nil }
        var arguments: [String: JSONValue] = ["substance": .string(substance)]
        for reaction in ["anaphylaxis", "hives", "rash", "swelling", "itching", "nausea", "wheezing"]
        where rest.contains(reaction) {
            arguments["reaction"] = .string(reaction)
            break
        }
        return (StructuredCall(name: "add_allergy", arguments: arguments), 0.9)
    }

    /// The words after a lead phrase, up to the end of the sentence.
    static func phrase(in text: String, after leads: [String]) -> String? {
        let lower = text.lowercased()
        for lead in leads {
            guard let range = lower.range(of: lead) else { continue }
            let tail = text[range.upperBound...]
                .prefix { !".;!?".contains($0) }
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !tail.isEmpty { return String(tail) }
        }
        return nil
    }

    static let problemLeads = [
        "history of ", "diagnosed with ", "assessment is ", "assessment: ", "presents with ", "complains of ",
        "suspect ", "likely ",
    ]
    static let planLeads = [
        "plan is to ", "plan: ", "we will ", "will order ", "order ", "refer to ", "referral to ", "follow up ",
        "follow-up ", "recheck ", "return in ",
    ]

    /// Drug names the STUB recognizes (the synthetic eval set's and common primary-care drugs).
    static let drugs = [
        "lisinopril", "metformin", "amlodipine", "atorvastatin", "ibuprofen", "acetaminophen", "amoxicillin",
        "ondansetron", "fentanyl", "insulin glargine", "insulin", "albuterol", "prednisone", "omeprazole",
        "sertraline", "levothyroxine", "aspirin", "apixaban", "gabapentin", "losartan", "metoprolol", "furosemide",
        "azithromycin", "cephalexin", "ceftriaxone", "hydrochlorothiazide", "naproxen", "famotidine", "doxycycline",
        "nitrofurantoin", "montelukast", "fluticasone", "tramadol", "ketamine", "tranexamic acid",
    ]

    struct TagMatch {
        var tag: String
        var prefix: String
        var range: Range<String.Index>
    }

    static func tags(in text: String, prefixes: [String]) -> [TagMatch] {
        var matches: [TagMatch] = []
        let pattern = "\\b(" + prefixes.joined(separator: "|") + ")_\\d+\\b"
        var searchStart = text.startIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: searchStart..<text.endIndex) {
            let tag = String(text[range])
            let prefix = String(tag.prefix { $0 != "_" })
            matches.append(TagMatch(tag: tag, prefix: prefix, range: range))
            searchStart = range.upperBound
        }
        return matches
    }
}

/// Word handling shared by the STUB and the voice-command resolver.
public enum VoiceCommandText {
    /// Lowercased words without punctuation.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// The utterance is exactly `phrase`, optionally after "okay", "ok", "please" or "and".
    public static func matches(_ words: [String], phrase: String) -> Bool {
        let target = phrase.split(separator: " ").map(String.init)
        var body = words
        while let first = body.first, ["okay", "ok", "please", "and", "now"].contains(first), body.count > target.count
        {
            body.removeFirst()
        }
        if body.last == "please", body.count > target.count { body.removeLast() }
        return body == target
    }
}
