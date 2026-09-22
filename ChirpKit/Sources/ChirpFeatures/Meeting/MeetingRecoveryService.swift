// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingRecoveryService.swift @ bbae9e0e
// Changes: `discoverPendingRecoveries`, `recover` and `discard` for one source and one process. The CAF needs no
// repair (it is readable to its last buffer), so "repair" is reading its real length; the metadata reconciliation,
// playback mix, finalization leases and PID checks are gone. Recovery claims the lock for this launch, inserts or
// reuses the row, marks audio cut by a kill as partial, and runs the normal `MeetingFinalizer`.

import ChirpCore
import Foundation

/// A meeting a killed or crashed launch left behind, offered at launch (`spec/contracts/meeting-session-v1.md`).
public struct PendingMeetingRecovery: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var startedAt: Date
    public var state: MeetingSessionState
    /// How much audio the file holds (nil when it cannot be read).
    public var audioDurationMs: Int?
    public var hasNotes: Bool
    /// The Library row's status, when the meeting already has one (it was stopped before the kill).
    public var rowStatus: Transcription.Status?

    /// The app was killed while recording: the audio ends where the kill happened.
    public var isPartialAudio: Bool { state == .recording }
}

/// Finds, recovers and (after the person confirms) discards meetings left behind by an earlier launch.
public actor MeetingRecoveryService {
    private let paths: AppPaths
    private let store: any TranscriptionStoring
    private let lockStore: MeetingSessionLockStore
    private let finalizer: MeetingFinalizer
    private let normalizer: any AudioNormalizing
    private let logger = Log.logger("meeting-recovery")

    public init(
        paths: AppPaths,
        store: any TranscriptionStoring,
        lockStore: MeetingSessionLockStore,
        finalizer: MeetingFinalizer,
        normalizer: any AudioNormalizing
    ) {
        self.paths = paths
        self.store = store
        self.lockStore = lockStore
        self.finalizer = finalizer
        self.normalizer = normalizer
    }

    /// Orphaned meetings to offer, oldest first. A lock whose row is already completed only outlived its save: it is
    /// settled (deleted) here. A row that is `.failed` or `.cancelled` is left to the Library's Retry.
    public func discoverPendingRecoveries() async -> [PendingMeetingRecovery] {
        var pending: [PendingMeetingRecovery] = []
        for lock in lockStore.discoverOrphans() {
            let id = lock.sessionId
            let row = try? await store.fetch(id: id)
            if let row, row.sourceType != .meeting { continue }
            switch row?.status {
            case .completed?:
                try? lockStore.delete(sessionId: id)
                logger.notice("meeting_lock_settled id=\(id, privacy: .public)")
                continue
            case .failed?, .cancelled?:
                continue
            case nil, .processing?, .interrupted?:
                break
            }
            let audio = audioURL(for: id)
            let duration: Int? =
                FileManager.default.fileExists(atPath: audio.path)
                ? (try? await normalizer.durationMs(of: audio)) : nil
            pending.append(
                PendingMeetingRecovery(
                    id: id, displayName: lock.displayName, startedAt: lock.startedAt, state: lock.state,
                    audioDurationMs: duration, hasNotes: MeetingCoordinator.storedNotes(lock.notes ?? "") != nil,
                    rowStatus: row?.status))
        }
        return pending
    }

    /// Recovers one meeting: claims its lock for this launch (`awaitingTranscription`), removes leftover live chunks,
    /// inserts the row if it has none (with the lock's notes; "Partial audio" when the kill cut the recording), and
    /// runs the final pass. Returns the row as saved, or nil when there is no readable lock or no row could be made.
    @discardableResult
    public func recover(
        _ id: UUID, progress: (@Sendable (JobProgress) -> Void)? = nil
    ) async -> Transcription? {
        guard let lock = lockStore.read(sessionId: id) else { return nil }
        let wasRecording = lock.state == .recording
        do {
            try lockStore.update(sessionId: id) {
                $0.state = .awaitingTranscription
                $0.launchId = lockStore.launchId
            }
        } catch {
            logger.error("meeting_recovery_claim_failed id=\(id, privacy: .public)")
        }
        try? FileManager.default.removeItem(
            at: lockStore.folder(for: id).appendingPathComponent(MeetingSessionFiles.chunks, isDirectory: true))

        let store = self.store
        let existing = try? await store.fetch(id: id)
        if let existing {
            guard existing.sourceType == .meeting else { return nil }
            if existing.status != .processing {
                _ = try? await store.transitionStatus(
                    id: id, from: [.interrupted, .failed, .cancelled], to: .processing, errorMessage: nil)
            }
            if existing.userNotes == nil, let notes = MeetingCoordinator.storedNotes(lock.notes ?? "") {
                _ = try? await store.updateUserNotes(id: id, userNotes: notes)
            }
        } else {
            let audio = audioURL(for: id)
            let duration = try? await normalizer.durationMs(of: audio)
            var row = Transcription(
                id: id,
                createdAt: lock.startedAt,
                sourceType: .meeting,
                fileName: lock.displayName,
                mediaRelativePath: paths.relativePath(for: audio),
                fileSizeBytes: (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?
                    .intValue,
                durationMs: duration,
                status: .processing,
                privacyClass: lock.privacyClass
            )
            row.userNotes = MeetingCoordinator.storedNotes(lock.notes ?? "")
            row.isPartialAudio = wasRecording
            do {
                try await store.insert(row)
            } catch {
                logger.error("meeting_recovery_insert_failed id=\(id, privacy: .public)")
                return nil
            }
        }
        logger.notice("meeting_recovering id=\(id, privacy: .public) partial=\(wasRecording, privacy: .public)")
        return await finalizer.finalize(id: id, progress: progress)
    }

    /// Deletes the meeting's row (if any) and its whole folder. Only after the person confirmed Discard.
    public func discard(_ id: UUID) async throws {
        if try await store.fetch(id: id) != nil {
            try await store.delete(id: id)
        }
        let folder = lockStore.folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        logger.notice("meeting_recovery_discarded id=\(id, privacy: .public)")
    }

    private func audioURL(for id: UUID) -> URL {
        lockStore.folder(for: id).appendingPathComponent(MeetingSessionFiles.audio, isDirectory: false)
    }
}
