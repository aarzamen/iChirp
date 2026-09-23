import ChirpText
import Foundation

/// Round 3 (the allow-list, `fix/needle-allowlist`): a clinical field is **clean** (act or provisional, the states one
/// tap accepts) only when this type proves it. Everything it cannot prove is needs review, with one reason starting
/// `reasonPrefix`. The older checks (`StructuredCallValidator`, `IndependentNumberCheck`, `CrossSentenceCorrection`)
/// stay: they add the more specific reasons.
///
/// Two review rounds patched named phrasings, and each re-review found new phrasings that still gave a clean wrong
/// number: a deny-list of dangerous patterns cannot converge. This proof works the other way round. It knows one small
/// grammar per field kind (`grammar`) and passes a field only when **all four** hold:
///
/// 1. Its sentence parses completely under the grammar (`medicationFailure`, `vitalFailure`).
/// 2. Every number in the field is written in the sentence as digits exactly as said, or as spoken number words read
///    as one number with nothing inside them (`exactness`); every number the sentence says sits inside a tag the
///    grammar placed (no stray number anywhere).
/// 3. No disqualifier is said in the sentence or in the next two sentences (`Disqualifier`).
/// 4. A vital's name is unambiguous: "pulse ox", "sats", "O2" and "SpO2" are oxygen saturation, never heart rate.
///
/// `StructuredResultGate.review(_:engineID:)` is the only caller, so the extraction service, the eval runner and the
/// safety corpus all use the same rule, whichever engine answered.
public enum ClinicalFieldProof {
    /// Every proof reason starts with this, so screens and tests can tell it apart.
    public static let reasonPrefix = "Couldn't confirm: "

    /// The grammar the proof accepts, as written in the contract (`spec/contracts/structured-results-v1.md`).
    public static let grammar = """
        MEDICATION (add_medication): one drug, one dose, in this order.
          sentence  := lead* DRUG suffix* dose? after*
          lead      := a word from leadWords (she, takes, continue, started, gave, hold, no longer, ...) or a route
          DRUG      := the field's drug, said once; no other known drug anywhere in the sentence
          suffix    := a form or salt word (succinate, ER, inhaler, ...), a route word, "at", ",", ":" or "-"
          dose      := the field's dose tag: one amount and one unit (mg, mcg, g, units, mEq, mL)
          after     := the field's frequency tag, then at most one duration tag, then words with no number
          Only the field's own dose, frequency and one duration may carry a number, in the order
          drug -> dose -> frequency -> duration. The dose is optional only when the sentence says no amount.
          The route said (PO, IV, IM, SC, SL, inhaled, topical; one route only) is the field's route, or "unknown"
          when none is said. The status follows the verb said: start/started/gave/given -> started;
          take/continue/remains/uses or no verb -> taking; stop/discontinue/hold/no longer -> stopped;
          consider/might -> considering. Mixed verbs never pass.
        VITALS (record_vital): each value right after its own vital-sign name.
          sentence  := vlead* clause (words* clause)* words*
          clause    := LABEL connector* VALUE
          LABEL     := BP: bp, blood pressure | HR: heart rate, hr, pulse, pulse rate |
                       RR: respiratory rate, resp rate, rr, respirations |
                       SpO2: sats, sat, saturation, spo2, o2, o2 sat, pulse ox, pulse oximetry, oxygen saturation |
                       temp: temp, temperature, tmax
          connector := is, was, of, today, now, currently, measured, reading, ":" or "-"
          VALUE     := one tag of the name's kind: a BP pair ("N/N" or "N over N"), a rate, a percent, a temperature
          vlead     := a word from vitalLeadWords (vitals, her, today, repeat, ...)
          words     := any words with no number in them
          The field's kind is its value's name's kind: "pulse ox 94" is never a heart rate.
        EVERY CLINICAL FIELD
          - no flagged tag in the sentence;
          - each number is digits exactly as written, or spoken number words read as one number with no comma,
            ellipsis or period inside;
          - no disqualifier in the sentence or the next two: a correction cue (sorry, I mean, my mistake, that should
            be, actually, rather, ...; a dose or bare number restated with no drug), a limit or condition (less than,
            greater than, over, under, above, below, goal, target, if, unless, hold for, titrate, increase, taper, ...),
            a range ("4 to 8", "25-50", between), a tablet, puff, spray or drop count, "each", a fraction, a
            day-by-day schedule (day one, then, followed by, weekdays).
        """

    /// Why `call` is not proven clean, or nil when it is (or when it is not a field: `none`).
    public static func reason(for call: ValidatedCall, sentence: NormalizedText, following: [NormalizedText])
        -> String?
    {
        guard let why = failure(for: call, sentence: sentence, following: Array(following.prefix(2))) else {
            return nil
        }
        return reasonPrefix + why
    }

    static func failure(for call: ValidatedCall, sentence: NormalizedText, following: [NormalizedText]) -> String? {
        let words = ProofWord.words(sentence.original)
        switch call.tool {
        case "none":
            return nil
        case "add_problem", "add_plan_item", "add_allergy":
            return freeTextFailure(call, sentence: sentence)
        case "add_medication", "record_vital":
            break
        default:
            return "“\(call.tool)” is not a field the checks know."
        }
        let isMedication = call.tool == "add_medication"
        if let flagged = sentence.tags.first(where: \.needsReview) {
            return "“\(flagged.sourceText)” in this sentence is flagged (see the reason above)."
        }
        if let hit = Disqualifier.first(in: sentence, words: words, own: true) {
            return "“\(hit.phrase)” \(hit.why)."
        }
        let grammar =
            isMedication ? medicationFailure(call, sentence, words) : vitalFailure(call, sentence, words)
        if let grammar { return grammar }
        let drug = isMedication ? call.arguments["drug"]?.stringValue : nil
        for (offset, next) in following.enumerated() {
            let nextWords = ProofWord.words(next.original)
            guard
                let hit = Disqualifier.first(in: next, words: nextWords, own: false)
                    ?? Disqualifier.restated(in: next, words: nextWords, drug: drug)
            else { continue }
            let place = offset == 0 ? "the next sentence says" : "two sentences on, it says"
            return "\(place) “\(hit.phrase)”, which \(hit.why)."
        }
        return nil
    }

    // MARK: - Medication

    static func medicationFailure(_ call: ValidatedCall, _ sentence: NormalizedText, _ words: [ProofWord])
        -> String?
    {
        let original = sentence.original
        guard let drug = call.arguments["drug"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased(),
            !drug.isEmpty
        else { return "the field names no drug." }
        let mentions = SentenceNeighbours.mentions(of: drug, in: original)
        guard let drugRange = mentions.first else { return "“\(drug)” is not said in this sentence as written." }
        guard mentions.count == 1 else { return "“\(drug)” is named more than once in this sentence." }
        if let other = ClinicalLexicon.otherDrug(than: drugRange, in: original) {
            return "this sentence names a second drug (“\(other)”)."
        }
        let tags = sentence.tags.filter { $0.kind != .laterality }
        guard let doseClaim = claimed(call, "dose", in: sentence) else {
            return "the field's dose is not a number said here."
        }
        guard let frequencyClaim = claimed(call, "frequency", in: sentence) else {
            return "the field's frequency is not one said here."
        }
        let dose: NumericTag? = doseClaim
        let frequency: NumericTag? = frequencyClaim
        let doses = tags.filter { $0.kind == .dose }
        if let other = doses.first(where: { $0.tag != dose?.tag }), dose != nil || doses.count > 1 {
            return "this sentence has a second dose (“\(other.sourceText)”)."
        }
        if dose == nil, let said = doses.first {
            return "the dose said (“\(said.sourceText)”) is not in the field."
        }
        if let dose, dose.kind != .dose { return "the field's dose (“\(dose.sourceText)”) is not a dose." }
        let frequencies = tags.filter { $0.kind == .frequency }
        if frequencies.count > 1 {
            return "this sentence says how often twice (“\(frequencies[0].sourceText)”, "
                + "“\(frequencies[1].sourceText)”)."
        }
        if let said = frequencies.first, frequency?.tag != said.tag {
            return frequency == nil
                ? "how often (“\(said.sourceText)”) is said but not in the field."
                : "the field's frequency is not the one said (“\(said.sourceText)”)."
        }
        if let frequency, frequency.kind != .frequency {
            return "the field's frequency (“\(frequency.sourceText)”) is not a frequency."
        }
        let durations = tags.filter { $0.kind == .duration }
        if durations.count > 1 { return "this sentence says two durations." }
        if let other = tags.first(where: { ![.dose, .frequency, .duration].contains($0.kind) }) {
            return "“\(other.sourceText)” is another number in this sentence."
        }
        // Order: drug → dose → frequency → duration.
        func said(_ range: Range<Int>) -> String {
            (original as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
        }
        if let dose, dose.sourceRange.lowerBound < drugRange.lowerBound {
            return "the dose (“\(dose.sourceText)”) comes before the drug; only “drug, then dose” is read as certain."
        }
        let slots = [drugRange, dose?.sourceRange, frequency?.sourceRange, durations.first?.sourceRange]
            .compactMap { $0 }
        for (earlier, later) in zip(slots, slots.dropFirst()) where later.lowerBound < earlier.upperBound {
            return "“\(said(later))” comes before “\(said(earlier))”; only drug, dose, how often, how long is read."
        }
        let doseStart = dose?.sourceRange.lowerBound
        var statuses: [Status] = []
        var routes: [(route: String, said: String)] = []
        for (index, word) in words.enumerated() {
            if word.range.overlaps(drugRange) || slots.contains(where: { word.isInside($0) }) { continue }
            if let route = ProofWord.route(at: index, in: words) { routes.append((route, word.original)) }
            if let status = Status.of(at: index, in: words) { statuses.append(status) }
            if word.range.upperBound <= drugRange.lowerBound {
                if word.isNumberBearing { return "“\(word.original)” is said before the drug." }
                if word.isPunctuation || ProofWord.leadWords.contains(word.text) || ProofWord.isRouteWord(word.text)
                    || ProofWord.isNoLonger(at: index, in: words)
                {
                    continue
                }
                return "“\(word.original)” before the drug is not part of a plain order."
            }
            if let doseStart, word.range.upperBound <= doseStart {
                if !word.isNumberBearing,
                    [",", ":", "-", "–", "—"].contains(word.text) || ProofWord.suffixWords.contains(word.text)
                        || ProofWord.isRouteWord(word.text)
                {
                    continue
                }
                return "“\(word.original)” sits between the drug and its dose."
            }
            if word.isNumberBearing {
                return "“\(word.original)” is a number that is not part of the dose, how often or how long."
            }
            // "… at bedtime and with meals": a joined item may add doses the field does not hold.
            if ProofWord.joiners.contains(word.text) {
                return "“\(word.original)” joins something else to this order."
            }
        }
        if let failure = routeFailure(call, routes) { return failure }
        if let failure = statusFailure(call, statuses) { return failure }
        for tag in [dose, frequency, durations.first].compactMap({ $0 }) {
            if let failure = exactness(tag) { return failure }
        }
        return nil
    }

    /// The tag an argument names: `.some(nil)` when the argument is absent, nil when it names nothing said here.
    static func claimed(_ call: ValidatedCall, _ key: String, in sentence: NormalizedText) -> NumericTag?? {
        guard let argument = call.arguments[key] else { return .some(nil) }
        guard let name = argument["tag"]?.stringValue, let tag = sentence.tag(named: name) else { return nil }
        return .some(tag)
    }

    static func routeFailure(_ call: ValidatedCall, _ routes: [(route: String, said: String)]) -> String? {
        let field = call.arguments["route"]?.stringValue ?? "unknown"
        let distinct = Set(routes.map(\.route))
        if distinct.count > 1 {
            return "two routes are said (\(routes.map { "“\($0.said)”" }.joined(separator: ", ")))."
        }
        guard let said = routes.first else {
            return field == "unknown" ? nil : "no route is said, but the field says \(field)."
        }
        if said.route == "other" { return "the route said (“\(said.said)”) is not one the field can hold." }
        return said.route == field ? nil : "the route said (“\(said.said)”) is not the field's (\(field))."
    }

    enum Status: String {
        case taking, started, stopped, considering

        /// The status a word (or "no longer") says.
        static func of(at index: Int, in words: [ProofWord]) -> Status? {
            if ProofWord.isNoLonger(at: index, in: words), words[index].text == "no" { return .stopped }
            // "no longer taking": the verb belongs to "no longer".
            if index >= 2, words[index - 1].text == "longer", words[index - 2].text == "no" { return nil }
            switch words[index].text {
            case "stop", "stops", "stopped", "stopping", "discontinue", "discontinues", "discontinued",
                "discontinuing", "dc", "hold", "holds", "held", "holding", "off":
                return .stopped
            case "start", "starts", "started", "starting", "begin", "begins", "began", "begun", "initiate",
                "initiated", "initiating", "prescribe", "prescribed", "add", "added", "adding", "give", "gives", "gave",
                "given", "giving", "administer", "administered", "administering", "receive", "receives", "received",
                "got", "new", "restart", "restarted":
                return .started
            case "take", "takes", "taking", "took", "continue", "continues", "continued", "continuing", "resume",
                "resumes", "resumed", "remain", "remains", "remained", "stay", "stays", "use", "uses", "using":
                return .taking
            case "consider", "considers", "considering", "considered", "might", "may", "could", "possibly":
                return .considering
            default:
                return nil
            }
        }
    }

    static func statusFailure(_ call: ValidatedCall, _ statuses: [Status]) -> String? {
        let field = call.arguments["status"]?.stringValue ?? ""
        let said = Set(statuses)
        let expected: Status
        if said.contains(.considering) {
            guard said.isSubset(of: [.considering, .started]) else {
                return "the verbs said (\(said.map(\.rawValue).sorted().joined(separator: ", "))) disagree."
            }
            expected = .considering
        } else if said.count > 1 {
            return "the verbs said (\(said.map(\.rawValue).sorted().joined(separator: ", "))) disagree."
        } else {
            expected = said.first ?? .taking
        }
        return field == expected.rawValue ? nil : "the words say \(expected.rawValue), but the field says \(field)."
    }

    // MARK: - Vitals

    static func vitalFailure(_ call: ValidatedCall, _ sentence: NormalizedText, _ words: [ProofWord]) -> String? {
        guard let kind = call.arguments["kind"]?.stringValue else { return "the field names no vital sign." }
        guard let name = call.arguments["value"]?["tag"]?.stringValue, let tag = sentence.tag(named: name) else {
            return "the value is not a number said here."
        }
        let labels = VitalLabel.all(in: words)
        let values = sentence.tags.filter { $0.kind != .laterality }
        var owner: VitalLabel?
        for value in values {
            guard VitalLabel.valueKinds.contains(value.kind) else {
                return "“\(value.sourceText)” is not a vital-sign value."
            }
            guard let label = VitalLabel.before(value.sourceRange, labels: labels, words: words) else {
                return "“\(value.sourceText)” has no vital-sign name right before it."
            }
            guard let labelKind = label.kind else { return "“\(label.said)” does not say which vital sign it is." }
            guard VitalLabel.fits(labelKind, value.kind) else {
                return "“\(label.said)” is \(VitalLabel.name(labelKind)), never \(VitalLabel.name(of: value.kind))."
            }
            if value.tag == tag.tag { owner = label }
        }
        guard let owner, let ownerKind = owner.kind else { return "the value has no vital-sign name." }
        if ownerKind != kind {
            return "“\(tag.sourceText)” follows “\(owner.said)”, so it is \(VitalLabel.name(ownerKind)), not "
                + "\(VitalLabel.name(kind))."
        }
        if let drug = ClinicalLexicon.otherDrug(than: nil, in: sentence.original) {
            return "this sentence also names a drug (“\(drug)”)."
        }
        let firstLabel = labels.first?.range.lowerBound ?? Int.max
        for word in words {
            if values.contains(where: { word.isInside($0.sourceRange) })
                || labels.contains(where: { word.isInside($0.range) })
            {
                continue
            }
            if word.isNumberBearing {
                return "“\(word.original)” is a number that is not part of a labelled vital sign."
            }
            if word.range.upperBound <= firstLabel, !word.isPunctuation, !VitalLabel.leadWords.contains(word.text) {
                return "“\(word.original)” before the vital sign is not part of a plain reading."
            }
        }
        return exactness(tag)
    }

    // MARK: - Free text

    /// A number in a problem, plan item or allergy from a sentence that says a dose or a vital: a medication or vital
    /// written as free text is never checked, so it is never clean.
    static func freeTextFailure(_ call: ValidatedCall, sentence: NormalizedText) -> String? {
        let clinical: Set<NumericTag.Kind> = [.dose, .bloodPressure, .rate, .oxygenSaturation, .temperature]
        guard sentence.tags.contains(where: { clinical.contains($0.kind) }) else { return nil }
        for key in ["text", "substance", "reaction"] {
            guard let text = call.arguments[key]?.stringValue else { continue }
            if ProofWord.words(text).contains(where: \.isNumberBearing) {
                return "a dose or vital written into a \(call.tool == "add_plan_item" ? "plan item" : "problem") is "
                    + "not checked; record it as a medication or vital."
            }
        }
        return nil
    }

    // MARK: - Exact numbers

    /// Condition 2: the tag's number is digits exactly as written, or spoken number words that read as one number
    /// (a pair for a blood pressure) with nothing inside them.
    static func exactness(_ tag: NumericTag) -> String? {
        let inside = ProofWord.words(tag.sourceText)
        let digits = inside.filter { $0.hasDigit && !ProofWord.labelTokens.contains($0.text) }
        let spoken = inside.filter { ProofWord.cardinalWords.contains($0.text) }
        let wanted = [tag.value, tag.kind == .bloodPressure ? tag.secondValue : nil].compactMap { $0 }
        if !digits.isEmpty, !spoken.isEmpty { return "“\(tag.sourceText)” mixes digits and spoken numbers." }
        if digits.isEmpty, spoken.isEmpty { return nil }
        guard wanted.count == (tag.kind == .bloodPressure ? 2 : 1) else {
            return "“\(tag.sourceText)” holds no single value."
        }
        let read: [Double]
        if !digits.isEmpty {
            read = digits.flatMap { ProofWord.numbers(inDigits: $0.text) }
        } else {
            let start = spoken.first!.range.lowerBound
            let end = spoken.last!.range.upperBound
            let number = (tag.sourceText as NSString).substring(with: NSRange(location: start, length: end - start))
            if number.contains(where: { ",;:….!?".contains($0) }) {
                return "“\(tag.sourceText)” has a pause or punctuation inside the number."
            }
            read = IndependentNumberReader.read(tag.sourceText).numbers
        }
        guard read.count == wanted.count, zip(read, wanted).allSatisfy({ IndependentNumberReader.same($0, $1) })
        else {
            return "“\(tag.sourceText)” does not read as exactly \(tag.display)."
        }
        return nil
    }
}

// MARK: - Disqualifiers

/// Condition 3: words that make a value a correction, a limit, a range, a count, a fraction or a schedule. Checked in
/// the field's sentence and in the next two.
enum Disqualifier {
    struct Hit: Equatable {
        let phrase: String
        /// Completes "“<phrase>” …": "may correct it", "is a range, not one value".
        let why: String
    }

    /// Correction cues: every cross-sentence cue plus the round-2 misses ("my mistake", "that should be").
    static let correctionCues: [[String]] =
        (CrossSentenceCorrection.cues + [
            "my mistake", "my bad", "that should be", "should be", "should read", "should say", "change that to",
            "change that", "i said", "instead", "disregard", "never mind", "nevermind", "cancel that", "delete that",
            "misspoke",
        ]).map { $0.split(separator: " ").map(String.init) }
    static let comparatorPhrases: [[String]] = [
        ["less", "than"], ["greater", "than"], ["more", "than"], ["fewer", "than"], ["higher", "than"],
        ["lower", "than"], ["or", "less"], ["or", "more"], ["or", "greater"], ["or", "higher"], ["or", "lower"],
        ["or", "above"], ["or", "below"], ["at", "least"], ["at", "most"], ["up", "to"], ["no", "more"],
        ["not", "to", "exceed"],
    ]
    static let comparatorWords: Set<String> = [
        "over", "under", "above", "below", "goal", "goals", "target", "targets", "targeting", "if", "unless", "when",
        "whenever", "exceed", "exceeds", "exceeding", "<", ">", "≤", "≥",
    ]
    static let conditionWords: Set<String> = ["if", "unless", "when", "whenever"]
    /// In the field's own sentence only: a negation ("never started", "not taking it") and a value from another time
    /// ("temp was 101.2 yesterday", "previously 10 mg").
    static let negationWords: Set<String> = [
        "not", "never", "denies", "denied", "refuses", "refused", "declines", "declined", "hasn't", "didn't",
        "doesn't", "won't", "isn't", "wasn't",
    ]
    static let otherTimeWords: Set<String> = [
        "yesterday", "previously", "previous", "prior", "ago", "baseline", "usual", "usually", "normally",
        "typically", "formerly", "earlier", "last",
    ]
    static let titrationWords: Set<String> = [
        "titrate", "titrated", "titrating", "titration", "uptitrate", "taper", "tapering", "tapered", "wean",
        "weaning", "weaned", "increase", "increased", "increasing", "decrease", "decreased", "decreasing", "reduce",
        "reduced", "reducing", "double", "doubled", "halve", "halved", "escalate", "escalating", "adjust", "adjusted",
    ]
    static let countWords: Set<String> = [
        "tablet", "tablets", "tab", "tabs", "pill", "pills", "capsule", "capsules", "cap", "caps", "caplet", "caplets",
        "puff", "puffs", "spray", "sprays", "drop", "drops", "patch", "patches", "inhalation", "inhalations",
        "actuation", "actuations", "vial", "vials", "ampule", "ampules", "ampoule", "ampoules", "suppository",
        "suppositories", "lozenge", "lozenges", "packet", "packets", "teaspoon", "teaspoons", "tsp", "tablespoon",
        "tablespoons", "tbsp",
    ]
    static let fractionWords: Set<String> = ["half", "halves", "quarter", "quarters", "third", "thirds", "½", "¼", "¾"]
    static let rangeJoiners: Set<String> = ["to", "through", "thru", "or", "-", "–", "—"]
    static let scheduleWords: Set<String> = [
        "thereafter", "alternating", "alternate", "except", "monday", "mondays", "tuesday", "tuesdays", "wednesday",
        "wednesdays", "thursday", "thursdays", "friday", "fridays", "saturday", "saturdays", "sunday", "sundays",
    ]
    static let schedulePhrases: [[String]] = [
        ["first", "day"], ["first", "dose"], ["on", "day"], ["loading", "dose"], ["followed", "by"],
    ]

    /// The first disqualifier in a sentence (by position). `own` adds the ones that only count in the field's own
    /// sentence: "then" (a schedule) and "not" (a correction: "5 mg, not 50 mg").
    static func first(in sentence: NormalizedText, words: [ProofWord], own: Bool) -> Hit? {
        let bloodPressures = sentence.tags.filter { $0.kind == .bloodPressure }.map(\.sourceRange)
        let texts = words.map(\.text)
        func phrase(at index: Int, _ parts: [String]) -> Bool {
            var cursor = index
            for part in parts {
                while cursor < words.count, words[cursor].isPunctuation, words[cursor].text != part { cursor += 1 }
                guard cursor < words.count, texts[cursor] == part else { return false }
                cursor += 1
            }
            return true
        }
        func next(after index: Int) -> ProofWord? {
            words[(index + 1)...].first { !$0.isPunctuation || ["-", "–", "—", "/"].contains($0.text) }
        }
        for (index, word) in words.enumerated() {
            let text = word.text
            for cue in correctionCues where phrase(at: index, cue) {
                return Hit(phrase: cue.joined(separator: " "), why: "may correct it")
            }
            if text == "no", let following = words[(index + 1)...].first(where: { !$0.isPunctuation }),
                following.isNumberBearing || IndependentNumberReader.isDoseUnit(following.text)
            {
                return Hit(phrase: "no", why: "may correct it")
            }
            if own, negationWords.contains(text) { return Hit(phrase: word.original, why: "may correct or negate it") }
            if own, otherTimeWords.contains(text) {
                return Hit(phrase: word.original, why: "may put it at another time, not today")
            }
            for comparator in comparatorPhrases where phrase(at: index, comparator) {
                return Hit(phrase: comparator.joined(separator: " "), why: "makes it a limit, not a plain value")
            }
            if comparatorWords.contains(text) {
                let insidePressure = text == "over" && bloodPressures.contains { word.isInside($0) }
                let underTongue = text == "under" && phrase(at: index, ["under", "the", "tongue"])
                if !insidePressure, !underTongue {
                    return Hit(
                        phrase: word.original,
                        why: conditionWords.contains(text)
                            ? "makes it conditional" : "makes it a limit, not a plain value")
                }
            }
            if ["hold", "holds", "held", "holding"].contains(text),
                words[(index + 1)...].prefix(5).contains(where: {
                    ["for", "if", "when", "unless", "parameters", "parameter"].contains($0.text)
                })
            {
                return Hit(phrase: "\(word.original) … for", why: "makes it conditional")
            }
            if titrationWords.contains(text) {
                return Hit(phrase: word.original, why: "describes a change over time, not one value")
            }
            if countWords.contains(text) {
                return Hit(
                    phrase: word.original, why: "is a tablet, puff, spray or drop count, so the dose given may differ")
            }
            if text == "each" { return Hit(phrase: "each", why: "can multiply the dose") }
            if fractionWords.contains(text)
                || (word.text.contains("/") && word.hasDigit && !bloodPressures.contains { word.isInside($0) })
            {
                return Hit(phrase: word.original, why: "is a fraction or a combination, so the dose given may differ")
            }
            if rangeJoiners.contains(text), let right = next(after: index), right.isNumberBearing,
                let left = numberBefore(index, in: words)
            {
                // "twenty-five" is one number, not a range.
                let compound =
                    ["-", "–"].contains(text) && ProofWord.tensWords.contains(left.text)
                    && ProofWord.unitWords.contains(right.text)
                if !compound {
                    return Hit(
                        phrase: "\(left.original) \(word.original) \(right.original)", why: "is a range, not one value")
                }
            }
            if text == "between", words[(index + 1)...].prefix(3).contains(where: \.isNumberBearing) {
                return Hit(phrase: "between", why: "is a range, not one value")
            }
            if (text == "day" || text == "days"), let right = next(after: index), right.isNumberBearing {
                return Hit(phrase: "\(word.original) \(right.original)", why: "describes a day-by-day schedule")
            }
            for schedule in schedulePhrases where phrase(at: index, schedule) {
                return Hit(phrase: schedule.joined(separator: " "), why: "describes a schedule, not one dose")
            }
            if scheduleWords.contains(text) || (own && text == "then") {
                return Hit(phrase: word.original, why: "describes a schedule, not one dose")
            }
        }
        return nil
    }

    /// The number right before a range word, across one unit ("4 *mg* to 8 mg"), or nil.
    static func numberBefore(_ index: Int, in words: [ProofWord]) -> ProofWord? {
        let before = words[..<index].filter { !$0.isPunctuation }
        guard let last = before.last else { return nil }
        if last.isNumberBearing { return last }
        guard IndependentNumberReader.isDoseUnit(last.text), let previous = before.dropLast().last,
            previous.isNumberBearing
        else { return nil }
        return previous
    }

    /// A following sentence that restates a number the field may have meant ("20 mg daily.", "Repeat 138/82."):
    /// - for a medication field (`drug` is its drug), a dose that no drug stands right before ("Recheck potassium in
    ///   a week. 20 mg daily." is one sentence to the tokenizer, and the 20 mg is nobody's);
    /// - for a vital field, a vital-sign value with no vital-sign name right before it;
    /// - for any field, a short sentence that is a bare number ("20.", "Then 25."), with no drug or vital-sign name.
    static func restated(in sentence: NormalizedText, words: [ProofWord], drug: String?) -> Hit? {
        if drug == nil {
            let labels = VitalLabel.all(in: words)
            for value in sentence.tags where VitalLabel.valueKinds.contains(value.kind) {
                if VitalLabel.before(value.sourceRange, labels: labels, words: words) == nil {
                    return Hit(phrase: value.sourceText, why: "gives a value with no vital-sign name right before it")
                }
            }
        }
        let drugs =
            ClinicalLexicon.ranges(in: sentence.original)
            + (drug.map { SentenceNeighbours.mentions(of: $0, in: sentence.original) } ?? [])
        if drug != nil {
            for dose in sentence.tags where dose.kind == .dose {
                let owned = drugs.contains { mention in
                    mention.upperBound <= dose.sourceRange.lowerBound
                        && words.filter {
                            $0.range.lowerBound >= mention.upperBound
                                && $0.range.upperBound <= dose.sourceRange.lowerBound
                        }
                        .allSatisfy {
                            $0.isPunctuation || ProofWord.suffixWords.contains($0.text)
                                || ProofWord.isRouteWord($0.text)
                        }
                }
                if !owned { return Hit(phrase: dose.sourceText, why: "gives a dose with no drug right before it") }
            }
        }
        guard drugs.isEmpty, VitalLabel.all(in: words).isEmpty else { return nil }
        let timing = sentence.tags.filter { [.duration, .time].contains($0.kind) }.map(\.sourceRange)
        guard
            let number = words.first(where: { word in word.isNumberBearing && !timing.contains { word.isInside($0) } })
        else { return nil }
        // "Diagnosed with type 2 diabetes." says a number, but it is not a restated value.
        let otherWords = words.filter { !$0.isPunctuation && !$0.isNumberBearing }
        guard otherWords.count <= 1 else { return nil }
        let tag = sentence.tags.first { number.isInside($0.sourceRange) }
        return Hit(phrase: tag?.sourceText ?? number.original, why: "gives a number with no drug or vital-sign name")
    }
}

// MARK: - Words

/// A word, number or punctuation mark with its UTF-16 range. Dotted abbreviations ("p.o.", "t.i.d.") are one word
/// without their dots; a digit run keeps a leading decimal point (".5") so it is never read as "5".
struct ProofWord {
    /// Lowercased.
    let text: String
    let original: String
    let range: Range<Int>
    let isPunctuation: Bool
    let hasDigit: Bool

    var isNumberBearing: Bool {
        (hasDigit && !Self.labelTokens.contains(text)) || Self.numberWords.contains(text)
    }

    func isInside(_ outer: Range<Int>) -> Bool {
        range.lowerBound >= outer.lowerBound && range.upperBound <= outer.upperBound
    }

    private static let pattern = try! NSRegularExpression(
        pattern:
            #"(?:[A-Za-z]\.){2,}|[A-Za-z]+\d[A-Za-z\d]*|\.?\d+(?:[.,:/]\d+)*[A-Za-z]*|[A-Za-z]+(?:'[A-Za-z]+)?|[^\sA-Za-z\d]"#
    )

    static func words(_ text: String) -> [ProofWord] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let original = ns.substring(with: match.range)
            let lower = original.lowercased()
            let dotted = lower.range(of: #"^(?:[a-z]\.){2,}$"#, options: .regularExpression) != nil
            return ProofWord(
                text: dotted ? lower.replacingOccurrences(of: ".", with: "") : lower, original: original,
                range: match.range.location..<NSMaxRange(match.range),
                isPunctuation: !original.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) },
                hasDigit: original.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) })
        }
    }

    /// The numbers in a digit token: "142/88" → [142, 88], "1,000" → [1000], "q6h" → [6], "500mg" → [500].
    static func numbers(inDigits text: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: #"\.?\d+(?:,\d{3})*(?:\.\d+)?"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Double(ns.substring(with: $0.range).replacingOccurrences(of: ",", with: ""))
        }
    }

    /// Tokens with a digit that name a vital sign, not a number.
    static let labelTokens: Set<String> = ["spo2", "o2", "sao2", "sp02"]
    static let unitWords: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    static let tensWords: Set<String> = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    /// Spoken cardinals (what `exactness` re-reads).
    static let cardinalWords: Set<String> =
        unitWords.union(tensWords).union([
            "zero", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
            "nineteen", "hundred", "thousand", "million", "point",
        ])
    /// Every word that says a number or a count, cardinal or not.
    static let numberWords: Set<String> =
        cardinalWords.subtracting(["point"]).union([
            "once", "twice", "thrice", "double", "triple", "dozen", "couple", "half", "halves", "quarter", "quarters",
            "third", "thirds", "first", "second", "fourth", "fifth", "½", "¼", "¾",
        ])

    /// Words allowed before the drug (closed): subjects, helpers and status verbs. A negation ("denies", "not",
    /// "no") or a change ("increase", "switch") is not here, so it never passes.
    static let leadWords: Set<String> = [
        "she", "he", "they", "we", "i", "patient", "patient's", "pt", "the", "her", "his", "their", "is", "was", "were",
        "will", "has", "have", "had", "been", "be", "to", "also", "still", "currently", "now", "today", "already",
        "and", "so", "okay", "ok", "please", "let's", "we'll", "i'll", "she's", "he's", "on", "home", "meds",
        "medications", "medication", "med", "current", "regimen", "include", "includes", "including",
        "take", "takes", "taking", "took", "continue", "continues", "continued", "continuing", "resume", "resumes",
        "resumed", "remain", "remains", "remained", "stay", "stays", "use", "uses", "using", "start", "starts",
        "started", "starting", "begin", "begins", "began", "begun", "initiate", "initiated", "initiating",
        "prescribe", "prescribed", "add", "added", "adding", "give", "gives", "gave", "given", "giving", "administer",
        "administered", "administering", "receive", "receives", "received", "got", "restart", "restarted", "stop",
        "stops", "stopped", "stopping", "discontinue", "discontinues", "discontinued", "discontinuing", "dc", "hold",
        "holds", "held", "holding", "consider", "considers", "considering", "considered", "might", "may", "could",
        "possibly", "new", "off", "a",
    ]
    /// Words after a medication's dose that join another item to the order.
    static let joiners: Set<String> = ["and", "plus", "or", "also", "&"]
    /// Form and salt words allowed between the drug and its dose.
    static let suffixWords: Set<String> = [
        "succinate", "tartrate", "er", "xr", "xl", "sr", "dr", "cr", "la", "hcl", "hydrochloride", "sodium",
        "potassium", "extended", "release", "delayed", "inhaler", "cream", "ointment", "gel", "lotion", "solution",
        "suspension", "at",
    ]

    /// "no longer": the "no" and the "longer".
    static func isNoLonger(at index: Int, in words: [ProofWord]) -> Bool {
        (words[index].text == "no" && index + 1 < words.count && words[index + 1].text == "longer")
            || (words[index].text == "longer" && index > 0 && words[index - 1].text == "no")
    }

    static let routeWords: [String: String] = [
        "po": "PO", "oral": "PO", "orally": "PO", "mouth": "PO", "iv": "IV", "ivp": "IV", "ivpb": "IV",
        "intravenous": "IV", "intravenously": "IV", "im": "IM", "intramuscular": "IM", "intramuscularly": "IM",
        "sc": "SC", "subq": "SC", "subcut": "SC", "sq": "SC", "subcutaneous": "SC", "subcutaneously": "SC",
        "sl": "SL", "sublingual": "SL", "sublingually": "SL", "tongue": "SL", "inhaled": "inhaled",
        "inhaler": "inhaled", "nebulized": "inhaled", "nebulizer": "inhaled", "neb": "inhaled", "topical": "topical",
        "topically": "topical", "cream": "topical", "ointment": "topical", "gel": "topical", "lotion": "topical",
        "rectal": "other", "rectally": "other", "rectum": "other", "pr": "other", "nasal": "other",
        "intranasal": "other", "intranasally": "other", "nostril": "other", "nostrils": "other",
        "ophthalmic": "other", "otic": "other", "transdermal": "other", "vaginal": "other", "vaginally": "other",
        "epidural": "other", "intrathecal": "other", "intraosseous": "other",
    ]

    static func isRouteWord(_ text: String) -> Bool { routeWords[text] != nil || ["by", "per", "os"].contains(text) }

    /// The route a word says ("mouth" only after "by" or "per"; "os" only after "per").
    static func route(at index: Int, in words: [ProofWord]) -> String? {
        let text = words[index].text
        let previous = index > 0 ? words[index - 1].text : ""
        if text == "mouth" { return ["by", "per"].contains(previous) ? "PO" : nil }
        if text == "os" { return previous == "per" ? "PO" : nil }
        if text == "tongue" { return previous == "the" ? "SL" : nil }
        if text == "sub", index + 1 < words.count, words[index + 1].text == "q" { return "SC" }
        return routeWords[text]
    }
}

// MARK: - Vital-sign names

struct VitalLabel {
    /// "BP", "HR", "RR", "SpO2", "temp"; nil for a name that does not say which ("rate", "pulse pressure").
    let kind: String?
    let range: Range<Int>
    let said: String

    static let valueKinds: Set<NumericTag.Kind> = [.bloodPressure, .rate, .oxygenSaturation, .temperature]

    /// Longest first.
    static let names: [([String], String?)] = [
        (["pulse", "oximetry"], "SpO2"), (["pulse", "oximeter"], "SpO2"), (["pulse", "ox"], "SpO2"),
        (["pulse", "-", "ox"], "SpO2"), (["pulse", "pressure"], nil), (["oxygen", "saturation"], "SpO2"),
        (["o2", "saturation"], "SpO2"), (["o2", "sats"], "SpO2"), (["o2", "sat"], "SpO2"),
        (["blood", "pressure"], "BP"),
        (["heart", "rate"], "HR"), (["pulse", "rate"], "HR"), (["respiratory", "rate"], "RR"),
        (["resp", "rate"], "RR"),
        (["t", "max"], "temp"), (["bp"], "BP"), (["hr"], "HR"), (["pulse"], "HR"), (["rr"], "RR"),
        (["respirations"], "RR"), (["resp"], "RR"), (["spo2"], "SpO2"), (["sao2"], "SpO2"), (["sp02"], "SpO2"),
        (["sats"], "SpO2"), (["sat"], "SpO2"), (["saturation"], "SpO2"), (["saturating"], "SpO2"), (["o2"], "SpO2"),
        (["temperature"], "temp"), (["temp"], "temp"), (["tmax"], "temp"), (["rate"], nil), (["pressure"], nil),
    ]
    static let connectors: Set<String> = [
        "is", "was", "of", "today", "now", "currently", "measured", "reading", ":", "-", "=",
    ]
    /// Words allowed before the first vital-sign name (closed). "Last", "prior" and "home" are not here: a vital
    /// from another day or another place is not today's.
    static let leadWords: Set<String> = [
        "vitals", "vital", "signs", "sign", "are", "is", "were", "was", "her", "his", "their", "the", "patient",
        "patient's", "today", "now", "currently", "on", "arrival", "initial", "repeat", "triage", "in", "at",
        "clinic", "this", "morning", "afternoon", "evening", "office", "visit", "and", "with", "show", "shows",
    ]

    static func all(in words: [ProofWord]) -> [VitalLabel] {
        var result: [VitalLabel] = []
        var index = 0
        while index < words.count {
            var matched = false
            for (parts, kind) in names where index + parts.count <= words.count {
                guard zip(parts, words[index..<(index + parts.count)]).allSatisfy({ $0 == $1.text }) else { continue }
                let range = words[index].range.lowerBound..<words[index + parts.count - 1].range.upperBound
                result.append(
                    VitalLabel(
                        kind: kind, range: range,
                        said: words[index..<(index + parts.count)].map(\.original)
                            .joined(separator: " ")))
                index += parts.count
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        return result
    }

    /// The name right before a value, with only connectors (and ":" / "-") between.
    static func before(_ value: Range<Int>, labels: [VitalLabel], words: [ProofWord]) -> VitalLabel? {
        guard let label = labels.last(where: { $0.range.upperBound <= value.lowerBound }) else { return nil }
        let between = words.filter {
            $0.range.lowerBound >= label.range.upperBound && $0.range.upperBound <= value.lowerBound
        }
        return between.allSatisfy { connectors.contains($0.text) } ? label : nil
    }

    static func fits(_ kind: String, _ tag: NumericTag.Kind) -> Bool {
        switch (kind, tag) {
        case ("BP", .bloodPressure), ("HR", .rate), ("RR", .rate), ("SpO2", .oxygenSaturation),
            ("temp", .temperature):
            return true
        default:
            return false
        }
    }

    static func name(_ kind: String) -> String {
        switch kind {
        case "BP": "a blood pressure"
        case "HR": "a heart rate"
        case "RR": "a respiratory rate"
        case "SpO2": "an oxygen saturation"
        case "temp": "a temperature"
        default: kind
        }
    }

    static func name(of tag: NumericTag.Kind) -> String {
        switch tag {
        case .bloodPressure: "a blood pressure"
        case .rate: "a heart or breathing rate"
        case .oxygenSaturation: "an oxygen saturation"
        case .temperature: "a temperature"
        default: "a vital sign"
        }
    }
}

// MARK: - Drug names

/// Drug names the proof knows, to find a second drug in a sentence and a following sentence that names none. It is
/// never complete: a drug it does not know can only make the proof stricter elsewhere (the lead and the words between
/// the drug and its dose are closed lists, and a second dose fails on its own).
enum ClinicalLexicon {
    static let drugs: [String] =
        Set(
            StubStructureModel.drugs + [
                "morphine", "hydromorphone", "oxycodone", "hydrocodone", "codeine", "heparin", "enoxaparin",
                "warfarin", "digoxin", "carvedilol", "clonidine", "hydralazine", "lorazepam", "diazepam", "midazolam",
                "ketorolac", "valsartan", "hctz", "potassium chloride", "vancomycin", "vanc", "cefazolin",
                "clindamycin", "levofloxacin", "ciprofloxacin", "glipizide", "glyburide", "glargine", "lispro",
                "prednisolone", "methylprednisolone", "dexamethasone", "labetalol", "nifedipine", "diltiazem",
                "spironolactone", "lasix", "tylenol", "advil", "motrin", "zofran", "norco", "percocet", "advair",
                "flonase", "lovenox", "coumadin", "eliquis", "xarelto", "rivaroxaban", "clopidogrel", "plavix",
                "simvastatin", "rosuvastatin", "pravastatin", "amiodarone", "metronidazole", "bactrim", "keflex",
                "augmentin", "cetirizine", "loratadine", "diphenhydramine", "benadryl", "pantoprazole", "sucralfate",
                "docusate", "senna", "miralax", "nitroglycerin", "epinephrine", "naloxone", "promethazine",
                "metoclopramide", "haloperidol", "quetiapine", "olanzapine", "trazodone", "zolpidem", "bupropion",
                "citalopram", "escitalopram", "fluoxetine", "paroxetine", "venlafaxine", "duloxetine", "amitriptyline",
                "pregabalin", "cyclobenzaprine", "methocarbamol", "tizanidine", "baclofen", "meloxicam", "celecoxib",
                "colchicine", "allopurinol", "levetiracetam", "lamotrigine", "propranolol", "atenolol", "torsemide",
                "bumetanide", "chlorthalidone", "sitagliptin", "empagliflozin", "semaglutide", "tamsulosin",
                "budesonide", "tiotropium", "ipratropium", "benzonatate", "guaifenesin", "oseltamivir", "acyclovir",
                "valacyclovir", "fluconazole", "hydrocortisone", "triamcinolone", "penicillin", "ampicillin",
                "gentamicin", "lidocaine", "txa", "clonazepam", "alprazolam", "methotrexate", "salmeterol",
                "glucagon", "dextrose", "magnesium", "calcium", "iron", "potassium",
            ]
        ).sorted()

    /// One pattern for every name, longest first, so "insulin glargine" wins over "insulin".
    private static let pattern: NSRegularExpression = {
        let names = drugs.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        return try! NSRegularExpression(
            pattern: "\\b(?:" + names.joined(separator: "|") + ")\\b", options: [.caseInsensitive])
    }()

    /// Every known drug named in `sentence`, lowercased, in order.
    static func names(in sentence: String) -> [String] {
        let ns = sentence as NSString
        return pattern.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).lowercased()
        }
    }

    /// Where each known drug is named in `sentence` (UTF-16).
    static func ranges(in sentence: String) -> [Range<Int>] {
        let ns = sentence as NSString
        return pattern.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map {
            $0.range.location..<NSMaxRange($0.range)
        }
    }

    /// The first known drug named in `sentence` outside `own` (the field's drug mention), or nil.
    static func otherDrug(than own: Range<Int>?, in sentence: String) -> String? {
        let ns = sentence as NSString
        for match in pattern.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range.location..<NSMaxRange(match.range)
            if let own, own.overlaps(range) { continue }
            return ns.substring(with: match.range)
        }
        return nil
    }
}
