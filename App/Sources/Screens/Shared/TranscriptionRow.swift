import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The cover at the left of a Capture or Library row: Seed-of-Life for meetings, a tint waveform tile for
/// dictations, a night play tile for links, a document tile for files (a clock while a file is still processing).
struct TranscriptionCover: View {
    let item: Transcription
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
                glyphTile("play.fill", fill: Tokens.Color.night, ink: .white)
            case .text:
                glyphTile("text.alignleft", fill: AppColor.quietFill, ink: Tokens.Color.secondary, stroked: true)
            case .file, .document:
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
            CardBackground(radius: radius, fill: fill, stroke: stroked ? Tokens.Color.border : .clear)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(ink)
        }
    }

    /// A stable per-row number (a UUID's `hashValue` changes every launch).
    static func seed(for id: UUID) -> Int {
        withUnsafeBytes(of: id.uuid) { bytes in bytes.reduce(0) { $0 &+ Int($1) } }
    }
}

/// One transcription in Capture's Recent list (`compact`) or the Library (full, with the snippet). The row is a
/// button that opens the transcript; a failed, cancelled or interrupted row adds a Retry button beside it.
struct TranscriptionRow: View {
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
                    TranscriptionCover(
                        item: item,
                        size: style == .full ? 52 : 40,
                        radius: style == .full ? Tokens.Radius.cover : Tokens.Radius.coverSmall)
                    text
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the transcript")

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
            if style == .full, item.status == .completed, let snippet = snippet {
                Text(snippet)
                    .chirpFont(12.8)
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(2)
                    .lineSpacing(1.5)
                    .padding(.top, 3)
            }
            statusOrMeta
                .padding(.top, style == .full ? 5 : 2)
            if item.isPartialAudio {
                StatusChip.partialAudio()  // M3: a meeting recovered after the app was killed while recording
                    .padding(.top, 5)
            }
        }
    }

    @ViewBuilder private var statusOrMeta: some View {
        if let status = Formatting.statusLine(for: item, progress: progress) {
            Text(status)
                .chirpFont(12, .semibold)
                .monospacedDigit()
                .foregroundStyle(statusColor)
                .lineLimit(2)
        } else {
            Text(Formatting.meta(for: item))
                .chirpFont(style == .full ? 11.5 : 12)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.secondary)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .processing: AppColor.accentText
        case .failed, .interrupted: AppColor.error
        case .cancelled, .completed: Tokens.Color.secondary
        }
    }

    /// The derived snippet (text after the title); nil when the whole transcript fits in the title.
    private var snippet: String? {
        let derived = item.derivedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return derived.isEmpty ? nil : derived
    }
}
