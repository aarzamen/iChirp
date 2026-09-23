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

    /// The gate these settings describe (thresholds clamped to 0…1, provisional never above act).
    public var gate: StructuredResultGate {
        StructuredResultGate(act: actThreshold, provisional: provisionalThreshold)
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

/// Re-parses and range-checks every number a structure model returned, in code. The model only ever copies tags;
/// anything that does not trace back to the normalizer's side table, or falls outside a plausible range, forces review.
public enum StructuredCallValidator {
    public static func validate(
        _ call: StructuredCall, sentence: NormalizedText, catalog: StructureCatalog
    ) -> ValidatedCall {
        var problems = call.problems(against: catalog)
        var hardFail = false
        var ranges: [Range<Int>] = []
        var arguments: [String: JSONValue] = [:]
        let tagArguments: [String: [NumericTag.Kind]] = [
            "value_tag": [.bloodPressure, .rate, .oxygenSaturation, .temperature],
            "dose_tag": [.dose],
            "frequency_tag": [.frequency],
        ]
        for (key, value) in call.arguments {
            guard let kinds = tagArguments[key] else {
                arguments[key] = freeText(value, sentence: sentence)
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
            if tag.needsReview, let reason = tag.reviewReason { problems.append(reason) }
            // Re-parse the sentence in code: the same words must give the same value and unit.
            let reparsed = NumericNormalizer.normalize(sentence.original).tags.first {
                $0.sourceRange == tag.sourceRange && $0.kind == tag.kind
            }
            if reparsed?.value != tag.value || reparsed?.unit != tag.unit || reparsed?.secondValue != tag.secondValue {
                problems.append("\(tag.display) did not re-parse to the same value.")
            }
            problems += rangeProblems(for: tag, vitalKind: call.string("kind"), tool: call.name)
            arguments[outputKey] = describe(tag)
        }
        if call.name == "add_medication", let drug = call.string("drug"), !drug.isEmpty,
            !sentence.original.lowercased().contains(drug.lowercased())
        {
            problems.append("“\(drug)” is not in this sentence.")
        }
        if call.name == "add_allergy", let substance = call.string("substance"), !substance.isEmpty,
            !sentence.original.lowercased().contains(substance.lowercased())
        {
            problems.append("“\(substance)” is not in this sentence.")
        }
        return ValidatedCall(
            tool: call.name, arguments: arguments, problems: problems, numericHardFail: hardFail, tagRanges: ranges)
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
            guard let value = tag.value, value > 0, value < 100_000, tag.unit != nil else {
                return ["The dose \(tag.display) is not a usable amount."]
            }
            return []
        default:
            return []
        }
    }

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
