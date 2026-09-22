import ChirpCore
import Foundation

/// What a continued-processing request is for. Its raw value is the identifier's semantic part:
/// `<bundle id>.<rawValue>.<UUID>`, permitted by the Info.plist wildcard `$(PRODUCT_BUNDLE_IDENTIFIER).<rawValue>.*`.
public enum ContinuedProcessingKind: String, Sendable, CaseIterable {
    /// File jobs the person started (import, share, Retry).
    case transcription = "transcribe"
    /// A model download the person started in Settings.
    case modelDownload = "download"
}

/// The system task that keeps user-started work running after the app leaves the foreground, with the system's own
/// progress UI (a Live Activity with Cancel). In the app this wraps `BGContinuedProcessingTask`; tests use a fake.
@MainActor public protocol ContinuedProcessingTask: AnyObject {
    /// The progress the system shows. It terminates tasks that report little progress first.
    var progress: Progress { get }
    /// `handler` runs on the main actor when the person taps Cancel in the system UI or the system expires the task.
    func setExpirationHandler(_ handler: @escaping @MainActor () -> Void)
    func updateTitle(_ title: String, subtitle: String)
    /// Must be called exactly once, when the work has ended (or was given up after expiration).
    func setTaskCompleted(success: Bool)
}

/// Submits continued-processing requests (`BGTaskScheduler` in the app; a fake in tests).
@MainActor public protocol ContinuedProcessingScheduling: AnyObject {
    /// Registers a launch handler under a new, never-reused identifier of `kind` and submits the request. Call it from
    /// the foreground, in response to a person's action. `onStart` receives the task when the system starts it: right
    /// away, later (the request was queued), or never. Returns an id for `withdraw`, or nil when the system refused
    /// the request (the work then runs as a foreground-only job, exactly as in M1).
    func submit(
        _ kind: ContinuedProcessingKind,
        title: String,
        subtitle: String,
        onStart: @escaping @MainActor (any ContinuedProcessingTask) -> Void
    ) -> String?
    /// Withdraws a submitted request the system has not started yet. No effect once it started.
    func withdraw(_ requestID: String)
}

/// One user action's work (a batch of file jobs, a Retry, or a model download) under one continued-processing
/// request: the bridge between the app's own job state and the system's keep-alive and progress UI.
///
/// The job's own state machine stays authoritative; the system task is only a keep-alive and a progress surface.
/// - **Progress** is the mean of the items' real fractions (an ended item counts as 1), reported in
///   `totalUnits` units and never decreasing. Nothing is simulated: with no real update, nothing moves.
/// - **Completion.** When every item has ended, the task completes with success only if every item succeeded. A
///   request the system has not started yet is withdrawn instead; if it starts anyway, it completes at once.
/// - **Expiration** (Cancel in the Live Activity, or the system's decision) calls `onExpiration`, which cancels the
///   work, so rows end `cancelled` (or `interrupted` at next launch if the process is suspended before the write
///   lands), never lost. The task completes once every item has ended, or after `expirationGrace` at the latest.
@MainActor public final class BackgroundContinuation {
    /// Units of the system `Progress`: fine enough that every whole percent moves it.
    public static let totalUnits: Int64 = 1_000

    public let kind: ContinuedProcessingKind
    public let title: String
    /// Called once, on the main actor, when the task expires. The owner cancels the work here.
    public var onExpiration: (@MainActor () -> Void)?

    public private(set) var isSubmitted = false
    public private(set) var isExpired = false
    /// True once the system task was completed, or the request withdrawn, after every item ended or the grace ran out.
    public private(set) var isFinished = false
    /// The fraction last reported to the system (0…1, never decreasing).
    public private(set) var reportedFraction: Double = 0

    private let scheduler: (any ContinuedProcessingScheduling)?
    private let items: [UUID]
    private var fractions: [UUID: Double] = [:]
    private var outcomes: [UUID: Bool] = [:]
    private var stageNames: [UUID: String] = [:]
    private var requestID: String?
    private var task: (any ContinuedProcessingTask)?
    /// The subtitle before any item reported a stage.
    private let initialSubtitle: String
    private var lastSubtitle: String
    private let expirationGrace: Duration
    private let logger = Log.logger("continued-processing")

    /// - Parameters:
    ///   - items: the work's ids (one per file job, or one for a download), all known up front.
    ///   - subtitle: shown before the first progress update, e.g. "Waiting to start".
    ///   - expirationGrace: after expiration, how long to wait for the cancelled work to end before completing the
    ///     task anyway.
    public init(
        scheduler: (any ContinuedProcessingScheduling)?,
        kind: ContinuedProcessingKind,
        title: String,
        subtitle: String,
        items: [UUID],
        expirationGrace: Duration = .seconds(5)
    ) {
        self.scheduler = scheduler
        self.kind = kind
        self.title = title
        self.items = items
        self.initialSubtitle = subtitle
        self.lastSubtitle = subtitle
        self.expirationGrace = expirationGrace
    }

    /// Submits the request (from the person's action). Returns whether the system accepted it; when it did not, the
    /// work simply runs in the foreground as before.
    @discardableResult public func begin() -> Bool {
        guard !isSubmitted, !items.isEmpty, let scheduler else { return false }
        requestID = scheduler.submit(kind, title: title, subtitle: lastSubtitle) { [weak self] task in
            self?.attach(task)
        }
        isSubmitted = requestID != nil
        logger.notice(
            "request_\(self.isSubmitted ? "submitted" : "refused", privacy: .public) kind=\(self.kind.rawValue, privacy: .public) items=\(self.items.count, privacy: .public)"
        )
        return isSubmitted
    }

    /// Records real progress for one item (`fraction` 0…1; lower values than before are ignored) and forwards the
    /// aggregate to the system task. `stage` names what the item is doing, e.g. "Transcribing".
    public func update(_ item: UUID, fraction: Double, stage: String) {
        guard items.contains(item), outcomes[item] == nil else { return }
        let clamped = min(max(fraction, 0), 1)
        fractions[item] = max(fractions[item] ?? 0, clamped)
        stageNames[item] = stage
        push()
    }

    /// Marks one item ended. Once every item has ended, the system task completes (or the request is withdrawn).
    public func end(_ item: UUID, succeeded: Bool) {
        guard items.contains(item), outcomes[item] == nil else { return }
        outcomes[item] = succeeded
        push()
        if outcomes.count == items.count {
            finish(success: outcomes.values.allSatisfy { $0 })
        }
    }

    /// The mean of the items' fractions, ended items counting as 1.
    public var aggregateFraction: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { total, item in
            total + (outcomes[item] != nil ? 1 : (fractions[item] ?? 0))
        }
        return sum / Double(items.count)
    }

    // MARK: - System task

    /// The system started the task: connect it, or complete it at once when the work already ended.
    func attach(_ task: any ContinuedProcessingTask) {
        logger.notice(
            "task_started kind=\(self.kind.rawValue, privacy: .public) finished=\(self.isFinished, privacy: .public)")
        task.progress.totalUnitCount = Self.totalUnits
        if isFinished {
            task.progress.completedUnitCount = Self.totalUnits
            task.setTaskCompleted(success: outcomes.count == items.count && outcomes.values.allSatisfy { $0 })
            return
        }
        self.task = task
        task.setExpirationHandler { [weak self] in self?.expire() }
        task.progress.completedUnitCount = units(for: reportedFraction)
        task.updateTitle(title, subtitle: lastSubtitle)
    }

    private func expire() {
        guard !isExpired, !isFinished else { return }
        isExpired = true
        logger.notice(
            "task_expired kind=\(self.kind.rawValue, privacy: .public) ended=\(self.outcomes.count, privacy: .public)/\(self.items.count, privacy: .public)"
        )
        onExpiration?()
        guard !isFinished else { return }
        let grace = expirationGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.finishAfterGrace()
        }
    }

    private func finishAfterGrace() {
        guard !isFinished else { return }
        logger.notice("task_completed_after_grace kind=\(self.kind.rawValue, privacy: .public)")
        finish(success: false)
    }

    private func finish(success: Bool) {
        guard !isFinished else { return }
        isFinished = true
        if let task {
            task.progress.completedUnitCount = max(task.progress.completedUnitCount, units(for: reportedFraction))
            task.setTaskCompleted(success: success)
            self.task = nil
            logger.notice(
                "task_completed kind=\(self.kind.rawValue, privacy: .public) success=\(success, privacy: .public)")
        } else if let requestID {
            // Queued and never started: nothing to keep alive any more.
            scheduler?.withdraw(requestID)
            logger.notice("request_withdrawn kind=\(self.kind.rawValue, privacy: .public)")
        }
    }

    // MARK: - Progress

    private func push() {
        let fraction = max(reportedFraction, aggregateFraction)
        reportedFraction = fraction
        let subtitle = makeSubtitle(fraction: fraction)
        guard let task else {
            lastSubtitle = subtitle
            return
        }
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, units(for: fraction))
        if subtitle != lastSubtitle {
            lastSubtitle = subtitle
            task.updateTitle(title, subtitle: subtitle)
        }
    }

    /// "Transcribing · 42%" for one item; "1 of 3 done · 42%" for several.
    private func makeSubtitle(fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded(.down))
        if items.count == 1, let item = items.first {
            let stage = stageNames[item] ?? initialSubtitle
            return outcomes[item] == nil ? "\(stage) · \(percent)%" : "Done"
        }
        return "\(outcomes.count) of \(items.count) done · \(percent)%"
    }

    private func units(for fraction: Double) -> Int64 {
        Int64((min(max(fraction, 0), 1) * Double(Self.totalUnits)).rounded(.down))
    }
}
