import Foundation
import Synchronization
import XCTest

@testable import ChirpEngineWhisperKit

/// Review R3-4: WhisperKit's `MonotonicFraction` and Apple Speech's `MonotonicProgress` are one helper copied into two
/// engine targets (ADR-004). This file's tests are the same in both test targets (only the alias differs), so the two
/// copies keep one behavior: progress in 0…1 that never goes back, the first value (0 too) included.
private typealias Monotonic = MonotonicFraction

final class MonotonicProgressParityTests: XCTestCase {
    func testTheFirstValueIsForwardedThenOnlyHigherOnesClampedToZeroOne() {
        let log = ProgressLog()
        let progress = Monotonic { log.append($0) }
        for value in [0, 0, 0.4, 0.2, 0.4, .nan, .infinity, -1, 0.9, 1.5, 1, 1] {
            progress.report(value)
        }
        XCTAssertEqual(log.values, [0, 0.4, 0.9, 1])
    }

    func testAFirstValueAboveZeroIsForwardedToo() {
        let log = ProgressLog()
        let progress = Monotonic { log.append($0) }
        progress.report(0.25)
        progress.report(0)
        progress.report(1)
        XCTAssertEqual(log.values, [0.25, 1])
    }
}

/// A thread-safe list of forwarded values.
private final class ProgressLog: Sendable {
    private let storage = Mutex<[Double]>([])

    func append(_ value: Double) { storage.withLock { $0.append(value) } }
    var values: [Double] { storage.withLock { $0 } }
}
