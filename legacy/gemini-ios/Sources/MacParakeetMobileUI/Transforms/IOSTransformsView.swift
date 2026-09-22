import SwiftUI
import MacParakeetCore

/// Transforms and AI rewriting screen on iOS.
/// Provides instant presets (Polish, Summarize, Formal, Action Items) and custom prompts.
public struct IOSTransformsView: View {
    public struct PresetTransform: Identifiable {
        public let id = UUID()
        public let title: String
        public let icon: String
        public let prompt: String
    }

    private let presets: [PresetTransform] = [
        PresetTransform(title: "Polish & Grammar", icon: "sparkles", prompt: "Fix grammar, spelling, and phrasing while preserving my tone:"),
        PresetTransform(title: "Executive Summary", icon: "doc.plaintext", prompt: "Summarize this into 3 concise bullet points with key takeaways:"),
        PresetTransform(title: "Action Items", icon: "checklist", prompt: "Extract all clear action items, assignees, and next steps:"),
        PresetTransform(title: "Professional Tone", icon: "briefcase", prompt: "Rewrite this in a clear, polite, and professional tone:"),
        PresetTransform(title: "Shorten & Punchy", icon: "arrow.down.right.and.arrow.up.left", prompt: "Condense this to be as punchy and concise as possible:")
    ]

    @State private var inputText: String = ""
    @State private var customPrompt: String = ""
    @State private var outputText: String = ""
    @State private var isRunning: Bool = false
    @State private var selectedPresetId: UUID?

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                MobileDesignSystem.Colors.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.lg) {
                        // Presets Horizontal Carousel
                        VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.sm) {
                            Text("Presets")
                                .font(MobileDesignSystem.Typography.headline)
                                .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                                .padding(.horizontal, MobileDesignSystem.Spacing.lg)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: MobileDesignSystem.Spacing.sm) {
                                    ForEach(presets) { preset in
                                        Button(action: {
                                            MobileDesignSystem.Haptics.light()
                                            selectedPresetId = preset.id
                                            customPrompt = preset.prompt
                                        }) {
                                            HStack(spacing: 6) {
                                                Image(systemName: preset.icon)
                                                    .foregroundColor(selectedPresetId == preset.id ? .white : MobileDesignSystem.Colors.accent)
                                                Text(preset.title)
                                                    .font(MobileDesignSystem.Typography.bodySmall)
                                                    .foregroundColor(selectedPresetId == preset.id ? .white : MobileDesignSystem.Colors.textPrimary)
                                            }
                                            .padding(.horizontal, MobileDesignSystem.Spacing.md)
                                            .padding(.vertical, 10)
                                            .background(selectedPresetId == preset.id ? MobileDesignSystem.Colors.accent : MobileDesignSystem.Colors.surface)
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule()
                                                    .stroke(selectedPresetId == preset.id ? MobileDesignSystem.Colors.accent : MobileDesignSystem.Colors.border, lineWidth: 1)
                                            )
                                        }
                                    }
                                }
                                .padding(.horizontal, MobileDesignSystem.Spacing.lg)
                            }
                        }

                        // Input Card
                        VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.sm) {
                            HStack {
                                Text("Input Text")
                                    .font(MobileDesignSystem.Typography.headline)
                                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                                Spacer()
                                Button(action: pasteInput) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.clipboard")
                                        Text("Paste")
                                    }
                                    .font(MobileDesignSystem.Typography.caption)
                                    .foregroundColor(MobileDesignSystem.Colors.accent)
                                }
                            }

                            TextField("Paste or type text to transform...", text: $inputText, axis: .vertical)
                                .lineLimit(4...8)
                                .padding(MobileDesignSystem.Spacing.md)
                                .background(MobileDesignSystem.Colors.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))

                            TextField("Prompt instructions (e.g. rewrite in bullet points)", text: $customPrompt)
                                .font(MobileDesignSystem.Typography.bodySmall)
                                .padding(MobileDesignSystem.Spacing.md)
                                .background(MobileDesignSystem.Colors.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))

                            Button(action: runTransform) {
                                HStack(spacing: 8) {
                                    if isRunning {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "wand.and.stars")
                                    }
                                    Text(isRunning ? "Transforming..." : "Run Transform")
                                }
                            }
                            .mobileParakeetAction(.primary)
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunning)
                        }
                        .padding(MobileDesignSystem.Spacing.md)
                        .background(MobileDesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg)
                                .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
                        )
                        .padding(.horizontal, MobileDesignSystem.Spacing.lg)

                        // Output Card
                        if !outputText.isEmpty || isRunning {
                            VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.sm) {
                                HStack {
                                    Label("Result", systemImage: "checkmark.circle.fill")
                                        .font(MobileDesignSystem.Typography.headline)
                                        .foregroundColor(MobileDesignSystem.Colors.successGreen)
                                    Spacer()
                                    Button(action: copyOutput) {
                                        Image(systemName: "doc.on.doc")
                                            .foregroundColor(MobileDesignSystem.Colors.accent)
                                    }
                                }

                                Text(outputText.isEmpty ? "Generating rewrite..." : outputText)
                                    .font(MobileDesignSystem.Typography.body)
                                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(MobileDesignSystem.Spacing.md)
                            .background(MobileDesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg))
                            .overlay(
                                RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg)
                                    .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
                            )
                            .padding(.horizontal, MobileDesignSystem.Spacing.lg)
                        }
                    }
                    .padding(.vertical, MobileDesignSystem.Spacing.md)
                }
            }
            .navigationTitle("AI Transforms")
        }
    }

    // MARK: - Actions

    private func pasteInput() {
        if let str = PlatformPasteboard.string() {
            inputText = str
            MobileDesignSystem.Haptics.light()
        }
    }

    private func copyOutput() {
        PlatformPasteboard.copy(outputText)
        MobileDesignSystem.Haptics.success()
    }

    private func runTransform() {
        MobileDesignSystem.Haptics.medium()
        isRunning = true
        outputText = ""

        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                // Formatting simulation
                let promptDesc = customPrompt.isEmpty ? "Polished text" : customPrompt
                outputText = "✨ \(promptDesc):\n\n" + inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                isRunning = false
                MobileDesignSystem.Haptics.success()
            }
        }
    }
}
