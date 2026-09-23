import Foundation

/// A generated document as a list shows it (the Library, a source's "Made from this"; plan 023, UX audit F43):
/// everything a row, a filter and the privacy rules need, and the start of the text instead of all of it, so thousands
/// of them stay cheap to hold and to refresh. Open the document itself with `DeliverableStoring.fetchDeliverable(id:)`.
public struct DeliverableSummary: Sendable, Equatable, Identifiable {
    /// How many characters of the text a summary keeps (`textStart`).
    public static let textStartLength = 320

    public var id: UUID
    public var transcriptionID: UUID
    /// The template it was made with; nil for Ask answers, or when the template was later removed.
    public var promptID: UUID?
    /// The template name at generation time ("SOAP note", "Summary"): the document's type.
    public var title: String
    /// The document's own class (an unknown stored class reads as `clinical`).
    public var privacyClass: PrivacyClass
    /// Provider display name at generation time.
    public var provider: String
    public var locality: EngineLocality
    public var createdAt: Date
    public var updatedAt: Date
    public var editedAt: Date?
    /// The first `textStartLength` characters of the text, as stored.
    public var textStart: String

    /// The start of the text on one line, without Markdown markers (`snippet(from:)`). Folded when a row asks, so a
    /// list of thousands never folds the ones it does not show.
    public var snippet: String { Self.snippet(from: textStart) }

    public init(
        id: UUID,
        transcriptionID: UUID,
        promptID: UUID?,
        title: String,
        privacyClass: PrivacyClass,
        provider: String,
        locality: EngineLocality,
        createdAt: Date,
        updatedAt: Date,
        editedAt: Date?,
        textStart: String
    ) {
        self.id = id
        self.transcriptionID = transcriptionID
        self.promptID = promptID
        self.title = title
        self.privacyClass = privacyClass
        self.provider = provider
        self.locality = locality
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.editedAt = editedAt
        self.textStart = String(textStart.prefix(Self.textStartLength))
    }

    /// A full document's summary.
    public init(_ deliverable: Deliverable) {
        self.init(
            id: deliverable.id, transcriptionID: deliverable.transcriptionID, promptID: deliverable.promptID,
            title: deliverable.title, privacyClass: deliverable.privacyClass, provider: deliverable.provider,
            locality: deliverable.locality, createdAt: deliverable.createdAt, updatedAt: deliverable.updatedAt,
            editedAt: deliverable.editedAt, textStart: deliverable.text)
    }

    /// One line from the start of a document: heading marks, list bullets, quote marks and emphasis markers (`**`,
    /// `__`, backticks) dropped, every run of whitespace folded to one space. A preview only; Copy and Share use the
    /// document's own text.
    public static func snippet(from text: String) -> String {
        var words: [Substring] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.drop(while: \.isWhitespace)
            // "## Subjective", "> quoted", "- item", "* item", "+ item" (a marker needs a space after it).
            while let first = line.first, "#>".contains(first) { line = line.dropFirst().drop(while: \.isWhitespace) }
            if let first = line.first, "-*+".contains(first), line.dropFirst().first?.isWhitespace == true {
                line = line.dropFirst().drop(while: \.isWhitespace)
            }
            let cleaned = String(line)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            words.append(contentsOf: cleaned.split(whereSeparator: \.isWhitespace))
        }
        return words.joined(separator: " ")
    }
}

/// Read-only lists of the generated documents for the Library (plan 023, UX audit F43: no document is ever
/// unreachable, so there is no limit here). The GRDB implementation is `GRDBDeliverableStore` in ChirpStore.
/// Contract: spec/contracts/deliverables-v1.md ("Listing").
public protocol DeliverableListing: Sendable {
    /// Every document, newest first (`createdAt`, then id). A row this build cannot read is skipped and logged.
    func fetchDeliverableSummaries() async throws -> [DeliverableSummary]
    /// The same list now, then again after every change to the documents (a new one, an edit, a raised class, a
    /// delete, or its transcript's delete). Ends when the consumer stops iterating.
    func observeDeliverableSummaries() -> AsyncStream<[DeliverableSummary]>
    /// Ids of the documents whose title or text contains `query`, ignoring case (surrounding whitespace is ignored;
    /// an empty query matches nothing).
    func searchDeliverables(matching query: String) async throws -> Set<UUID>
}
