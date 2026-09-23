import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// `DecisionService` with a `RecordingDecisionModel` (plan 021 Step 3): routing, the window, the recipes, the gate and
/// the ledger. Every transcript here is synthetic.
final class DecisionServiceTests: XCTestCase {
    static let marker = "SYNTHETIC-DECISION-MARKER-5512"

    private struct Harness {
        let store: FakeStore
        let ledger: FakeDeliverableStore
        let factory: RecordingDecisionFactory
        let settings: InMemoryJevSettings
        let service: DecisionService
        var engine: RecordingDecisionModel { factory.engine }
    }

    private func harness(
        rows: [Transcription],
        enabled: Bool = true,
        key: SecretValue? = SecretValue("ts-synthetic-key-0000"),
        policy: PrivacyRoutingPolicy = PrivacyRoutingPolicy()
    ) -> Harness {
        let store = FakeStore(rows: rows)
        let ledger = FakeDeliverableStore()
        let factory = RecordingDecisionFactory()
        let settings = InMemoryJevSettings(enabled: enabled, key: key)
        let service = DecisionService(
            transcripts: store, ledger: ledger, routingPolicy: { policy }, settings: settings, factory: factory)
        return Harness(store: store, ledger: ledger, factory: factory, settings: settings, service: service)
    }

    private func row(
        _ privacy: PrivacyClass = .personal,
        text: String? = nil,
        source: Transcription.SourceType = .file
    ) -> Transcription {
        var row = Transcription(
            sourceType: source, fileName: "synthetic-meeting.m4a", durationMs: 125_000, status: .completed,
            privacyClass: privacy)
        row.rawTranscript = text ?? "Speaker one says the \(Self.marker) plan ships on Friday. Speaker two agrees."
        row.speakerCount = 2
        return row
    }

    /// Sentences of synthetic text, `count` of them, each ending with a period.
    private func sentences(_ count: Int) -> String {
        (1...count).map { "Synthetic sentence number \($0) talks about the quarterly garden plan." }
            .joined(separator: " ")
    }

    // MARK: - Routing

    func testAClinicalItemIsRefusedWithARefusedRowAndNothingSent() async throws {
        let clinical = row(.clinical)
        // Even a policy that trusts the host changes nothing: decision engines never receive clinical items in v1.
        let h = harness(rows: [clinical], policy: PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["api.typesafe.ai"]))
        for recipe in DecisionRecipe.allCases {
            let outcome = try await h.service.run(recipe: recipe, transcriptionID: clinical.id)
            XCTAssertEqual(outcome, .blockedClinical)
        }
        XCTAssertEqual(h.engine.callCount, 0, "nothing reached the engine")
        let runs = await h.ledger.runs
        XCTAssertEqual(runs.count, 3)
        for run in runs {
            XCTAssertEqual(run.feature, .decision)
            XCTAssertEqual(run.status, .refused)
            XCTAssertEqual(run.engineID, "http.jev")
            XCTAssertEqual(run.locality, .cloud)
            XCTAssertEqual(run.privacyClass, .clinical)
            XCTAssertFalse(run.privacyOverride)
            XCTAssertEqual(run.callCount, 0)
            XCTAssertEqual(run.inputCharacters, 0)
            XCTAssertEqual(run.errorType, "clinical_blocked")
        }
    }

    func testGeneralAndPersonalItemsRun() async throws {
        for privacy in [PrivacyClass.general, .personal] {
            let item = row(privacy)
            let h = harness(rows: [item])
            let outcome = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
            guard case .decided(let report) = outcome else { return XCTFail("\(privacy): \(outcome)") }
            XCTAssertEqual(report.privacyClass, privacy)
            XCTAssertEqual(report.model, "jev-1.13.0")
            XCTAssertEqual(h.engine.callCount, 1)
            XCTAssertEqual(h.engine.requests.first?.privacyClass, privacy)
            let runs = await h.ledger.runs
            XCTAssertEqual(runs.map(\.status), [.succeeded])
            XCTAssertEqual(runs.first?.callCount, 1)
            XCTAssertEqual(runs.first?.latencyMs, 42)
            XCTAssertEqual(runs.first?.promptTokens, 250)
            XCTAssertEqual(runs.first?.completionTokens, 10)
            XCTAssertEqual(runs.first?.model, "jev-1.13.0")
            XCTAssertEqual(runs.first?.inputCharacters, item.displayText.count)
        }
    }

    func testTheClassAsStoredNowIsWhatRoutes() async throws {
        // The item was personal when listed and was marked clinical since: the stored class wins.
        let item = row(.personal)
        let h = harness(rows: [item])
        await h.store.setPrivacyClass(.clinical, for: item.id)
        let outcome = try await h.service.run(recipe: .templateSuggestion, transcriptionID: item.id)
        XCTAssertEqual(outcome, .blockedClinical)
        XCTAssertEqual(h.engine.callCount, 0)
    }

    func testOnlyDecisionServiceCallsDecide() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = ["ChirpKit/Sources/ChirpFeatures", "App/Sources"].map { repo.appendingPathComponent($0) }
        let direct = try NSRegularExpression(pattern: #"\.decide\("#)
        var offenders: [String] = []
        var scanned = 0
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned += 1
                guard file.lastPathComponent != "DecisionService.swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                if direct.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "the scan found the sources")
        XCTAssertEqual(offenders, [], "only DecisionService may hand transcript text to a DecisionModel")
    }

    // MARK: - Settings gates

    func testJevOffRunsNothingAndWritesNoRow() async {
        let item = row()
        let h = harness(rows: [item], enabled: false)
        do {
            _ = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
            XCTFail("expected disabled")
        } catch {
            XCTAssertEqual(error as? DecisionError, .disabled)
        }
        XCTAssertEqual(h.factory.makeCount, 0)
        let runs = await h.ledger.runs
        XCTAssertTrue(runs.isEmpty)
    }

    func testAMissingKeySendsNothingAndWritesAFailedRow() async {
        let item = row()
        let h = harness(rows: [item], key: nil)
        do {
            _ = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
            XCTFail("expected missing key")
        } catch {
            XCTAssertEqual(error as? DecisionError, .missingKey)
        }
        XCTAssertEqual(h.engine.callCount, 0)
        let runs = await h.ledger.runs
        XCTAssertEqual(runs.map(\.status), [.failed])
        XCTAssertEqual(runs.first?.errorType, "missing_key")
        XCTAssertEqual(runs.first?.callCount, 0)
    }

    // MARK: - Window

    func testTheExcerptNeverExceedsTheWindowAndEndsAtASentenceBoundary() async throws {
        let long = sentences(200)
        XCTAssertGreaterThan(long.count, 9_000)
        let item = row(text: long)
        let h = harness(rows: [item])
        _ = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
        let sent = try XCTUnwrap(h.engine.requests.first?.state.text)
        XCTAssertLessThanOrEqual(sent.count, DecisionInputWindow.limit)
        XCTAssertGreaterThan(sent.count, DecisionInputWindow.limit - 80, "cut back only to the last sentence")
        XCTAssertTrue(sent.hasSuffix("plan."), String(sent.suffix(20)))
        XCTAssertTrue(long.hasPrefix(sent))
        let runs = await h.ledger.runs
        XCTAssertEqual(runs.first?.inputCharacters, sent.count)
    }

    func testExcerptRules() {
        XCTAssertEqual(DecisionInputWindow.excerpt("  Short text.  "), "Short text.")
        // Decimal points and abbreviations without a following space are not sentence ends.
        let text = "Dose 3.5 mg was mentioned. " + String(repeating: "word ", count: 700)
        let cut = DecisionInputWindow.excerpt(text, limit: 100)
        XCTAssertLessThanOrEqual(cut.count, 100)
        XCTAssertTrue(text.hasPrefix(cut))
        // The only sentence end is early in the window: cut at a space instead of sending almost nothing.
        XCTAssertFalse(cut.hasSuffix("mentioned."), cut)
        XCTAssertFalse(cut.hasSuffix(" "))
        // A closing quote stays with its sentence.
        let quoted = "She said \u{201C}we ship Friday.\u{201D} " + String(repeating: "then more words ", count: 10)
        let quotedCut = DecisionInputWindow.excerpt(quoted, limit: 40)
        XCTAssertEqual(quotedCut, "She said \u{201C}we ship Friday.\u{201D}")
        // No space at all: a hard cut at the limit.
        XCTAssertEqual(DecisionInputWindow.excerpt(String(repeating: "x", count: 50), limit: 10).count, 10)
    }

    func testFactsAreContentFree() {
        var item = row()
        item.titleOverride = "Secret title \(Self.marker)"
        let facts = DecisionInputWindow.facts(for: item, paragraphCount: 3)
        XCTAssertEqual(
            facts, ["duration_seconds": "125", "speaker_count": "2", "paragraph_count": "3", "source": "audio"])
        XCTAssertEqual(DecisionInputWindow.source(of: row(source: .document)), "document")
        XCTAssertEqual(DecisionInputWindow.source(of: row(source: .podcast)), "link")
        XCTAssertEqual(DecisionInputWindow.source(of: row(source: .meeting)), "audio")
    }

    // MARK: - Recipes

    func testRecordingKindAndTemplateQuestions() async throws {
        let item = row()
        let h = harness(rows: [item])
        _ = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
        _ = try await h.service.run(recipe: .templateSuggestion, transcriptionID: item.id)
        let kind = try XCTUnwrap(h.engine.requests.first?.questions.first)
        XCTAssertEqual(h.engine.requests.first?.questions.count, 1)
        XCTAssertEqual(kind.id, "kind")
        XCTAssertEqual(
            Set(kind.options.keys),
            ["meeting", "dictation", "lecture_or_talk", "interview", "clinical_encounter", "other"])
        XCTAssertTrue(kind.instructions.contains("untrusted"))
        XCTAssertTrue(kind.instructions.contains("other"))
        XCTAssertEqual(h.engine.requests.first?.state.facts["source"], "audio")

        let template = try XCTUnwrap(h.engine.requests.last?.questions.first)
        XCTAssertEqual(template.id, "template")
        XCTAssertEqual(Set(template.options.keys), Set(BuiltInTemplates.all.map(\.canonicalKey)).union(["none"]))
        XCTAssertEqual(template.options.count, 10)
    }

    func testParagraphTagQuestionsCoverTheFirstTwelveParagraphs() async throws {
        // 15 short paragraphs (alternating speakers), so tagging stops at 12.
        var words: [WordTimestamp] = []
        var ms = 0
        for paragraph in 0..<15 {
            for word in "Paragraph \(paragraph + 1) says we will ship the garden plan.".split(separator: " ") {
                words.append(
                    WordTimestamp(
                        word: String(word), startMs: ms, endMs: ms + 200, confidence: 0.9,
                        speakerId: paragraph.isMultiple(of: 2) ? "S1" : "S2"))
                ms += 250
            }
        }
        var item = row()
        item.wordTimestamps = words
        let h = harness(rows: [item])
        let outcome = try await h.service.run(recipe: .paragraphTags, transcriptionID: item.id)
        let request = try XCTUnwrap(h.engine.requests.first)
        XCTAssertEqual(request.questions.map(\.id), (1...12).map { String(format: "p%02d", $0) })
        for question in request.questions {
            XCTAssertEqual(Set(question.options.keys), ["action_item", "decision", "question", "statement"])
            XCTAssertTrue(question.instructions.contains("\(question.id):"))
        }
        XCTAssertTrue(request.state.text.hasPrefix("p01: Paragraph 1 says"))
        XCTAssertFalse(request.state.text.contains("p13:"))
        XCTAssertEqual(request.state.facts["paragraph_count"], "15")
        guard case .decided(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.items.map(\.paragraphIndex), Array(0..<12))
    }

    func testLongParagraphsMeanFewerTagQuestionsUnderTheWindow() {
        let long = TranscriptParagraph(startMs: 0, endMs: 1, text: sentences(12), speakerId: nil)
        XCTAssertGreaterThan(long.text.count, 700)
        let (text, indexes) = DecisionInputWindow.paragraphExcerpt(Array(repeating: long, count: 12))
        XCTAssertLessThanOrEqual(text.count, DecisionInputWindow.limit)
        XCTAssertLessThan(indexes.count, 12)
        XCTAssertEqual(indexes, Array(0..<indexes.count))

        let huge = TranscriptParagraph(startMs: 0, endMs: 1, text: sentences(100), speakerId: nil)
        let (hugeText, hugeIndexes) = DecisionInputWindow.paragraphExcerpt([huge, huge])
        XCTAssertEqual(hugeIndexes, [0], "a first paragraph longer than the window is cut, not dropped")
        XCTAssertLessThanOrEqual(hugeText.count, DecisionInputWindow.limit)
        XCTAssertTrue(hugeText.hasPrefix("p01: ") && hugeText.hasSuffix("."))
    }

    // MARK: - Gate and report

    func testGateVerdictsAtTheBoundaries() {
        XCTAssertEqual(DecisionGate.verdict(for: 0.79), .suggest)
        XCTAssertEqual(DecisionGate.verdict(for: 0.80), .act)
        XCTAssertEqual(DecisionGate.verdict(for: 0.54), .unsure)
        XCTAssertEqual(DecisionGate.verdict(for: 0.55), .suggest)
        XCTAssertEqual(DecisionGate.verdict(for: .nan), .unsure)
    }

    func testConsequencesAreSuggestionsGatedByConfidence() async throws {
        let item = row()
        let h = harness(rows: [item])

        h.engine.script { $0.choices = ["kind": "clinical_encounter"]; $0.confidence = 0.6 }
        guard case .decided(let likely) = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
        else { return XCTFail("expected a decision") }
        XCTAssertEqual(likely.items.first?.verdict, .suggest)
        XCTAssertEqual(likely.items.first?.choiceTitle, "Clinical encounter")
        XCTAssertTrue(likely.suggestsMarkingClinical)
        XCTAssertEqual(likely.items.first?.options.first?.id, "clinical_encounter", "most likely first")
        XCTAssertEqual(likely.items.first?.options.count, 6)

        h.engine.script { $0.confidence = 0.5 }
        guard case .decided(let unsure) = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
        else { return XCTFail("expected a decision") }
        XCTAssertFalse(unsure.suggestsMarkingClinical, "an unsure answer suggests nothing")

        h.engine.script { $0.choices = ["template": "soap-note"]; $0.confidence = 0.9 }
        guard case .decided(let template) = try await h.service.run(recipe: .templateSuggestion, transcriptionID: item.id)
        else { return XCTFail("expected a decision") }
        XCTAssertEqual(template.suggestedTemplateKey, "soap-note")
        h.engine.script { $0.choices = ["template": "none"] }
        guard case .decided(let none) = try await h.service.run(recipe: .templateSuggestion, transcriptionID: item.id)
        else { return XCTFail("expected a decision") }
        XCTAssertNil(none.suggestedTemplateKey)
    }

    // MARK: - Ledger

    func testEveryRunWritesExactlyOneContentFreeLedgerRow() async throws {
        let item = row()
        let clinical = row(.clinical)
        let h = harness(rows: [item, clinical])
        _ = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
        _ = try await h.service.run(recipe: .paragraphTags, transcriptionID: item.id)
        _ = try await h.service.run(recipe: .templateSuggestion, transcriptionID: clinical.id)
        h.engine.script { $0.error = LanguageModelError.providerError("echo \(Self.marker)") }
        _ = try? await h.service.run(recipe: .recordingKind, transcriptionID: item.id)

        let runs = await h.ledger.runs
        XCTAssertEqual(runs.map(\.status), [.succeeded, .succeeded, .refused, .failed])
        XCTAssertEqual(Set(runs.map(\.id)).count, 4)
        for run in runs {
            XCTAssertEqual(run.feature, .decision)
            XCTAssertNil(run.outputCharacters)
            XCTAssertNil(run.deliverableID)
            XCTAssertNil(run.promptVersionID)
            for field in stringFields(of: run) {
                XCTAssertFalse(field.contains(Self.marker), "content in the ledger: \(field)")
                XCTAssertFalse(field.contains("Speaker one"), "content in the ledger: \(field)")
            }
        }
    }

    func testAThrownLanguageModelErrorWritesAFailedRowWithItsKindName() async {
        let item = row()
        let h = harness(rows: [item])
        h.engine.script { $0.error = LanguageModelError.rateLimited }
        do {
            _ = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
            XCTFail("expected the engine's error")
        } catch {
            XCTAssertEqual(error as? LanguageModelError, .rateLimited)
        }
        let runs = await h.ledger.runs
        XCTAssertEqual(runs.map(\.status), [.failed])
        XCTAssertEqual(runs.first?.errorType, "rate_limited")
        XCTAssertEqual(runs.first?.callCount, 1)
    }

    func testCancellationWritesACancelledRow() async {
        let item = row()
        let h = harness(rows: [item])
        h.engine.script { $0.error = CancellationError() }
        _ = try? await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
        let runs = await h.ledger.runs
        XCTAssertEqual(runs.map(\.status), [.cancelled])
        XCTAssertNil(runs.first?.errorType)
    }

    func testAnEmptyTranscriptSendsNothing() async {
        let item = row(text: "   ")
        let h = harness(rows: [item])
        do {
            _ = try await h.service.run(recipe: .recordingKind, transcriptionID: item.id)
            XCTFail("expected empty")
        } catch {
            XCTAssertEqual(error as? DecisionError, .emptyTranscript)
        }
        XCTAssertEqual(h.engine.callCount, 0)
        let runs = await h.ledger.runs
        XCTAssertEqual(runs.first?.errorType, "empty_transcript")
    }
}
