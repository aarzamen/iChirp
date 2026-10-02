import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// A chain in the Create sheet: its four stages with their real progress (the job's percent, the model's streamed
/// text, the voice message's parts), a failure with Retry at that stage, then the result with Open, Copy or Share.
struct CreateRunView: View {
    @Environment(AppEnvironment.self) private var environment
    let host: CreateHost
    let flow: CreateFlow
    let request: CreateRequest
    let choice: LanguageModelChoice
    let outputTitle: String
    let open: (CreateDestination) -> Void

    @State private var copied = CopyFeedback()
    @State private var shareItem: ShareItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                VStack(spacing: 0) {
                    ForEach(visibleStages, id: \.self) { stage in
                        if stage != visibleStages.first {
                            Rectangle().fill(AppColor.quietFill).frame(height: 1).padding(.leading, 56)
                        }
                        stageRow(stage)
                    }
                }
                .background(CardBackground(radius: Tokens.Radius.m))
                if let preview = writingPreview {
                    Text(preview)
                        .chirpFont(13.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(CardBackground(radius: Tokens.Radius.s, fill: AppColor.quietFill, stroke: .clear))
                        .accessibilityLabel("Text so far")
                }
                if case .voiceMessage = request.output, let voice = flow.voiceMessage as? VoiceMessageExporter,
                    voice.phase != .idle
                {
                    VoiceMessageProgressCard(
                        phase: voice.phase, voiceName: voice.voiceName,
                        onRetry: { host.retry(choice: choice, environment: environment) },
                        onShare: { file in shareVoiceMessage(file) })
                }
                result
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .background(Tokens.Color.ground)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .onChange(of: flow.voiceMessageFile) { _, file in
            if let file { shareVoiceMessage(file) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .chirpTitleFont(26, .heavy)
                .foregroundStyle(Tokens.Color.ink)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Label(request.input.kind.title, systemImage: request.input.kind.systemImage)
                Image(systemName: "arrow.right")
                    .chirpGlyph(10, .bold, relativeTo: .footnote)
                    .accessibilityHidden(true)
                Label(outputTitle, systemImage: outputSymbol)
                if request.privacyClass == .clinical {
                    PrivacyClassBadge(privacyClass: .clinical)
                        .padding(.leading, 4)
                }
            }
            .labelStyle(.titleAndIcon)
            .chirpFont(13, .semibold)
            .foregroundStyle(Tokens.Color.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var headline: String {
        switch flow.phase {
        case .idle, .running: "Creating…"
        case .waitingForAnswer: "Waiting for you"
        case .finished: "Created"
        case .failed: "Stopped"
        case .cancelled: "Stopped"
        }
    }

    private var outputSymbol: String {
        switch request.output {
        case .transcript: OutputSymbol.transcript
        case .summary: OutputSymbol.summary
        case .document: OutputSymbol.document
        case .voiceMessage: OutputSymbol.voiceMessage
        }
    }

    // MARK: - Stages

    /// The stages that do something here: skipped ones hide, and the output row shows only for a voice message (a
    /// transcript or document is ready the moment the step before it ends).
    private var visibleStages: [CreateFlow.Stage] {
        CreateFlow.Stage.allCases.filter { stage in
            guard flow.stages[stage] != .skipped else { return false }
            if stage == .output, !request.output.needsVoice { return false }
            return true
        }
    }

    private func stageRow(_ stage: CreateFlow.Stage) -> some View {
        let status = flow.stages[stage] ?? .pending
        let fraction = progressFraction(stage, status: status)
        return HStack(alignment: .top, spacing: 12) {
            stageIcon(status, stage: stage)
            VStack(alignment: .leading, spacing: 4) {
                Text(stageTitle(stage))
                    .chirpFont(15, .semibold)
                    .foregroundStyle(status == .pending ? Tokens.Color.secondary : Tokens.Color.ink)
                if let detail = stageDetail(stage, status: status) {
                    Text(detail)
                        .chirpFont(12.5)
                        .monospacedDigit()
                        .foregroundStyle(isFailed(status) ? AppColor.error : Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(Tokens.Color.accent)
                        .padding(.top, 2)
                }
                // R6b-23: a failed voice message shows its Retry once, on the voice-message card below.
                if isFailed(status), !(stage == .output && showsVoiceMessageCard) {
                    Button {
                        host.retry(choice: choice, environment: environment)
                    } label: {
                        CapsuleButtonLabel(
                            title: stage == .input && request.input == .speak ? "Record again" : "Retry", kind: .filled)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func stageIcon(_ status: CreateFlow.StageStatus, stage: CreateFlow.Stage) -> some View {
        ZStack {
            Circle().fill(iconFill(status))
            switch status {
            case .done:
                Image(systemName: "checkmark")
                    .chirpGlyph(13, .bold, relativeTo: .subheadline)
                    .foregroundStyle(Tokens.Color.onAccent)
            case .running:
                if flow.phase == .waitingForAnswer(stage) {
                    Image(systemName: "lock.fill")
                        .chirpGlyph(12, .bold, relativeTo: .footnote)
                        .foregroundStyle(AppColor.accentText)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .failed:
                Image(systemName: "exclamationmark")
                    .chirpGlyph(13, .bold, relativeTo: .subheadline)
                    .foregroundStyle(AppColor.error)
            case .pending, .skipped:
                Text("\((visibleStages.firstIndex(of: stage) ?? stage.rawValue) + 1)")
                    .chirpFont(12.5, .bold)
                    .foregroundStyle(Tokens.Color.secondary)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private func iconFill(_ status: CreateFlow.StageStatus) -> Color {
        switch status {
        case .done: Tokens.Color.success
        case .running: AppColor.tintFill
        case .failed: AppColor.quietFill
        case .pending, .skipped: AppColor.quietFill
        }
    }

    private func isFailed(_ status: CreateFlow.StageStatus) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private var isDocumentInput: Bool {
        if flow.item?.isDocument == true { return true }
        if case .file(let url) = request.input { return IncomingFileInbox.kind(of: url) == .document }
        return false
    }

    private func stageTitle(_ stage: CreateFlow.Stage) -> String {
        switch stage {
        case .input:
            switch request.input {
            case .speak: "Your dictation"
            case .text: "Your text"
            case .link: "The link"
            case .file(let url): url.lastPathComponent
            }
        case .transcribe: isDocumentInput ? "Read" : "Transcribe"
        // R6b-19: a voice message of a summary writes a Summary first; decided from the request, not the title's words.
        case .operation: request.output == .voiceMessage(summarizeFirst: true) ? "Summary" : outputTitle
        case .output:
            switch request.output {
            case .transcript: "Transcript"
            case .summary, .document: "Document"
            case .voiceMessage: "Voice message"
            }
        }
    }

    private func stageDetail(_ stage: CreateFlow.Stage, status: CreateFlow.StageStatus) -> String? {
        if case .failed(let message) = status { return message }
        switch (stage, status) {
        case (.input, .running):
            switch request.input {
            case .speak: return "On the Dictating screen. Tap Stop & copy when you are done."
            case .text: return "Saving…"
            case .link: return "Looking up the link…"
            case .file: return "Copying the file…"
            }
        case (.input, .done):
            return flow.item.map { "\($0.displayTitle) · in your Library" } ?? "In your Library"
        case (.transcribe, .running):
            guard let id = flow.itemID else { return "Waiting to start" }
            return environment.jobCenter.progress[id].map(Formatting.progress) ?? "Waiting to start"
        case (.transcribe, .done):
            return Self.transcribedLine(flow.item, isDocument: isDocumentInput)
        case (.operation, .running):
            if flow.phase == .waitingForAnswer(.operation) {
                return "Waiting for your answer. Nothing has been sent."
            }
            let place = flow.operationRun?.route.map { ModelPlace.phrase(locality: $0.locality, name: $0.providerName) }
            let step: String
            switch flow.operationRun?.phase {
            case .running(.reading(let part, let total))?: step = "Reading part \(part) of \(total)"
            case .running(.combining)?: step = "Combining the parts"
            case .running(.writing)?: step = "Writing"
            default: step = "Checking where it runs"
            }
            return [step, place].compactMap { $0 }.joined(separator: " · ") + "…"
        case (.operation, .done):
            // R7-14: every document lives in the Library (plan 023 F43); Transforms is where one is started.
            guard let document = flow.deliverable else { return "Saved in your Library" }
            return "Saved in your Library · "
                + ModelPlace.phrase(locality: document.locality, name: document.provider)
        case (.output, .running):
            if flow.phase == .waitingForAnswer(.output) { return "Waiting for your answer. Nothing has been sent." }
            return "Making the voice message…"
        case (.output, .done):
            switch request.output {
            case .transcript: return "Ready"
            case .summary, .document: return "Ready to open, copy or share"
            case .voiceMessage: return "Saved with the item"
            }
        case (_, .pending):
            return nil
        default:
            return nil
        }
    }

    private func progressFraction(_ stage: CreateFlow.Stage, status: CreateFlow.StageStatus) -> Double? {
        guard stage == .transcribe, status == .running, let id = flow.itemID,
            let progress = environment.jobCenter.progress[id], !progress.isIndeterminate
        else { return nil }
        return min(max(progress.overallFraction, 0), 1)
    }

    /// The model's text as it streams in (the last lines).
    private var writingPreview: String? {
        guard flow.phase == .running(.operation), let text = flow.operationRun?.text, !text.isEmpty else {
            return nil
        }
        return String(text.suffix(600))
    }

    // MARK: - Result

    @ViewBuilder private var result: some View {
        if flow.phase == .finished {
            switch request.output {
            case .transcript:
                if let item = flow.item { itemCard(item) }
            case .summary, .document:
                if let document = flow.deliverable { documentCard(document) }
            case .voiceMessage:
                if let item = flow.item {
                    Button {
                        open(.item(item.id))
                    } label: {
                        CapsuleButtonLabel(title: "Open \(item.displayTitle)", kind: .tinted)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if flow.phase == .cancelled {
            CreateNote(
                text: Self.stoppedNote(
                    input: request.input.kind, itemMade: flow.itemID != nil, makingInput: flow.isMakingInput,
                    jobFinished: flow.stages[.transcribe] == .done || flow.stages[.transcribe] == .skipped,
                    clinical: request.privacyClass == .clinical),
                systemImage: "stop.circle")
            if let id = flow.itemID {
                Button {
                    open(.item(id))
                } label: {
                    CapsuleButtonLabel(title: "Open the item", kind: .tinted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The transcribe stage's done line. YouTube captions (review M7) were downloaded from YouTube and nothing was
    /// transcribed; the rule is Paste a link's (a `.url` row with no media, or the captions engine).
    static func transcribedLine(_ item: Transcription?, isDocument: Bool) -> String {
        if let item,
            item.engine == LinkIngestService.captionsEngineID
                || (item.sourceType == .url && item.mediaRelativePath == nil)
        {
            return "Captions saved from YouTube; nothing was transcribed"
        }
        return isDocument ? "Read on this iPhone" : "Transcribed on this iPhone"
    }

    /// What a stopped chain left (review I1): an item made before or during the Stop stays in the Library with the
    /// class the person chose, and its job (download, transcription, reading) keeps going there; a lookup or copy
    /// still running may still make one.
    static func stoppedNote(
        input: CreateInputKind, itemMade: Bool, makingInput: Bool, jobFinished: Bool, clinical: Bool
    ) -> String {
        let marked = clinical ? " (marked Clinical)" : ""
        if itemMade {
            guard input == .link || input == .file, !jobFinished else {
                return "Stopped. What was already made stays in your Library\(marked)."
            }
            return "Stopped. The item was already made and stays in your Library\(marked). The Library shows its "
                + "progress."
        }
        if makingInput {
            switch input {
            case .link:
                return "Stopped. The link is still being looked up: if that finishes, the item it makes stays in your "
                    + "Library\(marked)."
            case .file:
                return "Stopped. The file is still being copied: if that finishes, the item it makes stays in your "
                    + "Library\(marked)."
            case .speak, .text:
                break
            }
        }
        return "Stopped. Nothing was created."
    }

    private func itemCard(_ item: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.displayTitle)
                .chirpFont(16, .semibold)
                .foregroundStyle(Tokens.Color.ink)
            Text(item.displayText)
                .chirpFont(14.5)
                .lineSpacing(4)
                .foregroundStyle(Tokens.Color.ink)
                .lineLimit(10)
                .textSelection(.enabled)
            resultActions(
                openLabel: item.isTextOnly ? "Open" : "Open transcript", destination: .item(item.id),
                text: item.displayText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.m))
    }

    private func documentCard(_ document: Deliverable) -> some View {
        // UX audit F23: this preview (and its Copy) shows clean plain text, not raw `**`/`##`. The full formatted
        // rendering — headings, bulleted and numbered lists, bold, italics — is what "Open document" leads to
        // (`DeliverableDetailScreen`'s `DocumentEditor`); a fixed-height card preview has no good way to truncate a
        // multi-block rendering to N lines the way `.lineLimit` truncates plain text.
        //
        // R7-15 (plan 024 Task 10): the preview is the formatted document, as "Open document" shows it (real bullets
        // and headings, not "- " and "Key Points:"), cut at a fixed height with a fade; Copy stays plain text.
        let plainText = PlainTextFlattener.flatten(document.text)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(document.title)
                    .chirpFont(16, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Spacer(minLength: 8)
                PrivacyClassBadge(privacyClass: document.privacyClass)
            }
            MarkdownDocument(document.text, style: .chirp)
                .frame(maxWidth: .infinity, maxHeight: Self.previewHeight, alignment: .topLeading)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Start of the document")
            if document.privacyClass == .clinical {
                ClinicalDraftNote()
            }
            resultActions(openLabel: "Open document", destination: .document(document.id), text: plainText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.m))
    }

    private func resultActions(openLabel: String, destination: CreateDestination, text: String) -> some View {
        HStack(spacing: 10) {
            Button {
                open(destination)
            } label: {
                CapsuleButtonLabel(title: openLabel, kind: .filled)
            }
            .buttonStyle(.plain)
            Button {
                LocalPasteboard.copy(text)
                copied.flash()
            } label: {
                CapsuleButtonLabel(title: copied.isShowing ? "Copied" : "Copy", kind: .tinted)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    // MARK: - Bottom bar

    /// The ChirpUI bar and buttons (R6b-18, R7-12): one height, font and fill per kind on every sheet.
    private var bottomBar: some View {
        ChirpBottomBar {
            ChirpButtonRow {
                if flow.isActive {
                    Button("Stop") { flow.cancel() }
                        .buttonStyle(.chirp(.destructive))
                        .accessibilityHint("Stops the steps that have not finished. What is already made stays.")
                    Button("Hide") { host.hide() }
                        .buttonStyle(.chirpPrimary)
                        .accessibilityHint("Keeps going; Capture shows the progress")
                } else {
                    Button("Create another") { host.startOver() }
                        .buttonStyle(.chirpSecondary)
                    Button("Done") { host.done() }
                        .buttonStyle(.chirpPrimary)
                }
            }
        }
    }

    /// The voice message's own card (with its Retry) is on screen.
    private var showsVoiceMessageCard: Bool {
        guard case .voiceMessage = request.output, let voice = flow.voiceMessage as? VoiceMessageExporter else {
            return false
        }
        return voice.phase != .idle
    }

    static let previewHeight: CGFloat = 320

    private func shareVoiceMessage(_ file: VoiceMessageFile) {
        guard let item = flow.item else { return }
        let title = flow.deliverable.map { "\($0.title) – \(item.displayTitle)" } ?? item.displayTitle
        shareItem = ShareItem(url: VoiceMessageShareFile.url(for: file, title: title, itemID: item.id))
    }
}
