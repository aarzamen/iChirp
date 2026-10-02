import ChirpCore
import ChirpUI
import SwiftUI

/// A Settings group: the uppercase label, a radius-14 card of rows with hairline separators, and an optional footer.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    /// The footer's text color — `secondary` unless a caller needs to flag it (a failed connection test, F85).
    var footerColor: Color = Tokens.Color.secondary
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title)
                .padding(.leading, 4)
                .padding(.top, 20)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 {
                            Rectangle()
                                .fill(AppColor.quietFill)
                                .frame(height: 1)
                                .padding(.leading, 14)
                        }
                        subview
                    }
                }
            }
            // R7-1: every card spans the full width, however short its rows.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground(radius: Tokens.Radius.s))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
            if let footer {
                Text(footer)
                    .chirpFont(12.5)
                    .foregroundStyle(footerColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
    }
}

/// A label on the left, optional caption under it, and trailing content.
///
/// R7-1 (plan 024 Task 10): the title and caption sit beside the trailing control and the caption wraps, so every
/// title in a card starts at the same x. The value drops under the title only when it would leave the title less
/// than about half the row (a wide segmented control) or at accessibility sizes (F77), always left-aligned, never
/// centred. A navigation row's chevron (`showsChevron`) is pinned to the trailing edge and never stacks.
struct SettingsRow<Trailing: View>: View {
    let title: String
    /// The title's own text color — `ink` unless a caller needs to flag the row itself (a destructive action).
    var titleColor: Color = Tokens.Color.ink
    var caption: String?
    var captionColor: Color = Tokens.Color.secondary
    /// A navigation row: a chevron pinned to the trailing edge.
    var showsChevron = false
    @ViewBuilder let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            SettingsRowLayout(stacks: dynamicTypeSize.isAccessibilitySize) {
                titleAndCaption
                HStack(spacing: 10) { trailing }
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .chirpGlyph(13, .semibold, relativeTo: .subheadline)
                    .foregroundStyle(Tokens.Color.mutedText)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : (caption == nil ? 52 : 62))
    }

    private var titleAndCaption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .chirpFont(15.5)
                .foregroundStyle(titleColor)
            if let caption {
                Text(caption)
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(captionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, caption: String? = nil, showsChevron: Bool = false) {
        self.init(title: title, caption: caption, showsChevron: showsChevron, trailing: { EmptyView() })
    }
}

/// `SettingsRow`'s two-part layout (R7-1): the title column and the trailing control side by side, the title column
/// taking the width the control leaves and wrapping its caption; or, when the control would leave the title less
/// than `minimumTitleShare` of the row (or `stacks`), the control under the title, both left-aligned. `ViewThatFits`
/// could not do this: it measures a caption at its unwrapped width, so any caption longer than one line stacked the
/// row and centred it.
struct SettingsRowLayout: Layout {
    var stacks = false
    var spacing: CGFloat = 10
    var stackSpacing: CGFloat = 8
    /// The share of the row the title column keeps beside the control.
    static let minimumTitleShare: CGFloat = 0.45

    /// Side by side when the control leaves the title at least `minimumTitleShare` of `width`.
    static func sideBySide(width: CGFloat, trailingWidth: CGFloat, spacing: CGFloat = 10) -> Bool {
        trailingWidth <= 0 || width - trailingWidth - spacing >= width * minimumTitleShare
    }

    private func fitsSideBySide(width: CGFloat, trailing: CGSize) -> Bool {
        !stacks && Self.sideBySide(width: width, trailingWidth: trailing.width, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        let trailing = subviews[1].sizeThatFits(.unspecified)
        if fitsSideBySide(width: width, trailing: trailing) {
            let titleWidth = max(0, width - (trailing.width > 0 ? trailing.width + spacing : 0))
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
            return CGSize(width: width, height: max(title.height, trailing.height))
        }
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let below = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let gap = below.height > 0 ? stackSpacing : 0
        return CGSize(width: width, height: title.height + gap + below.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            return
        }
        let trailing = subviews[1].sizeThatFits(.unspecified)
        if fitsSideBySide(width: bounds.width, trailing: trailing) {
            let titleWidth = max(0, bounds.width - (trailing.width > 0 ? trailing.width + spacing : 0))
            let titleProposal = ProposedViewSize(width: titleWidth, height: nil)
            let title = subviews[0].sizeThatFits(titleProposal)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY - title.height / 2), proposal: titleProposal)
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - trailing.width, y: bounds.midY - trailing.height / 2),
                proposal: ProposedViewSize(trailing))
            return
        }
        let full = ProposedViewSize(width: bounds.width, height: nil)
        let title = subviews[0].sizeThatFits(full)
        subviews[0].place(at: bounds.origin, proposal: full)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + title.height + stackSpacing), proposal: full)
    }
}

/// A model's download state with Download / Delete (delete asks first).
struct ModelAssetRow: View {
    let title: String
    let value: String
    let status: ModelAssetStatus
    /// For the not-downloaded line, e.g. 500_000_000 → "about 500 MB".
    let approximateDownloadBytes: Int64?
    /// Where it runs, for the ready line ("Neural Engine").
    let runsOn: String
    let onDownload: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // R7-18: at accessibility sizes the value goes under the name and the button under the status, instead of
            // squeezing "Community-" / "1" and "Not / downloaded" beside them.
            SettingsRowLayout(stacks: dynamicTypeSize.isAccessibilitySize, stackSpacing: 2) {
                Text(title)
                    .chirpFont(15.5)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            SettingsRowLayout(stacks: dynamicTypeSize.isAccessibilitySize) {
                Text(statusText)
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                action
            }
            if case .downloading(let fraction) = status {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(Tokens.Color.accent)
                    .accessibilityLabel("\(title) download")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // R6b-12: the model's own name ("Delete Qwen3.5 2B?"), not its tier or vendor.
        .confirmationDialog(
            Self.deleteQuestion(title: title), isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your transcripts stay. Parakeet needs to download the model again before it can use it.")
        }
    }

    static func deleteQuestion(title: String) -> String { "Delete \(title)?" }

    @ViewBuilder private var action: some View {
        switch status {
        case .notDownloaded:
            Button(action: onDownload) { CapsuleButtonLabel(title: "Download", kind: .filled) }
                .buttonStyle(.plain)
                .accessibilityLabel("Download \(title)")
        case .failed:
            Button(action: onDownload) { CapsuleButtonLabel(title: "Try again", kind: .filled) }
                .buttonStyle(.plain)
                .accessibilityLabel("Download \(title) again")
        case .ready:
            Button {
                confirmingDelete = true
            } label: {
                CapsuleButtonLabel(title: "Delete", kind: .destructive)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(title)")
        case .downloading:
            EmptyView()
        }
    }

    private var statusText: String {
        switch status {
        case .notDownloaded:
            if let approximateDownloadBytes {
                return "Not downloaded · about \(Formatting.size(bytes: approximateDownloadBytes))"
            }
            return "Not downloaded"
        case .downloading(let fraction):
            return "Downloading \(Formatting.percent(fraction))%"
        case .ready(let bytes):
            return "On device · \(Formatting.size(bytes: bytes)) · \(runsOn)"
        case .failed(let message):
            // The row shows the sentence only; the "Model action failed" alert carries the full text, whose
            // " Details: …" suffix (error code, host, phase, attempts) is for diagnosis, not for the settings list.
            let sentence = message.components(separatedBy: " Details: ").first ?? message
            return "Download failed: \(sentence)"
        }
    }

    private var statusColor: Color {
        if case .failed = status { return AppColor.error }
        return Tokens.Color.secondary
    }
}
