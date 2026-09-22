import ChirpCore
import ChirpUI
import SwiftUI

/// A Settings group: the uppercase label, a radius-14 card of rows with hairline separators, and an optional footer.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
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
            .background(CardBackground(radius: Tokens.Radius.s))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous))
            if let footer {
                Text(footer)
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
        }
    }
}

/// A label on the left, optional caption under it, and trailing content.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var caption: String?
    var captionColor: Color = Tokens.Color.secondary
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .chirpFont(15.5)
                    .foregroundStyle(Tokens.Color.ink)
                if let caption {
                    Text(caption)
                        .chirpFont(12.5)
                        .monospacedDigit()
                        .foregroundStyle(captionColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: caption == nil ? 52 : 62)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(title: String, caption: String? = nil) {
        self.init(title: title, caption: caption, trailing: { EmptyView() })
    }
}

/// A row that opens a "Not built yet" sheet: the canvas value dimmed, captioned with the milestone.
struct PlaceholderRow: View {
    let title: String
    let value: String
    let placeholder: Placeholder
    let open: (Placeholder) -> Void

    var body: some View {
        Button {
            open(placeholder)
        } label: {
            SettingsRow(title: title, caption: "Milestone \(placeholder.milestone)") {
                Text(value)
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.mutedText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Not built yet, milestone \(placeholder.milestone)")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .chirpFont(15.5)
                    .foregroundStyle(Tokens.Color.ink)
                Spacer(minLength: 8)
                Text(value)
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(statusText)
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
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
        .confirmationDialog(
            "Delete the \(value) model?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your transcripts stay. Parakeet needs to download the model again before it can use it.")
        }
    }

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
            return "Download failed: \(message)"
        }
    }

    private var statusColor: Color {
        if case .failed = status { return AppColor.error }
        return Tokens.Color.secondary
    }
}
