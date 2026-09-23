import ChirpCore
import FluidAudio
import XCTest

@testable import ChirpEngineFluidAudio

/// fix/speech-memory-fit: Parakeet, like every speech engine, compares its registry row's load need with what iOS
/// lets the app use right now before it loads, and refuses (loading nothing) instead of being terminated by iOS.
final class ParakeetMemoryFitTests: XCTestCase {
    /// A memory reading the test changes between calls.
    private final class Memory: AvailableMemoryReading, @unchecked Sendable {
        // @unchecked Sendable: `bytes` is only touched while `lock` is held.
        private let lock = NSLock()
        private var bytes: UInt64?

        init(_ bytes: UInt64?) { self.bytes = bytes }
        func set(_ value: UInt64?) { lock.withLock { bytes = value } }
        func availableMemoryBytes() -> UInt64? { lock.withLock { bytes } }
    }

    /// Counts loads; the model is always on disk.
    private final class Loads: @unchecked Sendable {
        // @unchecked Sendable: `count` is only touched while `lock` is held.
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private func engine(memory: Memory, loads: Loads, root: URL) -> ParakeetEngine {
        let hooks = ModelAssetLifecycle<ParakeetRuntime>.Hooks(
            engineID: ParakeetEngine.engineID,
            displayName: "Parakeet",
            modelsPresent: { true },
            bytesOnDisk: { 1 },
            download: { _ in },
            load: {
                loads.increment()
                return ParakeetRuntime(decoderLayerCount: 2, makeWorker: { fatalError("no inference in this test") })
            },
            remove: {}
        )
        return ParakeetEngine(
            variant: .v3, modelsRoot: root, gate: ANEInferenceGate(serializationRequired: false), hooks: hooks,
            network: .testing(), availableMemory: memory)
    }

    func testParakeetRefusesALoadThatDoesNotFitAndLoadsOnceThereIsRoom() async throws {
        let root = try makeScratchDirectory("ichirp-memfit")
        let key = SpeechEngineVariantKey(engineID: ParakeetEngine.engineID, variant: "v3")
        let needed = try XCTUnwrap(SpeechEngineCapabilityRegistry.memoryToLoadBytes(for: key))
        let memory = Memory(UInt64(needed) - 1)
        let loads = Loads()
        let engine = engine(memory: memory, loads: loads, root: root)
        let audio = try writeSilentWAV(seconds: 1, in: root)

        do {
            try await engine.prepare()
            XCTFail("a model that does not fit must be refused")
        } catch {
            XCTAssertEqual(
                error as? SpeechEngineError, .insufficientMemory(key, needed: needed, available: UInt64(needed) - 1))
            XCTAssertTrue(error.localizedDescription.hasPrefix("Parakeet v3 needs about 0.8 GB of memory"))
            XCTAssertTrue(error.localizedDescription.hasSuffix("Close other apps and try again."))
        }
        do {
            _ = try await engine.transcribe(fileAt: audio, options: .init(), progress: { _ in })
            XCTFail("transcribe loads through the same check")
        } catch {
            guard case .insufficientMemory = error as? SpeechEngineError else {
                return XCTFail("expected insufficientMemory, got \(error)")
            }
        }
        XCTAssertEqual(loads.value, 0, "never load after refusing")
        let loaded = await engine.lifecycle.isLoaded
        XCTAssertFalse(loaded)

        memory.set(UInt64(needed))
        try await engine.prepare()
        XCTAssertEqual(loads.value, 1, "Retry with enough memory loads")
    }

    func testAnUnknownReadingNeverRefuses() async throws {
        let root = try makeScratchDirectory("ichirp-memfit")
        let loads = Loads()
        let engine = engine(memory: Memory(nil), loads: loads, root: root)
        try await engine.prepare()
        XCTAssertEqual(loads.value, 1)
    }
}
