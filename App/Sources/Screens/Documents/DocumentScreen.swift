import ChirpCore
import ChirpExport
import ChirpFeatures
import ChirpUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One document (M5): its cover and facts, then the text (page by page for a PDF, with OCR pages marked). No player
/// and no SRT/VTT, because a document has no audio or timings. Copy, Share (Text, Markdown, JSON) and Transform work
/// on the text exactly as they do on a transcript, so M4 templates can use it. Plan 022: a typed or pasted text item
/// opens here too, and the summary card carries the privacy class control (as the Transcript's tab row does).
struct DocumentScreen: View {
    @Environment(AppEnvironment.self) private var environment
    let id: UUID

    @State private var model: TranscriptViewModel
    @State private var hasLoaded = false
    @State private var placeholder: Placeholder?
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

    /// Formats that make sense without timings.
    static let exportFormats: [ExportFormat] = [.txt, .markdown, .json]

    init(id: UUID, environment: AppEnvironment) {
        self.id = id
        _model = State(initialValue: environment.makeTranscriptViewModel(id: id))
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
            .task {
                await model.load()
                hasLoaded = true
            }
            .onChange(of: environment.jobCenter.progress[id]?.fraction) { _, _ in
                Task { await model.load() }
            }
            .onChange(of: environment.library.items.first { $0.id == id }?.status) { _, _ in
                Task { await model.load() }
            }
            .sheet(item: $placeholder) { NotBuiltYetSheet(placeholder: $0) }
            // M4: a document runs the same templates as a transcript (its text is the "transcript" input).
            .sheet(isPresented: $isTransforming, onDismiss: { Task { await environment.deliverableLibrary.load() } }) {
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
            .alert("Rename document", isPresented: $isRenaming) {
                TextField("Title", text: $renameText)
                Button("Save") { Task { await rename() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave it empty to use the document’s own title.")
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
            if let item = model.transcription {
                HStack(spacing: 5) {
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
                    .accessibilityHint("Renames the document")
                }
                Text(Formatting.day(item.createdAt) + " · " + DocumentRow.meta(for: item))
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
                Button {
                    isExtractingFields = true
                } label: {
                    Label("Extract fields (Needle)", systemImage: "list.bullet.rectangle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Tokens.Color.ink)
        }
        .accessibilityLabel("More options")
        .disabled(model.transcription == nil)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if let item = model.transcription {
            switch item.status {
            case .completed:
                completed(item)
            case .processing:
                statusPanel(
                    title: environment.jobCenter.progress[id].map(Formatting.progress) ?? "Waiting to start",
                    message: "The text appears here when Parakeet has read the document. You can leave this screen.",
                    fraction: environment.jobCenter.progress[id]?.fraction, isError: false, canRetry: false)
            case .failed, .interrupted, .cancelled:
                statusPanel(
                    title: item.status == .cancelled ? "Cancelled" : "Couldn’t read this document",
                    message: Formatting.statusLine(for: item, progress: nil) ?? "",
                    fraction: nil, isError: item.status != .cancelled, canRetry: true)
            }
        } else if let error = model.loadError {
            statusPanel(
                title: "Couldn’t open this document", message: error, fraction: nil, isError: true, canRetry: false)
        } else if hasLoaded {
            statusPanel(
                title: "This document is gone", message: "It may have been deleted.", fraction: nil, isError: false,
                canRetry: false)
        } else {
            Color.clear
        }
    }

    private func completed(_ item: Transcription) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                summaryCard(item)
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
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
    }

    private func summaryCard(_ item: Transcription) -> some View {
        HStack(alignment: .top, spacing: 14) {
            DocumentCover(format: item.documentFormat, size: 56, badge: DocumentRow.coverBadge(for: item))
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.kindTitle(for: item))
                    .chirpFont(14.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Text(DocumentRow.meta(for: item))
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
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
            PrivacyClassControl(current: item.privacyClass) { newClass in
                // Through the service, so documents made from this item are raised with it (never lowered).
                try await environment.deliverables.setPrivacyClass(newClass, transcriptionID: id)
                await model.load()
            }
        }
        .padding(14)
        .background(CardBackground(radius: Tokens.Radius.s))
    }

    /// "PDF document", "Typed text".
    static func kindTitle(for item: Transcription) -> String {
        if item.isTextItem { return "Typed text" }
        return item.documentFormat.map { "\($0.displayName) document" } ?? "Document"
    }

    private func pageView(_ page: DocumentPage, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel("Page \(page.number) of \(total)")
                if page.method == .ocr {
                    Text("OCR")
                        .chirpFont(10.5, .bold)
                        .foregroundStyle(AppColor.accentText)
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
        .padding(.top, 4)
    }

    private func paragraphText(_ text: String) -> some View {
        Text(text)
            .chirpFont(16)
            .lineSpacing(6)
            .foregroundStyle(Tokens.Color.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                ForEach(Self.exportFormats, id: \.self) { format in
                    Button(format.displayName) { share(format) }
                }
                // Plan 022 Step 6: page formats.
                ForEach(DocumentExportFormat.allCases, id: \.self) { format in
                    Button(format.displayName) { shareDocument(format) }
                }
                Divider()
                Button {
                    voiceMessage = model.transcription.flatMap(VoiceMessageJob.item)
                } label: {
                    Label("Voice message…", systemImage: "waveform.badge.plus")
                }
            } label: {
                barLabel(title: "Share", systemImage: "square.and.arrow.up", emphasized: false)
            }
            .accessibilityLabel("Share")
            // Plan 020: reads the document's text aloud.
            ListenBarButton(source: .document(id: id), privacyClass: model.transcription?.privacyClass ?? .clinical) {
                model.transcription?.displayText ?? ""
            }
            barButton(title: "Transform", systemImage: "sparkles", emphasized: true) {
                isTransforming = true
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

    private func copyText() {
        // .localOnly keeps document text off Universal Clipboard (same rule as transcripts).
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: model.plainText]], options: [.localOnly: true])
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

    /// Blank-line-separated paragraphs (so a long document scrolls lazily, one paragraph per row).
    static func paragraphs(of text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
