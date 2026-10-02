// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/ExportService.swift @ bbae9e0e
// Changes: collapsed upstream's `ExportServiceProtocol`/`ExportService` (TXT, Markdown, SRT, VTT, DAPT,
// JSON, PDF, DOCX, `TranscriptExportOptions`, speaker-correction projections) to the M0/M1 surface
// pinned by the implementation plan: five formats (txt, markdown, srt, vtt, json), no options struct,
// no PDF/DOCX (AppKit-only, out of scope for iOS), no DAPT, no speaker-correction projection. JSON is
// a new `ichirp.transcript/v1` schema, not a raw `Transcription` encode. SRT/VTT throw
// `ExportError.noTimestamps` instead of upstream's single-cue, full-duration fallback.

import ChirpCore
import ChirpText
import Foundation

/// A file format `TranscriptExporter` can render a transcription into.
public enum ExportFormat: String, CaseIterable, Sendable {
    case txt, markdown, srt, vtt, json

    public var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .json: return "json"
        }
    }

    public var displayName: String {
        switch self {
        case .txt: return "Text"
        case .markdown: return "Markdown"
        case .srt: return "SRT"
        case .vtt: return "VTT"
        case .json: return "JSON"
        }
    }
}

/// Errors `TranscriptExporter` can throw while rendering a transcription.
public enum ExportError: Error, Sendable, Equatable {
    /// SRT/VTT need word-level timestamps to build cues; the transcription has none.
    case noTimestamps
}

/// Renders a `Transcription` into TXT, Markdown, SRT, VTT, or JSON, and can write the result to disk.
public struct TranscriptExporter: Sendable {
    private let cleanupMode: CleanupMode
    private let effectivePrivacyClass: PrivacyClass?
    private let context: TranscriptTextContext

    /// `effectivePrivacyClass` is the class the privacy rules use for the item (`EffectivePrivacyClass`: its own class
    /// raised by its documents'), as `ExportDocument.transcript` takes it; nil uses the row's own class. It is never
    /// lower than the row's own. A clinical item's TXT, Markdown and WebVTT files carry
    /// `ExportDocument.clinicalPrivacyLine` and its JSON says `"privacyClass": "clinical"` (review R1-13).
    /// `context` is the person's clean-up rules, which a Clean export of a corrected transcript runs (plan 025 R4).
    public init(
        cleanupMode: CleanupMode, effectivePrivacyClass: PrivacyClass? = nil, context: TranscriptTextContext = .none
    ) {
        self.cleanupMode = cleanupMode
        self.effectivePrivacyClass = effectivePrivacyClass
        self.context = context
    }

    /// Renders `transcription` as `format`. Throws `ExportError.noTimestamps` for `.srt`/`.vtt` when
    /// the transcription has no word timestamps to build cues from.
    public func render(_ transcription: Transcription, as format: ExportFormat) throws -> String {
        switch format {
        case .txt:
            return renderPlainText(transcription)
        case .markdown:
            return renderMarkdown(transcription)
        case .srt:
            return try renderSRT(transcription)
        case .vtt:
            return try renderVTT(transcription)
        case .json:
            return try renderJSON(transcription)
        }
    }

    /// Renders `transcription` as `format` and writes it to `directory`, named after the
    /// transcription's `displayTitle` (`ExportFileName`, "transcript" when nothing is left) plus the format's
    /// extension. Returns the written file's URL.
    public func write(_ transcription: Transcription, as format: ExportFormat, to directory: URL) throws -> URL {
        let content = try render(transcription, as: format)
        let stem = ExportFileName.stem(fromTitle: transcription.displayTitle, fallback: "transcript")
        let url = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Text

    /// The text the person sees in the current clean-up mode (`Transcription.text(.shown(cleanupMode))`, plan 024
    /// Task 8): TXT, Markdown, PDF and Word print its lines (reading paragraphs with their speakers), JSON's `text` is
    /// its whole text, the same text Copy writes. So a Clean export of a timed transcript carries the clean text, custom
    /// words included (review R1-3, ADR-009). SRT, VTT and JSON's `segments` stay the words as heard, with the
    /// person's corrections (plan 025); JSON's `words` are the engine's words.
    private func shown(_ transcription: Transcription) -> TranscriptText {
        transcription.text(.shown(cleanupMode), context: context)
    }

    // MARK: - Privacy

    /// The class the privacy rules use: the row's own, raised (never lowered) by the caller's effective class.
    private func privacyClass(of transcription: Transcription) -> PrivacyClass {
        transcription.privacyClass.stricter(effectivePrivacyClass)
    }

    /// The header line a clinical item's text exports start with ("Privacy: Clinical: contains patient
    /// information", the line PDF and Word show); nil for any other class.
    private func clinicalHeader(_ transcription: Transcription) -> String? {
        guard privacyClass(of: transcription) == .clinical else { return nil }
        let line = ExportDocument.clinicalPrivacyLine
        return "\(line.label): \(line.value)"
    }

    // MARK: - TXT

    private func renderPlainText(_ transcription: Transcription) -> String {
        let header = clinicalHeader(transcription).map { [$0, ""] } ?? []
        let text = shown(transcription)
        guard text.hasWordTimings else {
            guard let line = header.first else { return text.plainText }
            return text.plainText.isEmpty ? line : line + "\n\n" + text.plainText
        }

        var lines: [String] = header
        for (index, line) in text.lines.enumerated() {
            if lines.count > header.count { lines.append("") }
            if let label = Self.newSpeaker(at: index, in: text.lines) {
                lines.append("\(label):")
            }
            lines.append(line.text)
        }
        return lines.joined(separator: "\n")
    }

    /// The line's speaker name when it starts a turn (the first line, or a different speaker than the line before);
    /// nil without real speakers.
    private static func newSpeaker(at index: Int, in lines: [TranscriptTextLine]) -> String? {
        guard let label = lines[index].speakerLabel else { return nil }
        return index == 0 || lines[index].speakerId != lines[index - 1].speakerId ? label : nil
    }

    // MARK: - Markdown

    private func renderMarkdown(_ transcription: Transcription) -> String {
        let top = ["# \(transcription.displayTitle)", ""] + (clinicalHeader(transcription).map { [$0, ""] } ?? [])
        let text = shown(transcription)
        guard text.hasWordTimings else {
            var lines = top
            if !text.plainText.isEmpty {
                lines.append(text.plainText)
            }
            return lines.joined(separator: "\n")
        }

        var lines: [String] = top
        for (index, line) in text.lines.enumerated() {
            if let label = Self.newSpeaker(at: index, in: text.lines) {
                lines.append("**\(label)**")
                lines.append("")
            }
            lines.append(line.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - SRT / VTT

    private func renderSRT(_ transcription: Transcription) throws -> String {
        let cues = try subtitleCues(for: transcription)
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(Self.srtTimestamp(ms: cue.startMs)) --> \(Self.srtTimestamp(ms: cue.endMs))")
            if let label = speakerLabel(for: cue.speakerId, in: transcription.speakers) {
                lines.append("\(Self.singleLine(label)): \(cue.text)")
            } else {
                lines.append(cue.text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func renderVTT(_ transcription: Transcription) throws -> String {
        let cues = try subtitleCues(for: transcription)
        var lines: [String] = ["WEBVTT", ""]
        // A WebVTT NOTE block is a comment players never show. SRT has no comment syntax, so it carries no marker.
        if let header = clinicalHeader(transcription) {
            lines += ["NOTE \(header)", ""]
        }
        for cue in cues {
            lines.append("\(Self.vttTimestamp(ms: cue.startMs)) --> \(Self.vttTimestamp(ms: cue.endMs))")
            let text = Self.vttEscaped(Self.singleLine(cue.text))
            if let label = speakerLabel(for: cue.speakerId, in: transcription.speakers) {
                lines.append("<v \(Self.vttEscaped(Self.singleLine(label)))>\(text)</v>")
            } else {
                lines.append(text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// WebVTT cue text escapes (review R1-8): "<" opens a tag (followed by a digit, a timestamp tag that runs to the
    /// next ">", so "<5 mg" vanished in conforming players), ">" closes the voice annotation early (a speaker renamed
    /// "A>B"), and "&" starts an escape. The words come back unchanged when a player reads the file.
    private static func vttEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A cue line never holds a line break: a renamed speaker's label (or a word) with one would end the cue line,
    /// and a blank line ends the cue. Each run of line breaks becomes one space.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// Cues from the words as heard (the word stream, `TranscriptCueBuilder.build(from: Transcription)`).
    private func subtitleCues(for transcription: Transcription) throws -> [TranscriptCue] {
        let cues = TranscriptCueBuilder.build(from: transcription)
        guard !cues.isEmpty else { throw ExportError.noTimestamps }
        return cues
    }

    /// SRT format: 00:01:23,456
    private static func srtTimestamp(ms: Int) -> String {
        let ms = max(0, ms)
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1_000
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    /// VTT format: 00:01:23.456
    private static func vttTimestamp(ms: Int) -> String {
        let ms = max(0, ms)
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1_000
        let millis = ms % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }

    // MARK: - JSON

    /// `ichirp.transcript/v1`: a stable, portable JSON projection of a transcription — not a raw
    /// `Transcription` encode, so the on-disk export shape stays independent of the row's persisted
    /// column shape. `speakers`, `segments` and `words` are always arrays, empty when the item has none (the
    /// contract types them as arrays; review R1-4); `privacyClass` is the effective class (review R1-13, an additive
    /// key).
    private struct ExportedTranscript: Encodable {
        let schema: String
        let id: UUID
        let title: String
        let createdAt: Date
        let durationMs: Int?
        let engine: String?
        let engineVariant: String?
        let language: String?
        let text: String
        let privacyClass: PrivacyClass
        let speakers: [SpeakerInfo]
        let segments: [TranscriptSegmentRecord]
        let words: [WordTimestamp]
        /// Plan 025: the person's corrections; omitted when there are none, so an uncorrected export is unchanged.
        let corrections: [ExportedCorrection]?
    }

    /// One correction in the JSON export (spec/contracts/transcript-json-v1.md): the engine's words it replaced
    /// (`wordRange` into `words`, `heard`), its text, its time envelope and where it came from.
    private struct ExportedCorrection: Encodable {
        let id: UUID
        let wordRange: TranscriptSegmentWordRange
        let heard: String
        let text: String
        let startMs: Int
        let endMs: Int
        let origin: String
    }

    private func renderJSON(_ transcription: Transcription) throws -> String {
        let heard = transcription.text(.heard, context: context)
        let corrections = heard.edits.compactMap { edit -> ExportedCorrection? in
            guard let token = heard.tokens.first(where: { $0.editID == edit.id }) else { return nil }
            return ExportedCorrection(
                id: edit.id, wordRange: edit.wordRange, heard: edit.heard, text: edit.text, startMs: token.startMs,
                endMs: token.endMs, origin: edit.origin.rawValue)
        }
        let exported = ExportedTranscript(
            schema: "ichirp.transcript/v1",
            id: transcription.id,
            title: transcription.displayTitle,
            createdAt: transcription.createdAt,
            durationMs: transcription.durationMs,
            engine: transcription.engine,
            engineVariant: transcription.engineVariant,
            language: transcription.language,
            text: transcription.plainText(.shown(cleanupMode), context: context),
            privacyClass: privacyClass(of: transcription),
            speakers: transcription.speakers ?? [],
            // The segments as heard, with the person's corrections (merged and marked `isTextEdited` where corrected;
            // the stored segments when there are none), and the engine's words: the evidence as heard, never rewritten
            // (spec/contracts/transcript-json-v1.md, transcript-corrections-v1.md).
            segments: heard.segments ?? [],
            words: transcription.wordTimestamps ?? [],
            corrections: corrections.isEmpty ? nil : corrections
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(exported)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Speaker labels

    private func speakerLabel(for speakerId: String?, in speakers: [SpeakerInfo]?) -> String? {
        guard let speakerId, let speakers, !speakers.isEmpty else { return nil }
        return speakers.first(where: { $0.id == speakerId })?.label ?? speakerId
    }
}
