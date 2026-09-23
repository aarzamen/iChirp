import ChirpCore
import Foundation
import XCTest

/// A gate the test opens: every `wait()` before `open()` suspends, every one after returns at once.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parties = waiters
        waiters.removeAll()
        for party in parties { party.resume() }
    }
}

/// A thread-safe append-only log, for recording events from `@Sendable` hooks and progress callbacks.
final class LockedLog<Element: Sendable>: @unchecked Sendable {
    // @unchecked Sendable: `storage` is only touched while `lock` is held.
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.withLock { storage.append(element) }
    }

    var values: [Element] {
        lock.withLock { storage }
    }
}

extension XCTestCase {
    /// Polls `condition` until it holds; fails (instead of hanging) after `timeout`.
    func waitUntil(
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Condition not met within \(timeout)", file: file, line: line)
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// An available-memory reading a test changes between calls (fix/speech-memory-fit).
final class SettableAvailableMemory: AvailableMemoryReading, @unchecked Sendable {
    // @unchecked Sendable: `bytes` is only touched while `lock` is held.
    private let lock = NSLock()
    private var bytes: UInt64?

    init(_ bytes: UInt64?) { self.bytes = bytes }

    func set(_ value: UInt64?) { lock.withLock { bytes = value } }
    func availableMemoryBytes() -> UInt64? { lock.withLock { bytes } }
}
