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

    public init(cleanupMode: CleanupMode) {
        self.cleanupMode = cleanupMode
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
    /// transcription's sanitized `displayTitle` plus the format's extension. Returns the written file's
    /// URL.
    public func write(_ transcription: Transcription, as format: ExportFormat, to directory: URL) throws -> URL {
        let content = try render(transcription, as: format)
        let stem = Self.sanitizedExportStem(fromTitle: transcription.displayTitle)
        let url = directory.appendingPathComponent("\(stem).\(format.fileExtension)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Sanitizes a display title for use as an export file stem: replaces disallowed characters
    /// (`/:\␀`) with spaces and trims, falling back to `"transcript"` when the result is empty.
    ///
    /// This is deliberately **not** `TranscriptSegmenter.sanitizedExportStem(from:)` (ChirpText):
    /// that helper expects a real file name and calls `.deletingPathExtension` to strip a trailing
    /// extension before sanitizing. `Transcription.displayTitle` is already extension-stripped (or
    /// has no file extension at all — it may be a user-entered title), so running it through
    /// `.deletingPathExtension` again corrupts any title that merely *looks* like it ends in an
    /// extension: `"Client Q&A v2.1"` would lose its `.1` and become `"Client Q&A v2"`. This helper
    /// only replaces disallowed characters — it never touches a trailing `.something`.
    private static func sanitizedExportStem(fromTitle title: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\\0")
        let parts = title.components(separatedBy: disallowed)
        let normalized = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "transcript" : normalized
    }

    // MARK: - Text used when there is nothing timed to build from

    /// The whole-transcript text used by TXT/Markdown when there are no word timestamps to build
    /// paragraphs from, and by JSON's `text` field. When `wordTimestamps` is non-empty, TXT/Markdown
    /// build their paragraphs from the words instead — this text is not consulted in that case, and
    /// `cleanupMode` has no effect on the word-derived path (words are the engine's literal output
    /// regardless of cleanup mode).
    ///
    /// The fallback rule matches the app's Raw/Clean product default (Raw shows the engine's literal
    /// output; Clean shows the deterministically cleaned copy) rather than always preferring whichever
    /// transcript happens to be non-empty:
    /// - `.raw`: `rawTranscript`, falling back to `cleanTranscript` only if raw is absent (a
    ///   transcription should always have a raw transcript once completed; the clean fallback covers
    ///   an unexpected gap rather than ever being the intended path).
    /// - `.clean`: `transcription.displayText` — the non-empty `cleanTranscript` if there is one, else
    ///   `rawTranscript`. So `.clean` on a transcription whose `cleanTranscript` is nil or blank still
    ///   exports the raw text, it does not produce an empty export.
    private func preferredText(_ transcription: Transcription) -> String {
        switch cleanupMode {
        case .raw:
            return transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
        case .clean:
            return transcription.displayText
        }
    }

    // MARK: - TXT

    private func renderPlainText(_ transcription: Transcription) -> String {
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            return preferredText(transcription)
        }

        let paragraphs = TranscriptParagraphBuilder.build(from: words)
        var lines: [String] = []
        var lastSpeakerId: String?
        for (index, paragraph) in paragraphs.enumerated() {
            if !lines.isEmpty { lines.append("") }
            if let label = speakerLabel(for: paragraph.speakerId, in: transcription.speakers),
                index == 0 || paragraph.speakerId != lastSpeakerId
            {
                lines.append("\(label):")
            }
            lastSpeakerId = paragraph.speakerId
            lines.append(paragraph.text)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown

    private func renderMarkdown(_ transcription: Transcription) -> String {
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            var lines = ["# \(transcription.displayTitle)", ""]
            let text = preferredText(transcription)
            if !text.isEmpty {
                lines.append(text)
            }
            return lines.joined(separator: "\n")
        }

        let paragraphs = TranscriptParagraphBuilder.build(from: words)
        var lines: [String] = ["# \(transcription.displayTitle)", ""]
        var lastSpeakerId: String?
        for (index, paragraph) in paragraphs.enumerated() {
            if let label = speakerLabel(for: paragraph.speakerId, in: transcription.speakers),
                index == 0 || paragraph.speakerId != lastSpeakerId
            {
                lines.append("**\(label)**")
                lines.append("")
            }
            lastSpeakerId = paragraph.speakerId
            lines.append(paragraph.text)
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
                lines.append("\(label): \(cue.text)")
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
        for cue in cues {
            lines.append("\(Self.vttTimestamp(ms: cue.startMs)) --> \(Self.vttTimestamp(ms: cue.endMs))")
            if let label = speakerLabel(for: cue.speakerId, in: transcription.speakers) {
                lines.append("<v \(label)>\(cue.text)</v>")
            } else {
                lines.append(cue.text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func subtitleCues(for transcription: Transcription) throws -> [TranscriptCue] {
        guard let words = transcription.wordTimestamps, !words.isEmpty else {
            throw ExportError.noTimestamps
        }
        return TranscriptCueBuilder.build(from: words)
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
    /// column shape.
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
        let speakers: [SpeakerInfo]?
        let segments: [TranscriptSegmentRecord]?
        let words: [WordTimestamp]?
    }

    private func renderJSON(_ transcription: Transcription) throws -> String {
        let exported = ExportedTranscript(
            schema: "ichirp.transcript/v1",
            id: transcription.id,
            title: transcription.displayTitle,
            createdAt: transcription.createdAt,
            durationMs: transcription.durationMs,
            engine: transcription.engine,
            engineVariant: transcription.engineVariant,
            language: transcription.language,
            text: preferredText(transcription),
            speakers: transcription.speakers,
            segments: transcription.transcriptSegments,
            words: transcription.wordTimestamps
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
