#if DEBUG
import ChirpCore
import ChirpFeatures
import ChirpText
import Foundation

/// DEBUG-only launch argument for the plan 025 corrections tour (`UITests/TranscriptCorrectionsTourUITests`):
/// `-ChirpSeedCorrectionsSample` adds one finished, timed, synthetic transcript ("Synthetic corrections sample") when the
/// Library has none, so the tour needs no speech model. No audio, two speakers, a pause between them. Release builds
/// ignore it. Plan 025 Part B: `-ChirpSeedClinicalFindSample` adds the same words as a Clinical item ("Synthetic clinical
/// find sample") for the find tour's rule offer with its clinical note.
enum CorrectionsPreviewLaunch {
    static let seedArgument = "-ChirpSeedCorrectionsSample"
    static let fileName = "Synthetic corrections sample.m4a"
    static let clinicalSeedArgument = "-ChirpSeedClinicalFindSample"
    static let clinicalFileName = "Synthetic clinical find sample.m4a"
    static let clinicalTitle = "Synthetic clinical find sample"

    static let parts: [(speaker: String, text: String)] = [
        ("S1", "The patient takes met for men 500 mg twice daily. Blood pressure was 128 over 82 today."),
        ("S2", "Thanks. I will book the follow up visit with Dr. Smyth in two weeks."),
    ]

    static func seedIfRequested(environment: AppEnvironment, arguments: [String] = ProcessInfo.processInfo.arguments)
        async
    {
        if arguments.contains(clinicalSeedArgument) { await seedClinical(environment: environment) }
        guard arguments.contains(seedArgument) else { return }
        let rows = (try? await environment.store.fetchAll()) ?? []
        if let existing = rows.first(where: { $0.fileName == fileName }) {
            // A tour stopped half way: put the sample's words back as heard (through the one writer), so the tour
            // starts from the same state. The row and its words are kept.
            _ = try? await TranscriptCorrectionService(store: environment.store, context: { .none })
                .revertAll(existing.id)
            return
        }
        try? await environment.store.insert(sample())
    }

    /// The clinical copy of the sample (its own id, file name and title), back as heard when it is already there.
    private static func seedClinical(environment: AppEnvironment) async {
        let rows = (try? await environment.store.fetchAll()) ?? []
        if let existing = rows.first(where: { $0.fileName == clinicalFileName }) {
            _ = try? await TranscriptCorrectionService(store: environment.store, context: { .none })
                .revertAll(existing.id)
            return
        }
        var clinical = sample()
        clinical.id = UUID()
        clinical.fileName = clinicalFileName
        clinical.titleOverride = clinicalTitle
        clinical.privacyClass = .clinical
        try? await environment.store.insert(clinical)
    }

    static func sample() -> Transcription {
        var words: [WordTimestamp] = []
        var clock = 0
        for (index, part) in parts.enumerated() {
            if index > 0 { clock += 3_000 }
            for word in part.text.split(separator: " ") {
                words.append(
                    WordTimestamp(
                        word: String(word), startMs: clock, endMs: clock + 320, confidence: 0.9,
                        speakerId: part.speaker))
                clock += 360
            }
        }
        var row = Transcription(
            sourceType: .file, fileName: fileName, durationMs: clock, status: .completed, privacyClass: .personal)
        row.rawTranscript = words.map(\.word).joined(separator: " ")
        row.wordTimestamps = words
        row.speakers = [SpeakerInfo(id: "S1", label: "Speaker 1"), SpeakerInfo(id: "S2", label: "Speaker 2")]
        row.speakerCount = 2
        row.engine = "fluidaudio.parakeet-tdt"
        row.engineVariant = "v3"
        row.derivedTitle = TitleDeriver.derive(from: row.rawTranscript) ?? ""
        row.derivedSnippet = SnippetDeriver.derive(from: row.rawTranscript, excluding: row.derivedTitle) ?? ""
        let segments = FileTranscriptSegments.materialize(words: words, speakers: row.speakers)
        row.transcriptSegments = segments.isEmpty ? nil : segments
        return row
    }
}
#endif
