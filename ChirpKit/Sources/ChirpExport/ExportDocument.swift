// Plan 022 Step 6 (plan 017 items 1–2): the page content PDF and Word exports share. Semantics from MacParakeet
// (GPL-3.0) `Sources/MacParakeetCore/Services/ExportService.swift` @ bbae9e0e (`buildRichTranscript`: title, metadata
// lines, then the transcript with speakers and timestamps); fresh for iOS, where upstream's AppKit text system and
// `NSAttributedString.DocumentType.officeOpenXML` do not exist.

import ChirpCore
import ChirpText
import Foundation

/// One label–value line under a document's title ("Date", "Duration", "Speakers").
public struct ExportMetadataLine: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// What a PDF or Word export contains, independent of the format: a title, metadata lines and blocks of text.
public struct ExportDocument: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        /// Level 1 or 2.
        case heading(String, level: Int)
        case paragraph(String)
        /// A transcript paragraph: who spoke (when the item has speakers) and when, then the words.
        case turn(speaker: String?, timestamp: String?, text: String)
        case bullet(String)
        /// A numbered list item, keeping the number the text had.
        case numbered(Int, String)
    }

    public var title: String
    public var metadata: [ExportMetadataLine]
    public var blocks: [Block]
    /// A quiet line after the content ("Made with Parakeet").
    public var footer: String?

    public init(title: String, metadata: [ExportMetadataLine] = [], blocks: [Block], footer: String? = nil) {
        self.title = title
        self.metadata = metadata
        self.blocks = blocks
        self.footer = footer
    }

    public static let defaultFooter = "Made with Parakeet on iPhone"
}

extension ExportDocument {
    /// A transcript, document or text item: title, its facts, then its paragraphs. With word timings each paragraph
    /// carries its start time and, when the item has speakers, the speaker's name (repeated only when it changes);
    /// without timings the text's own paragraphs follow. Every word is kept: nothing is cut.
    ///
    /// `effectivePrivacyClass` is the class the privacy rules use for the item (plan 022 review M5: its own class
    /// raised by its documents', `EffectivePrivacyClass`); the file says "Privacy: Clinical" when it or the row's own
    /// class is clinical. Nil uses the row's own class.
    public static func transcript(
        _ transcription: Transcription,
        cleanupMode: CleanupMode,
        effectivePrivacyClass: PrivacyClass? = nil,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> ExportDocument {
        var metadata: [ExportMetadataLine] = [
            ExportMetadataLine(
                "Date",
                transcription.createdAt.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar)))
        ]
        if let durationMs = transcription.durationMs, durationMs > 0 {
            metadata.append(
                ExportMetadataLine("Duration", TranscriptPromptFormatter.timestamp(milliseconds: durationMs)))
        }
        if let speakers = transcription.speakers, speakers.count > 1 {
            metadata.append(ExportMetadataLine("Speakers", speakers.map(\.label).joined(separator: ", ")))
        }
        if let link = transcription.sourceURL {
            metadata.append(ExportMetadataLine("Source", link))
        }
        if transcription.privacyClass.stricter(effectivePrivacyClass) == .clinical {
            metadata.append(ExportMetadataLine("Privacy", "Clinical: contains patient information"))
        }

        var blocks: [Block] = []
        if let words = transcription.wordTimestamps, !words.isEmpty {
            let roster = Dictionary(
                (transcription.speakers ?? []).map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
            var lastSpeaker: String?
            for paragraph in TranscriptParagraphBuilder.build(from: words) {
                let speaker = paragraph.speakerId.flatMap { roster[$0] ?? $0 }
                let shown = roster.isEmpty || speaker == lastSpeaker ? nil : speaker
                lastSpeaker = speaker
                blocks.append(
                    .turn(
                        speaker: shown,
                        timestamp: TranscriptPromptFormatter.timestamp(milliseconds: paragraph.startMs),
                        text: paragraph.text))
            }
        } else {
            let text: String
            switch cleanupMode {
            case .raw: text = transcription.rawTranscript ?? transcription.cleanTranscript ?? ""
            case .clean: text = transcription.displayText
            }
            blocks = paragraphs(of: text).map { .paragraph($0) }
        }
        return ExportDocument(
            title: transcription.displayTitle, metadata: metadata, blocks: blocks, footer: defaultFooter)
    }

    /// A generated document (or any Markdown-like text): `#` and `##` lines become headings, `-`, `*` and `•` lines
    /// bullets, `1.` lines numbered items; bold and code markers are dropped; everything else is kept as written.
    public static func text(
        title: String,
        body: String,
        metadata: [ExportMetadataLine] = [],
        footer: String? = defaultFooter
    ) -> ExportDocument {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let heading = headingText(line) {
                flush()
                // A heading that repeats the title (templates often start with it) is not shown twice.
                if !(blocks.isEmpty && heading.text.caseInsensitiveCompare(title) == .orderedSame) {
                    blocks.append(.heading(clean(heading.text), level: heading.level))
                }
            } else if let bullet = bulletText(line) {
                flush()
                blocks.append(.bullet(clean(bullet)))
            } else if let numbered = numberedText(line) {
                flush()
                blocks.append(.numbered(numbered.number, clean(numbered.text)))
            } else {
                paragraph.append(clean(line))
            }
        }
        flush()
        return ExportDocument(title: title, metadata: metadata, blocks: blocks, footer: footer)
    }

    /// Every character of the document's text, in reading order (for tests and plain-text checks).
    public var plainText: String {
        var parts = [title] + metadata.map { "\($0.label): \($0.value)" }
        for block in blocks {
            switch block {
            case .heading(let text, _), .paragraph(let text), .bullet(let text): parts.append(text)
            case .turn(let speaker, let timestamp, let text):
                parts.append([speaker, timestamp.map { "[\($0)]" }, text].compactMap { $0 }.joined(separator: " "))
            case .numbered(let number, let text): parts.append("\(number). \(text)")
            }
        }
        if let footer { parts.append(footer) }
        return parts.joined(separator: "\n")
    }

    // MARK: - Parsing

    static func paragraphs(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func headingText(_ line: String) -> (text: String, level: Int)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        guard hashes <= 6, !text.isEmpty else { return nil }
        return (text, hashes <= 1 ? 1 : 2)
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let text = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func numberedText(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }

    /// Drops Markdown emphasis and code markers; the words stay.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
    }
}
