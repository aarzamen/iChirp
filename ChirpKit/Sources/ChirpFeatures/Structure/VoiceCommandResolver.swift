import ChirpCore
import Foundation

/// A non-text effect of a voice command, performed after the text is copied.
public enum VoiceCommandAction: String, Sendable, Equatable, Codable {
    case readBack, sendToSOAP, sendToTransform
}

/// One spoken command the engine was asked about.
public struct VoiceCommandMatch: Sendable, Equatable {
    /// The catalog tool, e.g. "new_paragraph".
    public var command: String
    /// The words as spoken ("New paragraph.").
    public var utterance: String
    public var confidence: Double
    public var engineID: String

    public init(command: String, utterance: String, confidence: Double, engineID: String) {
        self.command = command
        self.utterance = utterance
        self.confidence = confidence
        self.engineID = engineID
    }
}

/// The final text with commands applied, and what else to do.
public struct VoiceCommandResult: Sendable, Equatable {
    public var text: String
    public var applied: [VoiceCommandMatch]
    /// Command-shaped sentences the engine did not confirm at the act threshold: left in the text as dictated.
    public var ignored: [VoiceCommandMatch]
    public var actions: [VoiceCommandAction]

    public static func unchanged(_ text: String) -> VoiceCommandResult {
        VoiceCommandResult(text: text, applied: [], ignored: [], actions: [])
    }
}

/// Resolves `dictation-commands.v1` deterministically on the final pass's words (plan 015 Step 7).
///
/// A command is recognized only when **a whole sentence** (at most eight words, after a pause Parakeet punctuates) is
/// one of the command's spoken phrases, and the engine confirms that tool at or above the act threshold. The
/// command's sentence is removed and its edit applied; the same words inside a longer sentence are dictated text and
/// are never touched, and a low-confidence answer changes nothing. The input is the final Parakeet pass (after
/// clean-up), never the live preview.
public struct VoiceCommandResolver: Sendable {
    public static let maxWords = 8

    let engine: any StructureModel
    let gate: StructuredResultGate
    let catalog: StructureCatalog

    public init(engine: any StructureModel, gate: StructuredResultGate, catalog: StructureCatalog = .dictationCommands)
    {
        self.engine = engine
        self.gate = gate
        self.catalog = catalog
    }

    // MARK: - Final pass

    public func resolve(_ text: String, privacyClass: PrivacyClass = .personal) async -> VoiceCommandResult {
        var ops: [Op] = []
        var applied: [VoiceCommandMatch] = []
        var ignored: [VoiceCommandMatch] = []
        var actions: [VoiceCommandAction] = []
        for segment in Self.segments(in: text) {
            let sentence = segment.text
            guard let candidate = candidate(for: sentence) else {
                ops.append(.text(sentence, continues: segment.continuesPrevious))
                continue
            }
            let match = await confirm(sentence, as: candidate, privacyClass: privacyClass)
            guard let match, gate.verdict(confidence: match.confidence) == .act else {
                if let match { ignored.append(match) }
                ops.append(.text(sentence, continues: segment.continuesPrevious))
                continue
            }
            applied.append(match)
            switch candidate {
            case "read_back": actions.append(.readBack)
            case "send_to_soap": actions.append(.sendToSOAP)
            case "send_to_transform": actions.append(.sendToTransform)
            case "stop": break
            case "undo":
                if let index = ops.lastIndex(where: \.isUndoable) { ops.remove(at: index) }
            case "scratch_that":
                // Re-review I9-R: the whole order, back through sentences split only after an abbreviation ("500 mg.
                // Three times daily." is one order).
                let scratched = Set(ops.flatMap(\.scratchedIndices))
                if var index = ops.indices.last(where: { ops[$0].isText && !scratched.contains($0) }) {
                    var removed = [index]
                    while ops[index].continuesPrevious, index > 0, ops[index - 1].isText, !scratched.contains(index - 1)
                    {
                        index -= 1
                        removed.append(index)
                    }
                    ops.append(.scratch(removed))
                }
            default:
                ops.append(.edit(candidate))
            }
        }
        return VoiceCommandResult(
            text: Self.render(ops).trimmingCharacters(in: .whitespacesAndNewlines), applied: applied, ignored: ignored,
            actions: actions)
    }

    // MARK: - Live preview

    /// The words after the last sentence end of the live text, when they are a command phrase: what a chip may show.
    public static func trailingWindow(of liveText: String) -> String? {
        let trimmed = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = trimmed.last.map { ".!?".contains($0) } == true ? String(trimmed.dropLast()) : trimmed
        let start = body.lastIndex { ".!?\n".contains($0) }.map { body.index(after: $0) } ?? body.startIndex
        let window = body[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        let count = VoiceCommandText.words(window).count
        return (1...maxWords).contains(count) ? window : nil
    }

    /// Checks the live preview's trailing words; a chip only (never an edit to the live text).
    public func liveCommand(in liveText: String, privacyClass: PrivacyClass = .personal) async -> VoiceCommandMatch? {
        guard let window = Self.trailingWindow(of: liveText), let candidate = candidate(for: window) else { return nil }
        guard let match = await confirm(window, as: candidate, privacyClass: privacyClass),
            gate.verdict(confidence: match.confidence) == .act
        else { return nil }
        return match
    }

    // MARK: - Pieces

    /// The command whose phrase the whole sentence is, if any (deterministic).
    public func candidate(for sentence: String) -> String? {
        let words = VoiceCommandText.words(sentence)
        guard (1...Self.maxWords).contains(words.count) else { return nil }
        return catalog.tools.first { tool in
            (tool.phrases ?? []).contains { VoiceCommandText.matches(words, phrase: $0) }
        }?.name
    }

    /// Asks the engine; nil when it failed or chose another tool.
    func confirm(_ sentence: String, as candidate: String, privacyClass: PrivacyClass) async -> VoiceCommandMatch? {
        guard StructuredExtractionService.mayRun(engine.descriptor, on: privacyClass),
            let output = try? await engine.extract(
                jsonSchema: catalog.toolsJSON, from: sentence, privacyClass: privacyClass),
            let call = StructuredCall.parseArray(output.json)?.first, call.name == candidate
        else { return nil }
        return VoiceCommandMatch(
            command: candidate, utterance: sentence, confidence: output.confidence, engineID: engine.descriptor.id)
    }

    /// Sentences of the final text: split after . ! ? followed by whitespace, and at line breaks. A period that ends
    /// an abbreviation (review L3 I9) ends the sentence only when a capital letter follows ("p.o. t.i.d." stays one
    /// order; "t.i.d. Scratch that." splits), never before a capitalized dosing acronym ("p.o. TID."), and never
    /// after a title or "vs.", "approx.", "e.g." ("Dr. Lee"). "No." ends a sentence unless a digit follows ("No. 5").
    public static func sentences(in text: String) -> [String] {
        segments(in: text).map(\.text)
    }

    /// One sentence of the final text, and whether it was split from the one before only after an abbreviation.
    public struct Segment: Sendable, Equatable {
        public var text: String
        /// Split from the previous sentence after an abbreviation followed by a capital ("500 mg. Three times
        /// daily."): "scratch that" removes both (re-review I9-R).
        public var continuesPrevious: Bool
    }

    /// `sentences(in:)` with each sentence's `continuesPrevious`.
    public static func segments(in text: String) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var continues = false
        let characters = Array(text)
        func close(nextContinues: Bool) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(Segment(text: trimmed, continuesPrevious: continues)) }
            current = ""
            continues = nextContinues
        }
        for (index, character) in characters.enumerated() {
            if character == "\n" {
                close(nextContinues: false)
                continue
            }
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard ".!?".contains(character), next == nil || next!.isWhitespace else { continue }
            if character == "." {
                let rest = characters[(index + 1)...].drop { $0.isWhitespace && $0 != "\n" }
                let following = rest.first == "\n" ? nil : String(rest.prefix { !$0.isWhitespace })
                switch boundary(after: current, following: following) {
                case .none: continue
                case .soft: close(nextContinues: true)
                case .hard: close(nextContinues: false)
                }
                continue
            }
            close(nextContinues: false)
        }
        close(nextContinues: false)
        return result
    }

    enum Boundary { case none, soft, hard }

    /// Whether the period at the end of `current` ends a sentence, given the next word (nil at the end of the text or
    /// a line). `.soft` is an end after an abbreviation: a new sentence that may still be part of the same order.
    static func boundary(after current: String, following: String?) -> Boundary {
        guard let following, let first = following.first else { return .hard }
        let word =
            current.split(whereSeparator: \.isWhitespace).last.map {
                String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'“‘["))
            } ?? ""
        let bare = String(word.dropLast())
        // Re-review minor 1: "No." is an answer and ends its sentence; "No. 5" is a number.
        if bare == "no" { return first.isNumber ? .none : .hard }
        if neverEnding.contains(bare) { return .none }
        let dotted = bare.range(of: #"^([a-z]\.)+[a-z]$"#, options: .regularExpression) != nil
        guard dotted || continuingAbbreviations.contains(bare) else { return .hard }
        guard first.isUppercase else { return .none }
        // Re-review I9-R: speech recognition writes TID, BID, PO, IV in capitals; they continue the order.
        let acronym = following.trimmingCharacters(in: .punctuationCharacters)
        if acronym == acronym.uppercased(), dosingAcronyms.contains(acronym.lowercased()) { return .none }
        return .soft
    }

    /// Abbreviations that are followed by more of the same sentence (a name, a comparison, an example).
    static let neverEnding: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "st", "vs", "approx", "e.g", "i.e", "cf",
    ]
    /// Clinical and unit abbreviations (without their last period) that do not end an order: a lowercase word after
    /// them continues the sentence, a capitalized dosing acronym ("TID") too, and any other capital starts a sentence
    /// that "scratch that" still treats as part of the same order (re-review I9-R).
    public static let continuingAbbreviations: Set<String> = [
        "p.o", "b.i.d", "t.i.d", "q.i.d", "q.d", "q.h.s", "p.r.n", "i.v", "i.m", "s.c", "s.l", "o.d", "o.s", "o.u",
        "e.g", "i.e", "mg", "mcg", "ml", "g", "kg", "tab", "tabs", "cap", "caps", "hr", "hrs", "min", "mins", "sec",
        "wk", "wks", "mo", "yr", "yrs", "pt", "pts", "dx", "hx", "rx", "sx", "tx", "etc", "qty", "prn", "po", "bid",
        "tid", "qid", "qd", "qhs", "od", "os", "ou", "iv", "im", "sc", "sl",
    ]
    /// Dosing acronyms that continue an order when written in capitals after an abbreviation ("p.o. TID").
    static let dosingAcronyms: Set<String> = [
        "tid", "bid", "qid", "qd", "qhs", "qam", "qpm", "prn", "po", "iv", "im", "sc", "sq", "sl", "pr", "od", "os",
        "ou", "ac", "pc", "hs", "stat",
    ]

    // MARK: - Rendering

    enum Op: Equatable {
        /// A dictated sentence; `continues` when it was split from the one before only after an abbreviation.
        case text(String, continues: Bool)
        case edit(String)
        /// Removes the text ops at these indices (one order, re-review I9-R).
        case scratch([Int])

        var isText: Bool { if case .text = self { true } else { false } }
        var isUndoable: Bool { if case .text = self { false } else { true } }
        var continuesPrevious: Bool { if case .text(_, let continues) = self { continues } else { false } }
        var scratchedIndices: [Int] { if case .scratch(let indices) = self { indices } else { [] } }
    }

    static func render(_ ops: [Op]) -> String {
        let scratched = Set(ops.flatMap(\.scratchedIndices))
        var output = ""
        for (index, op) in ops.enumerated() {
            switch op {
            case .text(let sentence, _):
                guard !scratched.contains(index) else { continue }
                if output.isEmpty || output.hasSuffix("\n") {
                    output += sentence
                } else {
                    output += " " + sentence
                }
            case .edit("new_paragraph"):
                output = trimmedTrailingSpaces(output) + (output.isEmpty ? "" : "\n\n")
            case .edit("new_line"):
                output = trimmedTrailingSpaces(output) + (output.isEmpty ? "" : "\n")
            case .edit("bullet_list"):
                output = bulletize(output)
            case .edit("capitalize"):
                output = capitalizeLastWord(output)
            case .edit, .scratch:
                break
            }
        }
        return output
    }

    static func trimmedTrailingSpaces(_ text: String) -> String {
        var result = text
        while result.last == " " { result.removeLast() }
        return result
    }

    /// The current paragraph (after the last blank line) as one bullet per sentence.
    static func bulletize(_ text: String) -> String {
        let trimmed = trimmedTrailingSpaces(text)
        let start = trimmed.range(of: "\n\n", options: .backwards)?.upperBound ?? trimmed.startIndex
        let paragraph = String(trimmed[start...])
        let bullets = sentences(in: paragraph).map { "- " + $0 }.joined(separator: "\n")
        guard !bullets.isEmpty else { return text }
        return String(trimmed[..<start]) + bullets + "\n"
    }

    static func capitalizeLastWord(_ text: String) -> String {
        guard let wordRange = text.range(of: #"[A-Za-z][A-Za-z'-]*(?=[^A-Za-z]*$)"#, options: .regularExpression)
        else { return text }
        var result = text
        result.replaceSubrange(wordRange, with: text[wordRange].prefix(1).uppercased() + text[wordRange].dropFirst())
        return result
    }
}
