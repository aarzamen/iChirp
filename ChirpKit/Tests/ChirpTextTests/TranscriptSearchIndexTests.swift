// Matching cases ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/ViewModels/TranscriptFindModelTests.swift
// @ bbae9e0e (the matcher's cases, against the folded index instead of the model), plus iChirp's own cases for
// decomposed accents, emoji and CJK, blocks and the original-text ranges (plan 025 Step B1).

import Foundation
import XCTest

@testable import ChirpText

final class TranscriptSearchIndexTests: XCTestCase {
    private func matches(_ blocks: [String], _ query: String) -> [TranscriptFindMatch] {
        TranscriptSearchIndex(blocks: blocks).matches(for: query)
    }

    private func match(_ block: Int, _ location: Int, _ length: Int) -> TranscriptFindMatch {
        TranscriptFindMatch(blockIndex: block, range: NSRange(location: location, length: length))
    }

    // MARK: - Upstream's matching cases

    func testEmptyQueryHasNoMatches() {
        XCTAssertEqual(matches(["the quick brown fox"], ""), [])
    }

    func testWhitespaceOnlyQueryHasNoMatches() {
        XCTAssertEqual(matches(["the quick brown fox"], "   \n\t"), [])
    }

    func testQueryWithEdgeSpacesMatchesLiterally() {
        // Non-empty after trimming, so it is searched untrimmed: "the " finds "the " in block 0 but not the "the" of
        // "there" (followed by "r") in block 1.
        XCTAssertEqual(matches(["the cat sat", "there it is"], "the "), [match(0, 0, 4)])
    }

    func testMultipleMatchesWithinOneBlockAreOrdered() {
        XCTAssertEqual(matches(["hello Hello HELLO"], "hello"), [match(0, 0, 5), match(0, 6, 5), match(0, 12, 5)])
    }

    func testMatchesAcrossBlocksAreGloballyOrdered() {
        XCTAssertEqual(
            matches(["alpha match", "no hit here", "match beta match"], "match"),
            [match(0, 6, 5), match(2, 0, 5), match(2, 11, 5)])
    }

    func testOverlappingCandidatesDoNotDoubleCount() {
        XCTAssertEqual(matches(["aaaa"], "aa"), [match(0, 0, 2), match(0, 2, 2)])
    }

    func testCaseInsensitive() {
        let lower = matches(["Title TITLE title"], "title")
        XCTAssertEqual(lower, matches(["Title TITLE title"], "TITLE"))
        XCTAssertEqual(lower.count, 3)
    }

    func testDiacriticInsensitive() {
        let found = matches(["café cafe Café"], "cafe")
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.first, match(0, 0, 4))
        // The other way round too: an accented query finds the plain word.
        XCTAssertEqual(matches(["cafe"], "café"), [match(0, 0, 4)])
    }

    // MARK: - iChirp's cases

    func testDecomposedAccentsMatchAndCoverWholeCharacters() {
        // "e" + COMBINING ACUTE ACCENT is one Character of two UTF-16 units: a match covers both.
        let decomposed = "cafe\u{301} au lait"
        XCTAssertEqual(matches([decomposed], "café"), [match(0, 0, 5)])
        XCTAssertEqual(matches([decomposed], "e"), [match(0, 3, 2)])
        // A precomposed text found by a decomposed query.
        XCTAssertEqual(matches(["café"], "cafe\u{301}"), [match(0, 0, 4)])
    }

    func testEmojiAndCJK() {
        let text = "ok 👍🏽 東京 tokyo 東京"
        let thumbs = matches([text], "👍🏽")
        XCTAssertEqual(thumbs, [match(0, 3, 4)])
        XCTAssertEqual(matches([text], "東京"), [match(0, 8, 2), match(0, 17, 2)])
        // Every range maps back onto whole Characters of the original text.
        for found in thumbs + matches([text], "東京") {
            XCTAssertNotNil(Range(found.range, in: text))
        }
    }

    func testMatchesNeverCrossBlocks() {
        XCTAssertEqual(matches(["the quick", "brown fox"], "quick brown"), [])
        XCTAssertEqual(matches(["the quick", "brown fox"], "kb"), [])
    }

    func testRangesMapToTheOriginalText() {
        let blocks = ["Ünïcödé MET for men, then met FOR MEN.", "no", "Met for men"]
        let found = matches(blocks, "met for men")
        XCTAssertEqual(found.count, 3)
        let texts = found.map { (blocks[$0.blockIndex] as NSString).substring(with: $0.range) }
        XCTAssertEqual(texts, ["MET for men", "met FOR MEN", "Met for men"])
    }

    func testEmptyBlocksAndNoBlocks() {
        XCTAssertEqual(matches([], "a"), [])
        XCTAssertEqual(matches(["", "a"], "a"), [match(1, 0, 1)])
    }

    func testCRLFIsOneCharacter() {
        // "\r\n" is one Character: a match never ends inside it.
        let found = matches(["a\r\nb"], "a\r")
        XCTAssertTrue(found.allSatisfy { Range($0.range, in: "a\r\nb") != nil })
    }
}

/// Plan 025 D4 budget, Mac debug build: building the index of 20,000 words ≤ 150 ms and a median query ≤ 16 ms (the
/// phone's budget, 50 ms and 8 ms p95 in a release build, is measured by the device smoke's `FIND BENCH` line).
final class TranscriptSearchIndexPerformanceTests: XCTestCase {
    /// Deterministic synthetic words in reading lines of 80, as the Transcript screen's paragraphs are.
    static func syntheticBlocks(words count: Int) -> [String] {
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

    func testTwentyThousandWords() {
        let blocks = Self.syntheticBlocks(words: 20_000)
        var buildTimes: [Double] = []
        var index = TranscriptSearchIndex(blocks: [])
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            index = TranscriptSearchIndex(blocks: blocks)
            buildTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let queries = ["m", "me", "met", "metf", "metformin", "cafe", "naive", "pain", "xyz", "the patient"]
        var queryTimes: [Double] = []
        var total = 0
        for _ in 0..<2 {
            for query in queries {
                let start = DispatchTime.now().uptimeNanoseconds
                total += index.matches(for: query).count
                queryTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        XCTAssertGreaterThan(total, 0)
        let build = buildTimes.min() ?? .infinity
        let median = queryTimes.sorted()[queryTimes.count / 2]
        print("FIND BENCH (Mac test) index=\(Int(build))ms query_median=\(String(format: "%.2f", median))ms")
        XCTAssertLessThanOrEqual(build, 150, "index build \(build) ms")
        XCTAssertLessThanOrEqual(median, 16, "median query \(median) ms")
        measure {
            _ = index.matches(for: "metformin")
        }
    }
}
