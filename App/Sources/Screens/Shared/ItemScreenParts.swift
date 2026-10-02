import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

// The pieces the Transcript screen and the Document screen share (review R6a-6). They were two copies, and the UX
// audit's fixes had landed in one and not the other: the action bar's baseline and large-content labels (F40, F50),
// the Copy announcement (F55), a 44 pt More button (F56), Delete in More (F53), and the reload that makes a Retry
// show its result (R6a-3). Each now exists once, here.

/// Builds a screen's objects once, on its first render, and keeps them for the screen's life (review R6a-5).
///
/// A `@State` given an object in `init` allocates that object again every time the parent re-renders (SwiftUI keeps
/// only the first one), and the Transcript screen's player registers an audio-session observer when it is made. This
/// box is the only thing allocated per `init` (`@State private var box = OnceBox<…>()`); `get` makes the real objects
/// the first time it is read.
@MainActor final class OnceBox<Value> {
    private var value: Value?

    /// How many times `make` ran (tests).
    private(set) var makeCount = 0

    func get(_ make: () -> Value) -> Value {
        if let value { return value }
        let made = make()
        value = made
        makeCount += 1
        return made
    }
}

/// What a Library item is called in its screen's words: "transcript", "text" (a typed or pasted note) or "document".
enum ItemNoun {
    static func of(_ item: some TranscriptionRowFields) -> String {
        item.isTextItem ? "text" : item.isDocument ? "document" : "transcript"
    }

    /// "Rename transcript", "Rename text", "Rename document".
    static func renameTitle(for item: some TranscriptionRowFields) -> String {
        "Rename \(of(item))"
    }

    /// "Renames the transcript", "Renames the text", …
    static func renameHint(for item: some TranscriptionRowFields) -> String {
        "Renames the \(of(item))"
    }

    /// The rename alert's line: what an empty title falls back to.
    static func renameMessage(for item: some TranscriptionRowFields) -> String {
        item.isDocument
            ? "Leave it empty to use the document’s own title." : "Leave it empty to use the automatic title."
    }
}

/// Copy on the Transcript and Document screens: local-only (`ContentClipboard`), announced to VoiceOver (F55).
@MainActor enum ItemCopy {
    static func copy(_ text: String) {
        ContentClipboard.copy(text)
        AccessibilityNotification.Announcement("Copied").post()
    }
}

/// The toolbar's title: the star, the title (tap to rename) and one meta line.
struct ItemTitleHeader: View {
    let item: Transcription
    let meta: String
    let onFavorite: () -> Void
    let onRename: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                Button(action: onFavorite) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .chirpGlyph(13, .semibold, relativeTo: .subheadline, maxScale: 1.6)
                        .foregroundStyle(item.isFavorite ? Tokens.Color.favorite : Tokens.Color.mutedText)
                        .frame(minWidth: Tokens.Metric.minTapTarget, minHeight: Tokens.Metric.minTapTarget)  // F47
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // F67: one name ("Favorite"); VoiceOver says "selected" while it is on.
                .accessibilityLabel("Favorite")
                .accessibilityAddTraits(item.isFavorite ? .isSelected : [])
                Button(action: onRename) {
                    Text(item.displayTitle)
                        .chirpFont(16, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .accessibilityHint(ItemNoun.renameHint(for: item))
            }
            Text(meta)
                .chirpFont(11.5)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: 240)
    }
}

/// The toolbar's More menu: Rename, Favorite, Copy Text and Extract fields when the text is there, then Delete…
struct ItemMoreMenu: View {
    let item: Transcription?
    let onRename: () -> Void
    let onFavorite: () -> Void
    let onCopy: () -> Void
    let onExtractFields: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(action: onRename) {
                Label("Rename…", systemImage: "pencil")
            }
            if let item {
                Button(action: onFavorite) {
                    Label(
                        LibraryFavoriteCopy.title(isFavorite: item.isFavorite),
                        systemImage: item.isFavorite ? "star.slash" : "star")
                }
            }
            if item?.status == .completed {
                Button(action: onCopy) {
                    Label("Copy Text", systemImage: "doc.on.doc")
                }
                Button(action: onExtractFields) {
                    Label(ExtractFieldsViewModel.menuTitle, systemImage: "list.bullet.rectangle")
                }
            }
            if item != nil {
                Divider()
                // F53: the Library's question, then the Library's delete.
                Button(role: .destructive, action: onDelete) {
                    Label("Delete…", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Tokens.Color.ink)
                .frame(width: Tokens.Metric.minTapTarget, height: Tokens.Metric.minTapTarget)  // F56
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options")
        .disabled(item == nil)
    }
}

/// The card shown instead of the text while it is not there: a job's real progress, a failure with Retry, or why the
/// item cannot be opened. It reads the job center itself, so only this card follows job progress (review R6a-10).
struct ItemStatusPanel: View {
    @Environment(AppEnvironment.self) private var environment

    enum Content: Equatable {
        /// The item's job is running (or queued); `waitingMessage` says what appears and when.
        case processing(message: String)
        case problem(title: String, message: String, isError: Bool, canRetry: Bool)
    }

    let id: UUID
    let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                switch content {
                case .processing(let message):
                    let progress = environment.jobCenter.progress[id]
                    title(progress.map(Formatting.progress) ?? "Waiting to start", isError: false)
                    if let fraction = progress?.determinateFraction {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .tint(Tokens.Color.accent)
                    }
                    self.message(message)
                case .problem(let title, let message, let isError, let canRetry):
                    self.title(title, isError: isError)
                    self.message(message)
                    if canRetry {
                        Button("Retry") { environment.retry(id) }
                            .buttonStyle(.chirp(.filled, size: .compact))
                            .padding(.top, Tokens.Spacing.xxs)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chirpCard(radius: Tokens.Radius.m, padding: Tokens.Spacing.m)
            .padding(Tokens.Spacing.xl)
        }
    }

    private func title(_ text: String, isError: Bool) -> some View {
        Text(text)
            .chirpFont(17, .semibold)
            .monospacedDigit()
            .foregroundStyle(isError ? AppColor.error : Tokens.Color.ink)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .chirpFont(14)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// When a Transcript or Document screen re-reads its row (review R6a-3): when its job starts, changes stage or ends,
/// and when the row's stored status changes. The second covers work that never reports to the job center, such as a
/// dictation's Retry, so the screen never keeps showing "Couldn't transcribe" after the text arrived.
struct ItemReloadKey: Equatable {
    var stage: PipelineStage?
    var status: Transcription.Status?
}

/// Watches `ItemReloadKey` for one row and calls `reload` when it changes. An invisible background view, so the job
/// center's and the Library's updates for other rows re-evaluate only this watcher, not the whole screen (R6a-10).
struct ItemReloadWatcher: View {
    @Environment(AppEnvironment.self) private var environment
    let id: UUID
    let reload: () -> Void

    var body: some View {
        let key = ItemReloadKey(
            stage: environment.jobCenter.progress[id]?.stage,
            status: environment.library.items.first { $0.id == id }?.status)
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: key) { _, _ in reload() }
    }
}

/// The bottom action bar of the Transcript and Document screens: Copy, Share (its menu), Listen and Transform, in the
/// shared `ChirpActionBar` (one row, or two columns at large text, never a shrunken label).
struct ItemActionBar<ShareMenu: View>: View {
    let copied: Bool
    let onCopy: () -> Void
    let listen: ListenBarButton
    let onTransform: () -> Void
    @ViewBuilder let shareMenu: () -> ShareMenu

    var body: some View {
        ChirpActionBar {
            ChirpActionBarItem(
                copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc", action: onCopy)
            Menu {
                shareMenu()
            } label: {
                ChirpActionBarLabel("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityLabel("Share")
            listen
            ChirpActionBarItem("Transform", systemImage: "sparkles", emphasized: true, action: onTransform)
        }
    }
}

/// Speaker colors by order of first speech (R6a-18): the transcript and the Notes sheet color "Speaker 2" the same.
enum SpeakerPalette {
    /// Speaker id → palette index, in the order the ids first appear (nil entries are skipped).
    static func order(_ speakerIDsInSpeechOrder: [String?]) -> [String: Int] {
        var order: [String: Int] = [:]
        for id in speakerIDsInSpeechOrder.compactMap({ $0 }) where order[id] == nil {
            order[id] = order.count
        }
        return order
    }

    /// The palette index of each of `roster`'s speakers: by first speech where `speechOrder` knows them, then the
    /// rest after them in roster order.
    static func indices(roster: [String], speechOrder: [String: Int]) -> [String: Int] {
        var result = speechOrder.filter { roster.contains($0.key) }
        var next = (result.values.max() ?? -1) + 1
        for id in roster where result[id] == nil {
            result[id] = next
            next += 1
        }
        return result
    }
}

/// "Partial audio" on an item's own screen (the Library rows already show the chip): the recording ends early, so
/// the text may stop short (a meeting recovered after Parakeet was closed, or a dictation that stopped on its own).
struct PartialAudioNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
            StatusChip.partialAudio()
            Text("The recording ends early, so the text may stop short.")
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The Library's delete question for an item, then the Library's delete (running job cancelled, the row, its audio
    /// or file copy and its documents removed); `onDeleted` runs after (the screen goes back).
    func itemDeleteConfirmation(
        isPresented: Binding<Bool>, item: Transcription?, environment: AppEnvironment,
        onDeleted: @escaping () -> Void, onError: @escaping (String) -> Void
    ) -> some View {
        confirmationDialog(
            item.map { LibraryDeleteCopy.title(for: $0) } ?? "Delete?", isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let id = item?.id else { return }
                Task {
                    do {
                        try await environment.delete(id)
                        onDeleted()
                    } catch {
                        onError(Formatting.message(for: error))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                item.map {
                    LibraryDeleteCopy.message(
                        for: $0, documentTitles: environment.library.documents(madeFrom: $0.id).map(\.typeTitle))
                } ?? "")
        }
    }
}
