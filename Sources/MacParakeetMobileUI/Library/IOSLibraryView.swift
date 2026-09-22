import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Library view for iOS: displays unified history of recordings and meetings with search and filters.
public struct IOSLibraryView: View {
    public enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case meetings = "Meetings"
        case dictations = "Dictations"
        public var id: String { rawValue }
    }

    @State private var filter: LibraryFilter = .all
    @State private var searchText: String = ""
    @State private var items: [Transcription] = []
    @State private var isLoading: Bool = false

    public init() {}

    private var filteredItems: [Transcription] {
        items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .meetings:
                matchesFilter = item.sourceType == .meeting
            case .dictations:
                matchesFilter = item.sourceType != .meeting
            }

            guard matchesFilter else { return false }

            if searchText.isEmpty { return true }
            let title = item.titleOverride ?? item.derivedTitle ?? item.fileName
            let text = item.cleanTranscript ?? item.rawTranscript ?? ""
            return title.localizedCaseInsensitiveContains(searchText) || text.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                MobileDesignSystem.Colors.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Filter picker
                    Picker("Filter", selection: $filter) {
                        ForEach(LibraryFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, MobileDesignSystem.Spacing.lg)
                    .padding(.vertical, MobileDesignSystem.Spacing.sm)

                    if filteredItems.isEmpty {
                        emptyStateView
                    } else {
                        List {
                            ForEach(filteredItems) { item in
                                NavigationLink(destination: IOSMeetingDetailView(transcription: item)) {
                                    IOSMeetingRowView(
                                        title: item.titleOverride ?? item.derivedTitle ?? item.fileName,
                                        previewText: item.derivedSnippet ?? item.cleanTranscript ?? item.rawTranscript ?? "",
                                        date: item.createdAt,
                                        durationMs: item.durationMs ?? 0,
                                        speakerCount: item.speakerCount,
                                        isMeeting: item.sourceType == .meeting,
                                        onCopy: {
                                            PlatformPasteboard.copy(item.cleanTranscript ?? item.rawTranscript ?? "")
                                        },
                                        onShare: {
                                            shareItem(item)
                                        },
                                        onDelete: {
                                            deleteItem(item)
                                        }
                                    )
                                }
                                .listRowBackground(MobileDesignSystem.Colors.surface)
                            }
                        }
                        #if os(iOS)
                        .listStyle(.insetGrouped)
                        #else
                        .listStyle(.inset)
                        #endif
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search transcripts & meetings")
            .navigationTitle("Library")
            .refreshable {
                await loadItems()
            }
            .task {
                await loadItems()
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: MobileDesignSystem.Spacing.md) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(MobileDesignSystem.Colors.textTertiary)

            Text("No Transcriptions Found")
                .font(MobileDesignSystem.Typography.headline)
                .foregroundColor(MobileDesignSystem.Colors.textPrimary)

            Text(searchText.isEmpty ? "Recorded meetings and voice dictations will appear here." : "No results matching \"\(searchText)\"")
                .font(MobileDesignSystem.Typography.bodySmall)
                .foregroundColor(MobileDesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MobileDesignSystem.Spacing.xl)

            Spacer()
        }
    }

    // MARK: - Actions

    private func loadItems() async {
        isLoading = true
        // Demo items for preview when database is cold
        if items.isEmpty {
            items = [
                Transcription(
                    createdAt: Date().addingTimeInterval(-3600),
                    fileName: "Team Standup Sync",
                    durationMs: 742000,
                    cleanTranscript: "Good morning everyone. Today we are finishing Phase 3 for the iPhone mobile UI and verifying audio session interruptions.",
                    speakerCount: 2,
                    transcriptSegments: [
                        TranscriptSegmentRecord(
                            startMs: 0,
                            endMs: 8000,
                            speakerId: "speaker_0",
                            speakerLabel: "Aaron",
                            text: "Good morning everyone. Today we are finishing Phase 3 for the iPhone mobile UI.",
                            wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 12)
                        ),
                        TranscriptSegmentRecord(
                            startMs: 8500,
                            endMs: 15000,
                            speakerId: "speaker_1",
                            speakerLabel: "Team",
                            text: "Sounds great, looking forward to testing it on device!",
                            wordRange: TranscriptSegmentWordRange(startIndex: 13, endIndexExclusive: 21)
                        )
                    ],
                    status: .completed,
                    sourceType: .meeting,
                    titleOverride: "Team Standup Sync",
                    derivedTitle: "Team Standup Sync",
                    derivedSnippet: "Good morning everyone. Today we are finishing Phase 3 for the iPhone mobile UI."
                ),
                Transcription(
                    createdAt: Date().addingTimeInterval(-86400),
                    fileName: "Voice Note: Product Architecture",
                    durationMs: 45000,
                    cleanTranscript: "Remember to verify the Jetsam limits on iOS keyboard extensions and keep CoreML weights loaded in the shared App Group.",
                    speakerCount: 1,
                    status: .completed,
                    sourceType: .file,
                    titleOverride: "Voice Note: Product Architecture",
                    derivedTitle: "Voice Note: Product Architecture",
                    derivedSnippet: "Remember to verify the Jetsam limits on iOS keyboard extensions."
                )
            ]
        }
        isLoading = false
    }

    private func deleteItem(_ item: Transcription) {
        withAnimation {
            items.removeAll { $0.id == item.id }
        }
    }

    private func shareItem(_ item: Transcription) {
        #if canImport(UIKit) && !os(macOS)
        let content = item.cleanTranscript ?? item.rawTranscript ?? ""
        let activityVC = UIActivityViewController(activityItems: [content], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #endif
    }
}
