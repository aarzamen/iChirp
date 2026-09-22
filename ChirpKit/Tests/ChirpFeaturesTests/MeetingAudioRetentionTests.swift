// Policy tests ported from MacParakeet (GPL-3.0): Tests/MacParakeetTests/Services/MeetingRecording/MeetingAudioRetentionPolicyTests.swift @ bbae9e0e
// Changes: names kept; iChirp has no "delete immediately" mode, so that test is not ported; non-meeting rows are
// excluded too. Plus the sweeper over a store and real folders.

import ChirpCore
import XCTest

@testable import ChirpFeatures

final class MeetingAudioRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func candidate(
        id: UUID = UUID(), isMeeting: Bool = true, isCompleted: Bool = true, hasAudioOnDisk: Bool = true,
        ageDays: Int, extraSeconds: TimeInterval = 0, hasLockFile: Bool = false
    ) -> MeetingAudioRetentionPolicy.Candidate {
        MeetingAudioRetentionPolicy.Candidate(
            id: id, isMeeting: isMeeting, isCompleted: isCompleted, hasAudioOnDisk: hasAudioOnDisk,
            hasLockFile: hasLockFile,
            ageReferenceDate: now.addingTimeInterval(-(TimeInterval(ageDays) * 86_400 + extraSeconds)))
    }

    func testKeepForeverReturnsNoCandidates() {
        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep([candidate(ageDays: 900)], retention: .keepForever, now: now), [])
        XCTAssertEqual(MeetingAudioRetention(days: nil), .keepForever, "the default keeps audio forever")
    }

    func testDeleteAfterDaysUsesStrictBoundary() {
        let older = candidate(ageDays: 30, extraSeconds: 1)
        let exactly = candidate(ageDays: 30)
        let newer = candidate(ageDays: 29, extraSeconds: 23 * 3_600)
        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep([older, exactly, newer], retention: .deleteAfterDays(30), now: now),
            [older.id])
    }

    func testSkipsIncompleteNoAudioAndLockedCandidates() {
        let incomplete = candidate(isCompleted: false, ageDays: 90)
        let noAudio = candidate(hasAudioOnDisk: false, ageDays: 90)
        let locked = candidate(ageDays: 90, hasLockFile: true)
        let notAMeeting = candidate(isMeeting: false, ageDays: 90)
        let eligible = candidate(ageDays: 90)
        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [incomplete, noAudio, locked, notAMeeting, eligible], retention: .deleteAfterDays(30), now: now),
            [eligible.id])
    }

    func testHasRecoveryLockRepresentsAnyRecordingLockFilePresence() {
        XCTAssertEqual(
            MeetingAudioRetentionPolicy.sweep(
                [candidate(ageDays: 90, hasLockFile: true)], retention: .deleteAfterDays(1), now: now), [])
    }
}

/// The sweeper over real folders: only the completed, unlocked, old meeting loses its audio; its row stays.
final class MeetingAudioRetentionSweeperTests: XCTestCase {
    func testSweepRemovesOnlyOldCompletedUnlockedMeetingAudioAndKeepsTheTranscript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRetention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = FakeStore()
        let lockStore = MeetingSessionLockStore(paths: paths)
        var settings = TranscriptionSettings()
        settings.meetingAudioRetentionDays = 30
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)

        func meeting(status: Transcription.Status, createdAt: Date, locked: Bool = false) async throws -> UUID {
            let id = UUID()
            let folder = paths.mediaDirectory(for: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: folder.appendingPathComponent(MeetingSessionFiles.audio))
            if locked {
                try Data("{}".utf8).write(to: lockStore.lockURL(for: id))  // unreadable, still a barrier
            }
            var row = Transcription(
                id: id, createdAt: createdAt, sourceType: .meeting, fileName: "Meeting",
                mediaRelativePath: "media/\(id.uuidString)/meeting.caf", status: status)
            row.rawTranscript = "kept"
            try await store.insert(row)
            return id
        }
        let eligible = try await meeting(status: .completed, createdAt: old)
        let recent = try await meeting(status: .completed, createdAt: now)
        let unfinished = try await meeting(status: .failed, createdAt: old)
        let locked = try await meeting(status: .completed, createdAt: old, locked: true)

        let keepForever = MeetingAudioRetentionSweeper(
            paths: paths, store: store, lockStore: lockStore, settings: InMemorySettingsStore())
        let none = await keepForever.sweep(now: now)
        XCTAssertEqual(none, 0)

        let sweeper = MeetingAudioRetentionSweeper(
            paths: paths, store: store, lockStore: lockStore, settings: InMemorySettingsStore(settings))
        let removed = await sweeper.sweep(now: now)
        XCTAssertEqual(removed, 1)

        func audioExists(_ id: UUID) -> Bool {
            fileExists(paths.mediaDirectory(for: id).appendingPathComponent(MeetingSessionFiles.audio))
        }
        XCTAssertFalse(audioExists(eligible))
        XCTAssertTrue(audioExists(recent))
        XCTAssertTrue(audioExists(unfinished), "an unfinished meeting is never swept")
        XCTAssertTrue(audioExists(locked), "a locked session is never swept")
        let row = try await store.fetch(id: eligible)
        XCTAssertNil(row?.mediaRelativePath)
        XCTAssertNotNil(row?.audioRemovedAt)
        XCTAssertEqual(row?.rawTranscript, "kept", "the transcript and notes stay")
    }
}

/// Settings → Meetings: the retention choice is saved onto the freshest settings.
@MainActor
final class MeetingSettingsViewModelTests: XCTestCase {
    func testRetentionChoiceIsSavedWithoutOverwritingOtherSettingsAndTheVADModelDownloads() async {
        let settings = InMemorySettingsStore()
        let model = MeetingSettingsViewModel(voiceActivity: FakeVoiceActivity(stream: nil), settings: settings)
        XCTAssertEqual(model.retention, .keepForever)
        var other = settings.load()
        other.keepDictationAudio = false  // written by another screen after the model loaded
        settings.save(other)
        model.retention = .deleteAfterDays(30)
        XCTAssertEqual(settings.load().meetingAudioRetentionDays, 30)
        XCTAssertFalse(settings.load().keepDictationAudio, "another screen's field survives")
        model.retention = .keepForever
        XCTAssertNil(settings.load().meetingAudioRetentionDays)
        await model.refresh()
        XCTAssertEqual(model.voiceActivityStatus, .notDownloaded)
    }
}
