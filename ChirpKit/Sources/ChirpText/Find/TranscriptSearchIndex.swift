// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetViewModels/TranscriptFindModel.swift @ bbae9e0e (case- and
// diacritic-insensitive, untrimmed query, non-overlapping, ordered by block then position). Fresh folded-index
// implementation for the 20,000-word budget (plan 025 D4).

import Foundation

/// One match of a find query: the block (the Transcript screen's line, in the order the blocks were given) and the
/// UTF-16 range of the match in that block's original text. A range always covers whole Characters, so it maps straight
/// onto `NSString`, `AttributedString` and `String` ranges of the text the screen shows.
public struct TranscriptFindMatch: Equatable, Hashable, Sendable {
    /// Index into the blocks the index was built from.
    public let blockIndex: Int
    /// UTF-16 range of the match in that block's text.
    public let range: NSRange

    public init(blockIndex: Int, range: NSRange) {
        self.blockIndex = blockIndex
        self.range = range
    }
}

/// A folded copy of the blocks, built once per text change, that answers a query with one scan of UTF-16 units
/// (plan 025 D4, option b).
///
/// Every Character of every block is folded with `String.folding(options: [.caseInsensitive, .diacriticInsensitive],
/// locale: nil)` (ASCII letters are lowercased directly, the fast path) and each folded UTF-16 unit remembers the
/// UTF-16 start and end of the Character it came from. The query is folded the same way. A match therefore always
/// covers whole Characters of the original text ("e" + a combining accent is one Character: a match covers both units),
/// matches never overlap, never cross a block, and come back in reading order. A query that is blank after trimming
/// matches nothing; otherwise the untrimmed query is searched (upstream: " the " finds the word, not the "the" in
/// "other").
public struct TranscriptSearchIndex: Sendable {
    /// Folded UTF-16 units of every block, one after another.
    private let units: [UInt16]
    /// For each folded unit: the UTF-16 start and end, in its block's original text, of the Character it came from.
    private let characterStarts: [Int32]
    private let characterEnds: [Int32]
    /// Each block's slice of `units`.
    private let blockRanges: [Range<Int>]

    public init(blocks: [String]) {
        var units: [UInt16] = []
        var starts: [Int32] = []
        var ends: [Int32] = []
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(blocks.count)
        let estimate = blocks.reduce(0) { $0 + $1.utf8.count }
        units.reserveCapacity(estimate)
        starts.reserveCapacity(estimate)
        ends.reserveCapacity(estimate)
        for block in blocks {
            let first = units.count
            Self.fold(block, into: &units, starts: &starts, ends: &ends)
            ranges.append(first..<units.count)
        }
        self.units = units
        characterStarts = starts
        characterEnds = ends
        blockRanges = ranges
    }

    /// The number of blocks the index was built from.
    public var blockCount: Int { blockRanges.count }

    /// Every match of `query`, in reading order (block order, then position).
    public func matches(for query: String) -> [TranscriptFindMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var needle: [UInt16] = []
        var ignoredStarts: [Int32] = []
        var ignoredEnds: [Int32] = []
        Self.fold(query, into: &needle, starts: &ignoredStarts, ends: &ignoredEnds)
        guard let head = needle.first else { return [] }
        let length = needle.count
        var result: [TranscriptFindMatch] = []
        units.withUnsafeBufferPointer { units in
            characterStarts.withUnsafeBufferPointer { starts in
                characterEnds.withUnsafeBufferPointer { ends in
                    needle.withUnsafeBufferPointer { needle in
                        for (blockIndex, range) in blockRanges.enumerated() where range.count >= length {
                            var position = range.lowerBound
                            let last = range.upperBound - length
                            while position <= last {
                                guard units[position] == head else {
                                    position += 1
                                    continue
                                }
                                var offset = 1
                                while offset < length, units[position + offset] == needle[offset] { offset += 1 }
                                guard offset == length else {
                                    position += 1
                                    continue
                                }
                                // Widen to whole Characters: from the start of the first unit's Character to the end
                                // of the last unit's.
                                let start = Int(starts[position])
                                let end = Int(ends[position + length - 1])
                                if let previous = result.last, previous.blockIndex == blockIndex,
                                    start < previous.range.location + previous.range.length
                                {
                                    // Inside the Character the previous match ended in: never overlap.
                                    position += 1
                                    continue
                                }
                                result.append(
                                    TranscriptFindMatch(
                                        blockIndex: blockIndex, range: NSRange(location: start, length: end - start)))
                                // Continue after the Character the match ended in.
                                position += length
                                while position < range.upperBound, Int(starts[position]) < end { position += 1 }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: - Folding

    /// Appends the folded UTF-16 units of `text`, each with its Character's original UTF-16 start and end.
    private static func fold(
        _ text: String, into units: inout [UInt16], starts: inout [Int32], ends: inout [Int32]
    ) {
        if let ascii = asciiFold(text) {
            units += ascii.units
            starts += ascii.starts
            ends += ascii.ends
            return
        }
        var offset = 0
        for character in text {
            let width = character.utf16.count
            let start = Int32(offset)
            let end = Int32(offset + width)
            offset += width
            if character.isASCII {
                // As the fast path folds it ("\r\n" keeps both units).
                for unit in character.utf16 {
                    units.append(UInt16(lowercased(UInt8(unit))))
                    starts.append(start)
                    ends.append(end)
                }
                continue
            }
            for unit in String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .utf16
            {
                units.append(unit)
                starts.append(start)
                ends.append(end)
            }
        }
    }

    /// The fast path for an all-ASCII text: one unit per byte, lowercased; "\r\n" (one Character) maps both units to
    /// the pair. Nil when the text has a non-ASCII byte.
    private static func asciiFold(_ text: String) -> (units: [UInt16], starts: [Int32], ends: [Int32])? {
        var text = text
        text.makeContiguousUTF8()
        let folded = text.utf8.withContiguousStorageIfAvailable {
            bytes -> (units: [UInt16], starts: [Int32], ends: [Int32])? in
            var units = [UInt16]()
            var starts = [Int32]()
            var ends = [Int32]()
            units.reserveCapacity(bytes.count)
            starts.reserveCapacity(bytes.count)
            ends.reserveCapacity(bytes.count)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                guard byte < 0x80 else { return nil }
                if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    units += [0x0D, 0x0A]
                    starts += [Int32(index), Int32(index)]
                    ends += [Int32(index + 2), Int32(index + 2)]
                    index += 2
                    continue
                }
                units.append(UInt16(lowercased(byte)))
                starts.append(Int32(index))
                ends.append(Int32(index + 1))
                index += 1
            }
            return (units, starts, ends)
        }
        return folded ?? nil
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }
}
