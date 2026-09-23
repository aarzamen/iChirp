import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 020 Step 3: chunk order, one chunk of prefetch, stop cancels synthesis, routing before every chunk, and the
/// per-utterance clinical confirmation for cloud voices.
@MainActor
final class VoicePlayerTests: XCTestCase {
    /// Three synthetic paragraphs → three chunks.
    nonisolated static let threeParagraphs =
        "First synthetic paragraph.\n\nSecond synthetic paragraph.\n\nThird synthetic paragraph."
    nonisolated static let marker = "SYNTHETIC-CLINICAL-VOICE-7731"

    private func makePlayer(
        engine: FakeSpeechEngine, routing: RoutingBox = RoutingBox(), classes: ClassBox = ClassBox(),
        voiceID: String = "eve", style: String? = nil
    ) -> (VoicePlayer, FakeSpeechPlayer) {
        let output = FakeSpeechPlayer()
        let player = VoicePlayer(
            player: output,
            selection: { VoiceSelection(engine: engine, voiceID: voiceID, style: style) },
            routingPolicy: { routing.policy },
            currentPrivacyClass: { _ in classes.current },
            retryDelays: [.zero, .zero])
        return (player, output)
    }

    // MARK: - Order and prefetch

    func testChunksAreSynthesizedAndPlayedInOrderWithNeighbours() async {
        let engine = FakeSpeechEngine()
        let (player, output) = makePlayer(engine: engine, style: "calm")
        await player.speak(text: Self.threeParagraphs, privacyClass: .personal, source: .deliverable(id: UUID()))

        await eventually("chunk 1 queued") { output.enqueued == [0, 1] }
        XCTAssertEqual(player.state, .speaking(chunk: 1, of: 3))
        output.emit(.chunkStarted(1))
        await eventually("chunk 2 queued") { output.enqueued == [0, 1, 2] }
        XCTAssertEqual(player.state, .speaking(chunk: 2, of: 3))
        output.emit(.chunkStarted(2))
        output.emit(.finished)

        XCTAssertEqual(
            engine.texts, ["First synthetic paragraph.", "Second synthetic paragraph.", "Third synthetic paragraph."])
        let requests = engine.requests
        XCTAssertNil(requests[0].previousText)
        XCTAssertEqual(requests[0].nextText, "Second synthetic paragraph.")
        XCTAssertEqual(requests[1].previousText, "First synthetic paragraph.")
        XCTAssertEqual(requests[2].nextText, nil)
        XCTAssertEqual(requests.map(\.voiceID), ["eve", "eve", "eve"])
        XCTAssertEqual(requests.map(\.style), ["calm", "calm", "calm"])
        XCTAssertEqual(requests.map(\.privacyClass), [.personal, .personal, .personal])
        XCTAssertEqual(
            output.calls,
            [
                .begin,
                .enqueue(index: 0, pauseAfterMs: 350, isFinal: false),
                .enqueue(index: 1, pauseAfterMs: 350, isFinal: false),
                .enqueue(index: 2, pauseAfterMs: 0, isFinal: true),
                .stop,
            ])
        XCTAssertEqual(player.state, .idle)
        XCTAssertNil(player.source)
    }

    func testPrefetchesExactlyOneChunkAhead() async {
        let engine = FakeSpeechEngine(mode: .gated)
        let (player, output) = makePlayer(engine: engine)
        await player.speak(text: Self.threeParagraphs, privacyClass: .general, source: .transcript(id: UUID()))

        await eventually("chunk 0 requested") { engine.waiting == 1 }
        XCTAssertEqual(engine.requests.count, 1, "one synthesis at a time")
        XCTAssertEqual(player.state, .preparing)
        engine.releaseNext()
        await eventually("chunk 1 requested while chunk 0 plays") { engine.waiting == 1 && engine.requests.count == 2 }
        XCTAssertEqual(output.enqueued, [0])
        engine.releaseNext()
        await eventually("chunk 1 queued") { output.enqueued == [0, 1] }
        // Chunk 0 still plays: chunk 2 would be two ahead, so it waits.
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.requests.count, 2, "never more than one chunk ahead")

        output.emit(.chunkStarted(1))
        await eventually("chunk 2 requested once chunk 1 plays") { engine.requests.count == 3 }
        player.stop()
    }

    func testStopCancelsPendingSynthesisAndNothingPlaysAfterwards() async {
        let engine = FakeSpeechEngine(mode: .gated)
        let (player, output) = makePlayer(engine: engine)
        await player.speak(text: Self.threeParagraphs, privacyClass: .general, source: .transcript(id: UUID()))
        await eventually("chunk 0 requested") { engine.waiting == 1 }

        player.stop()
        await eventually("synthesis cancelled") { engine.cancelled == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(output.enqueued, [])
        XCTAssertEqual(output.calls.last, .stop)
        XCTAssertEqual(engine.requests.count, 1, "nothing else is sent after Stop")
    }

    func testANewReadingReplacesTheOldOne() async {
        let engine = FakeSpeechEngine(mode: .gated)
        let (player, _) = makePlayer(engine: engine)
        let first = UUID()
        await player.speak(text: "One.", privacyClass: .general, source: .transcript(id: first))
        await eventually { engine.waiting == 1 }
        await player.speak(text: "Two.", privacyClass: .general, source: .deliverable(id: first))
        await eventually("the first synthesis was cancelled") { engine.cancelled == 1 }
        XCTAssertTrue(player.isReading(.deliverable(id: first)))
        XCTAssertFalse(player.isReading(.transcript(id: first)))
        player.stop()
    }

    // MARK: - Routing and the clinical confirmation

    func testClinicalTextToACloudVoiceWaitsAndCancelSendsNothing() async {
        let engine = FakeSpeechEngine(name: "Grok voices", locality: .cloud, host: "api.x.ai")
        let (player, output) = makePlayer(engine: engine)
        await player.speak(
            text: "Patient note \(Self.marker).", privacyClass: .clinical, source: .deliverable(id: UUID()))

        guard case .needsConfirmation(let request) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertEqual(request.title, "Read this clinical text aloud with Grok voices?")
        XCTAssertTrue(request.message.contains("over the internet"))
        XCTAssertTrue(engine.requests.isEmpty, "nothing sent before the answer")
        XCTAssertFalse(output.calls.contains(.begin), "no audio session taken either")

        player.declinePendingSpeech()
        XCTAssertEqual(player.state, .idle)
        player.confirmPendingSpeech(requestID: request.id)  // a late tap after Cancel does nothing
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testConfirmationCoversThisReadingOnly() async {
        let engine = FakeSpeechEngine(name: "Grok voices", locality: .cloud, host: "api.x.ai")
        let (player, output) = makePlayer(engine: engine)
        let source = VoiceSource.deliverable(id: UUID())
        await player.speak(text: Self.threeParagraphs, privacyClass: .clinical, source: source)
        guard case .needsConfirmation(let request) = player.state else { return XCTFail("\(player.state)") }

        player.confirmPendingSpeech(requestID: request.id)
        await eventually("reading started") { output.enqueued == [0, 1] }
        output.emit(.chunkStarted(1))
        await eventually("every chunk of this reading goes") { engine.requests.count == 3 }
        XCTAssertEqual(engine.requests.map(\.privacyClass), [.clinical, .clinical, .clinical])
        output.emit(.chunkStarted(2))
        output.emit(.finished)

        let sent = engine.requests.count
        await player.speak(text: Self.threeParagraphs, privacyClass: .clinical, source: source)
        guard case .needsConfirmation = player.state else { return XCTFail("the next reading asks again") }
        XCTAssertEqual(engine.requests.count, sent)
        player.stop()
    }

    func testPersonalTextToACloudVoiceNeedsNoConfirmation() async {
        let engine = FakeSpeechEngine(locality: .cloud, host: "api.x.ai")
        let (player, output) = makePlayer(engine: engine)
        await player.speak(text: "Hello.", privacyClass: .personal, source: .voiceTest)
        await eventually { output.enqueued == [0] }
        XCTAssertEqual(player.state, .speaking(chunk: 1, of: 1))
        player.stop()
    }

    func testATrustedMacNeedsNoConfirmationAnUntrustedOneAsks() async {
        let engine = FakeSpeechEngine(name: "Mac companion", locality: .localNetwork, host: "studio.local")
        let routing = RoutingBox(PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["studio.local"]))
        let (player, output) = makePlayer(engine: engine, routing: routing)
        await player.speak(text: "Clinical \(Self.marker).", privacyClass: .clinical, source: .voiceTest)
        await eventually { output.enqueued == [0] }
        XCTAssertEqual(engine.requests.count, 1)
        player.stop()

        routing.policy = PrivacyRoutingPolicy()
        await player.speak(text: "Clinical \(Self.marker).", privacyClass: .clinical, source: .voiceTest)
        guard case .needsConfirmation(let request) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertTrue(request.message.contains("studio.local"))
        XCTAssertEqual(engine.requests.count, 1, "nothing more sent")
        player.stop()
    }

    func testUntrustingTheMacMidReadingStopsTheNextChunk() async {
        let engine = FakeSpeechEngine(name: "Mac companion", locality: .localNetwork, host: "studio.local")
        let routing = RoutingBox(PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["studio.local"]))
        let (player, output) = makePlayer(engine: engine, routing: routing)
        await player.speak(text: Self.threeParagraphs, privacyClass: .clinical, source: .voiceTest)
        await eventually { output.enqueued == [0, 1] }

        routing.policy = PrivacyRoutingPolicy()
        output.emit(.chunkStarted(1))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.requests.count, 2, "chunk 3 is not sent once the Mac is no longer trusted")
        // An untrusted Mac is asked about, like at the start of a reading; the audio stops meanwhile.
        guard case .needsConfirmation(let request) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertTrue(request.message.contains("studio.local"))
        XCTAssertEqual(output.calls.last, .stop)
        player.declinePendingSpeech()
        XCTAssertEqual(engine.requests.count, 2)
    }

    // MARK: - The class as stored now (review L2 C1, M8, M1)

    func testRaisingTheClassToClinicalMidReadingAsksBeforeTheNextCloudChunk() async {
        let engine = FakeSpeechEngine(name: "Grok voices", locality: .cloud, host: "api.x.ai")
        let classes = ClassBox(.personal)
        let (player, output) = makePlayer(engine: engine, classes: classes)
        await player.speak(text: Self.threeParagraphs, privacyClass: .personal, source: .transcript(id: UUID()))
        await eventually("chunk 1 plays, chunk 2 queued") { output.enqueued == [0, 1] }
        XCTAssertEqual(engine.requests.count, 2)

        classes.current = .clinical  // the owner marks the transcript clinical while it is read
        output.emit(.chunkStarted(1))
        await eventually("the question") {
            if case .needsConfirmation = player.state { return true } else { return false }
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(engine.requests.count, 2, "chunk 3 is not sent without the confirmation")
        XCTAssertEqual(output.calls.last, .stop, "the reading stops while the question is up")
        guard case .needsConfirmation(let request) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertEqual(request.title, "Read this clinical text aloud with Grok voices?")

        player.confirmPendingSpeech(requestID: request.id)
        await eventually("reading resumes") { engine.requests.count == 4 }
        XCTAssertEqual(
            Array(engine.texts.suffix(2)), ["Second synthetic paragraph.", "Third synthetic paragraph."],
            "it resumes at the chunk that was playing")
        XCTAssertEqual(engine.requests.suffix(2).map(\.privacyClass), [.clinical, .clinical])
        player.stop()
    }

    func testDecliningAfterAMidReadingRaiseSendsNothingMore() async {
        let engine = FakeSpeechEngine(name: "Mac companion", locality: .localNetwork, host: "studio.local")
        let classes = ClassBox(.personal)
        let (player, output) = makePlayer(engine: engine, classes: classes)
        await player.speak(text: Self.threeParagraphs, privacyClass: .personal, source: .document(id: UUID()))
        await eventually { output.enqueued == [0, 1] }

        classes.current = .clinical
        output.emit(.chunkStarted(1))
        await eventually("the question") {
            if case .needsConfirmation = player.state { return true } else { return false }
        }
        guard case .needsConfirmation(let request) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertTrue(request.message.contains("studio.local"), "an untrusted Mac asks too")
        player.declinePendingSpeech()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(engine.requests.count, 2)
    }

    func testRaisingTheClassMidReadingOnATrustedMacKeepsReading() async {
        let engine = FakeSpeechEngine(name: "Mac companion", locality: .localNetwork, host: "studio.local")
        let routing = RoutingBox(PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["studio.local"]))
        let classes = ClassBox(.personal)
        let (player, output) = makePlayer(engine: engine, routing: routing, classes: classes)
        await player.speak(text: Self.threeParagraphs, privacyClass: .personal, source: .transcript(id: UUID()))
        await eventually { output.enqueued == [0, 1] }
        classes.current = .clinical
        output.emit(.chunkStarted(1))
        await eventually("chunk 3 goes to the trusted Mac") { engine.requests.count == 3 }
        XCTAssertEqual(engine.requests.last?.privacyClass, .clinical)
        XCTAssertEqual(player.state, .speaking(chunk: 2, of: 3))
        player.stop()
    }

    func testTheClassAsStoredNowRoutesTheFirstChunk() async {
        // The screen passed a stale class; the store says clinical: the first chunk already asks.
        let engine = FakeSpeechEngine(name: "Grok voices", locality: .cloud, host: "api.x.ai")
        let (player, output) = makePlayer(engine: engine, classes: ClassBox(.clinical))
        await player.speak(
            text: Self.threeParagraphs, privacyClass: .personal,
            source: .askAnswer(id: UUID(), transcriptionID: UUID()))
        guard case .needsConfirmation = player.state else { return XCTFail("\(player.state)") }
        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertTrue(output.calls.isEmpty)
    }

    func testAClassLoweredMidReadingKeepsTheStricterOne() async {
        let engine = FakeSpeechEngine(name: "Mac companion", locality: .localNetwork, host: "studio.local")
        let routing = RoutingBox(PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["studio.local"]))
        let classes = ClassBox(.clinical)
        let (player, output) = makePlayer(engine: engine, routing: routing, classes: classes)
        await player.speak(text: Self.threeParagraphs, privacyClass: .clinical, source: .transcript(id: UUID()))
        await eventually { output.enqueued == [0, 1] }
        classes.current = .general
        output.emit(.chunkStarted(1))
        await eventually { engine.requests.count == 3 }
        XCTAssertEqual(engine.requests.map(\.privacyClass), [.clinical, .clinical, .clinical])
        player.stop()
    }

    func testATransientRetryIsRoutedAgainBeforeItIsSent() async {
        let engine = FakeSpeechEngine(name: "Grok voices", locality: .cloud, host: "api.x.ai")
        let classes = ClassBox(.personal)
        engine.fail(text: "Second synthetic paragraph.", with: [.connectionFailed("offline")])
        // The class rises while the failed chunk waits for its retry.
        engine.onEachCall { number in if number == 2 { classes.current = .clinical } }
        let (player, output) = makePlayer(engine: engine, classes: classes)
        await player.speak(text: Self.threeParagraphs, privacyClass: .personal, source: .transcript(id: UUID()))
        await eventually("the question") {
            if case .needsConfirmation = player.state { return true } else { return false }
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(
            engine.texts.filter { $0.hasPrefix("Second") }.count, 1, "the retry is not sent without the confirmation")
        XCTAssertEqual(output.enqueued, [0])
        player.stop()
    }

    func testReadAloudConfirmsOnlyTheRequestItShowed() async {
        let engine = FakeSpeechEngine(name: "Grok voices", locality: .cloud, host: "api.x.ai")
        let (player, _) = makePlayer(engine: engine)
        await player.speak(text: "Answer one.", privacyClass: .clinical, source: .voiceTest)
        guard case .needsConfirmation(let first) = player.state else { return XCTFail("\(player.state)") }
        // A second answer replaces the first before the owner taps Read aloud on the first question.
        await player.speak(text: "Answer two.", privacyClass: .clinical, source: .voiceTest)
        guard case .needsConfirmation(let second) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertNotEqual(first.id, second.id)

        player.confirmPendingSpeech(requestID: first.id)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(engine.requests.isEmpty, "the stale answer confirms nothing")
        XCTAssertEqual(player.state, .needsConfirmation(second))
        player.confirmPendingSpeech(requestID: second.id)
        await eventually { engine.texts == ["Answer two."] }
        player.stop()
    }

    func testVoiceSourcePrivacyReadsTheEffectiveClassAsStoredNow() async throws {
        var personal = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: .personal)
        personal.rawTranscript = "Synthetic."
        let transcripts = FakeStore(rows: [personal])
        let deliverables = FakeDeliverableStore()
        func current(_ source: VoiceSource) async -> PrivacyClass? {
            await VoiceSourcePrivacy.current(for: source, transcripts: transcripts, deliverables: deliverables)
        }
        let summary = Deliverable(
            transcriptionID: personal.id, promptID: nil, promptVersionID: nil, title: "Summary", engineID: "fake",
            provider: "Fake", model: nil, locality: .onDevice, text: "Synthetic.", privacyClass: .general)
        try await deliverables.insertDeliverable(summary)
        let transcriptClass = await current(.transcript(id: personal.id))
        XCTAssertEqual(transcriptClass, .personal)
        let summaryClass = await current(.deliverable(id: summary.id))
        XCTAssertEqual(summaryClass, .personal, "a deliverable is at least as private as its transcript")

        try await deliverables.insertDeliverable(
            Deliverable(
                transcriptionID: personal.id, promptID: nil, promptVersionID: nil, title: "SOAP note",
                engineID: "fake", provider: "Fake", model: nil, locality: .onDevice, text: "Synthetic.",
                privacyClass: .clinical))
        for source in [
            VoiceSource.transcript(id: personal.id), .document(id: personal.id), .deliverable(id: summary.id),
            .askAnswer(id: UUID(), transcriptionID: personal.id), .dictationReadBack(id: personal.id),
        ] {
            let value = await current(source)
            XCTAssertEqual(value, .clinical, "\(source)")
        }
        let testSentence = await current(.voiceTest)
        XCTAssertNil(testSentence)
        let gone = await current(.transcript(id: UUID()))
        XCTAssertNil(gone)
    }

    func testAnEmptyTextFailureOffersNoRetry() async {
        let engine = FakeSpeechEngine()
        let (player, _) = makePlayer(engine: engine)
        await player.speak(text: "  ", privacyClass: .general, source: .voiceTest)
        XCTAssertEqual(player.state, .failed("There is no text to read."))
        XCTAssertFalse(player.canRetry)
        engine.fail(text: "Hello.", with: [.unauthorized])
        await player.speak(text: "Hello.", privacyClass: .general, source: .voiceTest)
        await eventually { if case .failed = player.state { return true } else { return false } }
        XCTAssertTrue(player.canRetry)
    }

    // MARK: - Availability, failures and retry

    func testAnUnavailableVoiceSaysSoAndSendsNothing() async {
        let engine = FakeSpeechEngine()
        engine.setAvailability(.unavailable("The Mac companion is not reachable at studio.local."))
        let (player, output) = makePlayer(engine: engine)
        await player.speak(text: "Hello.", privacyClass: .general, source: .voiceTest)
        XCTAssertEqual(player.state, .failed("The Mac companion is not reachable at studio.local."))
        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertTrue(output.calls.isEmpty)
    }

    func testNoVoiceChosenFailsWithASentence() async {
        let output = FakeSpeechPlayer()
        let player = VoicePlayer(
            player: output,
            selection: { throw SpeechSynthesisError.notConfigured("choose a voice in Settings → Voices.") },
            routingPolicy: { PrivacyRoutingPolicy() },
            currentPrivacyClass: { _ in nil })
        await player.speak(text: "Hello.", privacyClass: .general, source: .voiceTest)
        XCTAssertEqual(player.state, .failed("This voice is not set up yet: choose a voice in Settings → Voices."))
    }

    func testTransientErrorsAreRetriedThenQueuedAudioFinishesBeforeTheFailureShows() async {
        let engine = FakeSpeechEngine()
        engine.fail(
            text: "Second synthetic paragraph.",
            with: [.connectionFailed("offline"), .connectionFailed("offline"), .connectionFailed("offline")])
        let (player, output) = makePlayer(engine: engine)
        await player.speak(text: Self.threeParagraphs, privacyClass: .general, source: .voiceTest)

        await eventually("three attempts at chunk 2") { engine.texts.filter { $0.hasPrefix("Second") }.count == 3 }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(player.state, .speaking(chunk: 1, of: 3), "chunk 1 keeps playing")
        output.emit(.drained)
        guard case .failed(let message) = player.state else { return XCTFail("\(player.state)") }
        XCTAssertTrue(message.contains("offline"), message)

        await player.retry()
        await eventually("retry starts at the failed chunk") {
            output.enqueued == [0, 1, 2] && engine.requests.count == 6
        }
        XCTAssertEqual(Array(engine.texts.suffix(2)), ["Second synthetic paragraph.", "Third synthetic paragraph."])
        XCTAssertEqual(output.calls.filter { $0 == .begin }.count, 2, "Retry starts a fresh reading at chunk 2")
        player.stop()
    }

    func testAKeyProblemIsNotRetried() async {
        let engine = FakeSpeechEngine()
        engine.fail(text: "Hello.", with: [.unauthorized])
        let (player, _) = makePlayer(engine: engine)
        await player.speak(text: "Hello.", privacyClass: .general, source: .voiceTest)
        await eventually { if case .failed = player.state { return true } else { return false } }
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(player.state, .failed(SpeechSynthesisError.unauthorized.errorDescription!))
    }

    func testRecordingInProgressFailsBeforeAnythingIsSent() async {
        struct Busy: LocalizedError {
            var errorDescription: String? { "Playback is paused while Parakeet is recording." }
        }
        let engine = FakeSpeechEngine()
        let (player, output) = makePlayer(engine: engine)
        output.beginError = Busy()
        await player.speak(text: "Hello.", privacyClass: .general, source: .dictationReadBack(id: nil))
        XCTAssertEqual(player.state, .failed("Playback is paused while Parakeet is recording."))
        XCTAssertTrue(engine.requests.isEmpty)
    }

    // MARK: - Transport

    func testInterruptionPausesAndResumeContinues() async {
        let engine = FakeSpeechEngine()
        let (player, output) = makePlayer(engine: engine)
        await player.speak(text: Self.threeParagraphs, privacyClass: .general, source: .voiceTest)
        await eventually { output.enqueued == [0, 1] }

        output.emit(.interrupted)
        XCTAssertEqual(player.state, .paused(chunk: 1, of: 3), "a dictation or a call pauses the reading")
        output.emit(.chunkStarted(1))
        XCTAssertEqual(player.state, .paused(chunk: 1, of: 3), "it never resumes by itself")

        player.resume()
        XCTAssertEqual(output.calls.last, .resume)
        XCTAssertEqual(player.state, .speaking(chunk: 1, of: 3))

        player.pause()
        XCTAssertEqual(output.calls.last, .pause)
        XCTAssertEqual(player.state, .paused(chunk: 1, of: 3))
        player.stop()
        XCTAssertEqual(player.state, .idle)
    }

    func testResumeWhileRecordingFailsWithASentence() async {
        struct Busy: LocalizedError {
            var errorDescription: String? { "Playback is paused while Parakeet is recording." }
        }
        let engine = FakeSpeechEngine()
        let (player, output) = makePlayer(engine: engine)
        await player.speak(text: "Hello.", privacyClass: .general, source: .voiceTest)
        await eventually { output.enqueued == [0] }
        output.emit(.interrupted)
        output.resumeError = Busy()
        player.resume()
        XCTAssertEqual(player.state, .failed("Playback is paused while Parakeet is recording."))
    }

    func testEmptyTextFailsWithoutSending() async {
        let engine = FakeSpeechEngine()
        let (player, _) = makePlayer(engine: engine)
        await player.speak(text: "   \n ", privacyClass: .general, source: .voiceTest)
        XCTAssertEqual(player.state, .failed("There is no text to read."))
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testTransientClassification() {
        XCTAssertTrue(VoicePlayer.isTransient(SpeechSynthesisError.connectionFailed("x")))
        XCTAssertTrue(VoicePlayer.isTransient(SpeechSynthesisError.rateLimited))
        XCTAssertTrue(VoicePlayer.isTransient(SpeechSynthesisError.server(status: 502, message: "")))
        XCTAssertFalse(VoicePlayer.isTransient(SpeechSynthesisError.server(status: 503, message: "not loaded")))
        XCTAssertFalse(VoicePlayer.isTransient(SpeechSynthesisError.server(status: 400, message: "")))
        XCTAssertFalse(VoicePlayer.isTransient(SpeechSynthesisError.unauthorized))
        XCTAssertFalse(VoicePlayer.isTransient(SpeechSynthesisError.privacyRefused))
    }
}

final class SpeechChunkerTests: XCTestCase {
    func testParagraphsBecomeChunksThatEndParagraphs() {
        let chunks = SpeechChunker.chunk(VoicePlayerTests.threeParagraphs)
        XCTAssertEqual(chunks.map(\.text).count, 3)
        XCTAssertTrue(chunks.allSatisfy(\.endsParagraph))
    }

    func testFirstChunkIsShortLaterOnesLongerNeverMidSentence() {
        let sentence = "This synthetic sentence has exactly enough words to be useful here."  // 68 characters
        let text = Array(repeating: sentence, count: 60).joined(separator: " ")
        let chunks = SpeechChunker.chunk(text)
        XCTAssertLessThanOrEqual(chunks[0].text.count, SpeechChunker.firstChunkLimit)
        XCTAssertTrue(chunks.dropFirst().allSatisfy { $0.text.count <= SpeechChunker.chunkLimit })
        XCTAssertTrue(chunks.allSatisfy { $0.text.hasSuffix("here.") }, "every chunk ends on a sentence")
        XCTAssertEqual(chunks.map(\.text).joined(separator: " "), text)
        XCTAssertEqual(chunks.map(\.endsParagraph), Array(repeating: false, count: chunks.count - 1) + [true])
    }

    func testHardWrappedLinesJoinAndOnlySentenceEndsBreakParagraphs() {
        let paragraphs = SpeechChunker.splitParagraphs("A wrapped line\ncontinues here.\nNext paragraph.\n\nLast one")
        XCTAssertEqual(paragraphs, ["A wrapped line continues here.", "Next paragraph.", "Last one"])
    }

    func testAnOversizedSentenceSplitsAtClausesUnderTheEngineLimit() {
        let clause = String(repeating: "word ", count: 150) + "and more,"  // ~760 characters per clause
        let sentence = Array(repeating: clause, count: 8).joined(separator: " ") + " end."
        let chunks = SpeechChunker.chunk(sentence, hardCap: 1_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 1_000 }, "\(chunks.map(\.text.count))")
    }

    func testBlankTextHasNoChunks() {
        XCTAssertTrue(SpeechChunker.chunk(" \n\n ").isEmpty)
    }
}
