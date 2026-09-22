import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// A document's cover (M5): a page with a folded corner and the format on it ("PDF", "DOCX", "MD").
struct DocumentCover: View {
    let format: DocumentFormat?
    let size: CGFloat
    var isProcessing = false

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
                Text(Self.badge(for: format))
                    .font(.system(size: max(7, size * 0.15), weight: .heavy, design: .rounded))
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

/// One document in the Library or in Capture's Recent list (M5): the document cover, title, snippet and a meta line
/// ("PDF · 12 pages · 3 read with OCR"). Failed, cancelled or interrupted rows add Retry, like transcripts.
struct DocumentRow: View {
    enum Style {
        case compact, full
    }

    let item: Transcription
    let progress: JobProgress?
    let style: Style
    let onOpen: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: style == .full ? .top : .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: style == .full ? .top : .center, spacing: 12) {
                    DocumentCover(
                        format: item.documentFormat, size: style == .full ? 52 : 40,
                        isProcessing: item.status == .processing)
                    text
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the document")

            if Formatting.canRetry(item.status) {
                Button(action: onRetry) {
                    CapsuleButtonLabel(title: "Retry", kind: .tinted)
                }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .accessibilityLabel("Retry \(item.displayTitle)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, style == .full ? 12 : 10)
        .frame(minHeight: style == .full ? 76 : 62)
        .background(CardBackground(radius: Tokens.Radius.s))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(item.displayTitle)
                    .chirpFont(style == .full ? 15 : 14.5, .semibold)
                    .foregroundStyle(item.status == .processing ? Tokens.Color.secondary : Tokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.Color.favorite)
                        .accessibilityLabel("Favorite")
                }
            }
            if style == .full, item.status == .completed, let snippet {
                Text(snippet)
                    .chirpFont(12.8)
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(2)
                    .lineSpacing(1.5)
                    .padding(.top, 3)
            }
            Group {
                if let status = Formatting.statusLine(for: item, progress: progress) {
                    Text(status)
                        .chirpFont(12, .semibold)
                        .foregroundStyle(item.status == .processing ? AppColor.accentText : statusColor)
                        .lineLimit(2)
                } else {
                    Text(Self.meta(for: item))
                        .chirpFont(style == .full ? 11.5 : 12)
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(1)
                }
            }
            .monospacedDigit()
            .padding(.top, style == .full ? 5 : 2)
        }
    }

    private var statusColor: Color {
        item.status == .cancelled ? Tokens.Color.secondary : AppColor.error
    }

    private var snippet: String? {
        let derived = item.derivedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return derived.isEmpty ? nil : derived
    }

    /// "PDF · 12 pages · 3 read with OCR", "Word · 1,204 words", "Markdown · 86 words".
    static func meta(for item: Transcription) -> String {
        var parts = [item.documentFormat?.displayName ?? "Document"]
        if let pages = item.documentPages, !pages.isEmpty {
            parts.append(pages.count == 1 ? "1 page" : "\(pages.count) pages")
            let ocr = item.ocrPageCount
            if ocr > 0 {
                parts.append(ocr == pages.count ? "read with OCR" : "\(ocr) read with OCR")
            }
        } else {
            let words = wordCount(item.displayText)
            if words > 0 {
                parts.append(words == 1 ? "1 word" : "\(words.formatted()) words")
            }
        }
        return parts.joined(separator: " · ")
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// Opens the right screen for a Library id: documents (M5) get `DocumentScreen`, everything else the transcript.
struct LibraryItemScreen: View {
    let id: UUID
    let environment: AppEnvironment

    var body: some View {
        if environment.library.items.first(where: { $0.id == id })?.isDocument == true {
            DocumentScreen(id: id, environment: environment)
        } else {
            TranscriptScreen(id: id, environment: environment)
        }
    }
}

/// A Library or Recent row: `DocumentRow` for documents, `TranscriptionRow` for everything else.
struct LibraryItemRow: View {
    let item: Transcription
    let progress: JobProgress?
    let compact: Bool
    let onOpen: () -> Void
    let onRetry: () -> Void

    var body: some View {
        if item.isDocument {
            DocumentRow(
                item: item, progress: progress, style: compact ? .compact : .full, onOpen: onOpen, onRetry: onRetry)
        } else {
            TranscriptionRow(
                item: item, progress: progress, style: compact ? .compact : .full, onOpen: onOpen, onRetry: onRetry)
        }
    }
}
