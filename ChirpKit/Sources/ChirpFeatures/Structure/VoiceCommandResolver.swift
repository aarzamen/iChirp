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
        for sentence in Self.sentences(in: text) {
            guard let candidate = candidate(for: sentence) else {
                ops.append(.text(sentence))
                continue
            }
            let match = await confirm(sentence, as: candidate, privacyClass: privacyClass)
            guard let match, gate.verdict(confidence: match.confidence) == .act else {
                if let match { ignored.append(match) }
                ops.append(.text(sentence))
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
                let scratched = Set(ops.compactMap(\.scratchedIndex))
                if let index = ops.indices.last(where: { ops[$0].isText && !scratched.contains($0) }) {
                    ops.append(.scratch(index))
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
    /// order; "t.i.d. Scratch that." splits), and never after a title or "vs.", "approx.", "e.g." ("Dr. Lee").
    public static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character == "\n" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
                current = ""
                continue
            }
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard ".!?".contains(character), next == nil || next!.isWhitespace else { continue }
            if character == "." {
                let following = characters[(index + 1)...].first { !$0.isWhitespace }
                guard endsSentence(current, following: following) else { continue }
            }
            result.append(current)
            current = ""
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether the period at the end of `current` ends a sentence, given the next non-space character.
    static func endsSentence(_ current: String, following: Character?) -> Bool {
        guard let following, following != "\n" else { return true }
        let word =
            current.split(whereSeparator: \.isWhitespace).last.map {
                String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'“‘["))
            } ?? ""
        let bare = String(word.dropLast())
        if neverEnding.contains(bare) { return false }
        let dotted = bare.range(of: #"^([a-z]\.)+[a-z]$"#, options: .regularExpression) != nil
        if dotted || abbreviations.contains(bare) { return following.isUppercase }
        return true
    }

    /// Abbreviations that are followed by more of the same sentence (a name, a comparison, an example).
    static let neverEnding: Set<String> = [
        "dr", "mr", "mrs", "ms", "prof", "st", "vs", "approx", "e.g", "i.e", "cf", "no",
    ]
    /// Abbreviations that may end a sentence: a capital letter after them starts the next one.
    static let abbreviations: Set<String> = [
        "mg", "mcg", "ml", "g", "kg", "tab", "tabs", "cap", "caps", "hr", "hrs", "min", "mins", "sec", "wk", "wks",
        "mo",
        "yr", "yrs", "pt", "pts", "dx", "hx", "rx", "sx", "tx", "etc", "qty", "prn", "po", "bid", "tid", "qid",
        "qd", "qhs", "od", "os", "ou",
    ]

    // MARK: - Rendering

    enum Op: Equatable {
        case text(String)
        case edit(String)
        /// Removes the text op at this index.
        case scratch(Int)

        var isText: Bool { if case .text = self { true } else { false } }
        var isUndoable: Bool { if case .text = self { false } else { true } }
        var scratchedIndex: Int? { if case .scratch(let index) = self { index } else { nil } }
    }

    static func render(_ ops: [Op]) -> String {
        let scratched = Set(ops.compactMap(\.scratchedIndex))
        var output = ""
        for (index, op) in ops.enumerated() {
            switch op {
            case .text(let sentence):
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
