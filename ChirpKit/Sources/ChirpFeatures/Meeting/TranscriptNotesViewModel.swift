import ChirpCore
import Foundation
import Observation

/// The Transcript's Notes tab (M3): the person's notes and the speaker names of one transcript.
///
/// Both are field-level writes (`updateUserNotes`, `renameSpeaker`), so a final pass finishing meanwhile never loses
/// them and they never overwrite its transcript. Renaming updates the speaker list and every paragraph label, so the
/// Transcript tab shows the new names at once.
///
/// The notes save as you type (UX audit F59): an edit is written `autosaveDelay` after the last keystroke, and
/// `flush()` writes at once (Done, the sheet going away). Writes run one after another, each with the text as it is
/// when it runs, so the last one always holds the newest text.
@MainActor @Observable public final class TranscriptNotesViewModel {
    public private(set) var transcription: Transcription?
    /// The editor's text. Saved `autosaveDelay` after the last change, or at once by `flush()` / `save()`.
    public var notes = "" {
        didSet { if hasLoaded, notes != oldValue { scheduleAutosave() } }
    }
    public private(set) var isSaving = false
    public private(set) var lastError: String?
    public private(set) var hasLoaded = false

    /// The speakers in order of first speech, with their current names.
    public var speakers: [SpeakerInfo] { transcription?.speakers ?? [] }
    /// The notes differ from what is stored.
    public var hasUnsavedNotes: Bool { MeetingCoordinator.storedNotes(notes) != transcription?.userNotes }

    @ObservationIgnored private let id: UUID
    @ObservationIgnored private let store: any TranscriptionStoring
    @ObservationIgnored private let autosaveDelay: Duration
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// The newest write; the next one waits for it, so writes land in order.
    @ObservationIgnored private var lastWrite: Task<Bool, Never>?

    /// - Parameter autosaveDelay: how long after the last keystroke the notes are written.
    public init(id: UUID, store: any TranscriptionStoring, autosaveDelay: Duration = .milliseconds(800)) {
        self.id = id
        self.store = store
        self.autosaveDelay = autosaveDelay
    }

    isolated deinit {
        autosaveTask?.cancel()
    }

    public func load() async {
        do {
            transcription = try await store.fetch(id: id)
            notes = transcription?.userNotes ?? ""
            lastError = nil
        } catch {
            lastError = "The notes could not be read: \(error.localizedDescription)"
        }
        hasLoaded = true
    }

    /// Writes any unsaved notes now and cancels a pending autosave. Returns whether the notes are stored.
    @discardableResult
    public func flush() async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        await lastWrite?.value
        guard hasUnsavedNotes else { return true }
        return await save()
    }

    /// Saves the notes (blank clears them) after any write still running. Returns whether they are stored.
    @discardableResult
    public func save() async -> Bool {
        let previous = lastWrite
        let write = Task { () -> Bool in
            await previous?.value
            return await self.write()
        }
        lastWrite = write
        return await write.value
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.hasUnsavedNotes else { return }
            await self.save()
        }
    }

    /// One write of the notes as they are now.
    private func write() async -> Bool {
        let value = MeetingCoordinator.storedNotes(notes)
        isSaving = true
        defer { isSaving = false }
        do {
            guard let updated = try await store.updateUserNotes(id: id, userNotes: value) else {
                lastError = "This transcript no longer exists."
                return false
            }
            transcription = updated
            lastError = nil
            return true
        } catch {
            lastError = "The notes could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    /// Renames one speaker everywhere in this transcript. A blank name is refused (nothing changes).
    @discardableResult
    public func rename(speakerId: String, to name: String) async -> Bool {
        guard Transcription.speakerName(name) != nil else { return false }
        do {
            guard let updated = try await store.renameSpeaker(id: id, speakerId: speakerId, to: name) else {
                return false
            }
            // Keep the editor's unsaved text; take everything else from the stored row.
            transcription = updated
            lastError = nil
            return true
        } catch {
            lastError = "The name could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    public func dismissError() { lastError = nil }

    /// The person chose to close without saving (after a failed write): the editor goes back to the stored notes and
    /// nothing more is written.
    public func discardUnsavedNotes() {
        autosaveTask?.cancel()
        autosaveTask = nil
        notes = transcription?.userNotes ?? ""
    }
}
