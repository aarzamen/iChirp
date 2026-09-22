// Semantics from MacParakeet (GPL-3.0): Sources/MacParakeetCore/STT/STTScheduler.swift @ bbae9e0e — two slots, priority, FIFO, no preemption, backpressure. Fresh implementation, not a line port.

import Foundation

/// The kinds of speech work competing for the recognizer.
public enum SpeechJobKind: String, Sendable, CaseIterable {
    case dictation, meetingFinalize, meetingLiveChunk, fileTranscription

    /// Lower runs first within the background slot (upstream STTScheduler.priorityRank).
    ///
    /// `dictation` and `meetingFinalize` both rank 0 but never contend: they use different slots.
    public var priorityRank: Int {
        switch self {
        case .dictation, .meetingFinalize:
            return 0
        case .meetingLiveChunk:
            return 1
        case .fileTranscription:
            return 2
        }
    }

    /// True only for `.dictation`, which must stay responsive while background work runs.
    public var usesInteractiveSlot: Bool {
        self == .dictation
    }
}

public enum SpeechJobError: Error, Equatable {
    /// A pending `.meetingLiveChunk` was discarded because newer chunks exceeded the backlog limit.
    case droppedDueToBackpressure
}

/// Serializes speech work into two slots so at most one interactive job (dictation) and one background job
/// (meeting finalize, live chunk, file transcription) run at a time.
///
/// Invariants:
/// - Each slot is held by at most one job. A job holds its slot from the moment it is granted until its
///   operation has finished (success, throw or cancellation) — the slot is released exactly once.
/// - Every pending job's continuation is resumed exactly once: when it is granted a slot, cancelled or dropped.
///   A job is always removed from `pending` before its continuation is resumed.
public actor SpeechJobScheduler {
    private struct PendingJob: Sendable {
        let id: UUID
        let kind: SpeechJobKind
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maxPendingLiveChunks: Int
    private let logger = Log.logger("scheduler")
    private var interactiveBusy = false
    private var backgroundBusy = false
    /// Waiting jobs in enqueue order (ascending `sequence`).
    private var pending: [PendingJob] = []
    private var nextSequence: UInt64 = 0

    /// - Parameter maxPendingLiveChunks: pending live-preview chunks kept before the oldest is dropped.
    ///   Values below 1 are treated as 1.
    public init(maxPendingLiveChunks: Int = 120) {
        self.maxPendingLiveChunks = max(1, maxPendingLiveChunks)
    }

    /// Runs `operation` when its slot is free. Background jobs are ordered by priorityRank, then FIFO; a running job is
    /// never preempted. Cancelling the calling task removes a pending job or cancels the running one.
    /// A pending .meetingLiveChunk beyond maxPendingLiveChunks drops the oldest one, which throws SpeechJobError.droppedDueToBackpressure.
    public func run<T: Sendable>(
        _ kind: SpeechJobKind,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try await acquireSlot(for: kind)
        // From here on this call owns the slot; `defer` is the only release point.
        defer { releaseSlot(for: kind) }
        // Cancelled after the grant but before this call resumed: give the slot back without starting work.
        try Task.checkCancellation()
        let execution = Task { try await operation() }
        return try await withTaskCancellationHandler {
            try await execution.value
        } onCancel: {
            execution.cancel()
        }
    }

    /// Number of jobs waiting for a slot (both slots).
    public func pendingCount() -> Int {
        pending.count
    }

    // MARK: - Slot acquisition

    /// Suspends until `kind`'s slot is granted to this caller. Throws `CancellationError` if the caller is
    /// cancelled while waiting, or `SpeechJobError.droppedDueToBackpressure` if the job is dropped.
    private func acquireSlot(for kind: SpeechJobKind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enqueue(PendingJob(id: id, kind: kind, sequence: takeSequence(), continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelPending(id: id) }
        }
    }

    private func takeSequence() -> UInt64 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    private func enqueue(_ job: PendingJob) {
        // Runs synchronously inside the caller's task. If the caller was cancelled before the job existed, the
        // cancellation hop in `acquireSlot` finds nothing to remove, so reject the job here instead.
        guard !Task.isCancelled else {
            job.continuation.resume(throwing: CancellationError())
            return
        }
        if job.kind == .meetingLiveChunk {
            dropOldestLiveChunkIfOverLimit()
        }
        pending.append(job)
        dispatch()
    }

    private func dropOldestLiveChunkIfOverLimit() {
        let pendingLiveChunks = pending.lazy.filter { $0.kind == .meetingLiveChunk }.count
        guard pendingLiveChunks >= maxPendingLiveChunks,
            let oldest = pending.firstIndex(where: { $0.kind == .meetingLiveChunk })
        else {
            return
        }
        let dropped = pending.remove(at: oldest)
        logger.notice("backpressure: dropped pending live chunk seq=\(dropped.sequence, privacy: .public)")
        dropped.continuation.resume(throwing: SpeechJobError.droppedDueToBackpressure)
    }

    private func cancelPending(id: UUID) {
        // Not found means the job was already granted (its run observes cancellation itself), dropped, or
        // rejected in `enqueue`; each of those already resumed the continuation.
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let job = pending.remove(at: index)
        job.continuation.resume(throwing: CancellationError())
    }

    // MARK: - Dispatch

    private func releaseSlot(for kind: SpeechJobKind) {
        if kind.usesInteractiveSlot {
            interactiveBusy = false
        } else {
            backgroundBusy = false
        }
        dispatch()
    }

    /// Grants each free slot to its best pending job: lowest `priorityRank`, then oldest.
    private func dispatch() {
        if !interactiveBusy, let job = takeNext(interactive: true) {
            interactiveBusy = true
            job.continuation.resume()
        }
        if !backgroundBusy, let job = takeNext(interactive: false) {
            backgroundBusy = true
            job.continuation.resume()
        }
    }

    private func takeNext(interactive: Bool) -> PendingJob? {
        let best = pending.indices
            .filter { pending[$0].kind.usesInteractiveSlot == interactive }
            .min { lhs, rhs in
                (pending[lhs].kind.priorityRank, pending[lhs].sequence)
                    < (pending[rhs].kind.priorityRank, pending[rhs].sequence)
            }
        guard let best else { return nil }
        return pending.remove(at: best)
    }
}
