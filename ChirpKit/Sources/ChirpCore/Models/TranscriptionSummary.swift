import Foundation

/// The fields of a library item that a list row, a status line or a Retry choice reads: its identity, kind, status,
/// titles and badges, never its transcript (text, word timings, segments, pages). The full `Transcription` and the
/// lists' `TranscriptionSummary` both have them, so a display helper can take either (review R1-1).
public protocol TranscriptionRowFields: Sendable {
    var id: UUID { get }
    var createdAt: Date { get }
    var sourceType: Transcription.SourceType { get }
    /// Original file name shown to the user.
    var fileName: String { get }
    /// Relative to `AppPaths.root`; nil once retention removed the audio, and for text-only items.
    var mediaRelativePath: String? { get }
    var durationMs: Int? { get }
    var speakerCount: Int? { get }
    var status: Transcription.Status { get }
    var errorMessage: String? { get }
    var titleOverride: String? { get }
    var derivedTitle: String? { get }
    var derivedSnippet: String? { get }
    var isFavorite: Bool { get }
    var privacyClass: PrivacyClass { get }
    var isPartialAudio: Bool { get }
    var sourceURL: String? { get }
    var sourceTitle: String? { get }
    var documentFormat: DocumentFormat? { get }
}

extension TranscriptionRowFields {
    /// titleOverride ?? non-empty sourceTitle (M5) ?? non-empty derivedTitle ?? fileName without extension
    public var displayTitle: String {
        Transcription.displayTitle(
            titleOverride: titleOverride, sourceTitle: sourceTitle, derivedTitle: derivedTitle, fileName: fileName)
    }

    /// Whether this item is a document (text only: no player, no word timings, no SRT/VTT).
    public var isDocument: Bool { sourceType == .document }

    /// Whether this item is typed or pasted text (plan 022). Shown like a document: text only.
    public var isTextItem: Bool { sourceType == .text }

    /// Whether this item is text without audio or timings (a document or a text item): the document screen, no player.
    public var isTextOnly: Bool { isDocument || isTextItem }
}

extension Transcription: TranscriptionRowFields {}

/// One Library or Capture row (review R1-1, R6a-8): the columns a list shows, plus the counts a document's row prints,
/// read without the transcript's text, word timings, segments or pages. A distinct type, so a row can never stand in
/// for a full transcript: open the item (`TranscriptionStoring.fetch(id:)`) to get that.
///
/// `GRDBTranscriptionStore` reads it from the summary columns alone; `init(_:)` gives the same value from a full row.
public struct TranscriptionSummary: TranscriptionRowFields, Identifiable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var sourceType: Transcription.SourceType
    public var fileName: String
    public var mediaRelativePath: String?
    public var durationMs: Int?
    public var speakerCount: Int?
    public var status: Transcription.Status
    public var errorMessage: String?
    public var titleOverride: String?
    public var derivedTitle: String?
    public var derivedSnippet: String?
    public var isFavorite: Bool
    public var privacyClass: PrivacyClass
    public var isPartialAudio: Bool
    public var sourceURL: String?
    public var sourceTitle: String?
    public var documentFormat: DocumentFormat?
    /// How many pages a PDF's `documentPages` holds; 0 for every other item (and for pages this build cannot read).
    public var documentPageCount: Int
    /// How many of those pages were read with OCR.
    public var ocrPageCount: Int
    /// A document or text item that has no `documentPages`: the words in its `displayText` (`wordCount(of:)`); 0 for
    /// every other item.
    public var textWordCount: Int

    public init(
        id: UUID,
        createdAt: Date,
        sourceType: Transcription.SourceType,
        fileName: String,
        mediaRelativePath: String? = nil,
        durationMs: Int? = nil,
        speakerCount: Int? = nil,
        status: Transcription.Status,
        errorMessage: String? = nil,
        titleOverride: String? = nil,
        derivedTitle: String? = nil,
        derivedSnippet: String? = nil,
        isFavorite: Bool = false,
        privacyClass: PrivacyClass,
        isPartialAudio: Bool = false,
        sourceURL: String? = nil,
        sourceTitle: String? = nil,
        documentFormat: DocumentFormat? = nil,
        documentPageCount: Int = 0,
        ocrPageCount: Int = 0,
        textWordCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceType = sourceType
        self.fileName = fileName
        self.mediaRelativePath = mediaRelativePath
        self.durationMs = durationMs
        self.speakerCount = speakerCount
        self.status = status
        self.errorMessage = errorMessage
        self.titleOverride = titleOverride
        self.derivedTitle = derivedTitle
        self.derivedSnippet = derivedSnippet
        self.isFavorite = isFavorite
        self.privacyClass = privacyClass
        self.isPartialAudio = isPartialAudio
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.documentFormat = documentFormat
        self.documentPageCount = documentPageCount
        self.ocrPageCount = ocrPageCount
        self.textWordCount = textWordCount
    }

    /// The summary of a full row: the values the store's list query reads for it.
    public init(_ transcription: Transcription) {
        self.init(
            id: transcription.id, createdAt: transcription.createdAt, sourceType: transcription.sourceType,
            fileName: transcription.fileName, mediaRelativePath: transcription.mediaRelativePath,
            durationMs: transcription.durationMs, speakerCount: transcription.speakerCount,
            status: transcription.status, errorMessage: transcription.errorMessage,
            titleOverride: transcription.titleOverride, derivedTitle: transcription.derivedTitle,
            derivedSnippet: transcription.derivedSnippet, isFavorite: transcription.isFavorite,
            privacyClass: transcription.privacyClass, isPartialAudio: transcription.isPartialAudio,
            sourceURL: transcription.sourceURL, sourceTitle: transcription.sourceTitle,
            documentFormat: transcription.documentFormat,
            documentPageCount: transcription.documentPages?.count ?? 0,
            ocrPageCount: transcription.ocrPageCount,
            textWordCount: transcription.isTextOnly && transcription.documentPages == nil
                ? Self.wordCount(of: transcription.displayText) : 0)
    }

    /// Words as a document's row counts them: runs of characters between whitespace or line breaks.
    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// `rows` (newest first) summarized, at most `limit` of them when given.
    public static func newest(_ rows: [Transcription], limit: Int?) -> [TranscriptionSummary] {
        let shown = limit.map { rows.prefix(max(0, $0)) } ?? rows[...]
        return shown.map(TranscriptionSummary.init)
    }
}

/// The Library's search rule, shared by the store's query and every fallback, so all of them find the same items.
public enum TranscriptionSearch {
    /// Whether `query` (already trimmed) appears, ignoring case, in the display title, the display text, the
    /// transcript as the person corrected it (plan 025: `correctedText`, nil when it has no corrections; the words as
    /// heard stay findable through the display text), the file name or a speaker's label. `correctedText` and
    /// `speakerLabels` are read only when nothing before them matched.
    public static func matches(
        query: String,
        displayTitle: String,
        displayText: String,
        correctedText: () -> String? = { nil },
        fileName: String,
        speakerLabels: () -> [String]
    ) -> Bool {
        displayTitle.localizedCaseInsensitiveContains(query)
            || displayText.localizedCaseInsensitiveContains(query)
            || correctedText()?.localizedCaseInsensitiveContains(query) == true
            || fileName.localizedCaseInsensitiveContains(query)
            || speakerLabels().contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension Transcription {
    /// `TranscriptionSearch.matches` for this row.
    public func matchesSearch(_ query: String) -> Bool {
        TranscriptionSearch.matches(
            query: query, displayTitle: displayTitle, displayText: displayText, fileName: fileName,
            speakerLabels: { (speakers ?? []).map(\.label) })
    }
}
