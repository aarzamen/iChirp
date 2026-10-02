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
        /// A bulleted list item; `level` is its nesting depth (0 = top level), drawn one indent step further per level.
        case bullet(String, level: Int = 0)
        /// A numbered list item; `marker` is its number and delimiter exactly as the text had them ("2.", "2)", "07.").
        case numbered(marker: String, text: String, level: Int = 0)
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

    /// The line every export of a clinical item carries — PDF and Word as a fact under the title, TXT, Markdown and
    /// WebVTT as a header line (review R1-13) — so a file passed on still says it holds patient information.
    public static let clinicalPrivacyLine = ExportMetadataLine("Privacy", "Clinical: contains patient information")
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
        context: TranscriptTextContext = .none,
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
            metadata.append(clinicalPrivacyLine)
        }

        // The text Copy writes in this mode (`Transcription.text(.shown(_:))`, plan 024 Task 8): a Clean file carries
        // the clean text on its timed turns (review R1-3), and the person's corrections (plan 025; `context` is their
        // clean-up rules, which a Clean file of a corrected transcript runs).
        let text = transcription.text(.shown(cleanupMode), context: context)
        var blocks: [Block] = []
        if text.hasWordTimings {
            var lastSpeaker: String?
            for line in text.lines {
                let speaker = line.speakerLabel
                let shown = speaker == lastSpeaker ? nil : speaker
                lastSpeaker = speaker
                blocks.append(
                    .turn(
                        speaker: shown,
                        timestamp: TranscriptPromptFormatter.timestamp(milliseconds: line.startMs ?? 0),
                        text: line.text))
            }
        } else {
            blocks = paragraphs(of: text.plainText).map { .paragraph($0) }
        }
        return ExportDocument(
            title: transcription.displayTitle, metadata: metadata, blocks: blocks, footer: defaultFooter)
    }

    /// A generated document's Markdown, read by the parser the screen and Copy use (review R1-6, plan 024 Task 4):
    /// `ChirpText.MarkdownBlockParser` for the blocks and `MarkdownInline.plain` for each line's text, so a PDF or
    /// Word file holds exactly the characters Copy writes — the same headings (`##`…`######` and the templates'
    /// bold section names such as `**Subjective**`), list items with their nesting level and their own number
    /// and delimiter ("2)"), and every word, number and symbol; only Markdown syntax is dropped. A single "#" on the
    /// first line is the document's title (level 1, skipped when it repeats `title`); below it, a single "#" line
    /// ("# of doses given: 3") is text that keeps its "#"; fenced code prints exactly as written.
    public static func text(
        title: String,
        body: String,
        metadata: [ExportMetadataLine] = [],
        footer: String? = defaultFooter
    ) -> ExportDocument {
        var blocks: [Block] = []
        for block in MarkdownBlockParser.parse(body) {
            switch block {
            case .heading(let level, let text):
                let heading = MarkdownInline.plain(text)
                // A first heading that repeats the title (models often start with one) is not shown twice.
                if blocks.isEmpty, heading.caseInsensitiveCompare(title) == .orderedSame { continue }
                blocks.append(.heading(heading, level: level <= 1 ? 1 : 2))
            case .paragraph(let text):
                blocks.append(.paragraph(MarkdownInline.plain(text)))
            case .list(let items):
                for item in items {
                    let text = MarkdownInline.plain(item.text)
                    if let marker = item.marker {
                        blocks.append(.numbered(marker: marker, text: text, level: item.level))
                    } else {
                        blocks.append(.bullet(text, level: item.level))
                    }
                }
            case .code(let code):
                // Shown and copied as plain text with its fences dropped and its content never parsed; the same here.
                if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.paragraph(code)) }
            }
        }
        return ExportDocument(title: title, metadata: metadata, blocks: blocks, footer: footer)
    }

    /// Every character of the document's text, in reading order (for tests and plain-text checks).
    public var plainText: String {
        var parts = [title] + metadata.map { "\($0.label): \($0.value)" }
        for block in blocks {
            switch block {
            case .heading(let text, _), .paragraph(let text), .bullet(let text, _): parts.append(text)
            case .turn(let speaker, let timestamp, let text):
                parts.append([speaker, timestamp.map { "[\($0)]" }, text].compactMap { $0 }.joined(separator: " "))
            case .numbered(let marker, let text, _): parts.append("\(marker) \(text)")
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
}
