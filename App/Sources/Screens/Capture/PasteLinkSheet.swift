import ChirpCore
import ChirpFeatures
import ChirpIngest
import ChirpUI
import SwiftUI
import UniformTypeIdentifiers

/// Capture → Paste a link (M5): paste a podcast, YouTube or media link, see what Parakeet detected (decided on the
/// phone, no network), then tap Transcribe, the only step that goes online. Also the way in for documents: "Import a
/// document" picks PDFs, Word files and text from Files.
struct PasteLinkSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// Opens a row (the sheet closes first).
    let onOpen: (UUID) -> Void

    @State private var model: LinkImportViewModel
    @State private var isConfirmingCompanion = false
    @State private var isImportingDocument = false
    @State private var pickerError: String?
    @FocusState private var fieldFocused: Bool

    init(environment: AppEnvironment, onOpen: @escaping (UUID) -> Void) {
        self.onOpen = onOpen
        _model = State(initialValue: environment.makeLinkImportViewModel())
    }

    /// What the document picker offers: PDF, Word, RTF, HTML, Markdown and any plain text.
    static let documentTypes: [UTType] = [
        .pdf, .rtf, .html, .plainText,
        UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
        UTType("net.daringfireball.markdown")
            ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    linkField
                    detection
                    phaseView
                    transcribeButton
                    if model.kind.isActionable {
                        privacyNote
                    }
                    divider
                    documentImport
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Tokens.Color.ground)
            .navigationTitle("Paste a link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            #if DEBUG
            if model.text.isEmpty, let link = IngestPreviewLaunch.value(after: IngestPreviewLaunch.pasteLinkArgument) {
                model.text = link
            }
            #endif
            fieldFocused = model.text.isEmpty
        }
        .fileImporter(
            isPresented: $isImportingDocument, allowedContentTypes: Self.documentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                environment.importDocuments(urls)
                dismiss()
            case .failure(let error):
                pickerError = Formatting.message(for: error)
            }
        }
        .confirmationDialog(
            "Send this link to your Mac?", isPresented: $isConfirmingCompanion, titleVisibility: .visible
        ) {
            Button("Send link to my Mac") {
                model.confirmCompanion()
                model.getAudioFromMac()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.companionConfirmation(host: environment.companionSettings.companionEndpoint()?.normalizedHost))
        }
        .alert(
            "Couldn’t open the file picker",
            isPresented: Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickerError ?? "")
        }
    }

    // MARK: - Field

    private var linkField: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.Color.secondary)
                .accessibilityHidden(true)
            TextField("Podcast, YouTube or audio link", text: $model.text, axis: .vertical)
                .chirpFont(15)
                .foregroundStyle(Tokens.Color.ink)
                .lineLimit(1...4)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($fieldFocused)
                .onSubmit { model.transcribe() }
                .disabled(model.isWorking || model.startedID != nil)
            if !model.text.isEmpty, model.startedID == nil, !model.isWorking {
                Button {
                    model.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tokens.Color.mutedText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear link")
            }
            // PasteButton reads the clipboard only when tapped, so iOS shows no paste-permission prompt.
            PasteButton(payloadType: String.self) { strings in
                guard let first = strings.first else { return }
                Task { @MainActor in model.text = first }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .tint(Tokens.Color.accentInk)
            .disabled(model.isWorking || model.startedID != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .background(CardBackground(radius: Tokens.Radius.cover))
    }

    // MARK: - Detection

    @ViewBuilder private var detection: some View {
        if !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.Radius.iconTile, style: .continuous)
                        .fill(model.kind.isActionable ? AppColor.tintFill : AppColor.quietFill)
                    Image(systemName: Self.symbol(for: model.kind))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(model.kind.isActionable ? Tokens.Color.accentInk : AppColor.error)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.kind.title)
                        .chirpFont(15, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    Text(model.kind.detail)
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(CardBackground(radius: Tokens.Radius.s))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Detected: \(model.kind.title). \(model.kind.detail)")
        }
    }

    // MARK: - Phase

    @ViewBuilder private var phaseView: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .working(let message):
            HStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .chirpFont(14)
                    .foregroundStyle(Tokens.Color.ink)
                Spacer(minLength: 8)
                Button("Cancel") { model.cancel() }
                    .chirpFont(14, .semibold)
                    .foregroundStyle(AppColor.accentText)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(CardBackground(radius: Tokens.Radius.s))
        case .failed(let message):
            Label {
                Text(message)
                    .chirpFont(14)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColor.error)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardBackground(radius: Tokens.Radius.s, stroke: AppColor.error.opacity(0.4)))
        case .started(let id):
            startedCard(id)
        case .companionOffer(let reason):
            companionOfferCard(reason)
        }
    }

    /// Plan 019: the video has no usable captions and a Mac companion is set up.
    private func companionOfferCard(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(reason)
                    .chirpFont(15, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "captions.bubble")
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Text(
                "Your Mac can download its audio from YouTube and send it here. Parakeet then transcribes it on this "
                    + "iPhone."
            )
            .chirpFont(13)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                if model.needsCompanionConfirmation {
                    isConfirmingCompanion = true
                } else {
                    model.getAudioFromMac()
                }
            } label: {
                CapsuleButtonLabel(title: "Get the audio from your Mac", kind: .filled)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityHint("Sends only this video’s link to your Mac.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s, fill: AppColor.tintFill, stroke: AppColor.tintStroke))
    }

    private func startedCard(_ id: UUID) -> some View {
        let item = environment.library.items.first { $0.id == id }
        let progress = environment.jobCenter.progress[id]
        return VStack(alignment: .leading, spacing: 10) {
            Text(item?.displayTitle ?? "Adding to your Library…")
                .chirpFont(15, .semibold)
                .foregroundStyle(Tokens.Color.ink)
                .lineLimit(2)
            if let item {
                Text(Self.statusLine(for: item, progress: progress))
                    .chirpFont(13, .semibold)
                    .monospacedDigit()
                    .foregroundStyle(item.status == .failed ? AppColor.error : AppColor.accentText)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress, item.status == .processing {
                    if let fraction = progress.determinateFraction {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .tint(Tokens.Color.accent)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text("It keeps going in your Library if you close this.")
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
            HStack(spacing: 10) {
                Button {
                    dismiss()
                    onOpen(id)
                } label: {
                    CapsuleButtonLabel(title: "Open", kind: .filled)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                Button {
                    model.reset()
                    fieldFocused = true
                } label: {
                    CapsuleButtonLabel(title: "Paste another link", kind: .tinted)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s, fill: AppColor.tintFill, stroke: AppColor.tintStroke))
    }

    // MARK: - Actions

    @ViewBuilder private var transcribeButton: some View {
        if model.startedID == nil {
            Button {
                fieldFocused = false
                model.transcribe()
            } label: {
                Text(model.phase == .editing || !model.isWorking ? "Transcribe" : "Working…")
                    .chirpFont(16, .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous)
                            .fill(model.canTranscribe ? Tokens.Color.accentInk : Tokens.Color.mutedText))
            }
            .buttonStyle(.plain)
            .disabled(!model.canTranscribe)
            .accessibilityHint("Uses the internet to fetch this link. Only the link leaves this iPhone.")
        }
    }

    private var privacyNote: some View {
        Label {
            Text(Self.privacyNote(for: model.kind))
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(Tokens.Color.secondary)
        }
    }

    private var divider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Tokens.Color.border).frame(height: 1)
            Text("or")
                .chirpFont(12.5, .semibold)
                .foregroundStyle(Tokens.Color.secondary)
            Rectangle().fill(Tokens.Color.border).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    private var documentImport: some View {
        Button {
            isImportingDocument = true
        } label: {
            HStack(spacing: 12) {
                DocumentCover(format: .pdf, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import a document")
                        .chirpFont(15, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    Text("PDF (scans too), Word, RTF, HTML, Markdown or text. Read on this iPhone.")
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(minHeight: 68)
            .background(CardBackground(radius: Tokens.Radius.tile))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Copy

    static func symbol(for kind: LinkKind) -> String {
        switch kind {
        case .applePodcastEpisode, .applePodcastShow, .podcastFeed: "antenna.radiowaves.left.and.right"
        case .directMedia: "waveform"
        case .youtube: "captions.bubble"
        case .webLink: "globe"
        case .unsupported: "exclamationmark.triangle"
        }
    }

    static func privacyNote(for kind: LinkKind) -> String {
        switch kind {
        case .youtube:
            "Only the video’s link goes to YouTube, to fetch its captions. Nothing you have on this iPhone is sent."
        default:
            "Only the link leaves this iPhone, to download the audio. It is transcribed on this iPhone."
        }
    }

    /// The confirmation before a YouTube link goes to the Mac companion (asked once per link).
    static func companionConfirmation(host: String?) -> String {
        "Your Mac (\(host ?? "the Mac companion")) downloads this video’s audio from YouTube and sends it back to this "
            + "iPhone, where it is transcribed. Only the link leaves this iPhone; your Mac keeps nothing."
    }

    static func statusLine(for item: Transcription, progress: JobProgress?) -> String {
        if item.status == .completed {
            return item.sourceType == .url && item.mediaRelativePath == nil ? "Captions saved" : "Transcribed"
        }
        return Formatting.statusLine(for: item, progress: progress) ?? ""
    }
}
