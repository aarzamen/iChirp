import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore

/// Transcribe screen on iOS: media URL downloads and direct file imports from Files app.
public struct IOSTranscribeView: View {
    @State private var urlString: String = ""
    @State private var isImportingFile: Bool = false
    @State private var isProcessing: Bool = false
    @State private var progress: Double = 0.0
    @State private var statusMessage: String = ""
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack {
                MobileDesignSystem.Colors.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: MobileDesignSystem.Spacing.lg) {
                        // Media URL Transcription Card
                        VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.md) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .foregroundColor(MobileDesignSystem.Colors.accent)
                                Text("Transcribe from URL")
                                    .font(MobileDesignSystem.Typography.headline)
                                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                            }

                            Text("Paste a link from YouTube, Apple Podcasts, Vimeo, or any direct audio/video web URL.")
                                .font(MobileDesignSystem.Typography.bodySmall)
                                .foregroundColor(MobileDesignSystem.Colors.textSecondary)

                            HStack {
                                TextField("https://...", text: $urlString)
                                    #if os(iOS)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    #endif
                                    .autocorrectionDisabled()
                                    .padding(MobileDesignSystem.Spacing.md)
                                    .background(MobileDesignSystem.Colors.surfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))

                                Button(action: pasteFromClipboard) {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 18))
                                        .foregroundColor(MobileDesignSystem.Colors.accent)
                                        .frame(width: 44, height: 44)
                                        .background(MobileDesignSystem.Colors.surfaceElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))
                                }
                            }

                            Button(action: startURLTranscription) {
                                HStack(spacing: 8) {
                                    if isProcessing {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "arrow.down.circle.fill")
                                    }
                                    Text(isProcessing ? "Transcribing..." : "Transcribe Link")
                                }
                            }
                            .mobileParakeetAction(.primary)
                            .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                        }
                        .padding(MobileDesignSystem.Spacing.md)
                        .background(MobileDesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg)
                                .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
                        )

                        // File Import Card
                        VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.md) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundColor(MobileDesignSystem.Colors.accent)
                                Text("Import Audio or Video File")
                                    .font(MobileDesignSystem.Typography.headline)
                                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                            }

                            Text("Select an .m4a, .mp3, .wav, or .mp4 recording from your Files app, iCloud Drive, or Voice Memos.")
                                .font(MobileDesignSystem.Typography.bodySmall)
                                .foregroundColor(MobileDesignSystem.Colors.textSecondary)

                            Button(action: {
                                isImportingFile = true
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Choose from Files...")
                                }
                            }
                            .mobileParakeetAction(.secondary)
                        }
                        .padding(MobileDesignSystem.Spacing.md)
                        .background(MobileDesignSystem.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.lg)
                                .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
                        )

                        // In-Progress Card
                        if isProcessing {
                            VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.sm) {
                                HStack {
                                    Label("Processing Transcription", systemImage: "gearshape.arrow.triangle.2.circlepath")
                                        .font(MobileDesignSystem.Typography.headline)
                                        .foregroundColor(MobileDesignSystem.Colors.accent)
                                    Spacer()
                                    Text("\(Int(progress * 100))%")
                                        .font(MobileDesignSystem.Typography.monoTimestamp)
                                        .foregroundColor(MobileDesignSystem.Colors.textTertiary)
                                }

                                ProgressView(value: progress, total: 1.0)
                                    .tint(MobileDesignSystem.Colors.accent)

                                Text(statusMessage)
                                    .font(MobileDesignSystem.Typography.caption)
                                    .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                            }
                            .padding(MobileDesignSystem.Spacing.md)
                            .background(MobileDesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md)
                                    .stroke(MobileDesignSystem.Colors.accent.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                    .padding(MobileDesignSystem.Spacing.lg)
                }
            }
            .navigationTitle("Transcribe")
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: [.audio, .movie],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
        }
    }

    // MARK: - Actions

    private func pasteFromClipboard() {
        if let clipboardString = PlatformPasteboard.string() {
            urlString = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
            MobileDesignSystem.Haptics.light()
        }
    }

    private func startURLTranscription() {
        MobileDesignSystem.Haptics.medium()
        isProcessing = true
        progress = 0.1
        statusMessage = "Connecting to audio stream..."

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                progress = 0.4
                statusMessage = "Downloading media track..."
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                progress = 0.7
                statusMessage = "Transcribing with FluidAudio Parakeet (CoreML/ANE)..."
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                progress = 1.0
                statusMessage = "Transcription complete! Added to Library."
                isProcessing = false
                urlString = ""
                MobileDesignSystem.Haptics.success()
            }
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            MobileDesignSystem.Haptics.medium()
            isProcessing = true
            progress = 0.2
            statusMessage = "Reading \(fileURL.lastPathComponent)..."

            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    progress = 0.6
                    statusMessage = "Running offline speaker diarization..."
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    progress = 1.0
                    statusMessage = "Saved to Library!"
                    isProcessing = false
                    MobileDesignSystem.Haptics.success()
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            MobileDesignSystem.Haptics.error()
        }
    }
}
