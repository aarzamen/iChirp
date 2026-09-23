import ChirpCore
import ChirpText
import Foundation

/// Why a text item was not saved.
public enum TextItemError: Error, Equatable, LocalizedError {
    /// Nothing but whitespace.
    case empty
    /// Longer than `TextItemService.maxCharacters`.
    case tooLong(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .empty: "There is no text to save. Type or paste something first."
        case .tooLong(let limit):
            "That text is longer than \(limit.formatted()) characters. Save it in parts, or import it as a file."
        }
    }
}

/// Plan 022 Step 1: typed or pasted plain text as a first-class Library item.
///
/// A text item is a `Transcription` with `sourceType == .text`: the text is `rawTranscript` exactly as saved (only the
/// surrounding blank space trimmed and line endings made `\n`), `status` is `.completed` at once, and there is no media
/// folder, no engine and no timings. Because it is an ordinary row, everything that works on a transcript works on it
/// (Transform, Ask, Listen, Extract fields, Create) and routes through `EffectivePrivacyClass` like any other item.
/// Nothing leaves the phone to save one.
public struct TextItemService: Sendable {
    /// Long enough for any pasted note or article; a book belongs in a file import.
    public static let maxCharacters = 1_000_000
    /// The row's `fileName` (a text item has no file); `displayTitle` prefers the first line.
    public static let fileName = "Text"

    private let store: any TranscriptionStoring
    private let now: @Sendable () -> Date

    public init(store: any TranscriptionStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Saves `text` as a new `.completed` text item with `privacyClass` and returns the stored row. Throws
    /// `TextItemError.empty` for blank text (nothing is stored) and `.tooLong` above `maxCharacters`.
    public func save(_ text: String, privacyClass: PrivacyClass = .personal) async throws -> Transcription {
        let body = Self.normalized(text)
        guard !body.isEmpty else { throw TextItemError.empty }
        guard body.count <= Self.maxCharacters else { throw TextItemError.tooLong(limit: Self.maxCharacters) }
        var row = Transcription(
            createdAt: now(), sourceType: .text, fileName: Self.fileName, status: .completed,
            privacyClass: privacyClass)
        row.rawTranscript = body
        let title = Self.title(from: body)
        row.derivedTitle = title
        let rest = Self.textAfterFirstLine(body)
        row.derivedSnippet = rest.isEmpty ? nil : SnippetDeriver.derive(from: rest, excluding: title)
        try await store.insert(row)
        return row
    }

    /// Line endings as `\n`, surrounding whitespace and blank lines removed; the inside is untouched.
    public static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The title a text item shows: its first non-empty line, without Markdown heading or list markers, at most
    /// `TitleDeriver.maxLength` characters (cut at a word, with "…"). Empty text gives "Text".
    public static func title(from text: String) -> String {
        let firstLine =
            normalized(text)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        var line = firstLine.trimmingCharacters(in: .whitespaces)
        while let first = line.first, "#>-*•".contains(first) {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !line.isEmpty else { return fileName }
        let limit = TitleDeriver.maxLength
        guard line.count > limit else { return line }
        let cut = line.prefix(limit - 1)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    private static func textAfterFirstLine(_ body: String) -> String {
        guard let newline = body.firstIndex(of: "\n") else { return "" }
        return body[body.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
