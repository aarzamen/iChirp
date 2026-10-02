import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The cover at the left of a Capture or Library row: Seed-of-Life for meetings, a tint waveform tile for
/// dictations, a night play tile for links, a quiet waveform tile for imported audio (R7-21: a page is for documents
/// only), a clock while a file is still processing.
struct TranscriptionCover: View {
    let item: TranscriptionSummary
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            switch item.sourceType {
            case .meeting:
                SeedOfLifeCover(seed: Self.seed(for: item.id))
            case .dictation:
                glyphTile("waveform", fill: AppColor.tintFill, ink: Tokens.Color.accentInk)
            case .url, .podcast:
                glyphTile("play.fill", fill: Tokens.Color.night, ink: Tokens.Color.onAccent)
            case .text:
                glyphTile("text.alignleft", fill: AppColor.quietFill, ink: Tokens.Color.secondary, stroked: true)
            case .file:
                glyphTile(
                    item.status == .processing ? "clock" : "waveform",
                    fill: AppColor.quietFill, ink: Tokens.Color.secondary, stroked: true)
            case .document:
                glyphTile(
                    item.status == .processing ? "clock" : "doc.text",
                    fill: AppColor.quietFill, ink: Tokens.Color.secondary, stroked: true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    private func glyphTile(_ systemName: String, fill: Color, ink: Color, stroked: Bool = false) -> some View {
        ZStack {
            ChirpCardBackground(radius: radius, fill: fill, stroke: stroked ? Tokens.Color.border : .clear)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))  // sized by the tile, which is fixed
                .foregroundStyle(ink)
        }
    }

    /// A stable per-row number (a UUID's `hashValue` changes every launch).
    static func seed(for id: UUID) -> Int {
        withUnsafeBytes(of: id.uuid) { bytes in bytes.reduce(0) { $0 &+ Int($1) } }
    }
}

/// One Library or Recent row (`compact` in Capture's Recent, full with the snippet in the Library), for every kind of
/// item: recordings get `TranscriptionCover`, documents and typed text `DocumentCover`. It shows a
/// `TranscriptionSummary` (review R1-1): the list never holds the transcript itself.
///
/// Plan 024 Task 9 merged the two row types (R6a-7): the padding, minimum height and card live inside the button's
/// label, so the whole card opens the item (F9), for documents too; one VoiceOver hint per kind. A failed, cancelled
/// or interrupted row shows its whole message, keeps its meta line, and puts Retry under them as its own button
/// (R6a-9, R7-13): nothing is reserved at a fixed width, so a Retry that grows with Dynamic Type never covers text.
struct LibraryItemRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: TranscriptionSummary
    let progress: JobProgress?
    let compact: Bool
    let onOpen: () -> Void
    let onRetry: () -> Void

    private var coverSize: CGFloat { compact ? 40 : 52 }
    private var verticalPadding: CGFloat { compact ? 10 : 12 }
    private static let horizontalPadding: CGFloat = 12

    var body: some View {
        let canRetry = Formatting.canRetry(item.status)
        Button(action: onOpen) {
            HStack(alignment: compact && !canRetry ? .center : .top, spacing: Tokens.Spacing.s) {
                cover
                VStack(alignment: .leading, spacing: 0) {
                    text
                    if canRetry {
                        // Room for Retry, which sits on top of the card here (its own button, below).
                        retryButton.hidden().accessibilityHidden(true).padding(.top, Tokens.Spacing.xxs)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: compact ? 62 : 76)
            .background(ChirpCardBackground(radius: Tokens.Radius.s))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Self.rowHint(for: item.sourceType))
        .overlay(alignment: .bottomLeading) {
            if canRetry {
                retryButton
                    .accessibilityLabel("Retry \(item.displayTitle)")
                    .padding(.leading, Self.horizontalPadding + coverSize + Tokens.Spacing.s)
                    .padding(.bottom, verticalPadding)
            }
        }
    }

    private var retryButton: some View {
        Button("Retry", action: onRetry)
            .buttonStyle(.chirp(.tinted, size: .compact))
    }

    @ViewBuilder private var cover: some View {
        if item.isTextOnly {
            DocumentCover(
                format: item.documentFormat, size: coverSize, isProcessing: item.status == .processing,
                badge: DocumentRow.coverBadge(for: item))
        } else {
            TranscriptionCover(
                item: item, size: coverSize, radius: compact ? Tokens.Radius.coverSmall : Tokens.Radius.cover)
        }
    }

    /// What the row opens, in VoiceOver's words (F10), for every kind of item.
    static func rowHint(for sourceType: Transcription.SourceType) -> String {
        switch sourceType {
        case .text: "Opens this text"
        case .document: "Opens this document"
        case .file, .meeting, .dictation, .url, .podcast: "Opens the transcript"
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(item.displayTitle)
                    .chirpFont(compact ? 14.5 : 15, .semibold)
                    .foregroundStyle(item.status == .processing ? Tokens.Color.secondary : Tokens.Color.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .chirpGlyph(12, .semibold, relativeTo: .footnote, maxScale: 1.6)
                        .foregroundStyle(Tokens.Color.favorite)
                        .accessibilityLabel("Favorite")
                }
            }
            if !compact, item.status == .completed, let snippet {
                Text(snippet)
                    .chirpFont(12.8)
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(2)
                    .lineSpacing(1.5)
                    .padding(.top, 3)
            }
            if let status = Formatting.statusLine(for: item, progress: progress) {
                Text(status)
                    .chirpFont(12, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    // A failure's whole sentence (it says what to do), not "…recognized. Re…" (R7-13).
                    .lineLimit(item.status == .processing ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, compact ? 2 : 5)
            }
            if item.status != .processing {
                // Every finished row keeps its meta line ("Dictation · 3:47 PM"), failed ones too (R7-13).
                Text(meta)
                    .chirpFont(compact ? 12 : 11.5)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .padding(.top, item.status == .completed ? (compact ? 2 : 5) : 2)
            }
            if item.isPartialAudio {
                // Audio that ends early: a meeting recovered after a kill (M3), or a dictation that stopped on its own
                // or was adopted after a kill (review R2-6).
                StatusChip.partialAudio()
                    .padding(.top, 5)
            }
        }
    }

    private var meta: String {
        item.isTextOnly ? DocumentRow.meta(for: item) : Formatting.meta(for: item)
    }

    private var statusColor: Color {
        switch item.status {
        case .processing: AppColor.accentText
        case .failed, .interrupted: AppColor.error
        case .cancelled, .completed: Tokens.Color.secondary
        }
    }

    /// The derived snippet (text after the title); nil when the whole text fits in the title.
    private var snippet: String? {
        let derived = item.derivedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return derived.isEmpty ? nil : derived
    }
}
