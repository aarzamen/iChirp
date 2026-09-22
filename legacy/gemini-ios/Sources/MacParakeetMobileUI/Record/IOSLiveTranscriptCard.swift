import SwiftUI
import MacParakeetCore

/// Live streaming transcript card displaying spoken text in real-time.
public struct IOSLiveTranscriptCard: View {
    public let text: String
    public let isRecording: Bool
    public let onCopy: () -> Void

    @State private var copied: Bool = false

    public init(text: String, isRecording: Bool, onCopy: @escaping () -> Void) {
        self.text = text
        self.isRecording = isRecording
        self.onCopy = onCopy
    }

    private var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.sm) {
            HStack {
                HStack(spacing: 6) {
                    if isRecording {
                        Circle()
                            .fill(MobileDesignSystem.Colors.errorRed)
                            .frame(width: 8, height: 8)
                        Text("Live Transcript")
                            .font(MobileDesignSystem.Typography.headline)
                            .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                    } else {
                        Image(systemName: "text.quote")
                            .foregroundColor(MobileDesignSystem.Colors.accent)
                        Text("Transcript")
                            .font(MobileDesignSystem.Typography.headline)
                            .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                    }
                }

                Spacer()

                if !text.isEmpty {
                    Text("\(wordCount) words")
                        .font(MobileDesignSystem.Typography.caption)
                        .foregroundColor(MobileDesignSystem.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MobileDesignSystem.Colors.surfaceElevated)
                        .clipShape(Capsule())

                    Button(action: {
                        onCopy()
                        MobileDesignSystem.Haptics.light()
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            withAnimation { copied = false }
                        }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(copied ? MobileDesignSystem.Colors.successGreen : MobileDesignSystem.Colors.accent)
                            .frame(width: 32, height: 32)
                            .background(MobileDesignSystem.Colors.surfaceElevated)
                            .clipShape(Circle())
                    }
                }
            }

            Divider()
                .background(MobileDesignSystem.Colors.divider)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    if text.isEmpty {
                        VStack(spacing: MobileDesignSystem.Spacing.sm) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 28))
                                .foregroundColor(MobileDesignSystem.Colors.textTertiary.opacity(0.5))
                            Text(isRecording ? "Listening for speech..." : "Tap the record button to begin")
                                .font(MobileDesignSystem.Typography.bodySmall)
                                .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Text(text)
                            .font(MobileDesignSystem.Typography.body)
                            .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottomID")
                    }
                }
                .frame(maxHeight: 220)
                .onChange(of: text) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottomID", anchor: .bottom)
                    }
                }
            }
        }
        .padding(MobileDesignSystem.Spacing.md)
        .background(MobileDesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg, style: .continuous)
                .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
        )
    }
}
