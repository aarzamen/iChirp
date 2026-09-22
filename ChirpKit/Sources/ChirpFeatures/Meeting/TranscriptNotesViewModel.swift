import ChirpCore
import Foundation
import Observation

/// The Transcript's Notes tab (M3): the person's notes and the speaker names of one transcript.
///
/// Both are field-level writes (`updateUserNotes`, `renameSpeaker`), so a final pass finishing meanwhile never loses
/// them and they never overwrite its transcript. Renaming updates the speaker list and every paragraph label, so the
/// Transcript tab shows the new names at once.
@MainActor @Observable public final class TranscriptNotesViewModel {
    public private(set) var transcription: Transcription?
    /// The editor's text. `save()` writes it; nothing is written while the person types.
    public var notes = ""
    public private(set) var isSaving = false
    public private(set) var lastError: String?
    public private(set) var hasLoaded = false

    /// The speakers in order of first speech, with their current names.
    public var speakers: [SpeakerInfo] { transcription?.speakers ?? [] }
    /// The notes differ from what is stored.
    public var hasUnsavedNotes: Bool { MeetingCoordinator.storedNotes(notes) != transcription?.userNotes }

    @ObservationIgnored private let id: UUID
    @ObservationIgnored private let store: any TranscriptionStoring

    public init(id: UUID, store: any TranscriptionStoring) {
        self.id = id
        self.store = store
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

    /// Saves the notes (blank clears them). Returns whether they are stored.
    @discardableResult
    public func save() async -> Bool {
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
}
