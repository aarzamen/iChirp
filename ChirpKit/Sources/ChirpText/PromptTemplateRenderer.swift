// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Models/PromptTemplateRenderer.swift @ bbae9e0e
// Changes: logs through iChirp's `Log` (category "prompt-template"); an unknown key is logged `.private` (user
// templates can hold anything); adds `references(_:in:)`. Single-pass substitution and the unknown-key → empty rule
// are unchanged.

import ChirpCore
import Foundation

/// Single-pass simultaneous template substitution for prompt content.
///
/// Replaces `{{key}}` tokens with the supplied values. All replacements are computed against the original text in one
/// scan, so a value that itself contains `{{...}}` (a transcript that says "{{userNotes}}") is never interpreted as a
/// template: pasted content cannot smuggle other variables into the prompt.
///
/// Keys are case-sensitive; canonical casing is `{{transcript}}` and `{{userNotes}}`. An unknown key renders as the
/// empty string; an unterminated `{{` is emitted literally. Both log a warning with the key name only.
public enum PromptTemplateRenderer {
    public enum Variable: String, CaseIterable, Sendable {
        case userNotes
        case transcript
    }

    private static let logger = Log.logger("prompt-template")

    /// Whether `template` contains the `{{variable}}` token.
    public static func references(_ variable: Variable, in template: String) -> Bool {
        template.contains("{{\(variable.rawValue)}}")
    }

    public static func render(_ template: String, substitutions: [Variable: String]) -> String {
        guard template.contains("{{") else { return template }

        var output = ""
        output.reserveCapacity(template.count)

        var index = template.startIndex
        let end = template.endIndex

        while index < end {
            guard let openRange = template.range(of: "{{", range: index..<end) else {
                output.append(contentsOf: template[index..<end])
                break
            }
            output.append(contentsOf: template[index..<openRange.lowerBound])

            let afterOpen = openRange.upperBound
            guard let closeRange = template.range(of: "}}", range: afterOpen..<end) else {
                logger.warning("template_unterminated_marker")
                output.append(contentsOf: template[openRange])
                index = openRange.upperBound
                continue
            }

            let key = String(template[afterOpen..<closeRange.lowerBound])
            if let variable = Variable(rawValue: key) {
                output.append(substitutions[variable] ?? "")
            } else {
                logger.notice("template_unknown_variable key=\(key, privacy: .private)")
            }
            index = closeRange.upperBound
        }
        return output
    }
}
