import Foundation

/// Decodes HTML character references (`&amp;`, `&#39;`, `&#x2019;`, `&nbsp;` …) in plain text. Used for HTML documents
/// and YouTube caption text, which arrives HTML-escaped inside XML.
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×", "divide": "÷", "plusmn": "±",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "micro": "µ", "para": "¶", "sect": "§", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "laquo": "«", "raquo": "»", "shy": "",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
                let replacement = replacement(for: text[text.index(after: index)..<semicolon])
            else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            result.append(replacement)
            index = text.index(after: semicolon)
        }
        return result
    }

    private static func replacement(for entity: Substring) -> String? {
        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[String(entity)] ?? named[entity.lowercased()]
    }
}
