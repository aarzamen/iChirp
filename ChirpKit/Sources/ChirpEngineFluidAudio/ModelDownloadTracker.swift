import ChirpCore
import FluidAudio
import Foundation
import Synchronization

/// Download bookkeeping shared by the FluidAudio engines: maps FluidAudio's `DownloadProgress` onto one 0…1 bar,
/// remembers the in-flight fraction and the last failure for `assetStatus()`, and keeps the last phase and the
/// attempt count so a failure message can say where the download stopped.
///
/// FluidAudio's progress handler is called on an arbitrary queue, so state lives behind a `Mutex` rather than on
/// the owning actor.
final class ModelDownloadTracker: Sendable {
    private struct State {
        var fraction: Double?
        var failure: String?
        /// The last phase FluidAudio reported, as `phaseName(_:)` words.
        var phase: String?
        var attempts = 0
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

    /// Counts one call of the download hook (the first attempt or a retry).
    func beginAttempt() {
        state.withLock { $0.attempts += 1 }
    }

    func finish(failure: String?) {
        state.withLock { $0 = State(fraction: nil, failure: failure) }
    }

    /// `SpeechEngineError.downloadFailureMessage` with this download's last phase and attempt count; nil for a
    /// cancellation.
    func failureMessage(for error: any Error) -> String? {
        let (phase, attempts) = state.withLock { ($0.phase, $0.attempts) }
        return SpeechEngineError.downloadFailureMessage(for: error, phase: phase, attempts: attempts)
    }

    /// A FluidAudio progress handler that lifts every report to the high-water mark (FluidAudio restarts its
    /// fraction for each model it loads) and forwards the result to `forward`.
    func progressHandler(forwardingTo forward: @escaping @Sendable (Double) -> Void) -> ProgressHandler {
        { [self] progress in
            let mapped = min(Self.overallFraction(for: progress), Self.inFlightCeiling)
            let phase = Self.phaseName(progress.phase)
            let reported = state.withLock { current -> Double in
                let lifted = max(current.fraction ?? 0, mapped)
                current.fraction = lifted
                current.phase = phase
                return lifted
            }
            forward(reported)
        }
    }

    /// "listing", "downloading 3/12 files" or "compiling Encoder.mlmodelc" (model file names, never user data).
    static func phaseName(_ phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "listing"
        case .downloading(let completedFiles, let totalFiles):
            return "downloading \(completedFiles)/\(totalFiles) files"
        case .compiling(let modelName):
            return modelName.isEmpty ? "compiling" : "compiling \(modelName)"
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

/// The download never started because the device had no usable network path (`DownloadNetworkPolicy.checkPath`).
struct NoNetworkPath: Error, Equatable {
    /// Readable `NWPath.UnsatisfiedReason`, for the failure details.
    let reason: String
}

extension SpeechEngineError {
    /// What to check when the phone can't reach the model server. Shared by every connectivity message.
    static let connectivityAdvice =
        "Check that this iPhone is online — Wi-Fi, or cellular data allowed for this app in Settings — then try the "
        + "download again."

    /// The pre-flight path check found no network: said at once, instead of after a ~60 s connection timeout.
    static let noInternetMessage = "No internet connection. " + connectivityAdvice

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
        if error is NoNetworkPath {
            return .underlying(noInternetMessage)
        }
        if let urlError = connectivityError(in: error) {
            return .underlying(
                "Couldn't reach the model server (\(urlError.localizedDescription)) " + connectivityAdvice)
        }
        return .underlying(error.localizedDescription)
    }

    /// URLSession's own text ("The request timed out.") doesn't tell the owner what to check. These codes mean the
    /// phone never got a usable connection; FluidAudio may throw them directly or wrapped as an underlying error.
    private static let connectivityCodes: Set<URLError.Code> = [
        .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
    ]

    private static func connectivityError(in error: any Error) -> URLError? {
        var current: (any Error)? = error
        for _ in 0..<4 {
            guard let candidate = current else { return nil }
            if let urlError = candidate as? URLError, connectivityCodes.contains(urlError.code) {
                return urlError
            }
            current = (candidate as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return nil
    }

    /// Cancellation is not a download failure worth showing in `assetStatus()`.
    static func failureMessage(for error: any Error) -> String? {
        let mapped = mapping(error)
        if case .cancelled = mapped {
            return nil
        }
        return mapped.localizedDescription
    }

    /// The owner-facing sentence, then the clues for diagnosing it: error code, failing host, the phase FluidAudio
    /// last reported and how many attempts ran, e.g. "… Details: URLError -1001, host huggingface.co, phase listing,
    /// 4 attempts." Never contains a description, file name or anything from the user. Nil for a cancellation.
    static func downloadFailureMessage(for error: any Error, phase: String?, attempts: Int) -> String? {
        guard let sentence = failureMessage(for: error) else { return nil }
        var details: [String]
        if let offline = error as? NoNetworkPath {
            details = ["no network path (\(offline.reason))", "no request sent"]
        } else {
            details = [DownloadDiagnostics.code(of: error)]
            if let host = DownloadDiagnostics.host(of: error) {
                details.append("host \(host)")
            }
            if let phase {
                details.append("phase \(phase)")
            }
            details.append(attempts == 1 ? "1 attempt" : "\(attempts) attempts")
        }
        return sentence + " Details: " + details.joined(separator: ", ") + "."
    }
}

/// Classifies download errors for `ModelAssetLifecycle`'s retries. FluidAudio's own `RetryPolicy` is internal, so
/// this mirrors the part of it iChirp needs.
enum DownloadRetry {
    /// The phone had no working connection at that moment; a later attempt may get one. `dataNotAllowed` and
    /// `internationalRoamingOff` are settings the owner must change, so they are not retried.
    static let transientURLCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed,
    ]

    /// A transient URL error (directly or as an underlying error), or FluidAudio's stalled or rate-limited download.
    static func isTransient(_ error: any Error) -> Bool {
        DownloadDiagnostics.chain(of: error).contains { candidate in
            if let urlError = candidate as? URLError {
                return transientURLCodes.contains(urlError.code)
            }
            switch candidate as? DownloadError {
            case .stalled?, .rateLimited?: return true
            default: return false
            }
        }
    }

    /// `CancellationError` or a cancelled URL request anywhere in the chain.
    static func isCancellation(_ error: any Error) -> Bool {
        DownloadDiagnostics.chain(of: error).contains { candidate in
            candidate is CancellationError || (candidate as? URLError)?.code == .cancelled
        }
    }
}

/// Codes and hosts for failure messages and logs. Reads error codes and URLs only, never descriptions.
enum DownloadDiagnostics {
    /// The error, then its underlying errors (`NSUnderlyingErrorKey`, FluidAudio's `downloadFailed`), at most 5.
    static func chain(of error: any Error) -> [any Error] {
        var chain: [any Error] = []
        var current: (any Error)? = error
        while let candidate = current, chain.count < 5 {
            chain.append(candidate)
            if case .downloadFailed(_, let underlying)? = candidate as? DownloadError {
                current = underlying
            } else {
                current = (candidate as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
            }
        }
        return chain
    }

    /// "URLError -1001" for the first URL error in the chain, "DownloadError.stalled" (plus the HTTP status where
    /// FluidAudio has one) for FluidAudio's own errors, otherwise the error's domain and code.
    static func code(of error: any Error) -> String {
        let chain = chain(of: error)
        if let urlError = chain.lazy.compactMap({ $0 as? URLError }).first {
            return "URLError \(urlError.code.rawValue)"
        }
        if let downloadError = error as? DownloadError {
            switch downloadError {
            case .rateLimited(let statusCode, _):
                return "DownloadError.rateLimited (HTTP \(statusCode))"
            case .downloadFailed(_, let underlying):
                let nsError = underlying as NSError
                let status = nsError.domain == "HTTP" ? "HTTP \(nsError.code)" : "\(nsError.domain) \(nsError.code)"
                return "DownloadError.downloadFailed (\(status))"
            default:
                let caseName = String(describing: downloadError).prefix { $0 != "(" }
                return "DownloadError.\(caseName)"
            }
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    /// The host of the first failing URL in the chain (for example huggingface.co, or the CDN serving a file).
    static func host(of error: any Error) -> String? {
        for candidate in chain(of: error) {
            if let url = (candidate as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL, let host = url.host() {
                return host
            }
        }
        return nil
    }
}
