import BackgroundTasks
import ChirpCore
import ChirpFeatures
import Foundation

/// `BGTaskScheduler` behind ChirpFeatures' `ContinuedProcessingScheduling` (M1.5 Step 2): one
/// `BGContinuedProcessingTaskRequest` per user action, so a long job keeps running after the person leaves the app,
/// with the system's own progress UI (a Live Activity with Cancel).
///
/// - Identifiers are `<bundle id>.<kind>.<UUID>`, derived from the running bundle id and never reused: registering the
///   same identifier twice kills the app. `project.yml` permits them with the wildcards
///   `$(PRODUCT_BUNDLE_IDENTIFIER).transcribe.*` and `$(PRODUCT_BUNDLE_IDENTIFIER).download.*`.
/// - The launch handler is registered right before submitting (continued-processing tasks are exempt from
///   "register before launch finishes") and runs on the main queue.
/// - No `UIBackgroundModes` value and no entitlement: Parakeet's work is CPU and Neural Engine, and only background
///   GPU (`requiredResources = .gpu`) needs one. Strategy `.queue` (the default).
/// - The Simulator refuses every request (`unavailable`); the job then runs in the foreground only, as in M1.
@MainActor final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    private let bundleIdentifier: String
    private let logger = Log.logger("continued-processing")

    init?(bundle: Bundle = .main) {
        guard let bundleIdentifier = bundle.bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        self.bundleIdentifier = bundleIdentifier
    }

    static func identifier(bundleIdentifier: String, kind: ContinuedProcessingKind, suffix: UUID) -> String {
        "\(bundleIdentifier).\(kind.rawValue).\(suffix.uuidString)"
    }

    func submit(
        _ kind: ContinuedProcessingKind,
        title: String,
        subtitle: String,
        onStart: @escaping @MainActor (any ContinuedProcessingTask) -> Void
    ) -> String? {
        let identifier = Self.identifier(bundleIdentifier: bundleIdentifier, kind: kind, suffix: UUID())
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                onStart(SystemContinuedProcessingTask(task))
            }
        }
        guard registered else {
            // Not in BGTaskSchedulerPermittedIdentifiers: a build configuration problem, not a runtime one.
            logger.error("register_refused kind=\(kind.rawValue, privacy: .public)")
            return nil
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            return identifier
        } catch {
            let code = (error as? BGTaskScheduler.Error)?.code.rawValue ?? -1
            logger.notice(
                "submit_refused kind=\(kind.rawValue, privacy: .public) code=\(code, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return nil
        }
    }

    func withdraw(_ requestID: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestID)
    }
}

/// A running `BGContinuedProcessingTask`, as ChirpFeatures sees it.
@MainActor final class SystemContinuedProcessingTask: ContinuedProcessingTask {
    private let task: BGContinuedProcessingTask

    init(_ task: BGContinuedProcessingTask) {
        self.task = task
    }

    var progress: Progress { task.progress }

    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void) {
        // The system calls this on a queue of its choosing; the continuation lives on the main actor.
        task.expirationHandler = {
            Task { @MainActor in handler() }
        }
    }

    func updateTitle(_ title: String, subtitle: String) {
        task.updateTitle(title, subtitle: subtitle)
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
