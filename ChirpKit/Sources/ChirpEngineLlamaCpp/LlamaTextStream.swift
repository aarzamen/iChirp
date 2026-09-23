import Foundation

/// Turns token bytes into text deltas. A character can span two tokens (accents, emoji), so bytes of an unfinished
/// UTF-8 sequence wait for the next token instead of becoming a replacement character.
struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func push(_ bytes: [UInt8]) -> String {
        pending += bytes
        let complete = Self.completePrefixLength(pending)
        guard complete > 0 else { return "" }
        let text = String(decoding: pending[..<complete], as: UTF8.self)
        pending.removeFirst(complete)
        return text
    }

    /// What is left at the end (an unfinished sequence decodes to a replacement character).
    mutating func finish() -> String {
        defer { pending = [] }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    /// The length of the longest prefix that does not end inside a multi-byte sequence.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        var continuationBytes = 0
        while index >= 0, continuationBytes < 4 {
            let byte = bytes[index]
            if byte & 0b1100_0000 == 0b1000_0000 {
                continuationBytes += 1
                index -= 1
                continue
            }
            let needed: Int
            switch byte {
            case 0..<0x80: needed = 1
            case 0xC0..<0xE0: needed = 2
            case 0xE0..<0xF0: needed = 3
            case 0xF0..<0xF8: needed = 4
            default: needed = 1
            }
            return continuationBytes + 1 >= needed ? bytes.count : index
        }
        // Only stray continuation bytes: let the decoder replace them rather than wait forever.
        return bytes.count
    }
}

/// Drops a leading `<think>…</think>` block and the whitespace before the answer. Qwen3.5 is started with an empty
/// think block so it answers directly; if a model still reasons first, its reasoning is not part of the document.
struct LeadingThinkBlockFilter {
    private enum State {
        /// Before the first visible character: whitespace is dropped and `<think>` is recognised.
        case start
        case thinking
        case passthrough
    }

    private static let open = "<think>"
    private static let close = "</think>"
    private var state = State.start
    private var buffer = ""

    mutating func push(_ text: String) -> String {
        switch state {
        case .passthrough:
            return text
        case .start:
            buffer += text
            let visible = buffer.drop { $0.isWhitespace }
            if visible.isEmpty { return "" }
            if visible.hasPrefix(Self.open) {
                state = .thinking
                buffer = String(visible.dropFirst(Self.open.count))
                return push("")
            }
            // Still possibly the start of "<think>": wait for more.
            if Self.open.hasPrefix(visible) { return "" }
            state = .passthrough
            buffer = ""
            return String(visible)
        case .thinking:
            buffer += text
            guard let end = buffer.range(of: Self.close) else {
                // Keep only what could still be the start of "</think>".
                buffer = String(buffer.suffix(Self.close.count))
                return ""
            }
            let rest = String(buffer[end.upperBound...])
            state = .start
            buffer = ""
            return push(rest)
        }
    }

    /// The text held back at the end (an unfinished "<thi" that never became a think block).
    mutating func finish() -> String {
        defer { buffer = "" }
        guard state == .start else { return "" }
        return String(buffer.drop { $0.isWhitespace })
    }
}
