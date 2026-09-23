import ChirpCore
import Foundation
import Synchronization
import XCTest

@testable import ChirpFeatures

/// Plan 022 Step 5: voice messages. Chunks are synthesized in order, joined into one `media/<id>/voice-<n>.m4a`,
/// progress is real, and routing is `VoicePlayer`'s (before every chunk, the class as stored then, the dialog asks).
@MainActor
final class VoiceMessageExporterTests: XCTestCase {
    static let marker = "SYNTHETIC-PLOVER-5521"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VoiceMessageExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var paths: AppPaths { AppPaths(root: root.appendingPathComponent("library", isDirectory: true)) }
    private var temporaryRoot: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    private func makeExporter(
        engine: FakeSpeechEngine,
        writer: FakeVoiceMessageWriter = FakeVoiceMessageWriter(),
        routing: RoutingBox = RoutingBox(),
        stored: ClassBox = ClassBox()
    ) -> VoiceMessageExporter {
        VoiceMessageExporter(
            selection: { VoiceSelection(engine: engine, voiceID: "synthetic-voice") },
            routingPolicy: { routing.policy },
            currentPrivacyClass: { _ in stored.current },
            writer: writer, paths: paths, temporaryRoot: temporaryRoot, retryDelays: [])
    }

    /// Three paragraphs that split into several chunks at 120 characters per request.
    private static let longText = """
        First synthetic paragraph \(marker) talks about the synthetic schedule for the week. It keeps going a little.

        Second synthetic paragraph about the synthetic budget review. It also carries on for another sentence or two.

        Third synthetic paragraph ends the voice message.
        """

    private func request(_ privacyClass: PrivacyClass = .personal, itemID: UUID = UUID()) -> VoiceMessageRequest {
        VoiceMessageRequest(
            text: Self.longText, privacyClass: privacyClass, source: .transcript(id: itemID), itemID: itemID,
            title: "Synthetic")
    }

    // MARK: - Order, assembly, progress

    func testChunksAreSpokenInOrderAndJoinedIntoOneFile() async throws {
        let engine = FakeSpeechEngine(locality: .onDevice, host: nil, maxCharacters: 120)
        let writer = FakeVoiceMessageWriter()
        let exporter = makeExporter(engine: engine, writer: writer)
        let progress = PhaseRecorder()
        engine.onEachCall { _ in
            Task { @MainActor in progress.append(exporter.phase) }
        }
        let item = UUID()
        await exporter.start(request(itemID: item))

        guard case .finished(let file) = exporter.phase else { return XCTFail("\(exporter.phase)") }
        let chunks = SpeechChunker.chunk(Self.longText, hardCap: 120)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(engine.texts, chunks.map(\.text), "every chunk once, in order")
        XCTAssertEqual(file.chunkCount, chunks.count)
        XCTAssertEqual(file.url.lastPathComponent, "voice-1.m4a")
        XCTAssertEqual(file.relativePath, "media/\(item.uuidString)/voice-1.m4a")
        let joined = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertEqual(joined, FakeVoiceMessageWriter.expected(chunks: chunks))
        XCTAssertEqual(file.durationMs, chunks.count * 1_000)

        await eventually("progress recorded") { progress.phases.count == chunks.count }
        XCTAssertEqual(
            progress.phases, (0..<chunks.count).map { .synthesizing(done: $0, total: chunks.count) },
            "progress counts real chunks")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "the temporary chunks are removed")
    }

    func testTheNextMessageForTheSameItemGetsTheNextNumber() async throws {
        let engine = FakeSpeechEngine(locality: .onDevice, host: nil)
        let exporter = makeExporter(engine: engine)
        let item = UUID()
        await exporter.start(request(itemID: item))
        await exporter.start(request(itemID: item))
        guard case .finished(let second) = exporter.phase else { return XCTFail("\(exporter.phase)") }
        XCTAssertEqual(second.url.lastPathComponent, "voice-2.m4a")
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.mediaDirectory(for: item).path).sorted()
        XCTAssertEqual(names, ["voice-1.m4a", "voice-2.m4a"], "nothing is overwritten")
    }

    func testAWriterFailureLeavesNoFile() async throws {
        let engine = FakeSpeechEngine(locality: .onDevice, host: nil)
        let writer = FakeVoiceMessageWriter()
        writer.failure = FakeError(message: "The voice message could not be saved: disk full.")
        let exporter = makeExporter(engine: engine, writer: writer)
        let item = UUID()
        await exporter.start(request(itemID: item))
        XCTAssertEqual(exporter.phase, .failed("The voice message could not be saved: disk full."))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.mediaDirectory(for: item).path)) ?? []
        XCTAssertTrue(names.isEmpty)

        writer.failure = nil
        await exporter.retry()
        guard case .finished = exporter.phase else { return XCTFail("\(exporter.phase)") }
        XCTAssertEqual(engine.requests.count, SpeechChunker.chunk(Self.longText).count, "no chunk is spoken twice")
    }

    func testAChunkFailureRetriesFromThatChunk() async throws {
        let engine = FakeSpeechEngine(locality: .onDevice, host: nil, maxCharacters: 120)
        let chunks = SpeechChunker.chunk(Self.longText, hardCap: 120)
        engine.fail(text: chunks[1].text, with: [.unauthorized])
        let exporter = makeExporter(engine: engine)
        await exporter.start(request())
        XCTAssertEqual(exporter.phase, .failed(SpeechSynthesisError.unauthorized.errorDescription ?? ""))
        XCTAssertEqual(engine.texts, [chunks[0].text, chunks[1].text])

        await exporter.retry()
        guard case .finished = exporter.phase else { return XCTFail("\(exporter.phase)") }
        XCTAssertEqual(engine.texts, [chunks[0].text, chunks[1].text] + chunks.dropFirst().map(\.text))
    }

    func testTransientErrorsAreRetriedWithinTheChunk() async throws {
        let engine = FakeSpeechEngine(locality: .onDevice, host: nil)
        let text = SpeechChunker.chunk(Self.longText)[0].text
        engine.fail(text: text, with: [.connectionFailed("synthetic")])
        let exporter = VoiceMessageExporter(
            selection: { VoiceSelection(engine: engine, voiceID: "v") }, routingPolicy: { PrivacyRoutingPolicy() },
            currentPrivacyClass: { _ in nil }, writer: FakeVoiceMessageWriter(), paths: paths,
            temporaryRoot: temporaryRoot, retryDelays: [.milliseconds(1)])
        await exporter.start(request())
        guard case .finished = exporter.phase else { return XCTFail("\(exporter.phase)") }
    }

    func testAnUnavailableVoiceSaysWhyAndSendsNothing() async {
        let engine = FakeSpeechEngine()
        engine.setAvailability(.unavailable("The Mac companion is not reachable on this network."))
        let exporter = makeExporter(engine: engine)
        await exporter.start(request())
        XCTAssertEqual(exporter.phase, .failed("The Mac companion is not reachable on this network."))
        XCTAssertTrue(engine.requests.isEmpty)
    }

    // MARK: - Routing

    func testClinicalTextToACloudVoiceWaitsForTheDialog() async throws {
        let engine = FakeSpeechEngine(locality: .cloud, host: "voices.example.com")
        let exporter = makeExporter(engine: engine)
        var answered = 0
        exporter.onAnswered = { answered += 1 }
        await exporter.start(request(.clinical))
        guard case .needsConfirmation(let question) = exporter.phase else { return XCTFail("\(exporter.phase)") }
        XCTAssertTrue(engine.requests.isEmpty, "nothing is sent before the answer")
        XCTAssertEqual(question.title, "Read this clinical text aloud with Fake Voice?")

        exporter.declinePendingSynthesis()
        XCTAssertEqual(exporter.phase, .idle)
        XCTAssertEqual(answered, 1)
        XCTAssertTrue(engine.requests.isEmpty, "Cancel sends nothing")

        await exporter.start(request(.clinical))
        guard case .needsConfirmation(let again) = exporter.phase else { return XCTFail("asks again") }
        exporter.confirmPendingSynthesis(requestID: UUID())
        XCTAssertEqual(exporter.phase, .needsConfirmation(again), "a stale answer confirms nothing")
        exporter.confirmPendingSynthesis(requestID: again.id)
        await eventually("finished") {
            if case .finished = exporter.phase { return true }
            return false
        }
        XCTAssertEqual(answered, 2)
        XCTAssertTrue(engine.requests.allSatisfy { $0.privacyClass == .clinical })
        XCTAssertTrue(engine.texts.joined().contains(Self.marker))
    }

    func testAClassRaisedMidwayStopsBeforeTheNextChunk() async throws {
        let engine = FakeSpeechEngine(locality: .cloud, host: "voices.example.com", maxCharacters: 120)
        let stored = ClassBox(.personal)
        engine.onEachCall { number in
            if number == 1 { stored.current = .clinical }  // marked clinical while the first chunk is spoken
        }
        let exporter = makeExporter(engine: engine, stored: stored)
        await exporter.start(request(.personal))
        guard case .needsConfirmation(let question) = exporter.phase else { return XCTFail("\(exporter.phase)") }
        XCTAssertEqual(engine.requests.count, 1, "the next chunk waits for the answer")

        exporter.confirmPendingSynthesis(requestID: question.id)
        await eventually("finished") {
            if case .finished = exporter.phase { return true }
            return false
        }
        let chunks = SpeechChunker.chunk(Self.longText, hardCap: 120)
        XCTAssertEqual(engine.texts, chunks.map(\.text), "no chunk twice, none skipped")
        XCTAssertEqual(
            engine.requests.dropFirst().map(\.privacyClass), Array(repeating: .clinical, count: chunks.count - 1))
    }

    func testATrustedMacTakesClinicalTextWithoutAsking() async throws {
        let engine = FakeSpeechEngine(locality: .localNetwork, host: "studio.local")
        let exporter = makeExporter(
            engine: engine,
            routing: RoutingBox(PrivacyRoutingPolicy(trustedLocalNetworkHosts: ["studio.local"])))
        await exporter.start(request(.clinical))
        guard case .finished = exporter.phase else { return XCTFail("\(exporter.phase)") }
    }

    func testCancelStopsAndKeepsNoFile() async throws {
        let engine = FakeSpeechEngine(locality: .onDevice, host: nil, mode: .gated)
        let exporter = makeExporter(engine: engine)
        let item = UUID()
        let running = Task { @MainActor in await exporter.start(request(itemID: item)) }
        await eventually("the first chunk is being spoken") { engine.waiting == 1 }
        exporter.cancel()
        await running.value
        XCTAssertEqual(exporter.phase, .idle)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.mediaDirectory(for: item).path)) ?? []
        XCTAssertTrue(names.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testStaleWorkFoldersAreSweptAtLaunch() throws {
        let stale = temporaryRoot.appendingPathComponent("voice-message-old", isDirectory: true)
        let other = temporaryRoot.appendingPathComponent("speech-keep", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(VoiceMessageExporter.sweepStaleWork(in: temporaryRoot), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}

/// Phases seen by the fake engine, in call order.
final class PhaseRecorder: Sendable {
    private let state = Mutex<[VoiceMessagePhase]>([])
    var phases: [VoiceMessagePhase] { state.withLock { $0 } }
    func append(_ phase: VoiceMessagePhase) { state.withLock { $0.append(phase) } }
}

/// Joins the chunk files' bytes in order, with a marker for each pause, and reports one second per chunk.
final class FakeVoiceMessageWriter: VoiceMessageWriting, Sendable {
    private let state = Mutex<Error?>(nil)

    var failure: Error? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    @MainActor static func expected(chunks: [SpeechTextChunk]) -> String {
        chunks.enumerated().map { index, chunk in
            let pause = chunk.endsParagraph && index < chunks.count - 1 ? VoicePlayer.paragraphPauseMs : 0
            return "\(chunk.text)|pause:\(pause)|"
        }.joined()
    }

    func writeVoiceMessage(chunks: [URL], pausesAfterMs: [Int], to url: URL) async throws -> Int {
        if let failure { throw failure }
        var joined = ""
        for (index, chunk) in chunks.enumerated() {
            joined += try String(contentsOf: chunk, encoding: .utf8)
            joined += "|pause:\(pausesAfterMs[index])|"
        }
        try joined.write(to: url, atomically: true, encoding: .utf8)
        return chunks.count * 1_000
    }
}
