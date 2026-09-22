// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingAudioRetentionPolicy.swift @ bbae9e0e
// Changes: also ports the intent of `MeetingAudioRetentionSweeper.swift`: the policy (age-based only, never a locked or
// unfinished session) plus a sweep over the Library's meeting rows that marks the row first
// (`markAudioRemoved`, completed rows only) and then deletes `meeting.caf`. No "delete immediately" mode.

import ChirpCore
import Foundation

/// Which meetings' audio the person's retention setting removes. Pure, so the safety rules are tested directly.
public enum MeetingAudioRetentionPolicy {
    public struct Candidate: Sendable, Equatable {
        public var id: UUID
        public var isMeeting: Bool
        public var isCompleted: Bool
        public var hasAudioOnDisk: Bool
        /// Any file named `recording.lock` in the folder, readable or not.
        public var hasLockFile: Bool
        /// When the meeting started (`Transcription.createdAt`).
        public var ageReferenceDate: Date

        public init(
            id: UUID, isMeeting: Bool, isCompleted: Bool, hasAudioOnDisk: Bool, hasLockFile: Bool,
            ageReferenceDate: Date
        ) {
            self.id = id
            self.isMeeting = isMeeting
            self.isCompleted = isCompleted
            self.hasAudioOnDisk = hasAudioOnDisk
            self.hasLockFile = hasLockFile
            self.ageReferenceDate = ageReferenceDate
        }
    }

    /// The ids whose audio goes: completed meetings with audio, no lock file, older than the setting. Keep-forever
    /// (the default) returns nothing.
    public static func sweep(_ candidates: [Candidate], retention: MeetingAudioRetention, now: Date) -> [UUID] {
        guard case .deleteAfterDays(let days) = retention, days > 0 else { return [] }
        let interval = TimeInterval(days) * 24 * 60 * 60
        return candidates.compactMap { candidate in
            guard candidate.isMeeting, candidate.isCompleted, candidate.hasAudioOnDisk, !candidate.hasLockFile,
                now.timeIntervalSince(candidate.ageReferenceDate) > interval
            else { return nil }
            return candidate.id
        }
    }
}

/// Applies the retention setting at launch. Transcripts and notes stay; only `meeting.caf` goes.
public struct MeetingAudioRetentionSweeper: Sendable {
    private let paths: AppPaths
    private let store: any TranscriptionStoring
    private let lockStore: MeetingSessionLockStore
    private let settings: any SettingsStoring

    public init(
        paths: AppPaths, store: any TranscriptionStoring, lockStore: MeetingSessionLockStore,
        settings: any SettingsStoring
    ) {
        self.paths = paths
        self.store = store
        self.lockStore = lockStore
        self.settings = settings
    }

    /// Removes the audio of every meeting the policy selects. Returns how many were removed.
    @discardableResult
    public func sweep(now: Date = Date()) async -> Int {
        let retention = MeetingAudioRetention(days: settings.load().meetingAudioRetentionDays)
        guard retention != .keepForever, let rows = try? await store.fetchAll() else { return 0 }
        let candidates = rows.filter { $0.sourceType == .meeting }.map { row in
            MeetingAudioRetentionPolicy.Candidate(
                id: row.id,
                isMeeting: true,
                isCompleted: row.status == .completed,
                hasAudioOnDisk: row.mediaRelativePath.map {
                    FileManager.default.fileExists(atPath: paths.absoluteURL(forRelativePath: $0).path)
                } ?? false,
                hasLockFile: lockStore.hasLockFile(sessionId: row.id),
                ageReferenceDate: row.createdAt)
        }
        var removed = 0
        for id in MeetingAudioRetentionPolicy.sweep(candidates, retention: retention, now: now) {
            guard let relative = rows.first(where: { $0.id == id })?.mediaRelativePath,
                // The row is marked first (completed rows only), so it never points at a deleted file.
                (try? await store.markAudioRemoved(id: id, at: now)) != nil
            else { continue }
            let url = paths.absoluteURL(forRelativePath: relative)
            guard url.lastPathComponent == MeetingSessionFiles.audio, !lockStore.hasLockFile(sessionId: id) else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            Log.logger("meeting-retention").notice("meeting_audio_removed count=\(removed, privacy: .public)")
        }
        return removed
    }
}
