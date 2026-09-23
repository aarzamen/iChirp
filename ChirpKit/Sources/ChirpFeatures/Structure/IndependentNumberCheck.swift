import ChirpText
import Foundation

/// A second reading of the words a number came from, independent of `NumericNormalizer` (review L3 I1).
///
/// It shares no code with the normalizer: digits come from one regular expression, spelled numbers from Foundation's
/// lenient spell-out `NumberFormatter` ("one twenty-five" → 125), and units from its own small word list. The
/// validator compares this reading with the side table, and a disagreement forces review. The neighbour checks
/// (`SentenceNeighbours`) look at the words *around* a tag, which a too-short tag would otherwise hide.
enum IndependentNumberReader {
    struct Reading: Equatable {
        /// Every number in the words, in order ("five, no, fifty" → [5, 50]; "142/88" → [142, 88]).
        var numbers: [Double] = []
        /// Dose units in order ("mg", "mcg", "g", "units", "mL", "tablet", "puff", "drop", "mEq").
        var units: [String] = []
        /// What follows "per", "/", "a" or "an": "kg", "h", "min", "day", "lb", "wk", "dose".
        var denominators: [String] = []
    }

    /// A digit run with no letter right before it ("500mg" counts; "SpO2" and "q6h" do not), a word, or "/", "%",
    /// "," or ";" (a comma ends a run of number words: "two, three" is two numbers).
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])\d+(?:,\d{3})*(?:\.\d+)?|[A-Za-z]+|/|%|,|;"#)

    static func read(_ text: String) -> Reading {
        let ns = text as NSString
        let tokens = tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased()
        }
        var reading = Reading()
        var group: [String] = []
        func flush() {
            if !group.isEmpty { reading.numbers += parse(group) }
            group = []
        }
        for (index, token) in tokens.enumerated() {
            if let first = token.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
                flush()
                if let value = Double(token.replacingOccurrences(of: ",", with: "")) { reading.numbers.append(value) }
                continue
            }
            // Re-review C1-R: "a hundred" is one hundred, and "and" belongs to a number only after "hundred" or
            // "thousand" ("a hundred and twenty-five" is 125; "fifty and a hundred" is 50, then 100).
            if token == "a" || token == "an", index + 1 < tokens.count,
                ["hundred", "thousand"].contains(tokens[index + 1])
            {
                flush()
                group.append("one")
                continue
            }
            if isNumberWord(token) || (token == "and" && ["hundred", "thousand"].contains(group.last ?? ""))
                || ((token == "oh" || token == "point") && (!group.isEmpty || token == "point"))
            {
                group.append(token)
                continue
            }
            flush()
            if let unit = doseUnits[token] { reading.units.append(unit) }
            if ["per", "/", "a", "an"].contains(token), index + 1 < tokens.count,
                let denominator = denominators[tokens[index + 1]]
            {
                reading.denominators.append(denominator)
            }
        }
        flush()
        return reading
    }

    /// One run of number words → its value(s): the spell-out formatter first, then "one oh one" digit-by-digit, then
    /// each word on its own (which will disagree with a tag, forcing review, rather than guess).
    static func parse(_ words: [String]) -> [Double] {
        var words = words
        while words.last == "and" || words.last == "point" || words.last == "oh" { words.removeLast() }
        guard !words.isEmpty else { return [] }
        if words.first == "point" { words.insert("zero", at: 0) }
        if words.first == "hundred" || words.first == "thousand" { words.insert("one", at: 0) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        formatter.isLenient = true
        if !words.contains("oh"), let value = formatter.number(from: words.joined(separator: " ")) {
            return [value.doubleValue]
        }
        if let oh = words.firstIndex(of: "oh"), oh > 0,
            let hundreds = formatter.number(from: words[..<oh].joined(separator: " "))?.doubleValue,
            let digit = words.dropFirst(oh + 1).first.flatMap({ formatter.number(from: $0)?.doubleValue }), digit < 10
        {
            var value = hundreds * 100 + digit
            if let point = words.firstIndex(of: "point"), point > oh,
                let decimals = formatter.number(from: "zero point " + words[(point + 1)...].joined(separator: " "))
            {
                value += decimals.doubleValue
            }
            return [value]
        }
        return words.compactMap { formatter.number(from: $0)?.doubleValue }
    }

    static func isNumberWord(_ word: String) -> Bool {
        numberWords.contains(word)
    }

    /// The first range in the words, or nil (re-review N2): "4 to 8", "4-8", "500 or 1000", "fifty and a hundred".
    /// "a hundred and twenty" is one number, not a range.
    static func range(in text: String) -> String? {
        let ns = text as NSString
        let match = rangePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        return match.map { ns.substring(with: $0.range) }
    }

    private static let rangePattern: NSRegularExpression = {
        let smallWords = numberWords.subtracting(["hundred", "thousand"]).sorted().joined(separator: "|")
        let small = "(?:\\d+(?:\\.\\d+)?|\(smallWords))"
        let any = "(?:\\d+(?:\\.\\d+)?|\(numberWords.sorted().joined(separator: "|")))"
        let pattern =
            "\\d+(?:\\.\\d+)?\\s*[-–—]\\s*\\d"
            + "|\\b\(any)\\s+(?:to|or|through)\\s+(?:a\\s+)?\(any)\\b"
            + "|\\b\(small)\\s+and\\s+(?:a\\s+)?\(any)\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func same(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= max(1e-6, abs(b) * 1e-9)
    }

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
        "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
    ]
    private static let doseUnits: [String: String] = [
        "mg": "mg", "mgs": "mg", "milligram": "mg", "milligrams": "mg",
        "mcg": "mcg", "ug": "mcg", "microgram": "mcg", "micrograms": "mcg",
        "g": "g", "gm": "g", "gram": "g", "grams": "g",
        "unit": "units", "units": "units",
        "ml": "mL", "cc": "mL", "ccs": "mL", "milliliter": "mL", "milliliters": "mL", "millilitre": "mL",
        "millilitres": "mL",
        "tablet": "tablet", "tablets": "tablet", "tab": "tablet", "tabs": "tablet", "pill": "tablet", "pills": "tablet",
        "capsule": "tablet", "capsules": "tablet",
        "puff": "puff", "puffs": "puff", "drop": "drop", "drops": "drop", "meq": "mEq", "milliequivalents": "mEq",
    ]
    private static let denominators: [String: String] = [
        "kg": "kg", "kgs": "kg", "kilogram": "kg", "kilograms": "kg", "kilo": "kg", "kilos": "kg", "lb": "lb",
        "lbs": "lb", "pound": "lb", "pounds": "lb", "hour": "h", "hours": "h", "hr": "h", "hrs": "h", "h": "h",
        "minute": "min", "minutes": "min", "min": "min", "mins": "min", "day": "day", "days": "day", "week": "wk",
        "weeks": "wk", "dose": "dose",
    ]
}

/// Checks a tag against an independent reading of its own words and of the words around it (review L3 I1).
enum IndependentNumberCheck {
    static func problems(for tag: NumericTag, in sentence: String) -> [String] {
        var problems: [String] = []
        let reading = IndependentNumberReader.read(tag.sourceText)
        let quoted = "“\(tag.sourceText)”"
        func readsAs(_ values: [Double]) -> String {
            values.map(NumericNormalizer.format).joined(separator: ", ")
        }
        switch tag.kind {
        case .dose:
            if let value = tag.value {
                if let last = reading.numbers.last {
                    if !IndependentNumberReader.same(last, value) {
                        problems.append(
                            "The words \(quoted) read as \(readsAs(reading.numbers)), not \(tag.display).")
                    }
                } else {
                    problems.append("No number could be read from \(quoted), but the field says \(tag.display).")
                }
            }
            let parts = (tag.unit ?? "").split(separator: "/").map(String.init)
            let base = parts.first ?? ""
            if reading.units.last != base {
                problems.append(
                    "The words \(quoted) say \(reading.units.last ?? "no unit"), not \(base.isEmpty ? "no unit" : base)."
                )
            }
            let tagDenominators = parts.dropFirst().filter { !$0.contains(" ") }
            if Set(tagDenominators) != Set(reading.denominators) {
                problems.append(
                    "The words \(quoted) and the unit \(tag.unit ?? "none") disagree on per-weight or per-time.")
            }
        case .bloodPressure:
            let pair = Array(reading.numbers.suffix(2))
            if pair.count != 2 || tag.value.map({ !IndependentNumberReader.same(pair[0], $0) }) ?? true
                || tag.secondValue.map({ !IndependentNumberReader.same(pair[1], $0) }) ?? true
            {
                problems.append("The words \(quoted) read as \(readsAs(reading.numbers)), not \(tag.display).")
            }
        case .rate, .oxygenSaturation, .temperature:
            if let value = tag.value, reading.numbers.last.map({ !IndependentNumberReader.same($0, value) }) ?? true {
                problems.append("The words \(quoted) read as \(readsAs(reading.numbers)), not \(tag.display).")
            }
        case .frequency:
            if let value = tag.value, reading.numbers.count == 1,
                !IndependentNumberReader.same(reading.numbers[0], value)
            {
                problems.append("The words \(quoted) read as \(readsAs(reading.numbers)), not \(tag.display).")
            }
        case .time, .duration, .laterality:
            break
        }
        // Re-review N2: a range in the tag's own words is never one value.
        if [.dose, .rate, .oxygenSaturation, .temperature].contains(tag.kind), tag.value != nil,
            let range = IndependentNumberReader.range(in: tag.sourceText)
        {
            problems.append("“\(range)” is a range, but the field holds one value (\(tag.display)). Check it.")
        }
        problems += SentenceNeighbours.problems(for: tag, in: sentence)
        return problems
    }
}

/// The words right around a tag, and whole-sentence checks the validator makes without the normalizer.
enum SentenceNeighbours {
    /// A word (letters or digits) with its UTF-16 range.
    struct Word {
        let text: String
        let range: Range<Int>
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[A-Za-z]+|\d+(?:[.,:]\d+)*|/"#)

    static func words(_ text: String) -> [Word] {
        let ns = text as NSString
        return wordPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Word(text: ns.substring(with: $0.range).lowercased(), range: $0.range.location..<NSMaxRange($0.range))
        }
    }

    /// Words that correct what was just said. Plain "no" counts only between commas or dashes (see `correction(in:)`).
    static let correctionWords: Set<String> = ["sorry", "correction", "rather", "actually", "wait", "oops"]
    /// Words that can sit inside a spoken number or between two numbers said together ("a hundred *and* twelve",
    /// "fifty *and a* hundred").
    static let spokenNumberJoiners: Set<String> = ["and", "a", "an"]
    /// Words that join the two ends of a range ("4 *to* 8", "500 *or* 1000").
    static let rangeWords: Set<String> = ["to", "or", "through"]
    static let routeWords: Set<String> = ["mouth", "os", "rectum", "tube", "ng", "og", "peg", "vagina"]
    static let timeOrWeight = ["kg", "kilo", "kilogram", "hour", "minute", "day", "week"]
    static let correctionPairs: Set<String> = [
        "i mean", "i meant", "scratch that", "strike that", "make that", "make it",
    ]

    static func problems(for tag: NumericTag, in sentence: String) -> [String] {
        guard [.dose, .bloodPressure, .rate, .oxygenSaturation, .temperature].contains(tag.kind) else { return [] }
        let all = words(sentence)
        let before = all.filter { $0.range.upperBound <= tag.sourceRange.lowerBound }
        let after = all.filter { $0.range.lowerBound >= tag.sourceRange.upperBound }
        var problems: [String] = []
        let ns = sentence as NSString
        func gap(_ from: Int, _ to: Int) -> String {
            ns.substring(with: NSRange(location: from, length: max(0, to - from)))
        }
        // Re-review C1-R: the words right before the tag, across "and" / "a" inside a spoken number. The whole spoken
        // number is re-read, so "a hundred and" before "twenty-five micrograms" reads as 125, not 25.
        var run: [Word] = []
        var edge = tag.sourceRange.lowerBound
        for word in before.reversed() {
            guard gap(word.range.upperBound, edge).allSatisfy({ $0 == " " || $0 == "-" || $0 == "–" }),
                isNumber(word.text) || spokenNumberJoiners.contains(word.text) || rangeWords.contains(word.text)
            else { break }
            run.insert(word, at: 0)
            edge = word.range.lowerBound
        }
        if let firstNumber = run.firstIndex(where: { isNumber($0.text) }) {
            let start = run[run.first?.text == "a" || run.first?.text == "an" ? 0 : firstNumber].range.lowerBound
            let spoken = gap(start, tag.sourceRange.upperBound)
            let said = gap(start, tag.sourceRange.lowerBound).trimmingCharacters(in: .whitespaces)
            let whole = IndependentNumberReader.read(spoken).numbers
            if let range = IndependentNumberReader.range(in: spoken) {
                // Re-review N2: "4 to" before "8 mg" makes it a range.
                problems.append(
                    "“\(said)” was said right before “\(tag.sourceText)”: “\(range)” is a range, not one value. Check it."
                )
            } else if whole.count == 1, let value = tag.value, !IndependentNumberReader.same(whole[0], value) {
                problems.append(
                    "The spoken number “\(spoken)” reads as \(NumericNormalizer.format(whole[0])), not \(tag.display).")
            } else {
                problems.append("“\(said)” was said right before “\(tag.sourceText)”: check which amount was meant.")
            }
        }
        // Re-review N2: "100" followed by "to 120" (or "-120") is a range, not one value. Never across "and".
        if let next = after.first {
            let between = gap(tag.sourceRange.upperBound, next.range.lowerBound).trimmingCharacters(in: .whitespaces)
            let byWord =
                after.count >= 2 && between.isEmpty && rangeWords.contains(next.text) && isNumber(after[1].text)
            let byDash = ["-", "–", "—"].contains(between) && isNumber(next.text)
            if byWord || byDash {
                let phrase = byWord ? "\(next.text) \(after[1].text)" : "\(between)\(next.text)"
                problems.append(
                    "“\(tag.sourceText)” is followed by “\(phrase)”: a range, not one value. Check it.")
            }
        }
        if tag.kind == .dose, after.count >= 2,
            gap(tag.sourceRange.upperBound, after[0].range.lowerBound).trimmingCharacters(in: .whitespaces).isEmpty
        {
            let next = after[0].text
            let following = after[1].text
            let phrase = next == "/" ? "/\(following)" : "\(next) \(following)"
            let perSomething = next == "/" || (next == "per" && !routeWords.contains(following))
            let perTime = ["a", "an"].contains(next) && timeOrWeight.contains { following.hasPrefix($0) }
            if perSomething || perTime {
                problems.append(
                    "“\(tag.sourceText)” is followed by “\(phrase)”: the dose may be per weight or per time. Check the unit."
                )
            }
        }
        if let marker = correction(before.suffix(2)) ?? correction(Array(after.prefix(2)), leading: true) {
            problems.append("“\(marker)” was said next to “\(tag.sourceText)”: check this value.")
        }
        return problems
    }

    /// A correction phrase among two neighbouring words.
    private static func correction(_ words: ArraySlice<Word>) -> String? {
        correction(Array(words), leading: false)
    }

    private static func correction(_ words: [Word], leading: Bool) -> String? {
        let texts = words.map(\.text)
        if texts.count == 2, correctionPairs.contains(texts.joined(separator: " ")) {
            return texts.joined(separator: " ")
        }
        let nearest = leading ? texts.first : texts.last
        if let nearest, correctionWords.contains(nearest) { return nearest }
        if let nearest, nearest == "not", !leading { return nearest }
        if leading, texts.first == "no", let second = texts.dropFirst().first, SentenceNeighbours.isNumber(second) {
            return "no"
        }
        return nil
    }

    /// A spoken correction anywhere in the sentence ("sorry", "I mean", ", no,", "scratch that", …), or nil.
    static func correction(in sentence: String) -> String? {
        let all = words(sentence).map(\.text)
        for (index, word) in all.enumerated() {
            if correctionWords.contains(word) { return word }
            if index + 1 < all.count, correctionPairs.contains("\(word) \(all[index + 1])") {
                return "\(word) \(all[index + 1])"
            }
        }
        if sentence.lowercased().range(of: #"[,—–-]\s*no\s*[,—–-]|\bno,? wait\b"#, options: .regularExpression) != nil {
            return "no"
        }
        return nil
    }

    /// Case-insensitive, whole-word mentions of `name` in `sentence` (UTF-16 ranges).
    static func mentions(of name: String, in sentence: String) -> [Range<Int>] {
        let escaped = NSRegularExpression.escapedPattern(for: name.trimmingCharacters(in: .whitespaces))
        guard !escaped.isEmpty,
            let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive])
        else { return [] }
        let ns = sentence as NSString
        return regex.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map {
            $0.range.location..<NSMaxRange($0.range)
        }
    }

    /// Number of words strictly between two non-overlapping ranges.
    static func wordsBetween(_ a: Range<Int>, _ b: Range<Int>, in sentence: String) -> [Word] {
        let low = min(a.upperBound, b.upperBound)
        let high = max(a.lowerBound, b.lowerBound)
        guard low <= high else { return [] }
        return words(sentence).filter { $0.range.lowerBound >= low && $0.range.upperBound <= high }
    }

    static func isNumber(_ word: String) -> Bool {
        if let first = word.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { return true }
        return IndependentNumberReader.isNumberWord(word)
    }
}
