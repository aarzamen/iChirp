import Foundation

/// Decodes HTML character references (`&amp;`, `&#39;`, `&#x2019;`, `&ge;` …) in plain text. Used for HTML documents
/// and YouTube caption text, which arrives HTML-escaped inside XML.
///
/// Named references: all of HTML 4's (Latin-1 letters and signs, Greek letters, math and arrow symbols, typographic
/// marks) plus the HTML5 names clinical text uses (`&geq;`, `&leq;`, `&approx;`, `&check;`, more fractions). Names are
/// case-sensitive (`&Delta;` Δ, `&delta;` δ); an unknown name stays as written. `&nbsp;` becomes a plain space and
/// `&shy;` (an invisible hyphenation hint) nothing.
enum HTMLEntities {
    private static let named: [String: String] = {
        var table: [String: String] = [:]
        func add(_ name: String, _ value: UInt32) {
            if let scalar = Unicode.Scalar(value) { table[name] = String(Character(scalar)) }
        }
        // U+00A0–U+00FF in order (HTML 4's Latin-1 set).
        let latin1 = [
            "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not",
            "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1",
            "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute", "Acirc", "Atilde", "Auml",
            "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml", "ETH",
            "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc",
            "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig",
            "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml", "eth", "ntilde",
            "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml",
            "yacute", "thorn", "yuml",
        ]
        for (offset, name) in latin1.enumerated() {
            add(name, 0xA0 + UInt32(offset))
        }
        // Greek capitals U+0391–U+03A9 (U+03A2 is unassigned) and small letters U+03B1–U+03C9.
        let greek = [
            "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Mu", "Nu",
            "Xi", "Omicron", "Pi", "Rho", "", "Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega",
        ]
        for (offset, name) in greek.enumerated() where !name.isEmpty {
            add(name, 0x391 + UInt32(offset))
            add(name.lowercased(), 0x3B1 + UInt32(offset))
        }
        add("sigmaf", 0x3C2)
        let others: [(String, UInt32)] = [
            ("quot", 0x22), ("amp", 0x26), ("apos", 0x27), ("lt", 0x3C), ("gt", 0x3E),
            ("OElig", 0x152), ("oelig", 0x153), ("Scaron", 0x160), ("scaron", 0x161), ("Yuml", 0x178), ("fnof", 0x192),
            ("circ", 0x2C6), ("tilde", 0x2DC), ("thetasym", 0x3D1), ("upsih", 0x3D2), ("piv", 0x3D6),
            ("ensp", 0x2002), ("emsp", 0x2003), ("thinsp", 0x2009), ("zwnj", 0x200C), ("zwj", 0x200D),
            ("lrm", 0x200E), ("rlm", 0x200F), ("hyphen", 0x2010), ("dash", 0x2010), ("ndash", 0x2013),
            ("mdash", 0x2014), ("lsquo", 0x2018), ("rsquo", 0x2019), ("sbquo", 0x201A), ("ldquo", 0x201C),
            ("rdquo", 0x201D), ("bdquo", 0x201E), ("dagger", 0x2020), ("Dagger", 0x2021), ("bull", 0x2022),
            ("hellip", 0x2026), ("permil", 0x2030), ("prime", 0x2032), ("Prime", 0x2033), ("lsaquo", 0x2039),
            ("rsaquo", 0x203A), ("oline", 0x203E), ("frasl", 0x2044), ("euro", 0x20AC), ("image", 0x2111),
            ("weierp", 0x2118), ("real", 0x211C), ("trade", 0x2122), ("ohm", 0x2126), ("alefsym", 0x2135),
            ("frac13", 0x2153), ("frac23", 0x2154), ("frac15", 0x2155), ("frac25", 0x2156), ("frac35", 0x2157),
            ("frac45", 0x2158), ("frac16", 0x2159), ("frac56", 0x215A), ("frac18", 0x215B), ("frac38", 0x215C),
            ("frac58", 0x215D), ("frac78", 0x215E), ("larr", 0x2190), ("uarr", 0x2191), ("rarr", 0x2192),
            ("darr", 0x2193), ("harr", 0x2194), ("crarr", 0x21B5), ("lArr", 0x21D0), ("uArr", 0x21D1),
            ("rArr", 0x21D2), ("dArr", 0x21D3), ("hArr", 0x21D4), ("forall", 0x2200), ("part", 0x2202),
            ("exist", 0x2203), ("empty", 0x2205), ("nabla", 0x2207), ("isin", 0x2208), ("notin", 0x2209),
            ("ni", 0x220B), ("prod", 0x220F), ("sum", 0x2211), ("minus", 0x2212), ("mp", 0x2213), ("lowast", 0x2217),
            ("radic", 0x221A), ("prop", 0x221D), ("infin", 0x221E), ("ang", 0x2220), ("and", 0x2227), ("or", 0x2228),
            ("cap", 0x2229), ("cup", 0x222A), ("int", 0x222B), ("there4", 0x2234), ("sim", 0x223C), ("cong", 0x2245),
            ("asymp", 0x2248), ("approx", 0x2248), ("ne", 0x2260), ("equiv", 0x2261), ("le", 0x2264), ("leq", 0x2264),
            ("ge", 0x2265), ("geq", 0x2265), ("sub", 0x2282), ("sup", 0x2283), ("nsub", 0x2284), ("sube", 0x2286),
            ("supe", 0x2287), ("oplus", 0x2295), ("otimes", 0x2297), ("perp", 0x22A5), ("sdot", 0x22C5),
            ("lceil", 0x2308), ("rceil", 0x2309), ("lfloor", 0x230A), ("rfloor", 0x230B), ("loz", 0x25CA),
            ("spades", 0x2660), ("clubs", 0x2663), ("hearts", 0x2665), ("diams", 0x2666), ("check", 0x2713),
            ("cross", 0x2717), ("lang", 0x27E8), ("rang", 0x27E9), ("half", 0xBD), ("pm", 0xB1),
            ("centerdot", 0xB7),
        ]
        for (name, value) in others {
            add(name, value)
        }
        // A plain space and nothing: this decoder feeds plain text, where these two only get in the way.
        table["nbsp"] = " "
        table["shy"] = ""
        return table
    }()

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
