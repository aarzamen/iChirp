// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingLockFileStore.swift @ bbae9e0e
// Changes: the lock model only (L1–L160). One process on iOS, so `pid`, `finalizationLeaseId`, calendar, meeting-type
// and import fields are gone; `launchId` marks the owning app launch instead of a PID. The captured route is the
// engine descriptor id plus variant; the privacy class is captured too. Schema restarts at 1 for iChirp.

import Foundation

/// The file names inside a meeting's `media/<id>/` folder (`spec/contracts/meeting-session-v1.md`).
public enum MeetingSessionFiles {
    public static let lock = "recording.lock"
    /// 16 kHz mono 16-bit PCM CAF: readable up to the last written buffer after a kill.
    public static let audio = "meeting.caf"
    /// Temporary live-preview chunks.
    public static let chunks = "chunks"
}

/// Where a meeting session is. Stable raw values (they are on disk).
public enum MeetingSessionState: String, Codable, Sendable, Equatable, CaseIterable {
    /// The recorder may still be writing the audio.
    case recording
    /// The audio is closed; the transcript is not saved yet.
    case awaitingTranscription
}

/// `recording.lock`: written before the first audio buffer, removed only after the completed transcript is saved or
/// the person discarded the meeting.
public struct MeetingSessionLock: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Equals the folder name and the meeting's `Transcription.id`.
    public var sessionId: UUID
    public var startedAt: Date
    /// The app launch that owns the session. A lock from another launch is an orphan (iOS runs one app process).
    public var launchId: UUID
    public var displayName: String
    public var state: MeetingSessionState
    /// The final-pass route captured at start: `EngineDescriptor.id` and variant.
    public var speechEngine: String
    public var speechEngineVariant: String?
    public var privacyClass: PrivacyClass
    /// What the person typed while recording. Decoded on its own: a malformed value loses only the notes.
    public var notes: String?

    public init(
        schemaVersion: Int = MeetingSessionLock.currentSchemaVersion,
        sessionId: UUID,
        startedAt: Date,
        launchId: UUID,
        displayName: String,
        state: MeetingSessionState = .recording,
        speechEngine: String,
        speechEngineVariant: String? = nil,
        privacyClass: PrivacyClass = .personal,
        notes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.launchId = launchId
        self.displayName = displayName
        self.state = state
        self.speechEngine = speechEngine
        self.speechEngineVariant = speechEngineVariant
        self.privacyClass = privacyClass
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionId, startedAt, launchId, displayName, state, speechEngine, speechEngineVariant
        case privacyClass, notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        launchId = try container.decode(UUID.self, forKey: .launchId)
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? "Meeting"
        state = (try? container.decodeIfPresent(MeetingSessionState.self, forKey: .state)) ?? .recording
        speechEngine = (try? container.decodeIfPresent(String.self, forKey: .speechEngine)) ?? ""
        speechEngineVariant = (try? container.decodeIfPresent(String.self, forKey: .speechEngineVariant)) ?? nil
        // Unknown or missing: the most protective class, so routing stays on the device.
        privacyClass = (try? container.decodeIfPresent(PrivacyClass.self, forKey: .privacyClass)) ?? .clinical
        notes = (try? container.decodeIfPresent(String.self, forKey: .notes)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(launchId, forKey: .launchId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(state, forKey: .state)
        try container.encode(speechEngine, forKey: .speechEngine)
        try container.encodeIfPresent(speechEngineVariant, forKey: .speechEngineVariant)
        try container.encode(privacyClass, forKey: .privacyClass)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

/// How long meeting audio is kept (M3, Settings → Meetings). Transcripts and notes are never deleted by it.
public enum MeetingAudioRetention: Sendable, Equatable, Hashable {
    /// The default: audio stays until the person deletes the meeting.
    case keepForever
    /// Delete the audio of completed meetings older than this many days (never a locked or unfinished one).
    case deleteAfterDays(Int)

    /// The choices Settings offers.
    public static let choices: [MeetingAudioRetention] = [
        .keepForever, .deleteAfterDays(7), .deleteAfterDays(30), .deleteAfterDays(90),
    ]

    /// `TranscriptionSettings.meetingAudioRetentionDays`: nil (or 0 and below) keeps audio forever.
    public init(days: Int?) {
        if let days, days > 0 {
            self = .deleteAfterDays(days)
        } else {
            self = .keepForever
        }
    }

    public var days: Int? {
        switch self {
        case .keepForever: nil
        case .deleteAfterDays(let days): days
        }
    }
}
