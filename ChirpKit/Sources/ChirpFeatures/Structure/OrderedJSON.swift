import Foundation

/// JSON that keeps object keys in the order they were written.
///
/// Needle 3 was trained on tool schemas in their natural order (`name`, `description`, `parameters` with `type`,
/// `properties`, `required`); re-serializing with sorted keys measurably changed its answers (the needle-rs CLI and this
/// app disagreed on the same query until the order was kept). So the tool JSON a model reads is the catalog file's own
/// order, compacted.
indirect enum OrderedJSON: Equatable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// The number exactly as written.
    case number(String)
    case bool(Bool)
    case null

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let a), .array(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    subscript(key: String) -> OrderedJSON? {
        if case .object(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    /// The same value without the named keys (at this level only).
    func removing(_ keys: Set<String>) -> OrderedJSON {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs.filter { !keys.contains($0.key) })
    }

    /// Compact JSON, keys in their original order.
    var compact: String {
        switch self {
        case .object(let pairs):
            "{" + pairs.map { Self.quoted($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
        case .array(let values): "[" + values.map(\.compact).joined(separator: ",") + "]"
        case .string(let value): Self.quoted(value)
        case .number(let raw): raw
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        }
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    enum ParseError: Error { case invalid(Int) }

    /// Parses JSON text (UTF-8), keeping key order.
    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError.invalid(parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipWhitespace()
            guard index < bytes.count else { throw ParseError.invalid(index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return try number()
            }
        }

        mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
            let token = Array(word.utf8)
            guard index + token.count <= bytes.count, Array(bytes[index..<index + token.count]) == token else {
                throw ParseError.invalid(index)
            }
            index += token.count
            return value
        }

        mutating func number() throws -> OrderedJSON {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start, let raw = String(bytes: bytes[start..<index], encoding: .utf8),
                Double(raw) != nil
            else { throw ParseError.invalid(start) }
            return .number(raw)
        }

        mutating func string() throws -> String {
            // Hand the quoted token to JSONDecoder, which handles every escape.
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw ParseError.invalid(start) }
            index += 1
            return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
        }

        mutating func array() throws -> OrderedJSON {
            index += 1
            var values: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            while true {
                values.append(try value())
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.invalid(index) }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(values)
                } else {
                    throw ParseError.invalid(index)
                }
            }
        }

        mutating func object() throws -> OrderedJSON {
            index += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError.invalid(index) }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError.invalid(index) }
                index += 1
                pairs.append((key, try value()))
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.invalid(index) }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                } else if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(pairs)
                } else {
                    throw ParseError.invalid(index)
                }
            }
        }
    }
}
