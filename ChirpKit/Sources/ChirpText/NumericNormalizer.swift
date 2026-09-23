// Port of the owner's Needle Bench design (docs/research/2026-09-22-needle-bench-spec.md, "Deterministic
// normalizer"): numbers are found and parsed by code before a structure model sees the text, so the model copies tags
// ("dose_1") instead of digits, and code maps the tags back to exact values. New Swift; no upstream source.

import Foundation

/// One number (or laterality word) the normalizer found, with its parsed value and where it came from.
public struct NumericTag: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case time, bloodPressure, rate, oxygenSaturation, temperature, dose, frequency, duration, laterality

        /// The tag name's prefix: `dose_1`, `bp_1`, ….
        public var prefix: String {
            switch self {
            case .time: "time"
            case .bloodPressure: "bp"
            case .rate: "rate"
            case .oxygenSaturation: "spo2"
            case .temperature: "temp"
            case .dose: "dose"
            case .frequency: "freq"
            case .duration: "dur"
            case .laterality: "side"
            }
        }
    }

    /// What the model sees and copies, e.g. `dose_1`.
    public var tag: String
    public var kind: Kind
    /// The main number: the dose amount, systolic pressure, rate, percent, degrees, minutes after midnight (time),
    /// times per day or interval length (frequency), or the duration's length. Nil for word-only frequencies
    /// ("as needed") and laterality.
    public var value: Double?
    /// Diastolic pressure for a blood-pressure pair.
    public var secondValue: Double?
    /// Normalized unit: `mg`, `mcg`, `g`, `units`, `mL`, `tablet`, `puff`, `drop`, `mEq`, `%`, `°F`, `°C`, `/min`,
    /// `mmHg`, `s`, `min`, `h`, `d`, `wk`, `mo`, `yr`, `per day`, `L`/`R`/`bilateral`.
    public var unit: String?
    /// The value as the app shows it: "50 mg", "142/88 mmHg", "14:02", "every 6 hours", "twice daily".
    public var display: String
    /// UTF-16 offsets of the source words in the original text (for a self-correction: both attempts).
    public var sourceRange: Range<Int>
    /// The original words.
    public var sourceText: String
    /// Set when the words were ambiguous or corrected mid-sentence ("five, no, fifty milligrams").
    public var needsReview: Bool
    public var reviewReason: String?

    public init(
        tag: String, kind: Kind, value: Double?, secondValue: Double? = nil, unit: String?, display: String,
        sourceRange: Range<Int>, sourceText: String, needsReview: Bool = false, reviewReason: String? = nil
    ) {
        self.tag = tag
        self.kind = kind
        self.value = value
        self.secondValue = secondValue
        self.unit = unit
        self.display = display
        self.sourceRange = sourceRange
        self.sourceText = sourceText
        self.needsReview = needsReview
        self.reviewReason = reviewReason
    }
}

/// The normalizer's output: the original text, the tagged text a model reads, and the side table.
public struct NormalizedText: Sendable, Equatable {
    public var original: String
    /// `original` with every numeric span replaced by its tag (laterality words stay as spoken).
    public var tagged: String
    /// In source order, non-overlapping.
    public var tags: [NumericTag]

    public init(original: String, tagged: String, tags: [NumericTag]) {
        self.original = original
        self.tagged = tagged
        self.tags = tags
    }

    public func tag(named name: String) -> NumericTag? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tags.first { $0.tag == key }
    }
}

/// Deterministic numeric normalizer: times, blood-pressure pairs, rates, SpO₂, temperatures, doses with units,
/// frequencies, durations and laterality. Pure and synchronous; the same text always gives the same tags.
///
/// Rules that matter clinically: a unit is never guessed (no unit → no dose tag); "25 minute timer" is 25 minutes;
/// mg and mcg stay distinct; a spoken self-correction keeps the corrected value and flags it for review.
public enum NumericNormalizer {
    public static func normalize(_ text: String) -> NormalizedText {
        let quantities = NumericScanner(text: text).scan()
        var counters: [NumericTag.Kind: Int] = [:]
        var tags: [NumericTag] = []
        let ns = text as NSString
        for quantity in quantities {
            counters[quantity.kind, default: 0] += 1
            let name = "\(quantity.kind.prefix)_\(counters[quantity.kind]!)"
            let range = quantity.start..<quantity.end
            tags.append(
                NumericTag(
                    tag: name, kind: quantity.kind, value: quantity.value, secondValue: quantity.second,
                    unit: quantity.unit, display: quantity.display, sourceRange: range,
                    sourceText: ns.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                    needsReview: quantity.reviewReason != nil, reviewReason: quantity.reviewReason))
        }
        var tagged = ""
        var cursor = 0
        for tag in tags where tag.kind != .laterality {
            tagged += ns.substring(with: NSRange(location: cursor, length: tag.sourceRange.lowerBound - cursor))
            tagged += tag.tag
            cursor = tag.sourceRange.upperBound
        }
        tagged += ns.substring(from: cursor)
        return NormalizedText(original: text, tagged: tagged, tags: tags)
    }

    /// Formats a number without trailing zeros: 50 → "50", 0.5 → "0.5", 98.60 → "98.6".
    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e12 { return String(Int64(value)) }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Scanner

private struct Quantity {
    var kind: NumericTag.Kind
    var value: Double?
    var second: Double?
    var unit: String?
    var display: String
    /// UTF-16 offsets.
    var start: Int
    var end: Int
    /// Token index just past the quantity.
    var nextToken: Int
    var reviewReason: String?
}

private struct Token {
    /// Lowercased.
    let text: String
    let original: String
    let range: NSRange
    let isDigits: Bool

    var start: Int { range.location }
    var end: Int { range.location + range.length }
}

private struct NumericScanner {
    let text: String
    let tokens: [Token]

    init(text: String) {
        self.text = text
        tokens = Self.tokenize(text)
    }

    static let pattern = try! NSRegularExpression(
        pattern:
            #"\bq\d+(?:-\d+)?h\b|\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:[.:/]\d+)*|[A-Za-z]+(?:'[A-Za-z]+)?|[^\sA-Za-z\d]"#,
        options: [.caseInsensitive])

    static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let original = ns.substring(with: match.range)
            let first = original.unicodeScalars.first!
            return Token(
                text: original.lowercased(), original: original, range: match.range,
                isDigits: CharacterSet.decimalDigits.contains(first))
        }
    }

    static func isQHours(_ text: String) -> Bool {
        text.lowercased().range(of: #"^q\d+(?:-\d+)?h$"#, options: .regularExpression) != nil
    }

    func scan() -> [Quantity] {
        var result: [Quantity] = []
        var index = 0
        while index < tokens.count {
            let first = recognize(at: index)
            let bareEnd = first?.nextToken ?? cardinal(at: index)?.next
            if let bareEnd, let afterMarker = correctionMarker(at: bareEnd) {
                let said = text.utf16Substring(tokens[index].start, tokens[bareEnd - 1].end)
                if var second = recognize(at: afterMarker) {
                    second.reviewReason = "Self-correction: “\(said)” was corrected to “\(second.display)”."
                    second.start = tokens[index].start
                    result.append(second)
                    index = second.nextToken
                    continue
                }
                if let first, let corrected = partialCorrection(of: first, startToken: index, at: afterMarker) {
                    result.append(corrected)
                    index = corrected.nextToken
                    continue
                }
                if var first {
                    // Review L3 C2: a correction word after a value always needs review, even with nothing after it.
                    first.reviewReason = "A correction word follows “\(said)”: check this value."
                    result.append(first)
                    index = first.nextToken
                    continue
                }
            }
            if let first {
                result.append(first)
                index = first.nextToken
                continue
            }
            index += 1
        }
        return annotateNeighbours(result)
    }

    /// A correction that is not a whole second quantity (review L3 C2): a unit only ("five hundred micrograms, sorry,
    /// milligrams" → 500 mg) or a bare number ("pulse 76, no, 86" → 86/min). A bare number after a dose, a pressure, a
    /// time, a frequency or a duration is not a full value, so the tag keeps no amount at all. Always flagged.
    func partialCorrection(of first: Quantity, startToken: Int, at afterMarker: Int) -> Quantity? {
        let start = tokens[startToken].start
        if first.kind == .dose, let value = first.value, let word = peek(afterMarker), let unit = Self.doseUnits[word] {
            var corrected = doseQuantity(value: value, baseUnit: unit, start: start, unitIndex: afterMarker)
            let said = text.utf16Substring(start, corrected.end)
            corrected.reviewReason =
                (["Self-correction: “\(said)” was corrected to “\(corrected.display)”."]
                + [corrected.reviewReason].compactMap { $0 }).joined(separator: " ")
            return corrected
        }
        guard let bare = hundredsShorthand(at: afterMarker) ?? cardinal(at: afterMarker) else { return nil }
        var corrected = first
        corrected.start = start
        corrected.end = tokens[bare.next - 1].end
        corrected.nextToken = bare.next
        let said = text.utf16Substring(start, corrected.end)
        let value = NumericNormalizer.format(bare.value)
        switch first.kind {
        case .rate, .oxygenSaturation, .temperature:
            corrected.value = bare.value
            corrected.display =
                switch first.kind {
                case .rate: "\(value)/min"
                case .oxygenSaturation: "\(value)%"
                default: "\(value) \(first.unit ?? "")"
                }
            corrected.reviewReason = "Self-correction: “\(said)” was corrected to “\(corrected.display)”."
        default:
            corrected.value = nil
            corrected.second = nil
            corrected.display = "? (said “\(said)”)"
            corrected.reviewReason = "Self-correction without a full value: “\(said)”. Enter the intended value."
        }
        return corrected
    }

    /// Words next to a quantity that change what it means (review L3 C1/C2): a number said right before a dose is
    /// carried into its tag, and a correction word right before any quantity (or right after one that has no reason
    /// yet) flags it.
    func annotateNeighbours(_ quantities: [Quantity]) -> [Quantity] {
        var result = quantities
        for index in result.indices {
            guard let first = tokens.firstIndex(where: { $0.start == result[index].start }) else { continue }
            let floor = index > 0 ? result[index - 1].nextToken : 0
            var reasons: [String] = []
            if result[index].kind == .dose, first - 1 >= floor, isNumberWord(first - 1) {
                var start = first - 1
                while start - 1 >= floor, isNumberWord(start - 1) { start -= 1 }
                let words = text.utf16Substring(tokens[start].start, tokens[first - 1].end)
                result[index].start = tokens[start].start
                reasons.append(
                    "“\(words)” was said right before \(result[index].display): check which amount was meant.")
            }
            if let marker = correctionMarker(before: first, floor: floor) {
                reasons.append("“\(marker)” was said right before \(result[index].display): check this value.")
            }
            if result[index].reviewReason == nil, correctionMarker(at: result[index].nextToken) != nil {
                reasons.append("A correction word follows \(result[index].display): check this value.")
            }
            guard !reasons.isEmpty else { continue }
            result[index].reviewReason = ([result[index].reviewReason].compactMap { $0 } + reasons)
                .joined(separator: " ")
        }
        return result
    }

    func isNumberWord(_ index: Int) -> Bool {
        guard index >= 0, index < tokens.count else { return false }
        let token = tokens[index]
        if token.isDigits { return !token.text.contains(":") && !token.text.contains("/") }
        return Self.units[token.text] != nil || Self.tens[token.text] != nil || token.text == "hundred"
            || token.text == "thousand"
    }

    // MARK: Recognizers

    func recognize(at index: Int) -> Quantity? {
        guard index < tokens.count else { return nil }
        return frequency(at: index) ?? bloodPressure(at: index) ?? time(at: index) ?? measured(at: index)
            ?? laterality(at: index)
    }

    /// "no", "sorry", "correction", "I mean", "rather", "make that", "actually", "scratch that", "wait", … with optional
    /// punctuation around it (several in a row count as one: "no, wait,"). Returns the token after the marker.
    func correctionMarker(at index: Int) -> Int? {
        var cursor = skipPunctuation(index)
        guard var next = markerEnd(at: cursor) else { return nil }
        while true {
            cursor = skipPunctuation(next)
            guard let again = markerEnd(at: cursor) else { break }
            next = again
        }
        return skipPunctuation(next)
    }

    /// The token after a correction phrase starting at `index`, or nil.
    func markerEnd(at index: Int) -> Int? {
        guard let word = peek(index) else { return nil }
        let following = peek(index + 1)
        switch word {
        case "no", "sorry", "correction", "rather", "actually", "wait", "oops": return index + 1
        case "i" where following == "mean" || following == "meant": return index + 2
        case "make" where following == "that" || following == "it": return index + 2
        case "scratch" where following == "that": return index + 2
        case "strike" where following == "that": return index + 2
        default: return nil
        }
    }

    /// A correction phrase that ends right before `index` (punctuation between is fine), at or after `floor`. Plain
    /// "no" is not counted here ("no fever, 98.6"); "not" is ("5 mg, not 50 mg").
    func correctionMarker(before index: Int, floor: Int) -> String? {
        var cursor = index - 1
        while cursor >= floor, cursor < tokens.count, Self.punctuation.contains(tokens[cursor].text) { cursor -= 1 }
        guard cursor >= floor, cursor < tokens.count else { return nil }
        let word = tokens[cursor].text
        let previous = cursor - 1 >= floor ? tokens[cursor - 1].text : nil
        switch word {
        case "sorry", "correction", "rather", "actually", "wait", "oops", "not": return tokens[cursor].original
        case "mean" where previous == "i", "meant" where previous == "i": return "I \(word)"
        case "that" where ["make", "scratch", "strike"].contains(previous ?? ""): return "\(previous!) that"
        case "it" where previous == "make": return "make it"
        default: return nil
        }
    }

    func frequency(at index: Int) -> Quantity? {
        let token = tokens[index]
        let word = token.text
        func make(_ value: Double?, _ unit: String?, _ display: String, _ last: Int) -> Quantity {
            Quantity(
                kind: .frequency, value: value, second: nil, unit: unit, display: display, start: token.start,
                end: tokens[last].end, nextToken: last + 1)
        }
        if Self.isQHours(token.original) {
            let digits = word.dropFirst().dropLast()
            let parts = digits.split(separator: "-").compactMap { Double($0) }
            guard let hours = parts.first else { return nil }
            let display =
                parts.count == 2
                ? "every \(NumericNormalizer.format(parts[0]))–\(NumericNormalizer.format(parts[1])) hours"
                : "every \(NumericNormalizer.format(hours)) hours"
            return extendAsNeeded(make(hours, "h", display, index))
        }
        switch word {
        case "bid": return extendAsNeeded(make(2, "per day", "twice daily", index))
        case "tid": return extendAsNeeded(make(3, "per day", "three times daily", index))
        case "qid": return extendAsNeeded(make(4, "per day", "four times daily", index))
        case "qd", "daily", "nightly":
            return extendAsNeeded(make(1, "per day", word == "nightly" ? "nightly" : "daily", index))
        case "qhs": return make(1, "per day", "at bedtime", index)
        case "prn": return make(nil, nil, "as needed", index)
        case "weekly": return make(1, "per week", "weekly", index)
        case "as" where peek(index + 1) == "needed": return make(nil, nil, "as needed", index + 1)
        case "at" where peek(index + 1) == "bedtime": return make(1, "per day", "at bedtime", index + 1)
        case "once", "twice":
            let count: Double = word == "once" ? 1 : 2
            if let (last, period) = perPeriod(after: index + 1) {
                let display =
                    period == "day"
                    ? (count == 1 ? "once daily" : "twice daily")
                    : "\(word) \(period == "week" ? "weekly" : "a \(period)")"
                return extendAsNeeded(make(count, "per \(period)", display, last))
            }
            return nil
        case "every":
            if let after = peek(index + 1) {
                switch after {
                case "day": return extendAsNeeded(make(1, "per day", "daily", index + 1))
                case "morning", "night", "evening":
                    return extendAsNeeded(make(1, "per day", "every \(after)", index + 1))
                case "other" where peek(index + 2) == "day":
                    return extendAsNeeded(make(0.5, "per day", "every other day", index + 2))
                default: break
                }
            }
            if let number = cardinal(at: index + 1), let unit = timeUnit(peekSkippingHyphen(number.next)) {
                let last = indexSkippingHyphen(number.next)
                let display = "every \(NumericNormalizer.format(number.value)) \(Self.spelledUnit(unit, number.value))"
                return extendAsNeeded(make(number.value, unit, display, last))
            }
            return nil
        default:
            break
        }
        // "three times a day", "2 times daily"
        if let number = cardinal(at: index), peek(number.next) == "times",
            let (last, period) = perPeriod(after: number.next + 1)
        {
            let display = "\(NumericNormalizer.format(number.value)) times \(period == "day" ? "daily" : "a \(period)")"
            return extendAsNeeded(make(number.value, "per \(period)", display, last))
        }
        return nil
    }

    /// "a day", "per day", "daily", "a week", "weekly" after once/twice/N times.
    func perPeriod(after index: Int) -> (last: Int, period: String)? {
        switch peek(index) {
        case "daily": return (index, "day")
        case "weekly": return (index, "week")
        case "a", "per", "each", "every":
            if let period = peek(index + 1), ["day", "week", "month"].contains(period) { return (index + 1, period) }
            return nil
        default: return nil
        }
    }

    /// Joins a directly following "as needed" / "PRN" into the same frequency.
    func extendAsNeeded(_ quantity: Quantity) -> Quantity {
        var result = quantity
        var cursor = quantity.nextToken
        if peek(cursor) == "," { cursor += 1 }
        if peek(cursor) == "prn" {
            result.end = tokens[cursor].end
            result.nextToken = cursor + 1
            result.display += " as needed"
        } else if peek(cursor) == "as", peek(cursor + 1) == "needed" {
            result.end = tokens[cursor + 1].end
            result.nextToken = cursor + 2
            result.display += " as needed"
        }
        return result
    }

    func bloodPressure(at index: Int) -> Quantity? {
        let token = tokens[index]
        if token.isDigits, token.text.contains("/") {
            let parts = token.text.split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, (40...300).contains(parts[0]), (20...200).contains(parts[1]) else { return nil }
            return pressure(parts[0], parts[1], start: token.start, lastToken: index)
        }
        guard let systolic = vitalNumber(at: index), peek(systolic.next) == "over",
            let diastolic = vitalNumber(at: systolic.next + 1, afterOver: true)
        else { return nil }
        return pressure(systolic.value, diastolic.value, start: token.start, lastToken: diastolic.next - 1)
    }

    private func pressure(_ systolic: Double, _ diastolic: Double, start: Int, lastToken: Int) -> Quantity {
        var last = lastToken
        if peek(last + 1) == "mmhg" { last += 1 }
        return Quantity(
            kind: .bloodPressure, value: systolic, second: diastolic, unit: "mmHg",
            display: "\(NumericNormalizer.format(systolic))/\(NumericNormalizer.format(diastolic)) mmHg",
            start: start, end: tokens[last].end, nextToken: last + 1)
    }

    func time(at index: Int) -> Quantity? {
        let token = tokens[index]
        // "14:02", "2:30 pm"
        if token.isDigits, token.text.contains(":") {
            let parts = token.text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] < 24, parts[1] < 60 else { return nil }
            return clock(hour: parts[0], minute: parts[1], start: token.start, lastToken: index)
        }
        // "fourteen oh two", "oh eight hundred", "2 pm", "fourteen hundred hours"
        var cursor = index
        if token.text == "oh" || token.text == "zero" { cursor += 1 }
        guard let hour = cardinal(at: cursor, wordsOnly: false), hour.value == hour.value.rounded() else {
            return nil
        }
        let hourValue = Int(hour.value)
        if peek(hour.next) == "oh", let digit = cardinal(at: hour.next + 1), digit.value < 10, hourValue < 24,
            digit.next == hour.next + 2
        {
            return clock(hour: hourValue, minute: Int(digit.value), start: token.start, lastToken: digit.next - 1)
        }
        let ledByOh = cursor > index
        if hour.value >= 100, hour.value <= 2359, Int(hour.value) % 100 < 60, peek(hour.next) == "hours" || ledByOh {
            // "fourteen hundred hours", "1400 hours"
            return clock(
                hour: hourValue / 100, minute: hourValue % 100, start: token.start, lastToken: hour.next - 1)
        }
        if hourValue <= 12, hourValue >= 1, let meridiem = peek(hour.next), meridiem == "am" || meridiem == "pm" {
            return clock(hour: hourValue, minute: 0, start: token.start, lastToken: hour.next - 1)
        }
        return nil
    }

    private func clock(hour: Int, minute: Int, start: Int, lastToken: Int) -> Quantity {
        var hour24 = hour
        var last = lastToken
        if let meridiem = peek(last + 1), meridiem == "am" || meridiem == "pm", hour >= 1, hour <= 12 {
            if meridiem == "pm", hour < 12 { hour24 = hour + 12 }
            if meridiem == "am", hour == 12 { hour24 = 0 }
            last += 1
        } else if peek(last + 1) == "hours" {
            last += 1
        }
        let display = String(format: "%02d:%02d", hour24, minute)
        return Quantity(
            kind: .time, value: Double(hour24 * 60 + minute), second: nil, unit: "min after midnight",
            display: display, start: start, end: tokens[last].end, nextToken: last + 1)
    }

    /// A number followed by a unit, or preceded by a vital sign's name.
    func measured(at index: Int) -> Quantity? {
        if let dose = spokenHundredsDose(at: index) { return dose }
        guard let number = vitalNumber(at: index) ?? cardinal(at: index) else { return nil }
        let start = tokens[index].start
        let unitIndex = indexSkippingHyphen(number.next)
        let unitWord = peek(unitIndex)
        func make(_ kind: NumericTag.Kind, _ unit: String?, _ display: String, _ last: Int) -> Quantity {
            Quantity(
                kind: kind, value: number.value, second: nil, unit: unit, display: display, start: start,
                end: tokens[last].end, nextToken: last + 1)
        }
        let value = NumericNormalizer.format(number.value)

        if let unitWord, let dose = Self.doseUnits[unitWord] {
            return doseQuantity(value: number.value, baseUnit: dose, start: start, unitIndex: unitIndex)
        }
        if unitWord == "percent" || unitWord == "%" {
            guard hasContext(before: index, Self.saturationWords) || nextIs(unitIndex + 1, ["on"]) else { return nil }
            return make(.oxygenSaturation, "%", "\(value)%", unitIndex)
        }
        if let unitWord, ["degrees", "degree", "fahrenheit", "celsius", "°"].contains(unitWord) {
            var last = unitIndex
            var scale = number.value > 50 ? "°F" : "°C"
            if let next = peek(unitIndex + 1), ["fahrenheit", "f"].contains(next) {
                scale = "°F"
                last += 1
            } else if let next = peek(unitIndex + 1), ["celsius", "c", "centigrade"].contains(next) {
                scale = "°C"
                last += 1
            } else if unitWord == "celsius" {
                scale = "°C"
            } else if unitWord == "fahrenheit" {
                scale = "°F"
            }
            return make(.temperature, scale, "\(value) \(scale)", last)
        }
        if hasContext(before: index, Self.temperatureWords),
            (93...110).contains(number.value) || (34...43).contains(number.value)
        {
            let scale = number.value > 50 ? "°F" : "°C"
            return make(.temperature, scale, "\(value) \(scale)", number.next - 1)
        }
        if let unitWord, unitWord == "bpm" || unitWord == "beats" || unitWord == "breaths" {
            var last = unitIndex
            if peek(last + 1) == "per", peek(last + 2) == "minute" { last += 2 }
            return make(.rate, "/min", "\(value)/min", last)
        }
        if hasContext(before: index, Self.rateWords) {
            return make(.rate, "/min", "\(value)/min", number.next - 1)
        }
        if let unit = timeUnit(unitWord) {
            // "45 year old", "45-year-old": an age, not a duration.
            if unit == "yr", peekSkippingHyphen(unitIndex + 1) == "old" { return nil }
            return make(.duration, unit, "\(value) \(Self.spelledUnit(unit, number.value))", unitIndex)
        }
        return nil
    }

    /// "one twenty-five micrograms" = 125 mcg, never 25 (review L3 C1). Always flagged: it could also mean one 25 mcg
    /// tablet.
    func spokenHundredsDose(at index: Int) -> Quantity? {
        guard let number = hundredsShorthand(at: index) else { return nil }
        let unitIndex = indexSkippingHyphen(number.next)
        guard let word = peek(unitIndex), let unit = Self.doseUnits[word] else { return nil }
        let said = text.utf16Substring(tokens[index].start, tokens[unitIndex].end)
        return doseQuantity(
            value: number.value, baseUnit: unit, start: tokens[index].start, unitIndex: unitIndex,
            reason:
                "“\(said)” was read as \(NumericNormalizer.format(number.value)) \(unit) (hundreds said without "
                + "“hundred”): check the amount.")
    }

    /// A dose ending at the unit word at `unitIndex`, extended over a following "per kg", "/kg/min", "an hour" or
    /// "/5 mL" (review L3 C1): the unit becomes "mg/kg", "mcg/kg/min", "g/h", and the tag always needs review. Unknown
    /// words after "per" or "/" are carried into the tag and flagged; a route after "per" ("per mouth") is not.
    func doseQuantity(value: Double, baseUnit: String, start: Int, unitIndex: Int, reason: String? = nil) -> Quantity {
        var denominators: [String] = []
        var last = unitIndex
        var cursor = unitIndex + 1
        var unknown = false
        while let separator = peek(cursor), ["per", "/", "a", "an"].contains(separator) {
            let word = peek(cursor + 1)
            if let word, let denominator = Self.denominatorUnits[word] {
                denominators.append(denominator)
                last = cursor + 1
                cursor += 2
                continue
            }
            if separator == "/" || separator == "per", let amount = cardinal(at: cursor + 1),
                let unit = peek(amount.next).flatMap({ Self.doseUnits[$0] })
            {
                denominators.append("\(NumericNormalizer.format(amount.value)) \(unit)")
                last = amount.next
                cursor = amount.next + 1
                continue
            }
            if separator == "per", let word, Self.routeWords.contains(word) { break }
            if separator == "per" || separator == "/", word != nil {
                unknown = true
                last = cursor + 1
            }
            break
        }
        let unit = ([baseUnit] + denominators).joined(separator: "/")
        let said = text.utf16Substring(start, tokens[last].end)
        var reasons = [reason].compactMap { $0 }
        if !denominators.isEmpty {
            reasons.append("“\(said)” is a weight- or time-based dose (\(unit)): check the amount and the unit.")
        }
        if unknown { reasons.append("“\(said)”: the words after the unit may change the dose. Check it.") }
        return Quantity(
            kind: .dose, value: value, second: nil, unit: unit, display: "\(NumericNormalizer.format(value)) \(unit)",
            start: start, end: tokens[last].end, nextToken: last + 1,
            reviewReason: reasons.isEmpty ? nil : reasons.joined(separator: " "))
    }

    func laterality(at index: Int) -> Quantity? {
        let side: String
        switch tokens[index].text {
        case "left": side = "L"
        case "right": side = "R"
        case "bilateral", "bilaterally": side = "bilateral"
        default: return nil
        }
        return Quantity(
            kind: .laterality, value: nil, second: nil, unit: side, display: tokens[index].text,
            start: tokens[index].start, end: tokens[index].end, nextToken: index + 1)
    }

    // MARK: Numbers

    /// A cardinal number at `index`: digits ("142", "0.5", "1,000") or words ("ninety eight point six",
    /// "one hundred forty two", "forty-two"). `next` is the token index after it.
    func cardinal(at index: Int, wordsOnly: Bool = false) -> (value: Double, next: Int)? {
        guard index < tokens.count else { return nil }
        let token = tokens[index]
        if token.isDigits {
            guard !wordsOnly, !token.text.contains(":"), !token.text.contains("/"),
                let value = Double(token.text.replacingOccurrences(of: ",", with: ""))
            else { return nil }
            return (value, index + 1)
        }
        var total = 0.0
        var current = 0.0
        var cursor = index
        var any = false
        var lastKind = ""  // "unit", "teen", "tens", "hundred", "thousand"
        while cursor < tokens.count {
            let word = tokens[cursor].text
            if word == "-", any, cursor + 1 < tokens.count, Self.tens[tokens[cursor - 1].text] != nil {
                cursor += 1
                continue
            }
            if let unit = Self.units[word] {
                if unit < 10, lastKind == "unit" || lastKind == "teen" { break }
                if unit >= 10, lastKind == "unit" || lastKind == "teen" || lastKind == "tens" { break }
                current += Double(unit)
                lastKind = unit >= 10 ? "teen" : "unit"
            } else if let tens = Self.tens[word] {
                if lastKind == "unit" || lastKind == "teen" || lastKind == "tens" { break }
                current += Double(tens)
                lastKind = "tens"
            } else if word == "hundred", any, lastKind != "hundred", lastKind != "thousand" || current > 0 {
                current = max(current, 1) * 100
                lastKind = "hundred"
            } else if word == "thousand", any {
                total += max(current, 1) * 1000
                current = 0
                lastKind = "thousand"
            } else if word == "and", lastKind == "hundred", let next = peek(cursor + 1),
                Self.units[next] != nil || Self.tens[next] != nil
            {
                cursor += 1
                continue
            } else {
                break
            }
            any = true
            cursor += 1
        }
        guard any else {
            // "point five"
            if token.text == "point", let decimals = decimalDigits(at: index + 1) {
                return (decimals.value, decimals.next)
            }
            return nil
        }
        var value = total + current
        if peek(cursor) == "point", let decimals = decimalDigits(at: cursor + 1) {
            value += decimals.value
            cursor = decimals.next
        }
        return (value, cursor)
    }

    /// Digits after "point": "six" → 0.6, "two five" → 0.25, "5" → 0.5.
    func decimalDigits(at index: Int) -> (value: Double, next: Int)? {
        var digits = ""
        var cursor = index
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.isDigits, digits.isEmpty, token.text.allSatisfy(\.isNumber) {
                digits = token.text
                cursor += 1
                break
            }
            if let unit = Self.units[token.text], unit < 10 {
                digits += String(unit)
                cursor += 1
            } else if token.text == "oh" {
                digits += "0"
                cursor += 1
            } else {
                break
            }
        }
        guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
        return (value, cursor)
    }

    /// The spoken hundreds shorthand with no context check: "one twenty-five" = 125, "two fifty" = 250, "one oh one
    /// point two" = 101.2. Nil for anything else ("one hundred" is an ordinary cardinal).
    func hundredsShorthand(at index: Int) -> (value: Double, next: Int)? {
        guard index < tokens.count, !tokens[index].isDigits, let hundreds = Self.units[tokens[index].text],
            (1...9).contains(hundreds), let next = peek(index + 1)
        else { return nil }
        if next == "oh", let digit = peek(index + 2).flatMap({ Self.units[$0] }), digit < 10 {
            var value = Double(hundreds * 100 + digit)
            var cursor = index + 3
            if peek(cursor) == "point", let decimals = decimalDigits(at: cursor + 1) {
                value += decimals.value
                cursor = decimals.next
            }
            return (value, cursor)
        }
        if Self.tens[next] != nil || (Self.units[next] ?? 0) >= 10, let rest = cardinal(at: index + 1), rest.value < 100
        {
            return (Double(hundreds * 100) + rest.value, rest.next)
        }
        return nil
    }

    /// A vital-sign number, which allows the spoken hundreds shorthand: "one twenty" = 120, "one forty two" = 142,
    /// "one oh one point two" = 101.2. Used only for pressures, rates and temperatures.
    func vitalNumber(at index: Int, afterOver: Bool = false) -> (value: Double, next: Int)? {
        guard index < tokens.count else { return nil }
        func inVitalContext(_ next: Int) -> Bool {
            afterOver || peek(next) == "over" || nextIs(next, ["degrees", "fahrenheit", "bpm"])
                || hasContext(before: index, Self.rateWords + Self.temperatureWords + ["pressure", "bp"])
        }
        if let shorthand = hundredsShorthand(at: index), shorthand.value < 300, inVitalContext(shorthand.next) {
            return shorthand
        }
        guard let plain = cardinal(at: index) else { return nil }
        return inVitalContext(plain.next) ? plain : nil
    }

    // MARK: Helpers

    func peek(_ index: Int) -> String? {
        index >= 0 && index < tokens.count ? tokens[index].text : nil
    }

    func skipPunctuation(_ index: Int) -> Int {
        var cursor = index
        while cursor < tokens.count, Self.punctuation.contains(tokens[cursor].text) {
            cursor += 1
        }
        return cursor
    }

    func indexSkippingHyphen(_ index: Int) -> Int {
        peek(index) == "-" ? index + 1 : index
    }

    func peekSkippingHyphen(_ index: Int) -> String? {
        peek(indexSkippingHyphen(index))
    }

    func nextIs(_ index: Int, _ words: [String]) -> Bool {
        peek(index).map(words.contains) ?? false
    }

    /// One of `words` within the four tokens before `index`, in the same clause (review L3 I3): the look-back stops at a
    /// sentence or clause break (". ; ," and "on", "and", "with", …) and at another number, so "heart rate 110 on
    /// metoprolol 25" gives one rate, not two.
    func hasContext(before index: Int, _ words: [String]) -> Bool {
        var cursor = index - 1
        var seen = 0
        while cursor >= 0, seen < 4 {
            let token = tokens[cursor]
            if Self.clauseBreaks.contains(token.text) { return false }
            if words.contains(token.text) { return true }
            if token.isDigits || Self.units[token.text] != nil || Self.tens[token.text] != nil { return false }
            cursor -= 1
            seen += 1
        }
        return false
    }

    func timeUnit(_ word: String?) -> String? {
        guard let word else { return nil }
        return Self.timeUnits[word]
    }

    static func spelledUnit(_ unit: String, _ value: Double) -> String {
        let one = value == 1
        switch unit {
        case "s": return one ? "second" : "seconds"
        case "min": return one ? "minute" : "minutes"
        case "h": return one ? "hour" : "hours"
        case "d": return one ? "day" : "days"
        case "wk": return one ? "week" : "weeks"
        case "mo": return one ? "month" : "months"
        case "yr": return one ? "year" : "years"
        default: return unit
        }
    }

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let doseUnits: [String: String] = [
        "mg": "mg", "milligram": "mg", "milligrams": "mg",
        "mcg": "mcg", "microgram": "mcg", "micrograms": "mcg", "ug": "mcg",
        "g": "g", "gram": "g", "grams": "g", "gm": "g",
        "unit": "units", "units": "units",
        "ml": "mL", "milliliter": "mL", "milliliters": "mL", "millilitre": "mL", "millilitres": "mL", "cc": "mL",
        "ccs": "mL",
        "tablet": "tablet", "tablets": "tablet", "tab": "tablet", "tabs": "tablet", "pill": "tablet",
        "pills": "tablet", "capsule": "tablet", "capsules": "tablet",
        "puff": "puff", "puffs": "puff", "drop": "drop", "drops": "drop",
        "meq": "mEq", "milliequivalents": "mEq",
    ]
    static let timeUnits: [String: String] = [
        "second": "s", "seconds": "s", "sec": "s", "secs": "s",
        "minute": "min", "minutes": "min", "min": "min", "mins": "min",
        "hour": "h", "hours": "h", "hr": "h", "hrs": "h",
        "day": "d", "days": "d", "week": "wk", "weeks": "wk", "wk": "wk", "wks": "wk",
        "month": "mo", "months": "mo", "year": "yr", "years": "yr",
    ]
    /// After "per" or "/" (or "a"/"an") following a dose unit.
    static let denominatorUnits: [String: String] = [
        "kg": "kg", "kgs": "kg", "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kilos": "kg",
        "lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb",
        "hour": "h", "hours": "h", "hr": "h", "hrs": "h", "h": "h",
        "minute": "min", "minutes": "min", "min": "min", "mins": "min",
        "day": "day", "days": "day", "week": "wk", "weeks": "wk", "dose": "dose",
    ]
    /// "per mouth" is a route, not part of the dose.
    static let routeWords: Set<String> = ["mouth", "os", "rectum", "tube", "ng", "og", "peg", "vagina"]
    static let punctuation: Set<String> = [",", ".", ";", ":", "-", "—", "–", "…"]
    static let clauseBreaks: Set<String> = [
        ".", ";", ",", "on", "and", "with", "after", "but", "for", "while", "then", "plus", "also",
    ]
    static let saturationWords = ["sat", "sats", "saturation", "saturating", "spo2", "o2", "oxygen", "ox", "pulse-ox"]
    static let temperatureWords = ["temp", "temperature", "febrile", "tmax"]
    static let rateWords = ["pulse", "hr", "heart", "rate", "rr", "respiratory", "respirations", "resp", "tachycardic"]
}

extension String {
    /// The substring between two UTF-16 offsets.
    fileprivate func utf16Substring(_ start: Int, _ end: Int) -> String {
        (self as NSString).substring(with: NSRange(location: start, length: end - start))
    }
}
