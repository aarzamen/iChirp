#if DEBUG
import ChirpCore
import ChirpFeatures
import ChirpText
import Foundation

/// DEBUG-only launch argument for the plan 025 corrections tour (`UITests/TranscriptCorrectionsTourUITests`):
/// `-ChirpSeedCorrectionsSample` adds one finished, timed, synthetic transcript ("Synthetic corrections sample") when the
/// Library has none, so the tour needs no speech model. No audio, two speakers, a pause between them. Release builds
/// ignore it.
enum CorrectionsPreviewLaunch {
    static let seedArgument = "-ChirpSeedCorrectionsSample"
    static let fileName = "Synthetic corrections sample.m4a"

    static let parts: [(speaker: String, text: String)] = [
        ("S1", "The patient takes met for men 500 mg twice daily. Blood pressure was 128 over 82 today."),
        ("S2", "Thanks. I will book the follow up visit with Dr. Smyth in two weeks."),
    ]

    static func seedIfRequested(environment: AppEnvironment, arguments: [String] = ProcessInfo.processInfo.arguments)
        async
    {
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
