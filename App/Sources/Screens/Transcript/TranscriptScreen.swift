import ChirpCore
import ChirpExport
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One transcript (canvas `Transcript.dc.html`): header with star and rename, Transcript / Notes / Ask tabs,
/// player bar, speaker paragraphs with tappable timestamps, and Copy / Share / Transform.
struct TranscriptScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let id: UUID

    @State private var model: TranscriptViewModel
    @State private var player: AudioPlayerModel
    @State private var hasLoaded = false
    @State private var placeholder: Placeholder?
    @State private var shareItem: ShareItem?
    @State private var actionError: String?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var copied = false

    init(id: UUID, environment: AppEnvironment) {
        self.id = id
        _model = State(initialValue: environment.makeTranscriptViewModel(id: id))
        _player = State(initialValue: AudioPlayerModel(session: environment.audioSession))
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            content
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) { titleHeader }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.transcription?.status == .completed {
                bottomBar
            }
        }
        .task {
            await model.load()
            hasLoaded = true
            player.load(model.mediaURL)
        }
        .onChange(of: environment.jobCenter.progress[id]?.stage) { _, _ in
            // A job started, moved on or ended for this row: re-read it (the text appears when it completes).
            Task {
                await model.load()
                player.load(model.mediaURL)
            }
        }
        .onDisappear { player.stop() }
        .sheet(item: $placeholder) { NotBuiltYetSheet(placeholder: $0) }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert("Rename transcript", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the automatic title.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Header

    private var titleHeader: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                if let item = model.transcription {
                    Button {
                        Task { await toggleFavorite() }
                    } label: {
                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.isFavorite ? Tokens.Color.favorite : Tokens.Color.mutedText)
                            .frame(minWidth: 24, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

                    Button {
                        startRename()
                    } label: {
                        Text(item.displayTitle)
                            .chirpFont(16, .semibold)
                            .foregroundStyle(Tokens.Color.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Renames the transcript")
                }
            }
            if let item = model.transcription {
                Text(Formatting.transcriptMeta(for: item))
                    .chirpFont(11.5)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 240)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                startRename()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            if let item = model.transcription {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Label(
                        item.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: item.isFavorite ? "star.slash" : "star")
                }
            }
            if model.transcription?.status == .completed {
                Button {
                    copyText()
                } label: {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Tokens.Color.ink)
        }
        .accessibilityLabel("More options")
        .disabled(model.transcription == nil)
    }

    // MARK: - Tabs (Transcript real; Notes M3, Ask M4)

    private var tabs: some View {
        HStack(spacing: 24) {
            tabButton("Transcript", selected: true) {}
            tabButton("Notes", selected: false) { placeholder = .notes }
            tabButton("Ask", selected: false) { placeholder = .ask }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Color.border).frame(height: 1)
        }
        .padding(.horizontal, 24)
    }

    private func tabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .chirpFont(14.5, selected ? .bold : .semibold)
                .foregroundStyle(selected ? Tokens.Color.ink : Tokens.Color.secondary)
                .frame(minHeight: 43)
                .overlay(alignment: .bottom) {
                    if selected {
                        Rectangle().fill(Tokens.Color.accent).frame(height: 2.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "" : "Not built yet")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let item = model.transcription {
            switch item.status {
            case .completed:
                completedContent(item)
            case .processing:
                statusPanel(
                    title: environment.jobCenter.progress[id].map(Formatting.progress) ?? "Waiting to start",
                    message: "The text appears here when Parakeet finishes. You can leave this screen meanwhile.",
                    fraction: environment.jobCenter.progress[id]?.fraction,
                    isError: false,
                    canRetry: false)
            case .failed, .interrupted, .cancelled:
                statusPanel(
                    title: item.status == .cancelled ? "Cancelled" : "Couldn’t transcribe",
                    message: Formatting.statusLine(for: item, progress: nil) ?? "",
                    fraction: nil,
                    isError: item.status != .cancelled,
                    canRetry: true)
            }
        } else if let error = model.loadError {
            statusPanel(
                title: "Couldn’t open this transcript", message: error, fraction: nil, isError: true, canRetry: false)
        } else if hasLoaded {
            statusPanel(
                title: "This transcript is gone", message: "It may have been deleted.", fraction: nil, isError: false,
                canRetry: false)
        } else {
            Spacer()
        }
    }

    private func completedContent(_ item: Transcription) -> some View {
        let paragraphs = model.paragraphs
        let hasTimings = !(item.wordTimestamps ?? []).isEmpty
        let speakerOrder = Self.speakerOrder(paragraphs)
        let current =
            (player.isAvailable && hasTimings)
            ? TranscriptTiming.currentParagraphIndex(in: paragraphs, atMs: Int(player.currentTime * 1000)) : nil
        return VStack(spacing: 0) {
            if player.isAvailable {
                PlayerBar(player: player)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }
            ScrollView {
                if paragraphs.isEmpty {
                    EmptyStateView(title: "No speech found", message: "Parakeet didn’t hear any words in this file.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                            paragraphView(
                                paragraph,
                                speakerIndex: paragraph.speakerId.flatMap { speakerOrder[$0] },
                                showsTiming: hasTimings,
                                isCurrent: index == current)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func paragraphView(
        _ paragraph: TranscriptParagraph, speakerIndex: Int?, showsTiming: Bool, isCurrent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTiming {
                HStack(spacing: 7) {
                    if let speakerIndex {
                        SpeakerDot(label: model.speakerLabel(for: paragraph.speakerId), speakerIndex: speakerIndex)
                    }
                    Button {
                        seek(toMs: paragraph.startMs)
                    } label: {
                        Text(Formatting.clock(ms: paragraph.startMs))
                            .chirpFont(11.5)
                            .monospacedDigit()
                            .foregroundStyle(player.isAvailable ? AppColor.accentText : Tokens.Color.secondary)
                            .frame(minWidth: 44, minHeight: 28, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.isAvailable)
                    .accessibilityLabel("Play from \(Formatting.clock(ms: paragraph.startMs))")
                }
            }
            Text(paragraph.text)
                .chirpFont(16)
                .lineSpacing(6)
                .foregroundStyle(Tokens.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.cover, style: .continuous)
                .fill(isCurrent ? AppColor.tintFill : Color.clear)
        )
        .padding(.horizontal, -10)
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }

    private func statusPanel(title: String, message: String, fraction: Double?, isError: Bool, canRetry: Bool)
        -> some View
    {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .chirpFont(17, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(isError ? AppColor.error : Tokens.Color.ink)
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(Tokens.Color.accent)
                }
                Text(message)
                    .chirpFont(14)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if canRetry {
                    Button {
                        environment.retry(id)
                    } label: {
                        CapsuleButtonLabel(title: "Retry", kind: .filled)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chirpCard(radius: Tokens.Radius.m, padding: 16)
            .padding(24)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton(title: copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                copyText()
            }
            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.displayName) { share(format) }
                }
            } label: {
                barLabel(title: "Share", systemImage: "square.and.arrow.up", emphasized: false)
            }
            .accessibilityLabel("Share")
            barButton(title: "Transform", systemImage: "sparkles", emphasized: true) {
                placeholder = .transform
            }
        }
        .frame(minHeight: 58)
        .background(
            Tokens.Color.ground.opacity(0.94)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.Color.border).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func barButton(title: String, systemImage: String, emphasized: Bool = false, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            barLabel(title: title, systemImage: systemImage, emphasized: emphasized)
        }
        .buttonStyle(.plain)
    }

    private func barLabel(title: String, systemImage: String, emphasized: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
            Text(title)
                .chirpFont(11, emphasized ? .bold : .semibold)
        }
        .foregroundStyle(emphasized ? AppColor.accentText : Tokens.Color.ink)
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func seek(toMs ms: Int) {
        player.seek(to: TimeInterval(ms) / 1000)
        if !player.isPlaying { player.play() }
    }

    private func copyText() {
        // .localOnly keeps transcript text off Universal Clipboard, which would otherwise sync it to the owner's
        // other Apple devices (Minor 5, final-review).
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: model.plainText]],
            options: [.localOnly: true]
        )
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func share(_ format: ExportFormat) {
        do {
            shareItem = ShareItem(url: try model.exportFile(format))
        } catch {
            actionError = Formatting.message(for: error)
        }
    }

    private func startRename() {
        renameText = model.transcription?.titleOverride ?? model.transcription?.displayTitle ?? ""
        isRenaming = true
    }

    private func rename() async {
        do {
            try await model.rename(renameText)
        } catch {
            actionError = Formatting.message(for: error)
        }
    }

    private func toggleFavorite() async {
        do {
            try await model.toggleFavorite()
        } catch {
            actionError = Formatting.message(for: error)
        }
    }

    /// Speaker id → palette index, in order of first speech.
    static func speakerOrder(_ paragraphs: [TranscriptParagraph]) -> [String: Int] {
        var order: [String: Int] = [:]
        for speakerId in paragraphs.compactMap(\.speakerId) where order[speakerId] == nil {
            order[speakerId] = order.count
        }
        return order
    }
}

/// Which paragraph the playhead is in.
enum TranscriptTiming {
    /// The last paragraph that starts at or before `ms`, or nil before the first one starts.
    static func currentParagraphIndex(in paragraphs: [TranscriptParagraph], atMs ms: Int) -> Int? {
        var current: Int?
        for (index, paragraph) in paragraphs.enumerated() {
            if paragraph.startMs <= ms {
                current = index
            } else {
                break
            }
        }
        return current
    }
}

extension ExportError: ExportErrorDescribing {
    var readableMessage: String {
        switch self {
        case .noTimestamps:
            "SRT and VTT need word timings, and this transcript has none. Share it as Text or Markdown instead."
        }
    }
}
