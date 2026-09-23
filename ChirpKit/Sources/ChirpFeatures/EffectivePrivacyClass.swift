import ChirpCore
import Foundation

/// **The one rule for how private a transcript's content is** when it is about to leave the phone: the stricter of the
/// transcript's own class and the class of every deliverable made from it. A personal dictation that already has a
/// clinical SOAP note counts as clinical, because the app itself holds that clinical signal (review L4 M1).
///
/// Every router that sends a transcript's content reads it here, as stored at that moment: `DeliverableService`
/// (Transform and Ask), `DecisionService` (Jev) and `VoicePlayer`'s class provider (Listen, spoken Ask answers).
/// Lowering the transcript's class does not lower this while a stricter deliverable exists (deliverables are never
/// lowered; `DeliverableService.setPrivacyClass`).
public enum EffectivePrivacyClass {
    /// The stricter of `transcription.privacyClass` and each of `deliverables`' classes.
    public static func of(_ transcription: Transcription, deliverables: [Deliverable]) -> PrivacyClass {
        deliverables.reduce(transcription.privacyClass) { $0.stricter($1.privacyClass) }
    }

    /// `of(_:deliverables:)` with the transcript's deliverables as stored now.
    public static func of(_ transcription: Transcription, in store: any DeliverableStoring) async throws
        -> PrivacyClass
    {
        of(transcription, deliverables: try await store.fetchDeliverables(transcriptionID: transcription.id))
    }

    /// The transcript's effective class as stored now, or nil when the transcript no longer exists.
    public static func current(
        transcriptionID: UUID,
        transcripts: any TranscriptionStoring,
        deliverables: any DeliverableStoring
    ) async throws -> PrivacyClass? {
        guard let transcription = try await transcripts.fetch(id: transcriptionID) else { return nil }
        return try await of(transcription, in: deliverables)
    }
}
