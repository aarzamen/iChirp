import ChirpText
import Foundation

/// A spoken correction said in the **next** sentence (re-review N1). Parakeet puts a period at a pause, so "Gave
/// fentanyl 50 micrograms IV. Sorry, 25 micrograms." reaches the structure run as two sentences, and the first one
/// alone looks clean.
///
/// When a sentence starts with or contains a correction cue, every field from the sentence before it is forced to
/// needs review with a reason. A dose restated without a drug ("Sorry, 25 micrograms.") is named in the previous
/// sentence's medication fields; it is never applied to them.
public enum CrossSentenceCorrection {
    /// Correction cues, as lowercased words. It holds every in-sentence cue (`SentenceNeighbours.correctionWords` and
    /// `correctionPairs`) plus "no wait", "i misspoke" and "let me correct". A sentence that starts with "No," followed
    /// by a number or a dose unit ("No, 25 micrograms.") also counts; "No." or "No fever" alone does not.
    public static let cues: [String] = [
        "sorry", "i mean", "i meant", "correction", "no wait", "actually", "rather", "make that", "make it",
        "scratch that", "strike that", "wait", "oops", "i misspoke", "let me correct",
    ]

    /// What the next sentence said.
    public struct Correction: Sendable, Equatable {
        /// The cue as found ("sorry").
        public var cue: String
        /// The correcting sentence, as said.
        public var sentence: String
        /// A dose the sentence restates when none of its calls names a drug ("25 mcg"), else nil.
        public var restatedDose: String?

        /// The reasons a field from the previous sentence gets.
        public func reasons(forTool tool: String) -> [String] {
            var reasons = [
                "Corrected in the next sentence (“\(sentence)”, cue “\(cue)”): check this field before accepting it."
            ]
            if tool == "add_medication", let restatedDose {
                reasons.append(
                    "The next sentence restates a dose without a drug (\(restatedDose)): check which dose was meant. It "
                        + "was not applied.")
            }
            return reasons
        }
    }

    /// The cue in `sentence`, or nil.
    public static func cue(in sentence: String) -> String? {
        let words = SentenceNeighbours.words(sentence).map(\.text)
        let joined = " " + words.joined(separator: " ") + " "
        if let cue = cues.first(where: { joined.contains(" \($0) ") }) { return cue }
        if words.first == "no", words.count > 1,
            SentenceNeighbours.isNumber(words[1])
                || IndependentNumberReader.isDoseUnit(words[1])
        {
            return "no"
        }
        return nil
    }

    /// The correction `sentence` makes to the sentence before it, or nil when it has no cue. `tools` are the names of
    /// the calls the engine returned for `sentence`.
    public static func check(_ sentence: NormalizedText, tools: [String]) -> Correction? {
        guard let cue = cue(in: sentence.original) else { return nil }
        let dose = sentence.tags.first { $0.kind == .dose }
        let restated = tools.contains("add_medication") ? nil : dose?.display
        return Correction(
            cue: cue, sentence: sentence.original.trimmingCharacters(in: .whitespacesAndNewlines),
            restatedDose: restated)
    }
}
