import SwiftUI
import MacParakeetCore
#if canImport(SwiftStreamingMarkdown)
import SwiftStreamingMarkdown
#endif

/// Meeting detail review screen on iOS.
/// Displays speaker diarization bubbles, timeline scrubber, and AI summaries / action items.
public struct IOSMeetingDetailView: View {
    public enum DetailTab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case aiSummary = "AI Summary"
        case notes = "Notes"
        public var id: String { rawValue }
    }

    public let transcription: Transcription
    @State private var selectedTab: DetailTab = .transcript
    @State private var isPlaying: Bool = false
    @State private var currentProgress: Double = 0.0
    @State private var playbackRate: Float = 1.0
    @State private var currentPlaybackMs: Int = 0

    public init(transcription: Transcription) {
        self.transcription = transcription
    }

    private var durationMs: Int {
        transcription.durationMs ?? 0
    }

    private var segments: [TranscriptSegmentRecord] {
        transcription.transcriptSegments ?? []
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            MobileDesignSystem.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Segmented Tab Picker
                Picker("Tab", selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, MobileDesignSystem.Spacing.lg)
                .padding(.vertical, MobileDesignSystem.Spacing.sm)

                // Tab Content
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.md) {
                        switch selectedTab {
                        case .transcript:
                            transcriptContentView
                        case .aiSummary:
                            aiSummaryContentView
                        case .notes:
                            notesContentView
                        }
                    }
                    .padding(.horizontal, MobileDesignSystem.Spacing.lg)
                    .padding(.top, MobileDesignSystem.Spacing.sm)
                    .padding(.bottom, 120) // Clearance for floating player bar
                }
            }

            // Bottom Audio Player Bar
            if durationMs > 0 {
                IOSAudioPlayerBar(
                    isPlaying: $isPlaying,
                    currentProgress: $currentProgress,
                    playbackRate: $playbackRate,
                    totalDurationMs: durationMs,
                    onPlayPause: {
                        isPlaying.toggle()
                    },
                    onSeek: { progress in
                        currentPlaybackMs = Int(Double(durationMs) * progress)
                    }
                )
                .padding(.horizontal, MobileDesignSystem.Spacing.md)
                .padding(.bottom, MobileDesignSystem.Spacing.md)
            }
        }
        .navigationTitle(transcription.titleOverride ?? transcription.derivedTitle ?? transcription.fileName)
        .mobileNavigationBarTitleDisplayModeInline()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: copyTranscript) {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    Button(action: shareTranscript) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundColor(MobileDesignSystem.Colors.accent)
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var transcriptContentView: some View {
        if segments.isEmpty {
            // Fallback to plain text transcript
            let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? "No transcript available."
            Text(text)
                .font(MobileDesignSystem.Typography.body)
                .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                .lineSpacing(4)
                .padding(MobileDesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MobileDesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))
        } else {
            // Diarized speaker segments
            LazyVStack(spacing: MobileDesignSystem.Spacing.sm) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    let isCurrentSegment = currentPlaybackMs >= segment.startMs && currentPlaybackMs < segment.endMs
                    IOSSpeakerBubbleView(
                        segment: segment,
                        speakerIndex: index,
                        isPlaying: isCurrentSegment,
                        onSeek: { targetMs in
                            currentPlaybackMs = targetMs
                            currentProgress = Double(targetMs) / Double(max(durationMs, 1))
                            isPlaying = true
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var aiSummaryContentView: some View {
        VStack(alignment: .leading, spacing: MobileDesignSystem.Spacing.md) {
            // Overview card
            VStack(alignment: .leading, spacing: 6) {
                Label("Executive Summary", systemImage: "sparkles")
                    .font(MobileDesignSystem.Typography.headline)
                    .foregroundColor(MobileDesignSystem.Colors.accent)

                Text(transcription.derivedSnippet ?? "AI summary generation is available via the Transforms tab.")
                    .font(MobileDesignSystem.Typography.body)
                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                    .lineSpacing(3)
            }
            .padding(MobileDesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MobileDesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md)
                    .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
            )

            // Meeting info card
            VStack(alignment: .leading, spacing: 8) {
                Label("Details", systemImage: "info.circle")
                    .font(MobileDesignSystem.Typography.headline)
                    .foregroundColor(MobileDesignSystem.Colors.textPrimary)

                HStack {
                    Text("Date")
                        .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                    Spacer()
                    Text(transcription.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                }
                .font(MobileDesignSystem.Typography.bodySmall)

                Divider()

                HStack {
                    Text("Engine")
                        .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                    Spacer()
                    Text(transcription.engine ?? "Parakeet TDT CoreML")
                        .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                }
                .font(MobileDesignSystem.Typography.bodySmall)

                if let speakers = transcription.speakerCount {
                    Divider()
                    HStack {
                        Text("Speakers Detected")
                            .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                        Spacer()
                        Text("\(speakers)")
                            .foregroundColor(MobileDesignSystem.Colors.textPrimary)
                    }
                    .font(MobileDesignSystem.Typography.bodySmall)
                }
            }
            .padding(MobileDesignSystem.Spacing.md)
            .background(MobileDesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md)
                    .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var notesContentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Meeting Notes", systemImage: "note.text")
                .font(MobileDesignSystem.Typography.headline)
                .foregroundColor(MobileDesignSystem.Colors.textPrimary)

            let notes = transcription.userNotes ?? "No notes were taken during this recording."
            Text(notes)
                .font(MobileDesignSystem.Typography.body)
                .foregroundColor(notes.isEmpty ? MobileDesignSystem.Colors.textTertiary : MobileDesignSystem.Colors.textPrimary)
                .padding(MobileDesignSystem.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MobileDesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: MobileDesignSystem.CornerRadius.md)
                        .stroke(MobileDesignSystem.Colors.border, lineWidth: 1)
                )
        }
    }

    // MARK: - Actions

    private func copyTranscript() {
        let content = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        PlatformPasteboard.copy(content)
        MobileDesignSystem.Haptics.success()
    }

    private func shareTranscript() {
        #if canImport(UIKit) && !os(macOS)
        let content = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        let activityVC = UIActivityViewController(activityItems: [content], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #endif
    }
}
