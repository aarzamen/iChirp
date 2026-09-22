import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// `ParakeetEngine` gives every transcription its own `AsrManager`. A FluidAudio manager has exactly one stored
/// progress stream, and two tasks iterating it trap with "attempt to await next() on more than one task". The fake
/// worker here keeps that single-stream shape, so sharing a worker would crash or leak progress.
final class ParakeetWorkerPoolTests: XCTestCase {
    private struct InferenceFailure: Error {}

    private actor FakeWorker: ParakeetWorker {
        nonisolated let id: Int
        private let rendezvous: Rendezvous
        private let hold: Latch?
        private let events: LockedLog<String>
        private let fails: Bool
        private(set) var streamRequests = 0
        private var stream: AsyncThrowingStream<Double, any Error>?
        private var continuation: AsyncThrowingStream<Double, any Error>.Continuation?

        init(id: Int, rendezvous: Rendezvous, hold: Latch?, events: LockedLog<String>, fails: Bool) {
            self.id = id
            self.rendezvous = rendezvous
            self.hold = hold
            self.events = events
            self.fails = fails
        }

        static func marker(_ id: Int) -> Double { Double(id) / 10 }

        /// Like FluidAudio's `ProgressEmitter.ensureSession()`: one stored stream until the session finishes.
        var transcriptionProgressStream: AsyncThrowingStream<Double, any Error> {
            get async {
                streamRequests += 1
                if let stream { return stream }
                let (newStream, newContinuation) = AsyncThrowingStream<Double, any Error>.makeStream()
                stream = newStream
                continuation = newContinuation
                return newStream
            }
        }

        func transcribe(
            _ url: URL, decoderState: inout TdtDecoderState, language: Language?
        ) async throws -> ASRResult {
            events.append("transcribe-\(id)")
            continuation?.yield(Self.marker(id))
            await rendezvous.arrive()
            if let hold { await hold.wait() }
            if fails {
                // Like a CoreML or decoder error part-way through: the manager's state is now unknown.
                events.append("throw-\(id)")
                throw InferenceFailure()
            }
            continuation?.finish()
            continuation = nil
            stream = nil
            return ASRResult(
                text: "worker \(id)", confidence: 1, duration: 16, processingTime: 0.01,
                tokenTimings: [
                    TokenTiming(token: "▁worker", tokenId: 1, startTime: 0, endTime: 0.5, confidence: 1),
                    TokenTiming(token: "▁\(id)", tokenId: 2, startTime: 0.5, endTime: 1, confidence: 1),
                ])
        }

        func cleanup() {
            events.append("cleanup-\(id)")
        }
    }

    /// Fake FluidAudio wiring: models "exist" until removed, and every new worker is recorded.
    private final class FakeParakeet: @unchecked Sendable {
        // @unchecked Sendable: mutable state is only touched while `lock` is held.
        private let lock = NSLock()
        private var made: [FakeWorker] = []
        private var present = true
        let events = LockedLog<String>()
        let rendezvous: Rendezvous
        let hold: Latch?
        /// Workers (by 1-based creation order) whose transcription throws.
        let failingWorkers: Set<Int>

        init(partyCount: Int, hold: Latch? = nil, failingWorkers: Set<Int> = []) {
            rendezvous = Rendezvous(partyCount: partyCount)
            self.hold = hold
            self.failingWorkers = failingWorkers
        }

        var workers: [FakeWorker] {
            lock.lock()
            defer { lock.unlock() }
            return made
        }

        func setPresent(_ value: Bool) {
            lock.lock()
            present = value
            lock.unlock()
        }

        private var isPresent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return present
        }

        private func makeWorker() -> FakeWorker {
            lock.lock()
            defer { lock.unlock() }
            let id = made.count + 1
            let worker = FakeWorker(
                id: id, rendezvous: rendezvous, hold: hold, events: events, fails: failingWorkers.contains(id))
            made.append(worker)
            return worker
        }

        func engine(in root: URL) -> ParakeetEngine {
            let hooks = ModelAssetLifecycle<ParakeetRuntime>.Hooks(
                engineID: ParakeetEngine.engineID,
                displayName: "Fake Parakeet",
                modelsPresent: { self.isPresent },
                bytesOnDisk: { 0 },
                download: { _ in self.setPresent(true) },
                load: { ParakeetRuntime(decoderLayerCount: 2, makeWorker: { self.makeWorker() }) },
                remove: {
                    self.events.append("remove")
                    self.setPresent(false)
                }
            )
            // A pass-through gate, so both jobs can be inside inference at the same time.
            return ParakeetEngine(
                variant: .v3, modelsRoot: root, gate: ANEInferenceGate(serializationRequired: false), hooks: hooks,
                network: .testing())
        }
    }

    private func workerID(of result: SpeechResult) throws -> Int {
        try XCTUnwrap(result.text.split(separator: " ").last.flatMap { Int($0) })
    }

    func testConcurrentTranscriptionsGetTheirOwnWorkerAndProgressStream() async throws {
        let root = try makeScratchDirectory("ichirp-pool")
        // Longer than one 15 s window, so every call opens its worker's progress stream.
        let audio = try writeSilentWAV(seconds: 16, in: root)
        let fake = FakeParakeet(partyCount: 2)
        let engine = fake.engine(in: root)
        let logA = LockedLog<Double>()
        let logB = LockedLog<Double>()

        async let first = engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { logA.append($0) }
        async let second = engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { logB.append($0) }
        let results = try await [first, second]

        let ids = try results.map(workerID(of:))
        XCTAssertEqual(Set(ids), [1, 2], "two concurrent jobs must run on two different AsrManagers")
        XCTAssertEqual(fake.workers.count, 2)
        for worker in fake.workers {
            let requests = await worker.streamRequests
            XCTAssertEqual(requests, 1, "each worker's progress stream has exactly one subscriber")
        }
        for (id, log) in zip(ids, [logA, logB]) {
            let values = log.values
            XCTAssertTrue(
                Set(values).isSubset(of: [0, 1, FakeWorker.marker(id)]),
                "job \(id) saw another job's progress: \(values)")
            XCTAssertEqual(values.first, 0)
            XCTAssertEqual(values.last, 1, "no progress may arrive after the final 1: \(values)")
            XCTAssertEqual(values, values.sorted())
        }

        // Idle workers are reused: a third, sequential job makes no new manager.
        _ = try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
        XCTAssertEqual(fake.workers.count, 2)
    }

    func testDeleteIsRefusedWhileATranscriptionRunsAndDropsThePoolAfterwards() async throws {
        let root = try makeScratchDirectory("ichirp-pool")
        let audio = try writeSilentWAV(seconds: 2, in: root)
        let hold = Latch()
        let fake = FakeParakeet(partyCount: 1, hold: hold)
        let engine = fake.engine(in: root)

        let running = Task {
            try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
        }
        await waitUntil { fake.events.values.contains("transcribe-1") }

        do {
            try await engine.deleteAssets()
            XCTFail("Delete must refuse while a transcription runs")
        } catch {
            XCTAssertEqual(
                error as? SpeechEngineError,
                .underlying(ModelAssetLifecycle<ParakeetRuntime>.inUseMessage(for: "Fake Parakeet")))
        }
        XCTAssertFalse(fake.events.values.contains("remove"))

        await hold.open()
        _ = try await running.value
        try await engine.deleteAssets()
        XCTAssertEqual(fake.events.values.suffix(2), ["remove", "cleanup-1"], "idle managers are released on delete")
        await assertThrowsModelNotDownloaded {
            _ = try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
        }

        // After a fresh download the old pool is gone: the next job gets a new manager on the new models.
        try await engine.downloadAssets { _ in }
        let result = try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
        XCTAssertEqual(try workerID(of: result), 2)
    }

    /// A manager whose transcription threw may hold half-finished decoder or progress state, so it must never serve
    /// another job: the next job gets a fresh manager on the same loaded models.
    func testAWorkerWhoseTranscriptionThrewIsDroppedNotReturnedToThePool() async throws {
        let root = try makeScratchDirectory("ichirp-pool")
        let audio = try writeSilentWAV(seconds: 2, in: root)
        let fake = FakeParakeet(partyCount: 1, failingWorkers: [1])
        let engine = fake.engine(in: root)

        do {
            _ = try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
            XCTFail("Worker 1 throws")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .underlying(InferenceFailure().localizedDescription))
        }
        XCTAssertEqual(fake.events.values, ["transcribe-1", "throw-1"])

        let second = try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
        XCTAssertEqual(try workerID(of: second), 2, "the failed manager must not be checked out again")
        let third = try await engine.transcribe(fileAt: audio, options: SpeechTranscriptionOptions()) { _ in }
        XCTAssertEqual(try workerID(of: third), 2, "a manager that succeeded goes back to the pool")
        XCTAssertEqual(fake.workers.count, 2)
        XCTAssertEqual(fake.events.values.filter { $0 == "transcribe-1" }.count, 1)
        let leases = await engine.lifecycle.activeLeaseCount
        XCTAssertEqual(leases, 0, "the failed job still releases its lease")
    }
}
