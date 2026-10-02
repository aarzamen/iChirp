import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 025 Step A6: the one writer of corrections. It never touches the words as heard, binds every write to the
/// words the screen loaded, recomputes the title and snippet from the corrected text, and returns an undo plan.
/// Synthetic content only.
final class TranscriptCorrectionServiceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    /// "The patient takes met for men daily. She feels well today." (one line, S1).
    private func row(
        clean: String? = nil, status: Transcription.Status = .completed, words: Bool = true,
        source: Transcription.SourceType = .file
    ) -> Transcription {
        var row = Transcription(sourceType: source, fileName: "Synthetic visit.m4a", status: status)
        let text = "The patient takes met for men daily. She feels well today."
        if words {
            row.wordTimestamps = text.split(separator: " ").enumerated().map { index, word in
                WordTimestamp(
                    word: String(word), startMs: index * 300, endMs: index * 300 + 250, confidence: 0.9,
                    speakerId: "S1")
            }
            row.transcriptSegments = FileTranscriptSegments.materialize(words: row.wordTimestamps ?? [])
        }
        row.rawTranscript = text
        row.cleanTranscript = clean
        let source = clean ?? text
        row.derivedTitle = TitleDeriver.derive(from: source) ?? ""
        row.derivedSnippet = SnippetDeriver.derive(from: source, excluding: row.derivedTitle) ?? ""
        return row
    }

    private func service(
        _ store: FakeStore, context: TranscriptTextContext = .none
    ) -> TranscriptCorrectionService {
        let now = self.now
        return TranscriptCorrectionService(store: store, context: { context }, now: { now })
    }

    private func baseline(_ row: Transcription) -> String { row.wordsFingerprint }

    // MARK: - Correct

    func testCorrectSavesSpansAndKeepsTheBaseline() async throws {
        let original = row(clean: "The patient takes met for men daily. She feels well today.")
        let store = FakeStore(rows: [original])
        let outcome = try await service(store).correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The patient takes metformin daily. She feels well today.")

        XCTAssertEqual(outcome.row.textCorrections?.items.map(\.text), ["metformin"])
        XCTAssertEqual(outcome.row.textCorrections?.items.first?.heard, "met for men")
        XCTAssertEqual(outcome.row.textCorrections?.items.first?.origin, .edit)
        XCTAssertEqual(outcome.created, outcome.row.textCorrections?.items.map(\.id))
        let stored = await store.row(original.id)
        XCTAssertEqual(stored?.rawTranscript, original.rawTranscript, "the words as heard are never rewritten")
        XCTAssertEqual(stored?.cleanTranscript, original.cleanTranscript)
        XCTAssertEqual(stored?.wordTimestamps, original.wordTimestamps)
        XCTAssertEqual(stored?.transcriptSegments, original.transcriptSegments)
        XCTAssertEqual(stored?.text(.heard).lines.first?.text, "The patient takes metformin daily. She feels well today.")
        let writes = await store.wholeRowUpdates
        XCTAssertEqual(writes, 0)
    }

    func testCorrectRecomputesTitleAndSnippet() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        XCTAssertEqual(original.derivedTitle, "The patient takes met for men daily")
        let outcome = try await service(store).correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The patient takes metformin daily. She feels well today.")
        XCTAssertEqual(outcome.row.derivedTitle, "The patient takes metformin daily")
        XCTAssertFalse(outcome.row.derivedSnippet?.contains("met for men") ?? true)
    }

    func testCleanContextIsUsedForTheDerivedTitleOfACleanRow() async throws {
        let original = row(clean: "The patient takes met for men daily. She feels well today.")
        let store = FakeStore(rows: [original])
        let context = TranscriptTextContext(customWords: [CustomWord(word: "patient", replacement: "client")])
        let outcome = try await service(store, context: context).correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The patient takes metformin daily. She feels well today.")
        XCTAssertEqual(outcome.row.derivedTitle, "The client takes metformin daily")
    }

    func testRevertAllRestoresTheOriginalTitleAndSnippet() async throws {
        for clean in [nil, "The patient takes met for men daily. She feels well today."] {
            let original = row(clean: clean)
            let store = FakeStore(rows: [original])
            let corrections = service(store)
            _ = try await corrections.correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
                text: "Our patient takes metformin daily. She feels great today.")
            let reverted = try await corrections.revertAll(original.id)
            XCTAssertEqual(reverted.row.textCorrections?.items, [])
            XCTAssertEqual(reverted.row.derivedTitle, original.derivedTitle)
            XCTAssertEqual(reverted.row.derivedSnippet, original.derivedSnippet)
            XCTAssertEqual(reverted.row.text(.heard), original.text(.heard))
            XCTAssertEqual(reverted.row.textCorrections?.changedAt, now, "changedAt is kept, not cleared")
        }
    }

    func testRevertAndUndoRoundTrip() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let corrections = service(store)
        let corrected = try await corrections.correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The patient takes metformin daily. She feels great today.")
        let items = try XCTUnwrap(corrected.row.textCorrections?.items)
        XCTAssertEqual(items.map(\.text), ["metformin", "great"])

        let reverted = try await corrections.revert(original.id, corrections: [items[0].id])
        XCTAssertEqual(reverted.row.textCorrections?.items, [items[1]])
        let undone = try await corrections.undo(original.id, plan: reverted.undo, baseline: baseline(original))
        XCTAssertEqual(undone.row.textCorrections?.items, items, "undo restores the correction exactly")
        let undoneAgain = try await corrections.undo(original.id, plan: corrected.undo, baseline: baseline(original))
        XCTAssertEqual(undoneAgain.row.textCorrections?.items, [], "undoing the first save removes both")
    }

    func testANoChangeSaveWritesNothing() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let outcome = try await service(store).correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The  patient takes met for men daily.\nShe feels well today.")
        XCTAssertNil(outcome.row.textCorrections)
        XCTAssertTrue(outcome.undo.isEmpty)
        let writes = await store.textCorrectionWrites
        XCTAssertEqual(writes, 0)
    }

    // MARK: - Refusals

    func testRefusesNotCompletedOrUntimedRows() async throws {
        let processing = row(status: .processing)
        let untimed = row(words: false)
        let store = FakeStore(rows: [processing, untimed])
        let corrections = service(store)
        await assertThrows(.notCompleted) {
            _ = try await corrections.correct(
            processing.id, line: 0, in: processing.text(.heard), baseline: self.baseline(processing), text: "x")
        }
        await assertThrows(.noWordTimings) {
            _ = try await corrections.correct(
            untimed.id, line: 0, in: untimed.text(.heard), baseline: self.baseline(untimed), text: "x")
        }
        await assertThrows(.notFound) {
            _ = try await corrections.correct(UUID(), line: 0, in: processing.text(.heard), baseline: "w1:x", text: "x")
        }
        await assertThrows(.emptyText) {
            let fresh = self.row()
            try await store.insert(fresh)
            _ = try await corrections.correct(
            fresh.id, line: 0, in: fresh.text(.heard), baseline: self.baseline(fresh), text: "  ")
        }
    }

    func testRefusesWhenWordsChangedSinceLoad() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        var other = original.wordTimestamps ?? []
        other[0].word = "A"
        await assertThrows(.transcriptChanged) {
            _ = try await self.service(store).correct(
                original.id, line: 0, in: original.text(.heard), baseline: TranscriptFingerprint.of(other),
                text: "The person takes it.")
        }
        await assertThrows(.transcriptChanged) {
            _ = try await self.service(store).correct(
            original.id, line: 7, in: original.text(.heard), baseline: self.baseline(original), text: "A line that is gone.")
        }
        let stored = await store.row(original.id)
        XCTAssertNil(stored?.textCorrections)
    }

    func testRefusesNewerSchema() async throws {
        var original = row()
        original.textCorrections = TranscriptCorrections(schema: 2, baseline: "w2:future", changedAt: now)
        let store = FakeStore(rows: [original])
        await assertThrows(.newerVersion) {
            _ = try await self.service(store).correct(
            original.id, line: 0, in: original.text(.heard), baseline: self.baseline(original), text: "The person takes it.")
        }
        await assertThrows(.newerVersion) { _ = try await self.service(store).revertAll(original.id) }
        let stored = await store.row(original.id)
        XCTAssertEqual(stored?.textCorrections, original.textCorrections)
    }

    func testTwoConcurrentCorrectionsBothSurvive() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let corrections = service(store)
        let base = baseline(original)
        // The first write parks inside the store; the second lands meanwhile, then the first plans against the
        // row as stored at its turn, so neither is lost.
        let hold = await store.holdNext([.updateTextCorrections])
        let first = Task {
            try await corrections.correct(
                original.id, line: 0, in: original.text(.heard), baseline: base,
                text: "The patient takes metformin daily. She feels well today.")
        }
        await hold.entered.wait()
        _ = try await corrections.correct(
            original.id, line: 0, in: original.text(.heard), baseline: base,
            text: "The patient takes met for men daily. She feels great today.")
        hold.release.fire()
        _ = try await first.value
        let stored = await store.row(original.id)
        XCTAssertEqual(stored?.textCorrections?.items.map(\.text), ["metformin", "great"])
    }

    /// Fix round 1 (review MINOR 1): Revert All removes the corrections stored when it writes, including one that
    /// landed after it was asked.
    func testRevertAllRemovesACorrectionThatLandedMeanwhile() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let corrections = service(store)
        let loaded = original.text(.heard)
        _ = try await corrections.correct(
            original.id, line: 0, in: loaded, baseline: baseline(original),
            text: "The patient takes metformin daily. She feels well today.")
        let hold = await store.holdNext([.updateTextCorrections])
        let revert = Task { try await corrections.revertAll(original.id) }
        await hold.entered.wait()
        _ = try await corrections.correct(
            original.id, line: 0, in: loaded, baseline: baseline(original),
            text: "The patient takes met for men daily. She feels great today.")
        hold.release.fire()
        let reverted = try await revert.value
        XCTAssertEqual(reverted.row.textCorrections?.items, [])
        XCTAssertEqual(reverted.undo.add.map(\.text).sorted(), ["great", "metformin"])
    }

    /// Fix round 1 (review MINOR 2): reverting corrections that are no longer there writes nothing, so `changedAt`
    /// (Extract fields' stale rule) does not move.
    func testRevertingCorrectionsThatAreGoneWritesNothing() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let corrections = service(store)
        let corrected = try await corrections.correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The patient takes metformin daily. She feels well today.")
        let writes = await store.textCorrectionWrites
        let outcome = try await corrections.revert(original.id, corrections: [UUID()])
        let after = await store.textCorrectionWrites
        XCTAssertEqual(after, writes)
        XCTAssertEqual(outcome.row.textCorrections, corrected.row.textCorrections)
        XCTAssertTrue(outcome.undo.isEmpty)
        // Revert All with nothing left to revert writes nothing either.
        _ = try await corrections.revertAll(original.id)
        let afterFirst = await store.textCorrectionWrites
        let again = try await corrections.revertAll(original.id)
        let afterSecond = await store.textCorrectionWrites
        XCTAssertEqual(afterSecond, afterFirst)
        XCTAssertTrue(again.undo.isEmpty)
    }

    /// App fix round 1 (M5, M4): an undo whose words were corrected again in the meantime says so in plain words; a
    /// changed transcript's message leaves "your text is still here" to the sheet, which says it once.
    func testAnUndoOverWordsCorrectedAgainSaysSo() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let corrections = service(store)
        let loaded = original.text(.heard)
        let first = try await corrections.correct(
            original.id, line: 0, in: loaded, baseline: baseline(original),
            text: "The patient takes metformin daily. She feels well today.")
        let reverted = try await corrections.revert(original.id, corrections: Set(first.created))
        _ = try await corrections.correct(
            original.id, line: 0, in: loaded, baseline: baseline(original),
            text: "The patient took metformin twice daily. She feels well today.")
        await assertThrows(.correctedAgain) {
            _ = try await corrections.undo(original.id, plan: reverted.undo, baseline: self.baseline(original))
        }
        XCTAssertEqual(
            TranscriptCorrectionError.correctedAgain.errorDescription,
            "Those words were corrected again, so this can’t be undone.")
        XCTAssertFalse(
            TranscriptCorrectionError.transcriptChanged.errorDescription?.localizedCaseInsensitiveContains(
                "still here") ?? true)
    }

    /// App fix round 2 (N2, clinical safety): revert "metformin", correct the same words again (the same span, fewer
    /// words, a sub-span), then Undo. The Undo fails with the corrected-again message and the newer correction stays.
    func testAnUndoNeverOverwritesANewerCorrectionInsideTheRevertedWords() async throws {
        let newerTexts = [
            "The patient takes metoprolol daily. She feels well today.",  // the same words, 3..<6
            "The patient takes metfor men daily. She feels well today.",  // fewer words, 3..<5
            "The patient takes met four men daily. She feels well today.",  // a sub-span, 4..<5
        ]
        for newerText in newerTexts {
            let original = row()
            let store = FakeStore(rows: [original])
            let corrections = service(store)
            let loaded = original.text(.heard)
            let first = try await corrections.correct(
                original.id, line: 0, in: loaded, baseline: baseline(original),
                text: "The patient takes metformin daily. She feels well today.")
            let reverted = try await corrections.revert(original.id, corrections: Set(first.created))
            let newer = try await corrections.correct(
                original.id, line: 0, in: loaded, baseline: baseline(original), text: newerText)
            let newerItems = try XCTUnwrap(newer.row.textCorrections?.items)
            XCTAssertEqual(newerItems.count, 1, newerText)

            await assertThrows(.correctedAgain) {
                _ = try await corrections.undo(original.id, plan: reverted.undo, baseline: self.baseline(original))
            }
            let stored = await store.row(original.id)
            XCTAssertEqual(stored?.textCorrections?.items, newerItems, "the newer correction is intact: \(newerText)")
            XCTAssertEqual(stored?.text(.heard).lines.first?.text, newerText)
        }
    }

    /// The strict undo still restores what a revert took when nothing was corrected since.
    func testAStrictUndoRestoresARevertWhenNothingChanged() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let corrections = service(store)
        let corrected = try await corrections.correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The patient takes metformin daily. She feels great today.")
        let items = try XCTUnwrap(corrected.row.textCorrections?.items)
        let reverted = try await corrections.revertAll(original.id)
        let undone = try await corrections.undo(original.id, plan: reverted.undo, baseline: baseline(original))
        XCTAssertEqual(undone.row.textCorrections?.items, items)
    }

    func testDetachedCorrectionsAreKeptUntilDeletedOnRequest() async throws {
        let original = row()
        let store = FakeStore(rows: [original])
        let corrections = service(store)
        let corrected = try await corrections.correct(
            original.id, line: 0, in: original.text(.heard), baseline: baseline(original),
            text: "The patient takes metformin daily. She feels well today.")
        let items = try XCTUnwrap(corrected.row.textCorrections?.items)
        // A re-run with other words (the newer-build Retry path) detaches them.
        var rerun = corrected.row
        rerun.wordTimestamps = Array(rerun.wordTimestamps?.prefix(4) ?? [])
        _ = try await store.savePreservingUserMetadata(rerun)
        let detached = await store.row(original.id)
        XCTAssertEqual(detached?.textCorrections?.detached, items)
        XCTAssertEqual(detached?.textCorrections?.items, [])

        let cleared = try await corrections.deleteDetached(original.id, corrections: Set(items.map(\.id)))
        XCTAssertEqual(cleared.textCorrections?.detached, [])
    }

    func testTheContextComesFromTheRulesAndSettings() async throws {
        let rules = FakeTextRulesStore()
        try await rules.save(CustomWord(word: "zarelto", replacement: "Xarelto"))
        try await rules.save(CustomWord(word: "off", replacement: "on", isEnabled: false))
        try await rules.save(CustomWord(word: "learned one", replacement: "rule", source: .learned))
        try await rules.save(TextSnippet(trigger: "my sig", expansion: "Dr. Synthetic"))
        var settings = TranscriptionSettings()
        settings.removeUmFiller = false
        let context = await TranscriptTextContext.current(
            textRules: rules, settings: InMemorySettingsStore(settings))
        XCTAssertEqual(context.customWords.map(\.word), ["zarelto"], "manual, enabled words only")
        XCTAssertEqual(context.snippets.map(\.trigger), ["my sig"])
        XCTAssertFalse(context.removeUmFiller)
    }

    // MARK: - Draft rules

    func testCannotSaveBlankOrUnchanged() {
        var draft = CorrectionDraft(original: "The patient takes met for men daily.")
        XCTAssertFalse(draft.hasChanges)
        XCTAssertFalse(draft.canSave)
        draft.text = "The patient  takes met for men\ndaily. "
        XCTAssertFalse(draft.hasChanges, "whitespace alone is no change")
        XCTAssertFalse(draft.canSave)
        draft.text = "   "
        XCTAssertTrue(draft.hasChanges)
        XCTAssertFalse(draft.canSave, "blank never saves")
        draft.text = "The patient takes metformin daily."
        XCTAssertTrue(draft.canSave)
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: TranscriptCorrectionError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TranscriptCorrectionError, expected, file: file, line: line)
        }
    }
}
