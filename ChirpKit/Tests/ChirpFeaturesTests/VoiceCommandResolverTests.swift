import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Step 7 (plan 015): dictation voice commands, resolved deterministically on the final pass.
final class VoiceCommandResolverTests: XCTestCase {
    private func resolve(_ text: String, engine: any StructureModel = StubStructureModel()) async -> VoiceCommandResult
    {
        await VoiceCommandResolver(engine: engine, gate: StructuredResultGate()).resolve(text)
    }

    func testACommandAtTheEndApplies() async {
        let result = await resolve("Blood pressure is fine. Bullet list.")
        XCTAssertEqual(result.text, "- Blood pressure is fine.")
        XCTAssertEqual(result.applied.map(\.command), ["bullet_list"])
    }

    func testTheSameWordsMidSentenceDoNot() async {
        let text = "We will start a new paragraph in her care plan and scratch that idea later."
        let result = await resolve(text)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.applied, [])
    }

    func testLowConfidenceIsIgnored() async {
        let weak = CommandEngine(answer: "new_paragraph", confidence: 0.84)
        let result = await resolve("First. New paragraph. Second.", engine: weak)
        XCTAssertEqual(result.text, "First. New paragraph. Second.")
        XCTAssertEqual(result.ignored.map(\.command), ["new_paragraph"])
    }

    func testTheEngineMustAgreeWithTheSpokenPhrase() async {
        let disagreeing = CommandEngine(answer: "stop", confidence: 0.99)
        let result = await resolve("First. New paragraph. Second.", engine: disagreeing)
        XCTAssertEqual(result.text, "First. New paragraph. Second.")
    }

    func testEdits() async {
        let paragraph = await resolve("First point. New paragraph. Second point.")
        XCTAssertEqual(paragraph.text, "First point.\n\nSecond point.")
        let line = await resolve("Line one. New line. Line two.")
        XCTAssertEqual(line.text, "Line one.\nLine two.")
        let scratch = await resolve("Keep this. Drop this. Scratch that. Keep that.")
        XCTAssertEqual(scratch.text, "Keep this. Keep that.")
        let undoScratch = await resolve("Keep this. Keep this too. Scratch that. Undo.")
        XCTAssertEqual(undoScratch.text, "Keep this. Keep this too.")
        let undoParagraph = await resolve("One. New paragraph. Undo. Two.")
        XCTAssertEqual(undoParagraph.text, "One. Two.")
        let capital = await resolve("Start metformin. Capitalize that.")
        XCTAssertEqual(capital.text, "Start Metformin.")
        let polite = await resolve("Thanks. Okay, new paragraph please. Next.")
        XCTAssertEqual(polite.text, "Thanks.\n\nNext.")
    }

    func testActionsAreRemovedFromTheTextAndReported() async {
        let result = await resolve("Plan as discussed. Read it back. Send this to SOAP. Stop dictation.")
        XCTAssertEqual(result.text, "Plan as discussed.")
        XCTAssertEqual(result.actions, [.readBack, .sendToSOAP])
    }

    func testLiveWindowIsTheTrailingWordsAfterThePause() async {
        XCTAssertEqual(VoiceCommandResolver.trailingWindow(of: "Patient is well. New paragraph"), "New paragraph")
        XCTAssertNil(
            VoiceCommandResolver.trailingWindow(of: "one two three four five six seven eight nine"),
            "more than eight words is dictation")
        let resolver = VoiceCommandResolver(engine: StubStructureModel(), gate: StructuredResultGate())
        let chip = await resolver.liveCommand(in: "Patient is well. Scratch that")
        XCTAssertEqual(chip?.command, "scratch_that")
        let none = await resolver.liveCommand(in: "Patient said scratch that itch")
        XCTAssertNil(none)
    }

    func testSentenceSplitter() {
        XCTAssertEqual(
            VoiceCommandResolver.sentences(in: "A 2.5 mg dose. New line.\nNext? Yes!"),
            ["A 2.5 mg dose.", "New line.", "Next?", "Yes!"])
    }

    func testReadBackUsesTheSpeakerAndSendToOpensTransform() async {
        let speaker = RecordingSpeaker()
        var settings = StructureSettings()
        settings.voiceCommandsEnabled = true
        settings.engine = .stub
        let commands = await DictationVoiceCommands(
            settings: InMemoryStructureSettingsStore(settings),
            engines: StructureEngines(needle: nil, needleAvailability: { .unavailable("x") }), readBack: speaker)
        let id = UUID()
        await commands.perform([.readBack, .sendToSOAP], copiedText: "Hello.", transcriptionID: id)
        let pending = await commands.pendingTransform
        XCTAssertEqual(pending, PendingDictationTransform(transcriptionID: id, target: .soap))
        for _ in 0..<50 where speaker.texts.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(speaker.texts, ["Hello."])

        let silent = await DictationVoiceCommands(
            settings: InMemoryStructureSettingsStore(settings),
            engines: StructureEngines(needle: nil, needleAvailability: { .unavailable("x") }))
        await silent.perform([.readBack], copiedText: "Hello.", transcriptionID: id)
        let unavailable = await silent.readBackUnavailable
        XCTAssertTrue(unavailable, "no voice yet: the screen says so instead of pretending")
    }
}

/// Answers every command question with one tool at one confidence.
struct CommandEngine: StructureModel {
    let answer: String
    let confidence: Double
    let descriptor = EngineDescriptor(
        id: "fake.commands", kind: .structure, provider: "Fake", displayName: "Fake", locality: .onDevice,
        license: "Test")

    func extract(jsonSchema: String, from text: String, privacyClass: PrivacyClass) async throws -> StructuredOutput {
        StructuredOutput(json: #"[{"name":"\#(answer)","arguments":{}}]"#, confidence: confidence)
    }

    func embed(_ text: String) async throws -> [Float] { [] }
}

final class RecordingSpeaker: ReadBackSpeaking, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var isAvailable: Bool { true }
    var texts: [String] { lock.withLock { storage } }
    func readBack(_ text: String) async { lock.withLock { storage.append(text) } }
}
