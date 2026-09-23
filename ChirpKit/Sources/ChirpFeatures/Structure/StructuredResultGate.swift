import ChirpCore
import ChirpText
import Foundation

/// Which structure engine the person chose (Settings → Structure models).
public enum StructureEngineChoice: String, Codable, Sendable, CaseIterable {
    /// Needle 3 on this iPhone (needs the runtime in the build and the model downloaded).
    case needle
    /// The rule-based STUB, always available, always labelled STUB.
    case stub
}

/// The structure-model settings, kept apart from `TranscriptionSettings`.
public struct StructureSettings: Codable, Sendable, Equatable {
    /// Dictation voice commands (off by default).
    public var voiceCommandsEnabled = false
    /// Gate: at or above → act (solid). Default 0.85.
    public var actThreshold = StructuredResultGate.defaultAct
    /// Gate: at or above → provisional (dashed). Default 0.60.
    public var provisionalThreshold = StructuredResultGate.defaultProvisional
    public var engine: StructureEngineChoice = .needle

    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .voiceCommandsEnabled) {
            voiceCommandsEnabled = value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .actThreshold) { actThreshold = value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .provisionalThreshold) {
            provisionalThreshold = value
        }
        if let value = try? container.decodeIfPresent(StructureEngineChoice.self, forKey: .engine) { engine = value }
    }

    /// The lowest act and provisional thresholds the settings allow (review L3 minor 2: the eval's wrong allergies
    /// scored 0.29 and 0.39, so the gate never goes that low).
    public static let actFloor = 0.70
    public static let provisionalFloor = 0.50

    /// The gate these settings describe (thresholds clamped to their floors and 1, provisional never above act).
    public var gate: StructuredResultGate {
        StructuredResultGate(
            act: max(actThreshold, Self.actFloor), provisional: max(provisionalThreshold, Self.provisionalFloor))
    }
}

public protocol StructureSettingsStoring: Sendable {
    func load() -> StructureSettings
    func save(_ settings: StructureSettings)
}

/// `StructureSettings` as one JSON blob in `UserDefaults` (thread-safe, hence `@unchecked Sendable`).
public final class UserDefaultsStructureSettingsStore: StructureSettingsStoring, @unchecked Sendable {
    public static let key = "ichirp.structureSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> StructureSettings {
        guard let data = defaults.data(forKey: Self.key),
            let value = try? JSONDecoder().decode(StructureSettings.self, from: data)
        else { return StructureSettings() }
        return value
    }

    public func save(_ settings: StructureSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.key)
    }
}

/// In-memory settings for tests and previews.
public final class InMemoryStructureSettingsStore: StructureSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StructureSettings

    public init(_ value: StructureSettings = StructureSettings()) {
        self.value = value
    }

    public func load() -> StructureSettings { lock.withLock { value } }
    public func save(_ settings: StructureSettings) { lock.withLock { value = settings } }
}

/// The confidence gate (Needle Bench): act ≥ 0.85, provisional ≥ 0.60, else needs review. Any failed check forces
/// needs review whatever the confidence.
public struct StructuredResultGate: Sendable, Equatable {
    public static let defaultAct = 0.85
    public static let defaultProvisional = 0.60

    public let act: Double
    public let provisional: Double

    public init(
        act: Double = StructuredResultGate.defaultAct, provisional: Double = StructuredResultGate.defaultProvisional
    ) {
        let act = min(max(act, 0), 1)
        self.act = act
        self.provisional = min(max(provisional, 0), act)
    }

    public func verdict(confidence: Double, problems: [String] = []) -> StructuredVerdict {
        guard problems.isEmpty else { return .needsReview }
        if confidence >= act { return .act }
        if confidence >= provisional { return .provisional }
        return .needsReview
    }

    /// A clinical field's verdict. The STUB (rules, not a model) is never `act`, whatever the thresholds (review L3 I6).
    public func verdict(confidence: Double, problems: [String], engineID: String) -> StructuredVerdict {
        let verdict = verdict(confidence: confidence, problems: problems)
        return verdict == .act && engineID == StubStructureModel.engineID ? .provisional : verdict
    }
}

/// A call after tag mapping and checks: what the ledger stores and the draft card shows.
public struct ValidatedCall: Sendable, Equatable {
    public var tool: String
    /// Arguments with tags mapped back to values: a tag argument becomes
    /// `{"tag", "display", "value", "second"?, "unit"}`; free text has its tags replaced by their display values.
    public var arguments: [String: JSONValue]
    /// Why this call must be reviewed (empty when every check passed).
    public var problems: [String]
    /// A number the model produced that does not trace to a number the normalizer found (the Eval's hard fail).
    public var numericHardFail: Bool
    /// UTF-16 ranges (in the sentence) of the numbers this call used.
    public var tagRanges: [Range<Int>]
}

/// Checks every call a structure model returned, in code. The model only ever copies tags; anything that does not
/// trace back to the normalizer's side table, disagrees with an independent reading of the words
/// (`IndependentNumberCheck`, review L3 I1), sits away from its drug, carries a spoken correction, or falls outside a
/// plausible range forces review.
public enum StructuredCallValidator {
    static let tagArguments: [String: [NumericTag.Kind]] = [
        "value_tag": [.bloodPressure, .rate, .oxygenSaturation, .temperature],
        "dose_tag": [.dose],
        "frequency_tag": [.frequency],
    ]

    /// Every call from one sentence: each checked on its own (the others name the sentence's drugs), then against
    /// each other (review L3 I3: two values for one vital sign both need review).
    public static func validate(
        _ calls: [StructuredCall], sentence: NormalizedText, catalog: StructureCatalog
    ) -> [ValidatedCall] {
        var results = calls.map { validate($0, sentence: sentence, catalog: catalog, siblings: calls) }
        var byKind: [String: [Int]] = [:]
        for (index, call) in calls.enumerated() where call.name == "record_vital" {
            if let kind = call.string("kind"), !kind.isEmpty { byKind[kind, default: []].append(index) }
        }
        for (kind, indices) in byKind where indices.count > 1 {
            for index in indices {
                results[index].problems.append("\(indices.count) \(kind) values in one sentence: check which is which.")
            }
        }
        return results
    }

    public static func validate(
        _ call: StructuredCall, sentence: NormalizedText, catalog: StructureCatalog, siblings: [StructuredCall] = []
    ) -> ValidatedCall {
        var problems = call.problems(against: catalog)
        var hardFail = false
        var ranges: [Range<Int>] = []
        var arguments: [String: JSONValue] = [:]
        var used: [(key: String, tag: NumericTag)] = []
        let tool = catalog.tool(named: call.name)
        let known = Set(tool?.argumentNames ?? [])
        for key in call.arguments.keys.sorted() {
            guard let value = call.arguments[key] else { continue }
            // Review L3 I5: an argument the tool does not have is dropped, never shown.
            if tool != nil, !known.contains(key) {
                problems.append("Unknown argument “\(key)” was dropped.")
                continue
            }
            guard let kinds = tagArguments[key] else {
                switch value {
                case .string(let text):
                    arguments[key] = freeText(value, sentence: sentence)
                    if tool?.allowedValues(for: key) == nil {
                        problems += inventedNumbers(in: text, key: key, sentence: sentence)
                    }
                case .null:
                    break
                default:
                    problems.append("“\(key)” was not text, so it was dropped.")
                }
                continue
            }
            guard let raw = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            let outputKey = String(key.dropLast("_tag".count))
            guard let resolved = trace(raw, in: sentence) else {
                hardFail = true
                problems.append("“\(raw)” does not match any number in this sentence.")
                arguments[outputKey] = .object(["unresolved": .string(raw)])
                continue
            }
            if !resolved.exact {
                problems.append("The model copied “\(raw)” instead of its tag; check the number.")
            }
            let tag = resolved.tag
            ranges.append(tag.sourceRange)
            if !kinds.contains(tag.kind) {
                hardFail = true
                problems.append("\(key) points at a \(tag.kind.rawValue) (\(tag.display)), not a \(outputKey).")
            }
            // Review L3 I1: an independent reading of the tag's words and of the words next to it.
            problems += IndependentNumberCheck.problems(for: tag, in: sentence.original)
            problems += rangeProblems(for: tag, vitalKind: call.string("kind"), tool: call.name)
            arguments[outputKey] = describe(tag)
            used.append((outputKey, tag))
        }
        if call.name == "add_medication", let drug = call.string("drug"), !drug.isEmpty {
            if !sentence.original.lowercased().contains(drug.lowercased()) {
                problems.append("“\(drug)” is not in this sentence.")
            } else {
                problems += adjacencyProblems(drug: drug, used: used, sentence: sentence, siblings: siblings)
            }
        }
        if call.name == "add_allergy", let substance = call.string("substance"), !substance.isEmpty,
            !sentence.original.lowercased().contains(substance.lowercased())
        {
            problems.append("“\(substance)” is not in this sentence.")
        }
        if call.name == "record_vital" {
            for (_, tag) in used { problems += vitalAfterDrug(tag, sentence: sentence, siblings: siblings) }
        }
        // Review L3 I4: a flagged number or side, or a spoken correction, anywhere in the sentence reaches every call
        // from it (the model reads laterality and corrections as plain words).
        if call.name != "none" {
            let flagged = sentence.tags.filter(\.needsReview).compactMap(\.reviewReason)
            for reason in flagged where !problems.contains(reason) { problems.append(reason) }
            if flagged.isEmpty, let marker = SentenceNeighbours.correction(in: sentence.original) {
                problems.append("The sentence has a spoken correction (“\(marker)”): check every field from it.")
            }
        }
        return ValidatedCall(
            tool: call.name, arguments: arguments, problems: problems, numericHardFail: hardFail, tagRanges: ranges)
    }

    /// Drug names the checks know besides the call's own: the STUB's list and every drug the sentence's calls name.
    static func otherDrugs(than drug: String, siblings: [StructuredCall]) -> [String] {
        let named = siblings.filter { $0.name == "add_medication" }.compactMap { $0.string("drug") }
        let own = drug.lowercased()
        return Set((StubStructureModel.drugs + named).map { $0.lowercased() }).filter { $0 != own && !own.contains($0) }
            .sorted()
    }

    /// Review L3 I2: a dose or frequency belongs to the drug it sits next to. Another drug or another value of the same
    /// kind between them, or more than eight words, forces review.
    static func adjacencyProblems(
        drug: String, used: [(key: String, tag: NumericTag)], sentence: NormalizedText, siblings: [StructuredCall]
    ) -> [String] {
        let original = sentence.original
        let mentions = SentenceNeighbours.mentions(of: drug, in: original)
        guard !mentions.isEmpty else { return [] }
        let others = otherDrugs(than: drug, siblings: siblings).flatMap {
            SentenceNeighbours.mentions(of: $0, in: original)
        }
        .filter { other in !mentions.contains { $0.overlaps(other) } }
        func distance(_ a: Range<Int>, _ b: Range<Int>) -> Int {
            a.upperBound <= b.lowerBound ? b.lowerBound - a.upperBound : max(0, a.lowerBound - b.upperBound)
        }
        var problems: [String] = []
        for (key, tag) in used where key == "dose" || key == "frequency" {
            guard let nearest = mentions.min(by: { distance($0, tag.sourceRange) < distance($1, tag.sourceRange) })
            else { continue }
            let low = min(nearest.upperBound, tag.sourceRange.upperBound)
            let high = max(nearest.lowerBound, tag.sourceRange.lowerBound)
            let between = low..<max(low, high)
            func inside(_ range: Range<Int>) -> Bool {
                range.lowerBound >= between.lowerBound && range.upperBound <= between.upperBound
            }
            let drugBetween = others.first(where: inside)
            let sameKind = sentence.tags.contains { $0.kind == tag.kind && $0.tag != tag.tag && inside($0.sourceRange) }
            let count = SentenceNeighbours.wordsBetween(nearest, tag.sourceRange, in: original).count
            let why: String?
            if let drugBetween {
                let name = (original as NSString).substring(
                    with: NSRange(location: drugBetween.lowerBound, length: drugBetween.count))
                why = "“\(name)” comes between them"
            } else if sameKind {
                why = "another \(key) comes between them"
            } else if count > 8 {
                why = "\(count) words apart"
            } else {
                why = nil
            }
            if let why {
                problems.append("\(tag.display) is not next to \(drug) (\(why)): check which drug it belongs to.")
            }
        }
        return problems
    }

    /// Review L3 I3: a vital-sign number right after a drug name is more likely that drug's strength.
    static func vitalAfterDrug(_ tag: NumericTag, sentence: NormalizedText, siblings: [StructuredCall]) -> [String] {
        let original = sentence.original
        for drug in otherDrugs(than: "", siblings: siblings) {
            for mention in SentenceNeighbours.mentions(of: drug, in: original)
            where mention.upperBound <= tag.sourceRange.lowerBound
                && SentenceNeighbours.wordsBetween(mention, tag.sourceRange, in: original).count <= 1
            {
                return ["\(tag.display) comes right after “\(drug)”: a dose, not a vital sign? Check it."]
            }
        }
        return []
    }

    /// Review L3 I5: numbers written in free text that the sentence never said (tag names aside).
    static func inventedNumbers(in text: String, key: String, sentence: NormalizedText) -> [String] {
        let withoutTags = text.replacingOccurrences(
            of: #"\b(time|bp|rate|spo2|temp|dose|freq|dur|side)_\d+\b"#, with: " ",
            options: [.regularExpression, .caseInsensitive])
        let said = IndependentNumberReader.read(sentence.original).numbers
        let invented = IndependentNumberReader.read(withoutTags).numbers.filter { value in
            !said.contains { IndependentNumberReader.same($0, value) }
        }
        guard !invented.isEmpty else { return [] }
        return [
            "The \(key) has \(invented.map(NumericNormalizer.format).joined(separator: ", ")), which this sentence "
                + "does not say."
        ]
    }

    /// The tag `raw` names, or (flagged inexact) the tag whose spoken words or display equal it.
    static func trace(_ raw: String, in sentence: NormalizedText) -> (tag: NumericTag, exact: Bool)? {
        if let tag = sentence.tag(named: raw) { return (tag, true) }
        let key = raw.lowercased()
        let match = sentence.tags.first {
            $0.sourceText.lowercased() == key || $0.display.lowercased() == key
                || $0.value.map(NumericNormalizer.format) == key
        }
        return match.map { ($0, false) }
    }

    static func rangeProblems(for tag: NumericTag, vitalKind: String?, tool: String) -> [String] {
        func outside(_ label: String, _ range: ClosedRange<Double>, _ value: Double?) -> [String] {
            guard let value else { return ["\(label) has no number."] }
            return range.contains(value)
                ? []
                : [
                    "\(label) \(NumericNormalizer.format(value)) is outside \(Int(range.lowerBound))–\(Int(range.upperBound))."
                ]
        }
        switch (tool, vitalKind, tag.kind) {
        case ("record_vital", "BP", .bloodPressure):
            var problems = outside("Systolic", 50...260, tag.value) + outside("Diastolic", 20...160, tag.secondValue)
            if let systolic = tag.value, let diastolic = tag.secondValue, systolic <= diastolic {
                problems.append("Systolic is not above diastolic.")
            }
            return problems
        case ("record_vital", "HR", .rate): return outside("Heart rate", 20...250, tag.value)
        case ("record_vital", "RR", .rate): return outside("Respiratory rate", 4...60, tag.value)
        case ("record_vital", "SpO2", .oxygenSaturation): return outside("SpO₂", 50...100, tag.value)
        case ("record_vital", "temp", .temperature):
            return tag.unit == "°C"
                ? outside("Temperature °C", 32...43.5, tag.value) : outside("Temperature °F", 90...110, tag.value)
        case ("record_vital", let kind?, _):
            return ["\(kind) was given \(tag.display)."]
        case (_, _, .dose):
            guard let value = tag.value, value > 0, let unit = tag.unit else {
                return ["The dose \(tag.display) is not a usable amount."]
            }
            // Per weight or per time is always flagged by the normalizer; a plain amount has a per-unit ceiling.
            guard !unit.contains("/"), let limit = doseLimits[unit] else { return [] }
            return value <= limit
                ? [] : ["The dose \(tag.display) is outside 0–\(NumericNormalizer.format(limit)) \(unit)."]
        case (_, _, .frequency):
            guard let value = tag.value, let unit = tag.unit else { return [] }
            let limits: [String: ClosedRange<Double>] = [
                "per day": 0.1...24, "per week": 0.1...21, "h": 0.5...168, "min": 1...1440,
            ]
            guard let range = limits[unit], !range.contains(value) else { return [] }
            return ["\(tag.display) is outside a usable frequency."]
        default:
            return []
        }
    }

    /// Review L3 minor 1: the largest plausible single amount per unit (a check, not a dosing rule).
    static let doseLimits: [String: Double] = [
        "mg": 5000, "mcg": 2000, "g": 10, "units": 50_000, "mL": 5000, "tablet": 10, "puff": 12, "drop": 20,
        "mEq": 200,
    ]

    static func describe(_ tag: NumericTag) -> JSONValue {
        var object: [String: JSONValue] = ["tag": .string(tag.tag), "display": .string(tag.display)]
        if let value = tag.value { object["value"] = .number(value) }
        if let second = tag.secondValue { object["second"] = .number(second) }
        if let unit = tag.unit { object["unit"] = .string(unit) }
        return .object(object)
    }

    /// Free text with any tags replaced by what was said ("recheck in dur_1" → "recheck in 3 months").
    static func freeText(_ value: JSONValue, sentence: NormalizedText) -> JSONValue {
        guard case .string(var text) = value else { return value }
        for tag in sentence.tags where text.contains(tag.tag) {
            text = text.replacingOccurrences(
                of: "\\b\(tag.tag)\\b", with: tag.display, options: .regularExpression)
        }
        return .string(text)
    }
}
