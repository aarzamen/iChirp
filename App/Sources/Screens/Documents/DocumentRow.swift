import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// A document's cover (M5): a page with a folded corner and the format on it ("PDF", "DOCX", "MD"; "TEXT" for a
/// typed or pasted text item, plan 022).
struct DocumentCover: View {
    let format: DocumentFormat?
    let size: CGFloat
    var isProcessing = false
    /// Replaces the format badge ("TEXT" for a text item).
    var badge: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(AppColor.quietFill)
            PageShape(fold: size * 0.2)
                .fill(Tokens.Color.surface)
                .overlay(PageShape(fold: size * 0.2).stroke(Tokens.Color.border, lineWidth: 1))
                .frame(width: size * 0.56, height: size * 0.7)
            VStack(spacing: size * 0.05) {
                if isProcessing {
                    Image(systemName: "clock")
                        .font(.system(size: size * 0.22, weight: .semibold))
                        .foregroundStyle(Tokens.Color.secondary)
                } else {
                    ForEach(0..<3, id: \.self) { line in
                        Capsule()
                            .fill(Tokens.Color.border)
                            .frame(width: size * (line == 2 ? 0.22 : 0.34), height: max(1.5, size * 0.035))
                    }
                }
                Text(badge ?? Self.badge(for: format))
                    .font(Tokens.Font.rounded(max(7, size * 0.15), .heavy))
                    .foregroundStyle(Tokens.Color.accentInk)
                    .padding(.horizontal, size * 0.05)
                    .background(Capsule().fill(AppColor.tintFill))
            }
            .offset(y: size * 0.04)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func badge(for format: DocumentFormat?) -> String {
        switch format {
        case .pdf: "PDF"
        case .docx: "DOCX"
        case .markdown: "MD"
        case .plainText: "TXT"
        case .rtf: "RTF"
        case .html: "HTML"
        case nil: "DOC"
        }
    }
}

/// A page outline with its top-right corner folded.
private struct PageShape: Shape {
    let fold: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The words of a document or text item's row and screen (M5): the cover badge and the meta line ("PDF · 12 pages · 3
/// read with OCR"). The row itself is `LibraryItemRow`, shared with recordings (plan 024 Task 9, R6a-7).
enum DocumentRow {
    /// "TEXT" on a typed or pasted text item's cover; nil keeps the format badge.
    static func coverBadge(for item: some TranscriptionRowFields) -> String? {
        item.isTextItem ? "TEXT" : nil
    }

    /// "PDF · 12 pages · 3 read with OCR", "Word · 1,204 words", "Markdown · 86 words", "Text · 86 words".
    static func meta(for item: Transcription) -> String {
        let pages = item.documentPages ?? []
        return meta(
            isTextItem: item.isTextItem, format: item.documentFormat, pageCount: pages.count,
            ocrPageCount: item.ocrPageCount, words: pages.isEmpty ? wordCount(item.plainText(.heard)) : 0)
    }

    /// The same line from a list row's summary, which carries the counts instead of the pages and text.
    static func meta(for item: TranscriptionSummary) -> String {
        meta(
            isTextItem: item.isTextItem, format: item.documentFormat, pageCount: item.documentPageCount,
            ocrPageCount: item.ocrPageCount, words: item.textWordCount)
    }

    private static func meta(
        isTextItem: Bool, format: DocumentFormat?, pageCount: Int, ocrPageCount: Int, words: Int
    ) -> String {
        var parts = [isTextItem ? "Text" : format?.displayName ?? "Document"]
        if pageCount > 0 {
            parts.append(pageCount == 1 ? "1 page" : "\(pageCount) pages")
            if ocrPageCount > 0 {
                parts.append(ocrPageCount == pageCount ? "read with OCR" : "\(ocrPageCount) read with OCR")
            }
        } else if words > 0 {
            parts.append(words == 1 ? "1 word" : "\(words.formatted()) words")
        }
        return parts.joined(separator: " · ")
    }

    static func wordCount(_ text: String) -> Int {
        TranscriptionSummary.wordCount(of: text)
    }
}

/// Opens the right screen for a Library id: documents (M5) and typed text (plan 022) get `DocumentScreen`, everything
/// else the transcript.
///
/// Review R6a-5: the kind comes with the route, decided from the row that was tapped, so this view reads nothing the
/// Library observes; it is not rebuilt (and its screen's view models are not re-made) on every Library write, and a
/// just-saved text item cannot open as a transcript before the Library has delivered its row.
struct LibraryItemScreen: View {
    let id: UUID
    /// The kind when the caller knows it; nil: read the row once from the store.
    private let knownIsTextOnly: Bool?
    private let store: (any TranscriptionStoring)?
    @State private var storedIsTextOnly: Bool?

    init(id: UUID, isTextOnly: Bool) {
        self.id = id
        self.knownIsTextOnly = isTextOnly
        self.store = nil
    }

    /// For a caller that has only the id (Create's result): the kind as the Library knows it now, else from the row in
    /// the store, read once (a row saved a moment ago may not have reached the Library's list yet).
    init(id: UUID, environment: AppEnvironment) {
        self.id = id
        self.knownIsTextOnly = environment.library.items.first { $0.id == id }?.isTextOnly
        self.store = environment.store
    }

    var body: some View {
        if let isTextOnly = knownIsTextOnly ?? storedIsTextOnly {
            if isTextOnly {
                DocumentScreen(id: id)
            } else {
                TranscriptScreen(id: id)
            }
        } else {
            Tokens.Color.ground
                .ignoresSafeArea()
                .task {
                    // A row that cannot be read opens the transcript screen, which says it is gone.
                    let row = try? await store?.fetch(id: id)
                    storedIsTextOnly = row?.isTextOnly ?? false
                }
        }
    }
}

/// Where a Library row leads: a recording, text item or imported file (with its kind, R6a-5), or a generated document
/// (plan 023).
enum LibraryRoute: Hashable {
    case item(UUID, isTextOnly: Bool)
    case document(UUID)

    /// The route for a row in hand.
    static func item(_ item: some TranscriptionRowFields) -> LibraryRoute {
        .item(item.id, isTextOnly: item.isTextOnly)
    }

    /// The route for an id from elsewhere (a sheet that saved or started it): its kind from `items` when listed,
    /// else `fallbackIsTextOnly`.
    static func item(id: UUID, in items: [TranscriptionSummary], fallbackIsTextOnly: Bool = false) -> LibraryRoute {
        .item(id, isTextOnly: items.first { $0.id == id }?.isTextOnly ?? fallbackIsTextOnly)
    }

    /// The Library item this route opens, if it opens one.
    var itemID: UUID? {
        if case .item(let id, _) = self { return id }
        return nil
    }

    @ViewBuilder func destination(environment: AppEnvironment) -> some View {
        switch self {
        case .item(let id, let isTextOnly): LibraryItemScreen(id: id, isTextOnly: isTextOnly)
        // Built only when pushed, and not rebuilt with every parent render (R6a-5).
        case .document(let id): DeferredDeliverableDetail(id: id, environment: environment)
        }
    }
}
