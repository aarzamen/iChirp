import ChirpCore
import ChirpExport
import ChirpFeatures
import ChirpUI
import SwiftUI

/// One document (M5): its cover and facts, then the text (page by page for a PDF, with OCR pages marked). No player
/// and no SRT/VTT, because a document has no audio or timings. Copy, Share (Text, Markdown, JSON) and Transform work
/// on the text exactly as they do on a transcript, so M4 templates can use it. Plan 022: a typed or pasted text item
/// opens here too, and the summary card carries the privacy class control (as the Transcript's tab row does).
///
/// Plan 024 Task 9 (R6a-6): the title, More menu (now with Delete…), status card, reload and action bar are the
/// Transcript screen's (`ItemScreenParts`), so the audit's fixes (one baseline, large-content labels, the Copy
/// announcement, a 44 pt More button) hold here too; its view model is made once (`OnceBox`, R6a-5).
struct DocumentScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    @State private var box = OnceBox<TranscriptViewModel>()
    @State private var hasLoaded = false
    @State private var shareItem: ShareItem?
    @State private var actionError: String?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var copied = false
    @State private var isTransforming = false
    /// M6: Extract fields from a typed or pasted note (no audio, so a field cannot seek).
    @State private var isExtractingFields = false
    /// Plan 022: Share → Voice message.
    @State private var voiceMessage: VoiceMessageJob?
    /// The item's class as the routers use it, with why (UX audit F51): a Personal text with a SOAP note reads
    /// "Clinical (it has a SOAP note)".
    @State private var privacy: EffectivePrivacyExplanation?
    /// More → Delete… is asking (the Library's question).
    @State private var isConfirmingDelete = false

    /// Formats that make sense without timings.
    static let exportFormats: [ExportFormat] = [.txt, .markdown, .json]

    private var model: TranscriptViewModel {
        box.get { environment.makeTranscriptViewModel(id: id) }
    }

    var body: some View {
        content
            .voiceReading(environment.voicePlayer, confirmationEnabled: !isTransforming && voiceMessage == nil) {
                $0 == .document(id: id)  // plan 020
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
            .background {
                // The job's stage or the row's status changed: re-read the row (not on every OCR tick, R6a-6).
                ItemReloadWatcher(id: id) { Task { await model.load() } }
            }
            .task {
                await model.load()
                hasLoaded = true
                await loadPrivacy()
            }
            // M4: a document runs the same templates as a transcript (its text is the "transcript" input).
            .sheet(
                isPresented: $isTransforming,
                onDismiss: {
                    Task {
                        await environment.deliverableLibrary.load()
                        await loadPrivacy()  // a SOAP note made just now raises the class
                    }
                }
            ) {
                if let item = model.transcription {
                    TransformSheet(
                        transcriptionID: id, transcriptTitle: item.displayTitle, privacyClass: item.privacyClass,
                        environment: environment)
                }
            }
            .sheet(isPresented: $isExtractingFields) {
                if let item = model.transcription {
                    ExtractFieldsSheet(
                        transcriptionID: id, transcriptTitle: item.displayTitle, environment: environment,
                        onSeek: { _ in })
                }
            }
            .sheet(item: $voiceMessage) { job in VoiceMessageSheet(job: job, environment: environment) }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .itemDeleteConfirmation(
                isPresented: $isConfirmingDelete, item: model.transcription, environment: environment,
                onDeleted: { dismiss() }, onError: { actionError = $0 }
            )
            .alert(model.transcription.map(ItemNoun.renameTitle) ?? "Rename", isPresented: $isRenaming) {
                TextField("Title", text: $renameText)
                Button("Save") { Task { await rename() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.transcription.map(ItemNoun.renameMessage) ?? "")
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

    @ViewBuilder private var titleHeader: some View {
        if let item = model.transcription {
            // The format and size show once, here; the card below names the kind (UX audit F69).
            ItemTitleHeader(
                item: item, meta: Formatting.day(item.createdAt) + " · " + DocumentRow.meta(for: item),
                onFavorite: { Task { await toggleFavorite() } }, onRename: startRename)
        }
    }

    private var moreMenu: some View {
        ItemMoreMenu(
            item: model.transcription, onRename: startRename, onFavorite: { Task { await toggleFavorite() } },
            onCopy: copyText, onExtractFields: { isExtractingFields = true },
            onDelete: { isConfirmingDelete = true })
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        let noun = model.transcription.map(ItemNoun.of) ?? "document"
        if let item = model.transcription {
            switch item.status {
            case .completed:
                completed(item)
            case .processing:
                ItemStatusPanel(
                    id: id,
                    content: .processing(
                        message: "The text appears here when Parakeet has read the document. You can leave this screen."
                    ))
            case .failed, .interrupted, .cancelled:
                ItemStatusPanel(
                    id: id,
                    content: .problem(
                        title: item.status == .cancelled ? "Cancelled" : "Couldn’t read this \(noun)",
                        message: Formatting.statusLine(for: item, progress: nil) ?? "",
                        isError: item.status != .cancelled, canRetry: true))
            }
        } else if let error = model.loadError {
            ItemStatusPanel(
                id: id,
                content: .problem(title: "Couldn’t open this \(noun)", message: error, isError: true, canRetry: false))
        } else if hasLoaded {
            ItemStatusPanel(
                id: id,
                content: .problem(
                    title: "This \(noun) is gone", message: "It may have been deleted.", isError: false,
                    canRetry: false))
        } else {
            Color.clear
        }
    }

    private func completed(_ item: Transcription) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                summaryCard(item)
                // Plan 023 (UX audit F43): the documents made from this item.
                MadeFromThisSection(sourceID: id)
                if let pages = item.documentPages, !pages.isEmpty {
                    ForEach(pages, id: \.number) { page in
                        pageView(page, total: pages.count)
                    }
                } else {
                    ForEach(Array(Self.paragraphs(of: item.displayText).enumerated()), id: \.offset) { _, paragraph in
                        paragraphText(paragraph)
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.top, Tokens.Spacing.m)
            .padding(.bottom, Tokens.Spacing.xl)
        }
    }

    /// The cover, what the item is and where it was read, then the privacy class on its own row, so nothing wraps into
    /// a narrow column (UX audit F69).
    private func summaryCard(_ item: Transcription) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                DocumentCover(format: item.documentFormat, size: 56, badge: DocumentRow.coverBadge(for: item))
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.kindTitle(for: item))
                        .chirpFont(14.5, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        item.isTextItem
                            ? "Saved on this iPhone. Only you can see it." : "Read on this iPhone. Only you can see it."
                    )
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            PrivacyClassControl(current: item.privacyClass, effective: privacy) { newClass in
                // Through the service, so documents made from this item are raised with it (never lowered).
                try await environment.deliverables.setPrivacyClass(newClass, transcriptionID: id)
                await model.load()
                await loadPrivacy()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChirpCardBackground(radius: Tokens.Radius.s))
    }

    private func loadPrivacy() async {
        privacy = try? await EffectivePrivacyExplanation.current(
            transcriptionID: id, transcripts: environment.store, deliverables: environment.deliverableStore)
    }

    /// "Markdown", "Data (JSON)".
    static func formatTitle(_ format: ExportFormat) -> String {
        format == .json ? "Data (JSON)" : format.displayName
    }

    /// "PDF document", "Typed text".
    static func kindTitle(for item: Transcription) -> String {
        if item.isTextItem { return "Typed text" }
        return item.documentFormat.map { "\($0.displayName) document" } ?? "Document"
    }

    private func pageView(_ page: DocumentPage, total: Int) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.xs) {
                SectionLabel("Page \(page.number) of \(total)")
                if page.method == .ocr {
                    Text("OCR")
                        .chirpFont(10.5, .bold)
                        // Text-safe ink on the tint fill (F8): `accentText` alone is 4.39:1 there.
                        .foregroundStyle(AppColor.accentTextOnTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppColor.tintFill))
                        .accessibilityLabel("Read with text recognition")
                }
            }
            if page.text.isEmpty {
                Text("No text on this page.")
                    .chirpFont(14)
                    .italic()
                    .foregroundStyle(Tokens.Color.secondary)
            } else {
                ForEach(Array(Self.paragraphs(of: page.text).enumerated()), id: \.offset) { _, paragraph in
                    paragraphText(paragraph)
                }
            }
        }
        .padding(.top, Tokens.Spacing.xxs)
    }

    private func paragraphText(_ text: String) -> some View {
        Text(text)
            .chirpFont(16)
            .lineSpacing(6)
            .foregroundStyle(Tokens.Color.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        ItemActionBar(
            copied: copied, onCopy: copyText,
            // Plan 020: reads the document's text aloud.
            listen: ListenBarButton(
                source: .document(id: id), privacyClass: model.transcription?.privacyClass ?? .clinical
            ) { model.transcription?.displayText ?? "" },
            onTransform: { isTransforming = true }
        ) {
            // One Share order on every screen: PDF, Word, Text, Voice message…, then the other formats (UX audit F54).
            // Plan 022 Step 6: page formats.
            ForEach(DocumentExportFormat.allCases, id: \.self) { format in
                Button(format.displayName) { shareDocument(format) }
            }
            Button(ExportFormat.txt.displayName) { share(.txt) }
            Divider()
            Button {
                voiceMessage = model.transcription.flatMap(VoiceMessageJob.item)
            } label: {
                Label("Voice message…", systemImage: "waveform.badge.plus")
            }
            Menu("More formats") {
                ForEach(Self.exportFormats.filter { $0 != .txt }, id: \.self) { format in
                    Button(Self.formatTitle(format)) { share(format) }
                }
            }
        }
    }

    // MARK: - Actions

    private func copyText() {
        // Local-only (same rule as transcripts), announced to VoiceOver (F55).
        ItemCopy.copy(model.plainText)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Plan 022 Step 6: a PDF or Word copy for the share sheet (rendered off the main actor).
    private func shareDocument(_ format: DocumentExportFormat) {
        Task {
            do {
                shareItem = ShareItem(url: try await model.exportDocument(format))
            } catch {
                actionError = Formatting.message(for: error)
            }
        }
    }

    /// TXT, Markdown, SRT, VTT or JSON for the share sheet (written off the main actor, review R4-20).
    private func share(_ format: ExportFormat) {
        Task {
            do {
                shareItem = ShareItem(url: try await model.exportFile(format))
            } catch {
                actionError = Formatting.message(for: error)
            }
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

    /// Blank-line-separated paragraphs (so a long document scrolls lazily, one paragraph per row).
    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
