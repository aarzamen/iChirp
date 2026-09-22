import ChirpCore
import UIKit

/// Keeps the phone awake and the app alive while a model download runs (I3 keep-alive).
///
/// Model downloads (Settings → Speech/Speaker "Download" and the DEBUG smoke runner's auto-download) are the only
/// long network operations in M1: a locked or idle-timed-out phone would otherwise suspend the app mid-listing or
/// mid-download. Reentrant so two downloads racing (e.g. speech model and diarizer) share one idle-timer /
/// background-task pair and only restore normal behavior when the last one finishes.
/// `@unchecked Sendable`: every stored property is only ever touched on the main actor (`@MainActor` above), and
/// UIKit's `beginBackgroundTask` expiration handler is an escaping closure whose own isolation this type does not
/// control, so it must be able to capture `self` across that boundary.
@MainActor final class DownloadKeepAlive: @unchecked Sendable {
    static let shared = DownloadKeepAlive()

    private var activeCount = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let logger = Log.logger("keep-alive")

    private init() {}

    /// Runs `body` with `isIdleTimerDisabled` set and a background task open for its duration. Ends both on every
    /// exit path, including a thrown error or cancellation.
    func withKeepAlive<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        begin()
        defer { end() }
        return try await body()
    }

    private func begin() {
        activeCount += 1
        guard activeCount == 1 else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ModelDownload") { [weak self] in
            // Expiration handler: the OS grace period ran out. End the task so the app is not killed outright; the
            // download itself keeps running (or fails and surfaces its own error) once foregrounded again.
            MainActor.assumeIsolated {
                self?.logger.notice("keep_alive_expired")
                self?.endBackgroundTaskOnly()
            }
        }
    }

    private func end() {
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTaskOnly()
    }

    private func endBackgroundTaskOnly() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
