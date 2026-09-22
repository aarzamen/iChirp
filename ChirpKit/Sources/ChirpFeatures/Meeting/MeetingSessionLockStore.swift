// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingLockFileStore.swift @ bbae9e0e
// Changes: write (atomic), read (newer schema is opaque, malformed JSON reads as nil), delete and orphan discovery
// (L363–L600). iOS has one app process, so ownership is the launch id instead of a PID liveness check, and there are
// no finalization leases or ownership mutex. Discovery walks `media/*/recording.lock` (the folder is the meeting's
// row id) instead of a separate `meeting-recordings/` root.

import ChirpCore
import Foundation

/// Reads and writes a meeting folder's `recording.lock` (`spec/contracts/meeting-session-v1.md`).
///
/// One store per app launch: its `launchId` is stamped into every lock it writes, and `discoverOrphans` returns only
/// locks from other launches, so the meeting this launch is recording or finishing is never offered for recovery.
public struct MeetingSessionLockStore: Sendable {
    public let paths: AppPaths
    public let launchId: UUID

    public init(paths: AppPaths, launchId: UUID = UUID()) {
        self.paths = paths
        self.launchId = launchId
    }

    public func folder(for sessionId: UUID) -> URL {
        paths.mediaDirectory(for: sessionId)
    }

    public func lockURL(for sessionId: UUID) -> URL {
        folder(for: sessionId).appendingPathComponent(MeetingSessionFiles.lock, isDirectory: false)
    }

    /// Writes the lock atomically (a temporary file renamed over the old one), creating the folder if needed.
    public func write(_ lock: MeetingSessionLock) throws {
        let folder = folder(for: lock.sessionId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(lock)
        try data.write(to: lockURL(for: lock.sessionId), options: .atomic)
    }

    /// The lock, or nil when there is none, it cannot be decoded, or a newer build wrote it (opaque to this one).
    public func read(sessionId: UUID) -> MeetingSessionLock? {
        let url = lockURL(for: sessionId)
        guard let data = try? Data(contentsOf: url),
            let lock = try? Self.decoder.decode(MeetingSessionLock.self, from: data),
            lock.schemaVersion <= MeetingSessionLock.currentSchemaVersion
        else {
            return nil
        }
        return lock
    }

    /// Whether any file named `recording.lock` is in the session folder, readable or not (the retention barrier).
    public func hasLockFile(sessionId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: lockURL(for: sessionId).path)
    }

    /// Removes the lock (settlement after a completed save, or a confirmed discard). Missing is fine.
    public func delete(sessionId: UUID) throws {
        let url = lockURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Updates the stored lock with `change` (read, change, atomic write). Returns the new lock, or nil when there is
    /// no readable lock (nothing is written then).
    @discardableResult
    public func update(sessionId: UUID, _ change: (inout MeetingSessionLock) -> Void) throws -> MeetingSessionLock? {
        guard var lock = read(sessionId: sessionId) else { return nil }
        change(&lock)
        try write(lock)
        return lock
    }

    /// Readable locks written by another launch, oldest first: meetings a killed or crashed process left behind.
    public func discoverOrphans() -> [MeetingSessionLock] {
        let mediaRoot = paths.root.appendingPathComponent("media", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mediaRoot.path) else { return [] }
        return names.compactMap { name -> MeetingSessionLock? in
            guard let id = UUID(uuidString: name), let lock = read(sessionId: id),
                lock.sessionId == id, lock.launchId != launchId
            else { return nil }
            return lock
        }
        .sorted { ($0.startedAt, $0.sessionId.uuidString) < ($1.startedAt, $1.sessionId.uuidString) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
