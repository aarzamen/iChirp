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

    // MARK: - Review L3 I9: abbreviations do not end a sentence

    func testScratchThatRetractsTheWholeOrderSentenceWithDosingAbbreviations() async {
        let order = await resolve("Start amoxicillin 500 mg p.o. t.i.d. Scratch that.")
        XCTAssertEqual(order.text, "", "the whole order is retracted, not just “t.i.d.”")
        let kept = await resolve(
            "Patient seen. Start amoxicillin 500 mg p.o. t.i.d. Scratch that. Recheck in two weeks.")
        XCTAssertEqual(kept.text, "Patient seen. Recheck in two weeks.")
        let doctor = await resolve("Discussed with Dr. Lee vs. watchful waiting. Scratch that.")
        XCTAssertEqual(doctor.text, "")
        let units = await resolve(
            "Metoprolol 25 mg. b.i.d. with food. Scratch that. Aspirin 81 mg q.d. New line. Done.")
        XCTAssertEqual(units.text, "Aspirin 81 mg q.d.\nDone.")
    }

    func testSentenceSplitterKeepsAbbreviations() {
        XCTAssertEqual(
            VoiceCommandResolver.sentences(in: "Start amoxicillin 500 mg p.o. t.i.d. Scratch that."),
            ["Start amoxicillin 500 mg p.o. t.i.d.", "Scratch that."])
        XCTAssertEqual(
            VoiceCommandResolver.sentences(in: "Seen by Dr. Lee today. Plan approx. two weeks, e.g. Monday."),
            ["Seen by Dr. Lee today.", "Plan approx. two weeks, e.g. Monday."])
        XCTAssertEqual(
            VoiceCommandResolver.sentences(in: "Take 5 mg. Then stop. Give 2 tabs. q.d. dosing."),
            ["Take 5 mg.", "Then stop.", "Give 2 tabs. q.d. dosing."])
    }

    // MARK: - Re-review I9-R: scratch that removes the whole order

    func testTheContinuingAbbreviationListIsNamed() {
        for abbreviation in [
            "p.o", "b.i.d", "t.i.d", "q.i.d", "q.d", "q.h.s", "p.r.n", "i.v", "i.m", "s.c", "e.g", "i.e", "mg",
        ] {
            XCTAssertTrue(VoiceCommandResolver.continuingAbbreviations.contains(abbreviation), abbreviation)
        }
    }

    func testScratchThatRemovesTheWholeOrderWhenACapitalFollowsAnAbbreviation() async {
        let caps = await resolve("Start amoxicillin 500 mg p.o. TID. Scratch that.")
        XCTAssertEqual(caps.text, "", "never “Start amoxicillin 500 mg p.o.”")
        let unit = await resolve("Start amoxicillin 500 mg. Three times daily. Scratch that.")
        XCTAssertEqual(unit.text, "", "the order split after “mg.” is still one order")
        let kept = await resolve("Patient seen. Start amoxicillin 500 mg p.o. TID. Scratch that. Recheck in two weeks.")
        XCTAssertEqual(kept.text, "Patient seen. Recheck in two weeks.")
        for abbreviation in ["p.o.", "b.i.d.", "t.i.d.", "q.i.d.", "q.d.", "q.h.s.", "p.r.n.", "i.v.", "i.m.", "s.c."] {
            let order = await resolve("Patient seen. Give drug 5 mg \(abbreviation) With food. Scratch that.")
            XCTAssertEqual(order.text, "Patient seen.", abbreviation)
        }
        let undone = await resolve("Start amoxicillin 500 mg. Three times daily. Scratch that. Undo.")
        XCTAssertEqual(undone.text, "Start amoxicillin 500 mg. Three times daily.", "undo restores the whole order")
    }

    func testTheAnswerNoIsKeptWhenTheNextOrderIsScratched() async {
        let result = await resolve("Any drug allergies? No. Start amoxicillin 500 mg p.o. TID. Scratch that.")
        XCTAssertEqual(result.text, "Any drug allergies? No.")
        let spoken = await resolve("Any drug allergies? No. Start amoxicillin 500 mg three times daily. Scratch that.")
        XCTAssertEqual(spoken.text, "Any drug allergies? No.")
        XCTAssertEqual(VoiceCommandResolver.sentences(in: "No. Scratch that."), ["No.", "Scratch that."])
        XCTAssertEqual(VoiceCommandResolver.sentences(in: "See item No. 5 below."), ["See item No. 5 below."])
        let answer = await resolve("Any drug allergies? No. Scratch that.")
        XCTAssertEqual(answer.text, "Any drug allergies?", "“No. Scratch that.” is a command again")
    }

    // MARK: - Review L3 minors 6, 7, 8

    @MainActor
    func testALiveStopIsAChipOnlyAResetClearsAPendingSendAndTheDoneLineNamesTheStub() async throws {
        var settings = StructureSettings()
        settings.voiceCommandsEnabled = true
        settings.engine = .stub
        let commands = DictationVoiceCommands(
            settings: InMemoryStructureSettingsStore(settings),
            engines: StructureEngines(needle: nil, needleAvailability: { .unavailable("x") }), pauseSeconds: 0)
        var stopped = false
        commands.onLiveStop = { stopped = true }
        commands.observeLive("Patient is well. Stop dictation")
        for _ in 0..<200 where commands.chip == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(commands.chip?.command, "stop")
        XCTAssertFalse(stopped, "the live check is chip-only: the person keeps talking, nothing is lost")

        commands.perform([.sendToSOAP], copiedText: "Synthetic.", transcriptionID: UUID())
        commands.reset()
        XCTAssertNil(commands.pendingTransform, "a new dictation never opens the previous one's send-to sheet")

        _ = await commands.applyToFinalPass("Plan as discussed. New paragraph. Recheck.")
        XCTAssertTrue(commands.appliedSummary?.contains("STUB") ?? false, commands.appliedSummary ?? "nil")
    }

    @MainActor
    func testDictationCommandWordsNeverReachAnEngineOffThePhone() async {
        var settings = StructureSettings()
        settings.voiceCommandsEnabled = true
        settings.engine = .needle
        let cloud = RecordingStructureModel(
            locality: .cloud, reply: #"[{"name":"new_paragraph","arguments":{}}]"#, confidence: 0.99)
        let commands = DictationVoiceCommands(
            settings: InMemoryStructureSettingsStore(settings),
            engines: StructureEngines(needle: cloud, needleAvailability: { .ready }))
        let result = await commands.applyToFinalPass("First. New paragraph. Second.")
        XCTAssertEqual(result.text, "First. New paragraph. Second.")
        XCTAssertEqual(cloud.callCount, 0, "review L3 minor 4: dictation routes as clinical")
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
    private var idStorage: [UUID] = []
    @MainActor var isAvailable: Bool { true }
    var texts: [String] { lock.withLock { storage } }
    var transcriptionIDs: [UUID] { lock.withLock { idStorage } }
    func readBack(_ text: String, transcriptionID: UUID) async {
        lock.withLock {
            storage.append(text)
            idStorage.append(transcriptionID)
        }
    }
}

@MainActor
final class ReadBackRelayTests: XCTestCase {
    func testUnconnectedRelayIsSilent() async {
        let relay = ReadBackRelay()
        XCTAssertFalse(relay.isAvailable)
        await relay.readBack("Synthetic sentence.", transcriptionID: UUID())
    }

    func testConnectedRelayForwardsTextAndTheDictationID() async {
        let relay = ReadBackRelay()
        let speaker = RecordingSpeaker()
        relay.connect(
            isAvailable: { true },
            speak: { text, id in await speaker.readBack(text, transcriptionID: id) })
        let id = UUID()
        XCTAssertTrue(relay.isAvailable)
        await relay.readBack("Synthetic sentence.", transcriptionID: id)
        XCTAssertEqual(speaker.texts, ["Synthetic sentence."])
        XCTAssertEqual(speaker.transcriptionIDs, [id])
    }
}
