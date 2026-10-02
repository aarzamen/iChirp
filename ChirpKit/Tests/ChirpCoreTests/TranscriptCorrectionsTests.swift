import XCTest

@testable import ChirpCore

/// Plan 025 Step A1: the corrections envelope (`transcriptions.textCorrections`), its invariants, plans and inverses,
/// what a pipeline save keeps (D7) and the words' fingerprint. Synthetic words only.
final class TranscriptCorrectionsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 781_012_345.5)
    private let later = Date(timeIntervalSinceReferenceDate: 781_012_400)

    /// "the patient takes met for men daily | then Dana says hello" with S1 for the first six words, S2 after.
    private func words() -> [WordTimestamp] {
        let texts = ["the", "patient", "takes", "met", "for", "men", "daily.", "Okay", "hello."]
        return texts.enumerated().map { index, text in
            WordTimestamp(
                word: text, startMs: index * 300, endMs: index * 300 + 280, confidence: 0.9,
                speakerId: index < 7 ? "S1" : "S2")
        }
    }

    private func correction(
        _ range: Range<Int>, _ text: String, origin: TranscriptCorrection.Origin = .edit, id: UUID = UUID()
    ) -> TranscriptCorrection {
        TranscriptCorrection(
            id: id, wordRange: range, heard: "", text: text, origin: origin, createdAt: now, updatedAt: now)
    }

    private func applied(_ adds: [TranscriptCorrection], to base: TranscriptCorrections = .empty) throws
        -> TranscriptCorrections
    {
        try base.applying(TranscriptCorrectionPlan(add: adds), words: words(), now: now).corrections
    }

    // MARK: - Coding

    func testRoundTripPreservesEveryField() throws {
        var corrections = try applied([correction(3..<6, "metformin", origin: .replaceAll)])
        corrections.items[0].batchID = UUID()
        corrections.items[0].ruleID = UUID()
        corrections.detached = [correction(0..<1, "The", origin: .rule)]
        let decoded = try JSONDecoder().decode(
            TranscriptCorrections.self, from: JSONEncoder().encode(corrections))
        XCTAssertEqual(decoded, corrections)
        XCTAssertEqual(decoded.items.first?.heard, "met for men")
        XCTAssertEqual(decoded.items.first?.range, 3..<6)
    }

    func testJSONUsesTheContractKeys() throws {
        let corrections = try applied([correction(3..<6, "metformin", origin: .replaceAll)])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(corrections)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "baseline", "changedAt", "items", "detached"])
        XCTAssertEqual(object["schema"] as? Int, 1)
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["origin"] as? String, "replaceAll")
        XCTAssertEqual(
            item["wordRange"] as? [String: Int], ["startIndex": 3, "endIndexExclusive": 6])
        XCTAssertEqual(item["heard"] as? String, "met for men")
    }

    func testUnknownOriginReadsAsEdit() throws {
        let json = """
            {"id":"6C1D9B0E-8C5A-4A3B-9C8E-0F9A1B2C3D4E","wordRange":{"startIndex":1,"endIndexExclusive":2},
            "heard":"patient","text":"person","origin":"somethingNew","createdAt":1,"updatedAt":2}
            """
        let item = try JSONDecoder().decode(TranscriptCorrection.self, from: Data(json.utf8))
        XCTAssertEqual(item.origin, .edit)
        XCTAssertEqual(item.text, "person")
    }

    func testNewerSchemaDecodesAsPlaceholderThatAppliesNothing() throws {
        let json = """
            {"schema":2,"baseline":"w2:abc","changedAt":5,"items":[{"whatever":true}],"detached":[],"future":1}
            """
        let corrections = try JSONDecoder().decode(TranscriptCorrections.self, from: Data(json.utf8))
        XCTAssertTrue(corrections.isFromNewerBuild)
        XCTAssertEqual(corrections.items, [])
        XCTAssertEqual(corrections.validItems(in: words()), [])
        XCTAssertThrowsError(
            try corrections.applying(
                TranscriptCorrectionPlan(add: [correction(0..<1, "The")]), words: words(), now: now)
        ) { error in
            XCTAssertEqual(error as? TranscriptCorrectionsError, .newerVersion)
        }
        XCTAssertEqual(corrections.preserved(acrossNewWords: [], now: later), corrections)
    }

    // MARK: - Applying plans

    func testApplyingRejectsOutOfBoundsOverlappingEmptyOrMixedSpeakerRanges() throws {
        let cases: [([TranscriptCorrection], TranscriptCorrectionsError)] = [
            ([correction(8..<10, "x")], .invalidRange),
            ([correction(3..<3, "x")], .invalidRange),
            ([correction(-1..<1, "x")], .invalidRange),
            ([correction(3..<5, "x"), correction(4..<6, "y")], .overlapping),
            ([correction(3..<6, "  \n ")], .emptyText),
            ([correction(6..<8, "daily. Okay")], .mixedSpeakers),
        ]
        for (adds, expected) in cases {
            XCTAssertThrowsError(try applied(adds), "\(adds.map(\.range))") { error in
                XCTAssertEqual(error as? TranscriptCorrectionsError, expected)
            }
        }
        // A correction that only partly overlaps a stored one is refused (the planner widens to whole tokens).
        let base = try applied([correction(3..<6, "metformin")])
        XCTAssertThrowsError(try applied([correction(5..<7, "men, daily")], to: base)) { error in
            XCTAssertEqual(error as? TranscriptCorrectionsError, .overlapping)
        }
    }

    /// App fix round 2 (N2): an undo plan is applied strictly. An add that touches any stored correction the plan does
    /// not remove is refused whole (same words, fewer words, a sub-span), so a newer correction is never overwritten.
    func testAStrictPlanRefusesToTouchACorrectionItDoesNotRemove() throws {
        let reverted = correction(3..<6, "metformin")
        for newer in [correction(3..<6, "metoprolol"), correction(3..<5, "metfor"), correction(4..<5, "four")] {
            let base = try applied([newer])
            XCTAssertThrowsError(
                try base.applying(
                    TranscriptCorrectionPlan(add: [reverted]), words: words(), now: later, strict: true),
                "\(newer.range)"
            ) { error in
                XCTAssertEqual(error as? TranscriptCorrectionsError, .overlapping)
            }
            // The same plan, also removing the newer item, applies (an undo of a correction that replaced another).
            let (result, _) = try base.applying(
                TranscriptCorrectionPlan(remove: [newer.id], add: [reverted]), words: words(), now: later,
                strict: true)
            XCTAssertEqual(result.items.map(\.id), [reverted.id])
        }
        // Words nobody corrected since: the strict plan applies.
        let (clean, _) = try TranscriptCorrections.empty.applying(
            TranscriptCorrectionPlan(add: [reverted]), words: words(), now: later, strict: true)
        XCTAssertEqual(clean.items.map(\.text), ["metformin"])
    }

    func testApplyingReplacesCoveredCorrectionsAndReturnsInverse() throws {
        let first = correction(3..<6, "metformin")
        let base = try applied([first])
        let wider = correction(2..<7, "takes metformin twice daily.")
        let (result, inverse) = try base.applying(
            TranscriptCorrectionPlan(add: [wider]), words: words(), now: later)
        XCTAssertEqual(result.items.map(\.id), [wider.id])
        XCTAssertEqual(result.items.first?.heard, "takes met for men daily.")
        XCTAssertEqual(result.items.first?.text, "takes metformin twice daily.")
        XCTAssertEqual(inverse.remove, [wider.id])
        XCTAssertEqual(inverse.add.map(\.id), [first.id])
        XCTAssertEqual(result.changedAt, later)
        XCTAssertEqual(result.baseline, TranscriptFingerprint.of(words()))
    }

    func testItemsStaySortedByStart() throws {
        let corrections = try applied([correction(7..<8, "OK"), correction(0..<1, "The")])
        XCTAssertEqual(corrections.items.map(\.range), [0..<1, 7..<8])
    }

    func testAddingTheHeardTextBackRemovesTheCorrection() throws {
        let base = try applied([correction(3..<6, "metformin")])
        let (result, inverse) = try base.applying(
            TranscriptCorrectionPlan(add: [correction(3..<6, "  met for men ")]), words: words(), now: later)
        XCTAssertEqual(result.items, [])
        XCTAssertEqual(inverse.add, base.items)
        XCTAssertEqual(inverse.remove, [])
    }

    func testInverseRestoresPreviousItemsExactly() throws {
        let base = try applied([correction(3..<6, "metformin"), correction(7..<8, "OK")])
        let plan = TranscriptCorrectionPlan(remove: [base.items[1].id], add: [correction(1..<3, "person takes")])
        let (changed, inverse) = try base.applying(plan, words: words(), now: later)
        XCTAssertNotEqual(changed.items, base.items)
        let (restored, _) = try changed.applying(inverse, words: words(), now: later)
        XCTAssertEqual(restored.items, base.items)
    }

    func testRevertAllLeavesEmptyItemsAndBumpsChangedAt() throws {
        let base = try applied([correction(3..<6, "metformin"), correction(7..<8, "OK")])
        let (result, inverse) = try base.applying(
            TranscriptCorrectionPlan(remove: Set(base.items.map(\.id))), words: words(), now: later)
        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.changedAt, later)
        XCTAssertEqual(inverse.add, base.items)
        XCTAssertNotNil(try? JSONEncoder().encode(result))
    }

    func testApplyingRefusesWhenTheWordsChangedSinceTheBaseline() throws {
        let base = try applied([correction(3..<6, "metformin")])
        var other = words()
        other[0].word = "a"
        XCTAssertThrowsError(
            try base.applying(TranscriptCorrectionPlan(add: [correction(0..<1, "The")]), words: other, now: later)
        ) { error in
            XCTAssertEqual(error as? TranscriptCorrectionsError, .baselineChanged)
        }
    }

    // MARK: - Reading

    func testValidItemsSkipItemsThatBreakTheInvariants() throws {
        var corrections = try applied([correction(3..<6, "metformin"), correction(7..<8, "OK")])
        XCTAssertEqual(corrections.validItems(in: words()).count, 2)
        // A heard text that no longer matches the words, an out-of-range item and an overlapping one are skipped.
        corrections.items[1].heard = "Okey"
        corrections.items.append(correction(8..<12, "x"))
        corrections.items.append(correction(4..<5, "y"))
        XCTAssertEqual(corrections.validItems(in: words()).map(\.range), [3..<6])
    }

    // MARK: - Pipelines (D7)

    func testPreservedKeepsItemsWhenWordsAreTheSame() throws {
        let base = try applied([correction(3..<6, "metformin")])
        var sameWithSpeakers = words()
        sameWithSpeakers[0].speakerId = "S9"
        XCTAssertEqual(base.preserved(acrossNewWords: sameWithSpeakers, now: later), base)
        XCTAssertEqual(base.preserved(acrossNewWords: [], now: later), base)
    }

    func testPreservedDetachesItemsWhenWordsChanged() throws {
        let base = try applied([correction(3..<6, "metformin")])
        var changed = words()
        changed[3].word = "metformin"
        let result = base.preserved(acrossNewWords: changed, now: later)
        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.detached, base.items)
        XCTAssertEqual(result.baseline, TranscriptFingerprint.of(changed))
        XCTAssertEqual(result.changedAt, later)
        // Detached items stay detached across a later change of words.
        let again = result.preserved(acrossNewWords: words(), now: later)
        XCTAssertEqual(again.detached, base.items)
    }

    // MARK: - Fingerprint

    func testFingerprintIsStableAndIgnoresSpeakers() {
        let first = TranscriptFingerprint.of(words())
        XCTAssertTrue(first.hasPrefix("w1:"))
        XCTAssertEqual(first.count, 3 + 64)
        var other = words()
        other = other.map { word in
            var copy = word
            copy.speakerId = nil
            copy.confidence = 0.1
            return copy
        }
        XCTAssertEqual(TranscriptFingerprint.of(other), first)
        XCTAssertEqual(TranscriptFingerprint.of(words()), first)
    }

    func testFingerprintChangesWithWordTextOrTime() {
        let base = TranscriptFingerprint.of(words())
        var text = words()
        text[2].word = "took"
        var time = words()
        time[2].endMs += 1
        XCTAssertNotEqual(TranscriptFingerprint.of(text), base)
        XCTAssertNotEqual(TranscriptFingerprint.of(time), base)
        XCTAssertNotEqual(TranscriptFingerprint.of(Array(words().dropLast())), base)
    }
}
