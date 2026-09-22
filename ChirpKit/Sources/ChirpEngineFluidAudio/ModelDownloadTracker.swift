import ChirpCore
import FluidAudio
import Foundation
import Synchronization

/// Download bookkeeping shared by the FluidAudio engines: maps FluidAudio's `DownloadProgress` onto one 0…1 bar
/// and remembers the in-flight fraction and the last failure for `assetStatus()`.
///
/// FluidAudio's progress handler is called on an arbitrary queue, so state lives behind a `Mutex` rather than on
/// the owning actor.
final class ModelDownloadTracker: Sendable {
    private struct State {
        var fraction: Double?
        var failure: String?
    }

    /// Share of the bar given to downloading; compiling fills the rest. Downloading is the slow part on a phone.
    static let downloadShare = 0.95
    /// FluidAudio repo loads spend the first half of `fractionCompleted` downloading and the second half
    /// compiling (`ProgressReporter(downloadPhaseWeight: 0.5)` in FluidAudio 0.16.1). Re-check on a bump.
    static let fluidAudioDownloadWeight = 0.5
    /// In-flight progress stops short of 1 so the bar only completes when the whole download call returns.
    static let inFlightCeiling = 0.99

    private let state = Mutex(State())

    /// Non-nil while a download runs.
    var inFlightFraction: Double? {
        state.withLock { $0.fraction }
    }

    /// The last failed download's message, cleared when the next one begins.
    var lastFailure: String? {
        state.withLock { $0.failure }
    }

    func begin() {
        state.withLock { $0 = State(fraction: 0, failure: nil) }
    }

    func finish(failure: String?) {
        state.withLock { $0 = State(fraction: nil, failure: failure) }
    }

    /// A FluidAudio progress handler that lifts every report to the high-water mark (FluidAudio restarts its
    /// fraction for each model it loads) and forwards the result to `forward`.
    func progressHandler(forwardingTo forward: @escaping @Sendable (Double) -> Void) -> ProgressHandler {
        { [self] progress in
            let mapped = min(Self.overallFraction(for: progress), Self.inFlightCeiling)
            let reported = state.withLock { current -> Double in
                let lifted = max(current.fraction ?? 0, mapped)
                current.fraction = lifted
                return lifted
            }
            forward(reported)
        }
    }

    /// One FluidAudio progress report as a fraction of the whole bar.
    static func overallFraction(for progress: DownloadProgress) -> Double {
        let raw = min(max(progress.fractionCompleted, 0), 1)
        switch progress.phase {
        case .listing:
            return 0
        case .downloading:
            return downloadShare * min(raw / fluidAudioDownloadWeight, 1)
        case .compiling:
            let compiled = max(0, raw - fluidAudioDownloadWeight) / (1 - fluidAudioDownloadWeight)
            return downloadShare + (1 - downloadShare) * min(compiled, 1)
        }
    }
}

extension SpeechEngineError {
    /// Maps any engine failure onto the ChirpCore error contract.
    static func mapping(_ error: any Error) -> SpeechEngineError {
        if let engineError = error as? SpeechEngineError {
            return engineError
        }
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .cancelled
        }
        return .underlying(error.localizedDescription)
    }

    /// Cancellation is not a download failure worth showing in `assetStatus()`.
    static func failureMessage(for error: any Error) -> String? {
        let mapped = mapping(error)
        if case .cancelled = mapped {
            return nil
        }
        return mapped.localizedDescription
    }
}
