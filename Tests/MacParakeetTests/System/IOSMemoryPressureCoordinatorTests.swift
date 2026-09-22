import XCTest
@testable import MacParakeetCore

private actor MockSTTRuntimeManager: STTRuntimeManaging {
    var didShutdown = false
    var warmUpCount = 0

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpCount += 1
    }

    func backgroundWarmUp() async {
        warmUpCount += 1
    }

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        (UUID(), AsyncStream { $0.finish() })
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {
        didShutdown = true
    }
}

final class IOSMemoryPressureCoordinatorTests: XCTestCase {

    func testMemoryPressureTriggersEvictionWhenIdle() async {
        let coordinator = IOSMemoryPressureCoordinator()
        let mock = MockSTTRuntimeManager()
        coordinator.configure(runtimeManager: mock)
        coordinator.setRecordingActive(false)

        let initialEvictions = coordinator.evictionCount
        coordinator.handleMemoryPressure(level: .critical)

        // Wait brief moment for async eviction Task
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.evictionCount, initialEvictions + 1)
        XCTAssertEqual(coordinator.currentLevel, .critical)
        let didShutdown = await mock.didShutdown
        XCTAssertTrue(didShutdown, "Expected STTRuntime to be shut down when idle under critical pressure")
    }

    func testMemoryPressureSkipsEvictionWhenRecordingIsActive() async {
        let coordinator = IOSMemoryPressureCoordinator()
        let mock = MockSTTRuntimeManager()
        coordinator.configure(runtimeManager: mock)
        coordinator.setRecordingActive(true)

        let initialEvictions = coordinator.evictionCount
        coordinator.handleMemoryPressure(level: .warning)

        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(coordinator.evictionCount, initialEvictions, "Should not evict while active recording is in progress")
        let didShutdown = await mock.didShutdown
        XCTAssertFalse(didShutdown, "Runtime should remain loaded during active speech recording")
    }
}
