import ChirpCore
import ChirpFeatures
import Foundation

/// Asks iOS to keep a meeting's final pass (or a recovery) running with the phone locked, through the same
/// continued-processing request file jobs use (`BackgroundContinuation`, kind `transcribe`), fed with the finalizer's
/// real progress. When the system refuses (the Simulator always does) the pass simply runs in the foreground.
@MainActor final class MeetingBackgroundWork {
    private let scheduler: (any ContinuedProcessingScheduling)?
    private var running: [UUID: BackgroundContinuation] = [:]

    init(scheduler: (any ContinuedProcessingScheduling)?) {
        self.scheduler = scheduler
    }

    func begin(_ id: UUID, title: String) {
        guard running[id] == nil else { return }
        let continuation = BackgroundContinuation(
            scheduler: scheduler, kind: .transcription, title: title, subtitle: "Waiting to start", items: [id])
        continuation.begin()
        running[id] = continuation
    }

    func progress(_ id: UUID, _ progress: JobProgress) {
        running[id]?.update(id, fraction: progress.fraction, stage: progress.stage.displayName)
    }

    func end(_ id: UUID, succeeded: Bool) {
        running.removeValue(forKey: id)?.end(id, succeeded: succeeded)
    }
}
