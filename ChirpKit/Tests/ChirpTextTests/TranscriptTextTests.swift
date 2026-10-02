import ChirpCore
import XCTest

@testable import ChirpText

/// Plan 024 Task 8: the one accessor for the text the person sees (`Transcription.text(_:context:)`).
final class TranscriptTextTests: XCTestCase {
    private func words(_ text: String, from startMs: Int = 0, speaker: String? = nil) -> [WordTimestamp] {
        text.split(separator: " ").enumerated().map { index, word in
            WordTimestamp(
                word: String(word), startMs: startMs + index * 300, endMs: startMs + index * 300 + 250,
                confidence: 0.8, speakerId: speaker)
        }
    }

    private func row(
        _ words: [WordTimestamp], clean: String? = nil, speakers: [SpeakerInfo]? = nil,
        source: Transcription.SourceType = .file
    ) -> Transcription {
        var row = Transcription(sourceType: source, fileName: "synthetic", status: .completed)
        row.wordTimestamps = words
        row.rawTranscript = words.map(\.word).joined(separator: " ")
        row.cleanTranscript = clean
        row.speakers = speakers
        return row
    }

    func testHeardLinesAreTheScreenParagraphs() {
        let item = row(
            words("One. Two. Three. Four.", speaker: "S1") + words("Five six.", from: 10_000, speaker: "S2"),
            speakers: [SpeakerInfo(id: "S1", label: "Dana")])
        let heard = item.text(.heard)
        let paragraphs = TranscriptParagraphBuilder.build(from: item.wordTimestamps!)
        XCTAssertEqual(heard.lines.map(\.text), paragraphs.map(\.text))
        XCTAssertEqual(heard.lines.map(\.startMs), paragraphs.map(\.startMs))
        XCTAssertEqual(heard.lines.map(\.id), [0, 1, 2])
        XCTAssertEqual(heard.lines.map(\.wordRange), [0..<3, 3..<4, 4..<6])
        // S2 is not in the roster: its id is its name, as on the screen and in the exports.
        XCTAssertEqual(heard.lines.map(\.speakerLabel), ["Dana", "Dana", "S2"])
        XCTAssertTrue(heard.hasSpeakers)
        XCTAssertTrue(heard.hasWordTimings)
    }

    func testWordRangesCoverEveryWordOnceInOrder() {
        var all: [WordTimestamp] = []
        var clock = 0
        for index in 0..<400 {
            let text = index % 7 == 0 ? "end." : "w\(index)"
            clock += index % 53 == 0 ? 3_000 : 200
            all.append(
                WordTimestamp(
                    word: text, startMs: clock, endMs: clock + 150, confidence: 1,
                    speakerId: index % 90 < 45 ? "A" : "B"))
        }
        let built = TranscriptParagraphBuilder.buildWithWordRanges(from: all)
        XCTAssertEqual(built.map(\.paragraph), TranscriptParagraphBuilder.build(from: all))
        XCTAssertEqual(built.flatMap { Array($0.wordRange) }, Array(all.indices))
        for (paragraph, range) in built {
            XCTAssertEqual(paragraph.text, all[range].map(\.word).joined(separator: " "))
        }
    }

    /// Review R2-1: no roster, no names, whatever the stored segments say.
    func testWithoutARosterLinesHaveNoSpeakerName() {
        let item = row(words("Patient stable.", speaker: nil))
        XCTAssertEqual(item.text(.shown(.raw)).lines.map(\.speakerLabel), [nil])
        XCTAssertFalse(item.text(.heard).hasSpeakers)
    }

    /// Plan 025 R3: an unedited row returns exactly what Copy returned before the accessor.
    func testPlainTextIsTodaysCopyText() {
        let item = row(words("um hello there"), clean: "Hello there.")
        XCTAssertEqual(item.plainText(.shown(.raw)), "um hello there")
        XCTAssertEqual(item.plainText(.shown(.clean)), "Hello there.")
        XCTAssertEqual(item.plainText(.heard), "Hello there.")
        var blankClean = item
        blankClean.cleanTranscript = "  "
        XCTAssertEqual(blankClean.plainText(.shown(.clean)), "um hello there")
        var noRaw = item
        noRaw.rawTranscript = nil
        XCTAssertEqual(noRaw.plainText(.shown(.raw)), "Hello there.")
        for view in [TranscriptTextView.heard, .shown(.raw), .shown(.clean)] {
            XCTAssertEqual(item.text(view).plainText, item.plainText(view))
        }
    }

    /// Review R4-1: a dictation's polished text (Polish after, or Clean when it was made) is its text in either mode:
    /// its Done screen copied it.
    func testADictationShowsItsPolishedTextInRawToo() {
        let item = row(words("um zarelto 20 mg daily"), clean: "Xarelto 20 mg daily.", source: .dictation)
        XCTAssertEqual(item.plainText(.shown(.raw)), "Xarelto 20 mg daily.")
        XCTAssertEqual(item.text(.shown(.raw)).lines.map(\.text), ["Xarelto 20 mg daily."])
        XCTAssertEqual(item.text(.heard).lines.map(\.text), ["um zarelto 20 mg daily"])
        let unpolished = row(words("um zarelto 20 mg daily"), source: .dictation)
        XCTAssertEqual(unpolished.plainText(.shown(.raw)), "um zarelto 20 mg daily")
    }

    func testUntimedRowsHaveOneUntimedLineOfTheirText() {
        var item = Transcription(sourceType: .document, fileName: "Leaflet.pdf", status: .completed)
        item.rawTranscript = "Dose: 2.5 mg.\n\nTwice daily."
        let shown = item.text(.shown(.clean))
        XCTAssertFalse(shown.hasWordTimings)
        XCTAssertEqual(shown.lines.count, 1)
        XCTAssertNil(shown.lines[0].startMs)
        XCTAssertEqual(shown.lines[0].text, "Dose: 2.5 mg.\n\nTwice daily.")
        item.rawTranscript = "   "
        XCTAssertEqual(item.text(.shown(.raw)).lines, [])
    }

    func testCleanLinesCarryTheCleanTextOnTheWordsTheyCameFrom() {
        let item = row(
            words("Um, the dose is zarelto 20 mg.", speaker: "S1")
                + words("Uh, recheck in 2.5 weeks.", from: 10_000, speaker: "S2"),
            clean: "The dose is Xarelto 20 mg. recheck in 2.5 weeks.",
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Dana")])
        let clean = item.text(.shown(.clean))
        XCTAssertEqual(clean.lines.map(\.text), ["The dose is Xarelto 20 mg.", "recheck in 2.5 weeks."])
        XCTAssertEqual(clean.lines.map(\.startMs), [0, 10_000])
        XCTAssertEqual(clean.lines.map(\.speakerLabel), ["Speaker 1", "Dana"])
        XCTAssertEqual(clean.plainText, "The dose is Xarelto 20 mg. recheck in 2.5 weeks.")
    }

    /// A multi-word replacement goes with the line of the words it replaced, and a snippet's expansion with its
    /// trigger's line, even when that line starts with it.
    func testReplacementsAndExpansionsGoWithTheWordsTheyReplaced() {
        let item = row(
            words("Patient takes metro pull all.") + words("normal cardiac exam today.", from: 10_000),
            clean: "Patient takes metoprolol. Regular rate and rhythm, no murmurs today.", source: .dictation)
        let lines = item.text(.shown(.clean)).lines
        XCTAssertEqual(lines.map(\.text), ["Patient takes metoprolol.", "Regular rate and rhythm, no murmurs today."])
        XCTAssertEqual(lines.map(\.id), [0, 1])
    }

    /// A Clean line that held only fillers is left out; the other lines keep their ids (the screen's paragraph
    /// indexes).
    func testAFillerOnlyLineIsLeftOutAndIdsStayStable() {
        let item = row(
            words("First point.") + words("Um, uh.", from: 10_000) + words("Last point.", from: 20_000),
            clean: "First point. Last point.")
        let lines = item.text(.shown(.clean)).lines
        XCTAssertEqual(lines.map(\.id), [0, 2])
        XCTAssertEqual(lines.map(\.text), ["First point.", "Last point."])
    }

    /// Property: whatever the clean text, its lines hold every one of its words, in order, and nothing else; lines keep
    /// their order and ids.
    func testCleanLinesHoldEveryCleanWordInOrderProperty() {
        var seed: UInt64 = 0xC1EA_2024
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        let vocabulary = [
            "um", "uh,", "the", "dose", "2.5", "mg.", "Xarelto", "zarelto", "daily.", "BP", "120/80", "ok",
        ]
        for round in 0..<200 {
            var all: [WordTimestamp] = []
            for index in 0..<(next() % 60 + 1) {
                all.append(
                    WordTimestamp(
                        word: vocabulary[next() % vocabulary.count], startMs: index * 900, endMs: index * 900 + 300,
                        confidence: 1))
            }
            // A clean text: the words with some dropped, some changed and some added.
            var cleanWords: [String] = []
            for word in all {
                switch next() % 6 {
                case 0: continue
                case 1: cleanWords.append(word.word.uppercased())
                case 2: cleanWords += [word.word, vocabulary[next() % vocabulary.count]]
                default: cleanWords.append(word.word)
                }
            }
            if next() % 4 == 0 { cleanWords.insert("Added", at: 0) }
            let item = row(all, clean: cleanWords.isEmpty ? "x" : cleanWords.joined(separator: "  "))
            let lines = item.text(.shown(.clean)).lines
            let placed = lines.flatMap { $0.text.split(separator: " ").map(String.init) }
            XCTAssertEqual(placed, cleanWords.isEmpty ? ["x"] : cleanWords, "round \(round)")
            XCTAssertEqual(lines.map(\.id), lines.map(\.id).sorted(), "round \(round)")
        }
    }

    /// An hour of speech (about 9,000 words) with fillers removed and a custom word swapped throughout.
    func testAnHourLongCleanTextIsPlacedWhole() {
        var all: [WordTimestamp] = []
        var cleanWords: [String] = []
        for index in 0..<9_000 {
            let word = index % 37 == 0 ? "um," : (index % 101 == 0 ? "zarelto" : (index % 11 == 0 ? "done." : "word"))
            all.append(WordTimestamp(word: word, startMs: index * 400, endMs: index * 400 + 300, confidence: 1))
            if word == "um," { continue }
            cleanWords.append(word == "zarelto" ? "Xarelto" : word)
        }
        let item = row(all, clean: cleanWords.joined(separator: " "))
        let lines = item.text(.shown(.clean)).lines
        XCTAssertEqual(lines.flatMap { $0.text.split(separator: " ").map(String.init) }, cleanWords)
        XCTAssertEqual(lines.count, item.text(.heard).lines.count)
    }

    func testTokensAreTheEngineWordsOneToOne() {
        let item = row(words("Hello there.", speaker: "S1"))
        let tokens = TranscriptTokens.of(item)
        XCTAssertEqual(tokens.map(\.text), ["Hello", "there."])
        XCTAssertEqual(tokens.map(\.wordRange), [0..<1, 1..<2])
        XCTAssertEqual(tokens.map(\.editID), [nil, nil])
        XCTAssertEqual(TranscriptTokens.words(of: item), item.wordTimestamps)
        XCTAssertEqual(TranscriptTokens.of(Transcription(fileName: "x")), [])
    }
}
