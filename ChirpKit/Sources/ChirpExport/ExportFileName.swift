// Review R1-9 (plan 024 Task 4): one rule names every export file — the text formats (`TranscriptExporter`) and the
// page formats (`DocumentExporter`) used two helpers that disagreed (no length limit, and 120 characters).

import Foundation

/// The file name an export is written under: the title, made safe for a file name and short enough for any file
/// system the person may save it to.
public enum ExportFileName {
    /// The most bytes of title in a file name. A file name holds 255 units: on Apple's file systems UTF-16 units of
    /// the *decomposed* name (measured on APFS: 251 kanji fit, but 251 Hangul syllables or accented letters do not,
    /// because each decomposes into several), on Linux 255 UTF-8 bytes, on Windows 255 UTF-16 units. A character's
    /// UTF-8 bytes in its larger form (composed or decomposed) bound all of those, so 200 of them leave room for the
    /// longest extension (".docx") everywhere.
    public static let maxStemBytes = 200

    /// The title with `/`, `:`, `\` and NUL each replaced by a space, trimmed, then cut on a character boundary (an
    /// accent stays with its letter, an emoji sequence stays whole) to at most `maxStemBytes`, and trimmed again;
    /// `fallback` when nothing is left. A title's own trailing ".something" is kept: a display title is never a file
    /// name, so "Client Q&A v2.1" stays whole (this is deliberately not ChirpText's
    /// `TranscriptSegmenter.sanitizedExportStem(from:)`, which strips an extension from a real file name).
    public static func stem(fromTitle title: String, fallback: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\\0")
        let cleaned = title.components(separatedBy: disallowed)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = ""
        var bytes = 0
        for character in cleaned {
            let size = largestUTF8Count(of: character)
            guard bytes + size <= maxStemBytes else { break }
            stem.append(character)
            bytes += size
        }
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func largestUTF8Count(of character: Character) -> Int {
        let text = String(character)
        return max(
            text.precomposedStringWithCanonicalMapping.utf8.count,
            text.decomposedStringWithCanonicalMapping.utf8.count)
    }
}
