// Fresh implementation for iChirp (plan 020 Step 5): what Listen hands to `VoicePlayer`.

import Foundation

/// Turns text written for the screen into text worth hearing. Removes what a voice would read as noise: citation
/// timestamps ("[00:12]", "[1:02:03–1:02:40]"), Markdown markers (heading hashes, list bullets, `**`, `*`, backticks,
/// rules) and link targets (the link's words stay). Heading and list lines get a full stop, so the voice pauses after
/// them. Words are never changed or dropped.
public enum SpeakableText {
    public static func prepare(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in inlinePatterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let lines = result.components(separatedBy: "\n").map(prepareLine)
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let inlinePatterns: [(String, String)] = [
        // Citations: [00:12], [1:02:03], [00:12–00:40], [00:12-00:40].
        (#"\s?\[(\d{1,2}:)?\d{1,2}:\d{2}(\s*[–-]\s*(\d{1,2}:)?\d{1,2}:\d{2})?\]"#, ""),
        // [words](https://…) → words
        (#"\[([^\]\n]+)\]\([^)\n]*\)"#, "$1"),
        (#"\*\*|__|`"#, ""),
        (#"(?<=\s|^)\*(?=\S)|(?<=\S)\*(?=\s|$|[.,;:!?])"#, ""),
    ]

    private static func prepareLine(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.range(of: #"^([-*_=]\s*){3,}$"#, options: .regularExpression) != nil { return "" }
        var isStructural = false
        if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            line.removeSubrange(heading)
            isStructural = true
        } else if let bullet = line.range(of: #"^[-+•*]\s+"#, options: .regularExpression) {
            line.removeSubrange(bullet)
            isStructural = true
        } else if line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) != nil {
            isStructural = true
        }
        line = line.trimmingCharacters(in: .whitespaces)
        if isStructural, let last = line.last, !".!?:;…".contains(last) {
            line += "."
        }
        return line
    }
}
