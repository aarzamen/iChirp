import Foundation
import Network
import Synchronization

/// The device's network path right before a model download.
enum NetworkPathStatus: Sendable, Equatable {
    /// A path exists. The server may still be unreachable; the download finds out.
    case usable
    /// No usable path. `reason` is readable text from `NWPath.UnsatisfiedReason`, kept for the failure details.
    case unusable(reason: String)
    /// The check did not answer in time. The download goes ahead rather than blocking on the check.
    case unknown
}

/// How `ModelAssetLifecycle.download` treats the network:
///
/// - A pre-flight path check, so an offline phone fails at once with "No internet connection" instead of after
///   URLSession's ~60 s connection timeout. FluidAudio owns its `URLSession`, so `waitsForConnectivity` is not an
///   option.
/// - Bounded retries with backoff for transient failures. FluidAudio retries each file but not its first request
///   (the file listing), which is what failed on the iPhone 17 Pro. Retrying is cheap: FluidAudio skips finished
///   files and resumes `.partial` ones.
///
/// Injected, so tests never wait and never look at the real network.
struct DownloadNetworkPolicy: Sendable {
    /// The pause before each retry. Its count is the number of retries after the first attempt.
    var retryDelays: [Duration]
    /// Must throw when the task is cancelled, like `Task.sleep`.
    var sleep: @Sendable (Duration) async throws -> Void
    var checkPath: @Sendable () async -> NetworkPathStatus

    /// Three retries, after 2 s, 8 s and 20 s; the path check waits at most 2 s for `NWPathMonitor`.
    static let live = DownloadNetworkPolicy(
        retryDelays: [.seconds(2), .seconds(8), .seconds(20)],
        sleep: { try await Task.sleep(for: $0) },
        checkPath: { await NetworkPathProbe.currentStatus(timeoutSeconds: 2) }
    )
}

/// Reads the current path from `NWPathMonitor`'s first update. Sends nothing over the network.
enum NetworkPathProbe {
    static func currentStatus(timeoutSeconds: Double) async -> NetworkPathStatus {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.aarzamen.ichirp.network-path")
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<NetworkPathStatus, Never>) in
            let once = ResumeOnce(continuation)
            monitor.pathUpdateHandler = { path in once.resume(returning: NetworkPathProbe.status(of: path)) }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) { once.resume(returning: .unknown) }
        }
        // On the monitor's queue, so no update handler is running while it is cleared.
        queue.async {
            monitor.pathUpdateHandler = nil
            monitor.cancel()
        }
        return result
    }

    static func status(of path: NWPath) -> NetworkPathStatus {
        switch path.status {
        case .satisfied, .requiresConnection:
            return .usable
        case .unsatisfied:
            return .unusable(reason: reason(path.unsatisfiedReason))
        @unknown default:
            return .unknown
        }
    }

    private static func reason(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: return "no Wi-Fi or cellular connection"
        case .cellularDenied: return "cellular data is turned off for this app"
        case .wifiDenied: return "Wi-Fi is turned off for this app"
        case .localNetworkDenied: return "local network access is denied"
        case .vpnInactive: return "the required VPN is not connected"
        @unknown default: return "the network path is unsatisfied"
        }
    }
}

/// Resumes a continuation exactly once, whichever of the path update and the timeout comes first.
private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: Value) {
        let pending = continuation.withLock { current -> CheckedContinuation<Value, Never>? in
            defer { current = nil }
            return current
        }
        pending?.resume(returning: value)
    }
}
