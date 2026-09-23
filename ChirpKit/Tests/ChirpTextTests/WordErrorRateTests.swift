import XCTest

@testable import ChirpText

/// M7 Step 6: word error rate as upstream's `score.py --simple` computes it.
final class WordErrorRateTests: XCTestCase {
    func testIdenticalTextIsZero() {
        let wer = WordErrorRate.score(reference: "The quick brown fox.", hypothesis: "the quick brown fox")
        XCTAssertEqual(wer.errors, 0)
        XCTAssertEqual(wer.rate, 0)
        XCTAssertEqual(wer.referenceWords, 4)
    }

    func testSubstitutionDeletionAndInsertionAreCounted() {
        let wer = WordErrorRate.score(
            reference: "please call the clinic today", hypothesis: "please fall clinic today now")
        XCTAssertEqual(wer.substitutions, 1)  // call → fall
        XCTAssertEqual(wer.deletions, 1)  // the
        XCTAssertEqual(wer.insertions, 1)  // now
        XCTAssertEqual(wer.rate, 3.0 / 5.0, accuracy: 1e-9)
    }

    func testNormalizationFoldsCasePunctuationQuotesAndHyphens() {
        XCTAssertEqual(
            WordErrorRate.normalizedWords("Follow-up: it’s “fine”, 'really' — OK?"),
            ["follow", "up", "it's", "fine", "really", "ok"])
    }

    func testAnEmptyHypothesisIsAllDeletions() {
        let wer = WordErrorRate.score(reference: "three words here", hypothesis: "")
        XCTAssertEqual(wer.deletions, 3)
        XCTAssertEqual(wer.rate, 1)
    }

    func testCorpusRateSumsCountsNotRates() {
        let short = WordErrorRate.score(reference: "yes", hypothesis: "no")  // 1 of 1
        let long = WordErrorRate.score(
            reference: "one two three four five six seven eight nine",
            hypothesis: "one two three four five six seven eight nine")
        let corpus = WordErrorRate.corpus([short, long])
        XCTAssertEqual(corpus.errors, 1)
        XCTAssertEqual(corpus.referenceWords, 10)
        XCTAssertEqual(corpus.rate, 0.1, accuracy: 1e-9)
    }
}
