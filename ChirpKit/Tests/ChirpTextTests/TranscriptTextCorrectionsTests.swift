import ChirpCore
import XCTest

@testable import ChirpText

/// Plan 025 Step A3: corrections enter the one word stream (`TranscriptTokens.of`) and every view follows; a row
/// without corrections takes the fast path and returns exactly what it returned before. Synthetic content only.
final class TranscriptTextCorrectionsTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 790_000_000)

    /// S1: "Um, the patient takes met for men daily." (0–7), S2 after a 2.6 s pause: "Recheck zarelto in two
    /// weeks." (8–13).
    private func words() -> [WordTimestamp] {
        var result: [WordTimestamp] = []
        var clock = 0
        for (index, text) in "Um, the patient takes met for men daily.".split(separator: " ").enumerated() {
            result.append(
                WordTimestamp(
                    word: String(text), startMs: clock, endMs: clock + 250, confidence: 0.8 + Double(index) / 100,
                    speakerId: "S1"))
            clock += 300
        }
        clock += 2_600
        for text in "Recheck zarelto in two weeks.".split(separator: " ") {
            result.append(
                WordTimestamp(word: String(text), startMs: clock, endMs: clock + 250, confidence: 0.9, speakerId: "S2"))
            clock += 300
        }
        return result
    }

    private func row(
        source: Transcription.SourceType = .file, clean: String? = nil, segments: [TranscriptSegmentRecord]? = nil
    ) -> Transcription {
        var row = Transcription(sourceType: source, fileName: "synthetic.m4a", status: .completed)
        let words = words()
        row.wordTimestamps = words
        row.rawTranscript = words.map(\.word).joined(separator: " ")
        row.cleanTranscript = clean
        row.speakers = [SpeakerInfo(id: "S1", label: "Dana"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.transcriptSegments = segments ?? FileTranscriptSegments.materialize(words: words, speakers: row.speakers)
        return row
    }

    private func correction(_ range: Range<Int>, _ text: String) -> TranscriptCorrection {
        TranscriptCorrection(wordRange: range, heard: "", text: text, origin: .edit, createdAt: now, updatedAt: now)
    }

    private func corrected(_ row: Transcription, _ adds: [TranscriptCorrection]) throws -> Transcription {
        var row = row
        row.textCorrections = try (row.textCorrections ?? .empty).applying(
            TranscriptCorrectionPlan(add: adds), words: row.wordTimestamps ?? [], now: now
        ).corrections
        return row
    }

    private let context = TranscriptTextContext(
        customWords: [CustomWord(word: "zarelto", replacement: "Xarelto")],
        snippets: [TextSnippet(trigger: "two weeks", expansion: "2 weeks")], removeUmFiller: true)

    private static let views: [TranscriptTextView] = [.heard, .shown(.raw), .shown(.clean)]

    // MARK: - Fast path

    func testNoCorrectionsIsTheFastPath() throws {
        let plain = row(clean: "The patient takes met for men daily. Recheck Xarelto in two weeks.")
        var emptied = try corrected(plain, [correction(4..<7, "metformin")])
        emptied.textCorrections = try emptied.textCorrections?.applying(
            TranscriptCorrectionPlan(remove: Set(emptied.textCorrections?.items.map(\.id) ?? [])),
            words: emptied.wordTimestamps ?? [], now: now
        ).corrections
        XCTAssertEqual(emptied.textCorrections?.items, [])
        for view in Self.views {
            XCTAssertEqual(emptied.text(view, context: context), plain.text(view, context: context), "\(view)")
            XCTAssertEqual(emptied.plainText(view, context: context), plain.plainText(view), "\(view)")
            XCTAssertEqual(plain.text(view, context: context), plain.text(view), "the context is not read")
        }
        XCTAssertEqual(plain.text(.heard).segments, plain.transcriptSegments)
        XCTAssertEqual(plain.text(.heard).words, plain.wordTimestamps)
        XCTAssertEqual(plain.text(.heard).edits, [])
    }

    func testRevertAllReturnsTheFastPathOutputs() throws {
        let plain = row(clean: "The patient takes met for men daily. Recheck Xarelto in two weeks.")
        let before = Self.views.map { plain.text($0, context: context) }
        var item = try corrected(plain, [correction(4..<7, "metformin"), correction(9..<10, "Xarelto")])
        XCTAssertNotEqual(Self.views.map { item.text($0, context: context) }, before)
        item.textCorrections = try item.textCorrections?.applying(
            TranscriptCorrectionPlan(remove: Set(item.textCorrections?.items.map(\.id) ?? [])),
            words: item.wordTimestamps ?? [], now: now
        ).corrections
        XCTAssertEqual(Self.views.map { item.text($0, context: context) }, before)
        XCTAssertEqual(TranscriptCueBuilder.build(from: item), TranscriptCueBuilder.build(from: plain))
    }

    // MARK: - The stream

    func testCorrectionBecomesOneTokenWithItsEnvelope() throws {
        let item = try corrected(row(), [correction(4..<7, "metformin")])
        let tokens = TranscriptTokens.of(item)
        let words = words()
        XCTAssertEqual(tokens.count, words.count - 2)
        let token = tokens[4]
        XCTAssertEqual(token.text, "metformin")
        XCTAssertEqual(token.startMs, words[4].startMs)
        XCTAssertEqual(token.endMs, words[6].endMs)
        XCTAssertEqual(token.speakerId, "S1")
        XCTAssertEqual(token.wordRange, 4..<7)
        XCTAssertEqual(token.editID, item.textCorrections?.items.first?.id)
        XCTAssertEqual(tokens[5].text, "daily.")
        XCTAssertEqual(tokens[5].wordRange, 7..<8)
        XCTAssertNil(tokens[5].editID)
        XCTAssertEqual(item.text(.heard).edits.map(\.text), ["metformin"])
        // Word timings: every other word keeps its own time and confidence; the edit has the envelope.
        let streamWords = item.text(.heard).words
        XCTAssertEqual(streamWords[4], WordTimestamp(word: "metformin", startMs: 1_200, endMs: 2_050, confidence: 1, speakerId: "S1"))
        XCTAssertEqual(streamWords[5], words[7])
    }

    func testLineBoundariesNeverMove() throws {
        let plain = row()
        // The correction adds sentence ends; the lines still break where the engine's words break them.
        let item = try corrected(plain, [correction(1..<3, "the. patient. now."), correction(9..<10, "Xarelto.")])
        let before = plain.text(.heard).lines
        let after = item.text(.heard).lines
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.wordRange), before.map(\.wordRange))
        XCTAssertEqual(after.map(\.startMs), before.map(\.startMs))
        XCTAssertEqual(after.map(\.endMs), before.map(\.endMs))
        XCTAssertEqual(after.map(\.speakerLabel), before.map(\.speakerLabel))
        XCTAssertEqual(after.map(\.tokenRange), [0..<7, 7..<12])
    }

    func testLineTextAndTokenUTF16Ranges() throws {
        let item = try corrected(row(), [correction(4..<7, "metformin 500 mg")])
        let text = item.text(.heard)
        let line = text.lines[0]
        XCTAssertEqual(line.text, "Um, the patient takes metformin 500 mg daily.")
        XCTAssertEqual(line.tokenUTF16Ranges.count, line.tokenRange.count)
        let utf16 = Array(line.text.utf16)
        for (range, token) in zip(line.tokenUTF16Ranges, text.tokens[line.tokenRange]) {
            XCTAssertEqual(String(decoding: utf16[range], as: UTF16.self), token.text)
        }
        // Clean lines are the clean text, so they carry no token map.
        let clean = try corrected(row(clean: "Patient."), [correction(4..<7, "metformin")])
        XCTAssertEqual(clean.text(.shown(.clean), context: context).lines.map(\.tokenUTF16Ranges), [[], []])
    }

    func testAParagraphFullyCoveredByAnEarlierLinesCorrectionIsLeftOut() throws {
        // A voice command that removes the S2 sentence attaches to the line before it: the S2 line has no tokens.
        var item = row(source: .dictation)
        item.speakers = nil
        item.wordTimestamps = item.wordTimestamps?.map { word in
            var copy = word
            copy.speakerId = nil
            return copy
        }
        item = try corrected(item, [correction(7..<13, "daily.")])
        let lines = item.text(.heard).lines
        XCTAssertEqual(lines.map(\.id), [0])
        XCTAssertEqual(lines.map(\.text), ["Um, the patient takes met for men daily."])
    }

    // MARK: - Segments

    func testSegmentsMergeWhenACorrectionStraddlesAndMarkIsTextEdited() throws {
        let ids = (0..<3).map { _ in UUID() }
        let words = words()
        func segment(_ index: Int, _ range: Range<Int>) -> TranscriptSegmentRecord {
            TranscriptSegmentRecord(
                id: ids[index], startMs: words[range.lowerBound].startMs, endMs: words[range.upperBound - 1].endMs,
                speakerId: words[range.lowerBound].speakerId, speakerLabel: "x",
                text: words[range].map(\.word).joined(separator: " "),
                wordRange: TranscriptSegmentWordRange(startIndex: range.lowerBound, endIndexExclusive: range.upperBound))
        }
        let stored = [segment(0, 0..<5), segment(1, 5..<8), segment(2, 8..<13)]
        let item = try corrected(row(segments: stored), [correction(4..<7, "metformin")])
        let segments = try XCTUnwrap(item.text(.heard).segments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].id, ids[0])
        XCTAssertEqual(segments[0].startMs, stored[0].startMs)
        XCTAssertEqual(segments[0].endMs, stored[1].endMs)
        XCTAssertEqual(segments[0].wordRange, TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 8))
        XCTAssertEqual(segments[0].text, "Um, the patient takes metformin daily.")
        XCTAssertEqual(segments[0].isTextEdited, true)
        XCTAssertEqual(segments[1], stored[2])
    }

    func testUncorrectedSegmentsKeepTheirIdsAndText() throws {
        let plain = row()
        let item = try corrected(plain, [correction(9..<10, "Xarelto")])
        let segments = try XCTUnwrap(item.text(.heard).segments)
        let stored = try XCTUnwrap(plain.transcriptSegments)
        XCTAssertEqual(segments.map(\.id), stored.map(\.id))
        XCTAssertEqual(segments[0], stored[0])
        XCTAssertEqual(segments[1].text, "Recheck Xarelto in two weeks.")
        XCTAssertEqual(segments[1].isTextEdited, true)
        XCTAssertNil(segments[0].isTextEdited)
    }

    func testCuesUseCorrectedWords() throws {
        let item = try corrected(row(), [correction(4..<7, "metformin")])
        let cues = TranscriptCueBuilder.build(from: item)
        let plainCues = TranscriptCueBuilder.build(from: row())
        XCTAssertEqual(cues.first?.text, "Um, the patient takes metformin daily.")
        XCTAssertEqual(cues.first?.startMs, plainCues.first?.startMs)
        XCTAssertEqual(cues.first?.endMs, plainCues.first?.endMs)
        XCTAssertEqual(Array(cues.dropFirst()), Array(plainCues.dropFirst()), "other cues keep their text and times")
    }

    func testWordsHoldNoLineBreaks() throws {
        // A voice command's paragraph break stays in the text views and never reaches a cue or a word.
        let item = try corrected(row(), [correction(7..<8, "daily.\n\nNew")])
        XCTAssertTrue(item.text(.heard).plainText.contains("daily.\n\nNew"))
        XCTAssertEqual(item.text(.heard).words[7].word, "daily. New")
        XCTAssertFalse(TranscriptCueBuilder.build(from: item).contains { $0.text.contains("\n") })
    }

    // MARK: - Shown views

    func testShownRawJoinsTokensWithUpstreamSeparators() throws {
        let item = try corrected(row(), [correction(4..<7, "metformin"), correction(7..<8, ", daily.")])
        let tokens = TranscriptTokens.of(item).map(\.text)
        let expected = FileTranscriptSegments.joinedText(tokens)
        XCTAssertEqual(item.plainText(.shown(.raw)), expected)
        XCTAssertTrue(expected.contains("takes metformin, daily. Recheck"), expected)
        XCTAssertEqual(item.text(.shown(.raw)).plainText, expected)
        XCTAssertEqual(item.plainText(.heard), expected)
    }

    func testShownCleanRunsCleanUpOverTheCorrectedStream() throws {
        // The stored clean text is not used once the stream has edits (it has no word mapping).
        let item = try corrected(row(clean: "STORED CLEAN TEXT."), [correction(4..<7, "metformin")])
        let expected = TextProcessingPipeline().process(
            text: FileTranscriptSegments.joinedText(TranscriptTokens.of(item).map(\.text)),
            customWords: context.customWords, snippets: [], removeUmFiller: true
        ).text
        XCTAssertEqual(expected, "The patient takes metformin daily. Recheck Xarelto in two weeks.")
        XCTAssertEqual(item.plainText(.shown(.clean), context: context), expected)
        let shown = item.text(.shown(.clean), context: context)
        XCTAssertEqual(shown.plainText, expected)
        XCTAssertEqual(shown.lines.map(\.text), ["The patient takes metformin daily.", "Recheck Xarelto in two weeks."])
        XCTAssertEqual(shown.lines.map(\.startMs), item.text(.heard).lines.map(\.startMs))
        // The person's filler setting is read too.
        let keepUm = TranscriptTextContext(customWords: [], snippets: [], removeUmFiller: false)
        XCTAssertTrue(item.plainText(.shown(.clean), context: keepUm).hasPrefix("Um,"))
        // Raw shows the corrected words as heard.
        XCTAssertTrue(item.plainText(.shown(.raw), context: context).hasPrefix("Um, the patient takes metformin"))
    }

    func testARowWithoutCleanTextShowsTheCorrectedWordsInClean() throws {
        // A row transcribed in Raw has no clean text: Clean shows its words, corrected, and never runs a fresh clean-up.
        let item = try corrected(row(clean: nil), [correction(4..<7, "metformin")])
        XCTAssertEqual(item.plainText(.shown(.clean), context: context), item.plainText(.shown(.raw)))
        XCTAssertTrue(item.plainText(.shown(.clean), context: context).hasPrefix("Um,"))
    }

    func testADictationRunsCleanUpWithSnippetsInBothModes() throws {
        let dictation = try corrected(row(source: .dictation, clean: "Stored."), [correction(4..<7, "metformin")])
        let expected = "The patient takes metformin daily. Recheck Xarelto in 2 weeks."
        XCTAssertEqual(dictation.plainText(.shown(.raw), context: context), expected)
        XCTAssertEqual(dictation.plainText(.shown(.clean), context: context), expected)
        // A file never expands snippets (the file pipeline passes none).
        let file = try corrected(row(source: .file, clean: "Stored."), [correction(4..<7, "metformin")])
        XCTAssertTrue(file.plainText(.shown(.clean), context: context).hasSuffix("in two weeks."))
    }

    // MARK: - What is never applied

    func testInvalidOrDetachedItemsAreNotApplied() throws {
        let plain = row()
        var item = try corrected(plain, [correction(4..<7, "metformin")])
        item.textCorrections?.detached = [correction(0..<1, "Hmm,")]
        item.textCorrections?.items[0].heard = "met four men"
        for view in Self.views {
            XCTAssertEqual(item.text(view, context: context), plain.text(view, context: context), "\(view)")
        }
        var newer = plain
        newer.textCorrections = TranscriptCorrections(schema: 2, baseline: "", changedAt: now)
        XCTAssertEqual(newer.text(.heard), plain.text(.heard))
    }

    func testUntimedRowsIgnoreCorrections() throws {
        var untimed = Transcription(sourceType: .file, fileName: "synthetic", status: .completed)
        untimed.rawTranscript = "Untimed words."
        var item = untimed
        item.textCorrections = try TranscriptCorrections.empty.applying(
            TranscriptCorrectionPlan(add: [correction(0..<1, "x")]), words: words(), now: now
        ).corrections
        for view in Self.views {
            XCTAssertEqual(item.text(view, context: context), untimed.text(view, context: context))
        }
    }

    func testHeardTextOfARangeIsTheEngineWords() throws {
        let item = try corrected(row(), [correction(4..<7, "metformin")])
        XCTAssertEqual(item.heardText(4..<7), "met for men")
        XCTAssertEqual(item.heardText(item.text(.heard).lines[0].wordRange), "Um, the patient takes met for men daily.")
    }
}
