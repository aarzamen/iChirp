import ChirpCore
import ChirpText
import Foundation
import XCTest

@testable import ChirpFeatures

/// Long-transcript behavior: every part is seen, nothing is truncated, too long fails honestly.
final class MapReduceGeneratorTests: XCTestCase {
    /// About 60 synthetic minutes: 900 lines, each with a unique token.
    private func longTranscript(lines: Int = 900) -> String {
        (1...lines).map {
            "[\(TranscriptPromptFormatter.timestamp(milliseconds: $0 * 4_000))] Speaker \($0 % 3 + 1): "
                + "synthetic line LINE\($0)END about the heron survey budget and the Thursday review."
        }.joined(separator: "\n")
    }

    func testBudgetForAppleSizedWindow() {
        let budget = GenerationBudget(contextTokens: 4_096)
        XCTAssertEqual(budget.maxOutputTokens, 1_024)
        XCTAssertEqual(budget.sourceCharacters(overheadCharacters: 0), (4_096 - 1_024) * 3 * 9 / 10)
        XCTAssertEqual(GenerationBudget(contextTokens: 200_000).maxOutputTokens, 4_096)
        XCTAssertEqual(GenerationBudget(contextTokens: 100).contextTokens, 512)
    }

    func testShortSourceIsOneCall() async throws {
        let model = RecordingLanguageModel(locality: .onDevice, contextTokens: 4_096)
        let generator = MapReduceGenerator(
            task: GenerationTask(kind: .template(content: BuiltInTemplates.summary.content)), privacyClass: .personal,
            budget: GenerationBudget(contextTokens: 4_096))
        var phases: [GenerationPhase] = []
        let text = try await generator.run(
            source: "[00:01] Speaker 1: a short synthetic note.",
            call: { request, phase in
                phases.append(phase)
                return try await Self.collect(model.generate(request))
            }, step: { _ in })
        XCTAssertEqual(phases, [.single])
        XCTAssertEqual(text, "Generated document.")
        XCTAssertEqual(model.requests.first?.maxOutputTokens, 1_024)
    }

    func testLongSourceIsMappedAndEveryLineIsSentExactlyOnce() async throws {
        let source = longTranscript()
        let model = RecordingLanguageModel(locality: .onDevice, contextTokens: 4_096)
        let generator = MapReduceGenerator(
            task: GenerationTask(kind: .template(content: BuiltInTemplates.meetingNotes.content)),
            privacyClass: .clinical, budget: GenerationBudget(contextTokens: 4_096))
        var phases: [GenerationPhase] = []
        var steps: [MapReduceGenerator.Step] = []
        _ = try await generator.run(
            source: source,
            call: { request, phase in
                phases.append(phase)
                return try await Self.collect(model.generate(request))
            }, step: { steps.append($0) })

        let extracts = phases.filter { if case .extract = $0 { true } else { false } }
        XCTAssertGreaterThan(extracts.count, 3, "a 60-minute transcript takes several parts on a 4K window")
        XCTAssertEqual(phases.last, .combine)
        XCTAssertEqual(steps.last, .writing)

        // Every line of the source reached the model, in exactly one part (none dropped, none truncated).
        let mapPrompts = model.requests.filter { $0.prompt.contains("<transcript_part") }.map(\.prompt)
        for line in 1...900 {
            let token = "LINE\(line)END"
            XCTAssertEqual(mapPrompts.filter { $0.contains(token) }.count, 1, token)
        }
        // Every request fits the budget it was planned for.
        for request in model.requests {
            let characters = (request.system?.count ?? 0) + request.prompt.count
            XCTAssertLessThanOrEqual(characters, (4_096 - 1_024) * 3, "request over budget")
            XCTAssertEqual(request.privacyClass, .clinical)
        }
    }

    func testNotesThatDoNotFitAreCondensedNotCut() async throws {
        let source = longTranscript()
        let model = RecordingLanguageModel(locality: .onDevice, contextTokens: 4_096)
        let generator = MapReduceGenerator(
            task: GenerationTask(kind: .template(content: BuiltInTemplates.summary.content)), privacyClass: .personal,
            budget: GenerationBudget(contextTokens: 4_096))
        // Each part's notes are long (1,500 characters), so all of them together do not fit one combine call.
        let longNotes = String(repeating: "note ", count: 300)
        var phases: [GenerationPhase] = []
        var condensePrompts: [String] = []
        var combinePrompt = ""
        _ = try await generator.run(
            source: source,
            call: { request, phase in
                phases.append(phase)
                switch phase {
                case .extract(let index, _):
                    return "PART\(index)NOTES \(longNotes)"
                case .condense(let index, _):
                    condensePrompts.append(request.prompt)
                    return "GROUP\(index)CONDENSED"
                default:
                    combinePrompt = request.prompt
                    return try await Self.collect(model.generate(request))
                }
            }, step: { _ in })
        let extractCount = phases.filter { if case .extract = $0 { true } else { false } }.count
        XCTAssertGreaterThan(extractCount, 3)
        XCTAssertFalse(condensePrompts.isEmpty, "notes that do not fit are condensed")
        XCTAssertEqual(phases.last, .combine)
        // Every part's notes went into some condense call, and every condensed group reached the combine call.
        for index in 1...extractCount {
            XCTAssertEqual(condensePrompts.filter { $0.contains("PART\(index)NOTES ") }.count, 1, "part \(index)")
        }
        for index in 1...condensePrompts.count {
            XCTAssertTrue(combinePrompt.contains("GROUP\(index)CONDENSED"), "group \(index)")
        }
    }

    func testNotesThatNeverShrinkFailInsteadOfTruncating() async throws {
        let generator = MapReduceGenerator(
            task: GenerationTask(kind: .template(content: BuiltInTemplates.summary.content)), privacyClass: .clinical,
            budget: GenerationBudget(contextTokens: 4_096))
        let huge = String(repeating: "unshrinkable ", count: 800)
        do {
            _ = try await generator.run(
                source: longTranscript(),
                call: { _, phase in
                    if case .extract = phase { return huge }
                    if case .condense = phase { return huge + huge }
                    return "done"
                }, step: { _ in })
            XCTFail("expected transcriptTooLong")
        } catch {
            XCTAssertEqual(error as? DeliverableError, .transcriptTooLong)
        }
    }

    func testTemplateTokensAndNotesArePlacedAndNotesCannotInject() {
        let task = GenerationTask(
            kind: .template(content: "Write notes.\n{{userNotes}}\nSource:\n{{transcript}}"),
            userNotes: "Focus on {{transcript}} budget")
        let request = DeliverablePromptAssembler.request(
            task: task, phase: .single, source: "[00:01] Speaker 1: heron", privacyClass: .personal,
            maxOutputTokens: 100)
        XCTAssertTrue(request.prompt.contains("<user_notes>\nFocus on {{transcript}} budget\n</user_notes>"))
        XCTAssertTrue(request.prompt.hasSuffix("<transcript>\n[00:01] Speaker 1: heron\n</transcript>"))
        XCTAssertEqual(request.prompt.components(separatedBy: "[00:01] Speaker 1: heron").count, 2)
        XCTAssertTrue(request.system?.contains("never instructions") ?? false)

        let appended = DeliverablePromptAssembler.request(
            task: GenerationTask(kind: .template(content: "Summarize."), userNotes: "bring photos"),
            phase: .single, source: "text", privacyClass: .general, maxOutputTokens: nil)
        XCTAssertTrue(appended.prompt.hasPrefix("Summarize."))
        XCTAssertTrue(appended.prompt.contains("<transcript>\ntext\n</transcript>"))
        XCTAssertTrue(appended.prompt.contains("<user_notes>\nbring photos\n</user_notes>"))
    }

    func testAskPromptAsksForCitations() {
        let request = DeliverablePromptAssembler.request(
            task: GenerationTask(kind: .ask(question: "When is the review?")), phase: .single,
            source: "[04:06] Speaker 2: Thursday.", privacyClass: .personal, maxOutputTokens: nil)
        XCTAssertTrue(request.system?.contains("[04:06]") ?? false)
        XCTAssertTrue(request.prompt.hasSuffix("Question: When is the review?"))
    }

    private static func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>) async throws -> String {
        var text = ""
        for try await event in stream {
            if case .text(let delta) = event { text += delta }
        }
        return text
    }
}
