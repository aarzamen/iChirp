// New for iChirp (plan 025 Step B7): the find budget measured the same way on the Mac (a package test) and on the
// iPhone (the device smoke's FIND BENCH line).

import Foundation

/// Times `TranscriptSearchIndex` over a deterministic synthetic transcript (D4 budget: 20,000 words, index ≤ 50 ms and
/// query ≤ 8 ms on the iPhone 17 Pro in a release build): the first (cold) index build and the median of 20 queries.
/// Synthetic words only.
public enum TranscriptSearchBenchmark {
    public struct Result: Sendable, Equatable {
        /// The first index build, in milliseconds: cold, as when a transcript opens (fix round 1, M9).
        public var coldIndexMs: Double
        /// The median of the query times, in milliseconds.
        public var queryMedianMs: Double
        /// Matches found over all queries (proof the queries searched something).
        public var totalMatches: Int
    }

    /// The budget D4 sets for the iPhone.
    public static let indexBudgetMs = 50.0
    public static let queryBudgetMs = 8.0

    /// Twenty queries typed as a person types them (prefixes of a word, a phrase, accents, a miss).
    public static let queries = [
        "m", "me", "met", "metf", "metfo", "metform", "metformin", "cafe", "café", "naive", "pain", "pain.", "the",
        "the patient", "blood pressure", "follow-up", "weeks,", "xyz", "zz top", "Three",
    ]

    /// Deterministic synthetic words in reading lines of 80, as the Transcript screen's paragraphs are.
    public static func syntheticBlocks(words count: Int) -> [String] {
        let vocabulary = [
            "the", "patient", "reports", "metformin", "twice", "daily", "and", "denies", "chest", "pain.", "Café",
            "naïve", "follow-up", "in", "three", "weeks,", "blood", "pressure", "was", "normal",
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var blocks: [String] = []
        var line: [String] = []
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            line.append(vocabulary[Int(state >> 33) % vocabulary.count])
            if line.count == 80 {
                blocks.append(line.joined(separator: " "))
                line.removeAll()
            }
        }
        if !line.isEmpty { blocks.append(line.joined(separator: " ")) }
        return blocks
    }

    /// Builds the index once (cold) and times every query once.
    public static func run(words: Int = 20_000) -> Result {
        let blocks = syntheticBlocks(words: words)
        let clock = ContinuousClock()
        var index = TranscriptSearchIndex(blocks: [])
        let cold = milliseconds(clock.measure { index = TranscriptSearchIndex(blocks: blocks) })
        var times: [Double] = []
        var total = 0
        for query in queries {
            var found = 0
            let elapsed = clock.measure { found = index.matches(for: query).count }
            total += found
            times.append(milliseconds(elapsed))
        }
        times.sort()
        let median = (times[(times.count - 1) / 2] + times[times.count / 2]) / 2
        return Result(coldIndexMs: cold, queryMedianMs: median, totalMatches: total)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
