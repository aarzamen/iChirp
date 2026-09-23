import ChirpCore
import ChirpExport
import ChirpFeatures
import ChirpUI
import SwiftUI

/// One "Save as voice message" request for a sheet (plan 022 Step 5).
struct VoiceMessageJob: Identifiable {
    let id = UUID()
    let request: VoiceMessageRequest

    /// A transcript, document or text item, spoken as it reads now.
    static func item(_ item: Transcription) -> VoiceMessageJob? {
        let text = SpeakableText.prepare(item.displayText)
        guard !text.isEmpty else { return nil }
        return VoiceMessageJob(
            request: VoiceMessageRequest(
                text: text, privacyClass: item.privacyClass,
                source: item.isTextOnly ? .document(id: item.id) : .transcript(id: item.id), itemID: item.id,
                title: item.displayTitle))
    }

    /// Where the file is kept and what deletes it, for the sheet (review M4): a generated document's voice message lives
    /// with the transcript it came from, so deleting only the document keeps it.
    var storageNote: String {
        let routing = "The text goes to the voice you chose in Settings → Voices; clinical text asks first."
        if case .deliverable = request.source {
            return "Saved on your iPhone with the transcript this document came from. Deleting that transcript deletes "
                + "its voice messages; deleting only this document keeps them. " + routing
        }
        return "Saved with this item on your iPhone. Deleting the item deletes its voice messages. " + routing
    }

    /// A generated document, spoken as edited now (`text`); the file lives with its transcript.
    static func deliverable(_ deliverable: Deliverable, text: String) -> VoiceMessageJob? {
        let speakable = SpeakableText.prepare(text)
        guard !speakable.isEmpty else { return nil }
        return VoiceMessageJob(
            request: VoiceMessageRequest(
                text: speakable, privacyClass: deliverable.privacyClass, source: .deliverable(id: deliverable.id),
                itemID: deliverable.transcriptionID, title: deliverable.title))
    }
}

/// The copy a voice message is shared as: `<title>.m4a` in the item's temporary export folder (removed with the item
/// and swept at launch), so the recipient sees a name, not `voice-3.m4a`. The kept file stays in `media/<id>/`.
enum VoiceMessageShareFile {
    static func url(for file: VoiceMessageFile, title: String, itemID: UUID) -> URL {
        let directory = ExportTempFiles.directory(for: itemID)
        let destination = directory.appendingPathComponent("\(stem(title)).m4a", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.url, to: destination)
            return destination
        } catch {
            return file.url
        }
    }

    /// The title without characters a file name cannot hold, at most 80 characters; "Voice message" when empty.
    static func stem(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\0\n\r"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Voice message" : String(cleaned.prefix(80))
    }
}

/// Transcript, document or generated document → Save as voice message: the chosen voice speaks the text, the parts are
/// joined into one `.m4a` kept with the item, then the share sheet opens. Progress is the real count of parts.
struct VoiceMessageSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let job: VoiceMessageJob

    @State private var exporter: VoiceMessageExporter
    @State private var shareItem: ShareItem?
    @State private var hasStarted = false

    init(job: VoiceMessageJob, environment: AppEnvironment) {
        self.job = job
        _exporter = State(initialValue: environment.makeVoiceMessageExporter())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Voice message")
                        .chirpTitleFont(26, .heavy)
                        .foregroundStyle(Tokens.Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(job.request.title)
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(2)
                    VoiceMessageProgressCard(
                        phase: exporter.phase, voiceName: exporter.voiceName,
                        onRetry: { Task { await exporter.retry() } },
                        onShare: { file in shareItem = ShareItem(url: shareURL(file)) })
                    Text(job.storageNote)
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Tokens.Color.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isFinished ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // A swipe would stop a voice message being made: only Cancel does that (never silently).
        .interactiveDismissDisabled(Self.isMaking(exporter.phase))
        .voiceMessageConfirmation(for: exporter, source: job.request.source)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            await exporter.start(job.request)
        }
        .onChange(of: finishedURL) { _, url in
            if url != nil, case .finished(let file) = exporter.phase { shareItem = ShareItem(url: shareURL(file)) }
        }
        .onDisappear {
            if !isFinished { exporter.cancel() }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    private func shareURL(_ file: VoiceMessageFile) -> URL {
        VoiceMessageShareFile.url(for: file, title: job.request.title, itemID: job.request.itemID)
    }

    private var finishedURL: URL? {
        if case .finished(let file) = exporter.phase { return file.url }
        return nil
    }

    private var isFinished: Bool { finishedURL != nil }

    /// The voice message is being made (a swipe would stop it).
    static func isMaking(_ phase: VoiceMessagePhase) -> Bool {
        switch phase {
        case .preparing, .needsConfirmation, .synthesizing, .assembling: true
        case .idle, .finished, .failed: false
        }
    }
}

/// The voice message's progress, result or failure, as a card. Shared by the voice-message sheet and Create.
struct VoiceMessageProgressCard: View {
    let phase: VoiceMessagePhase
    let voiceName: String?
    let onRetry: () -> Void
    let onShare: (VoiceMessageFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(isFailed ? AppColor.quietFill : AppColor.tintFill)
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isFailed ? AppColor.error : AppColor.accentText)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(phase))
                        .chirpFont(15.5, .semibold)
                        .foregroundStyle(isFailed ? AppColor.error : Tokens.Color.ink)
                    Text(detail)
                        .chirpFont(12.5)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let fraction = Self.fraction(phase) {
                ProgressView(value: fraction)
                    .tint(Tokens.Color.accent)
                    .accessibilityLabel("Parts spoken")
            } else if Self.isIndeterminate(phase) {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch phase {
            case .finished(let file):
                Button {
                    onShare(file)
                } label: {
                    Label("Share voice message", systemImage: "square.and.arrow.up")
                        .chirpFont(15, .semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Capsule().fill(Tokens.Color.accentFill))
                }
                .buttonStyle(.plain)
            case .failed:
                Button(action: onRetry) {
                    CapsuleButtonLabel(title: "Retry", kind: .filled)
                }
                .buttonStyle(.plain)
            default:
                EmptyView()
            }
        }
        .padding(14)
        .background(CardBackground(radius: Tokens.Radius.m))
        .accessibilityElement(children: .contain)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var symbol: String {
        switch phase {
        case .finished: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        case .needsConfirmation: "lock.fill"
        default: "waveform"
        }
    }

    private var detail: String {
        switch phase {
        case .idle: "Nothing was sent."
        case .preparing: voiceName.map { "Checking \($0)…" } ?? "Checking the voice…"
        case .needsConfirmation: "Waiting for your answer. Nothing has been sent."
        case .synthesizing(let done, let total):
            [voiceName, "Part \(min(done + 1, total)) of \(total)"].compactMap { $0 }.joined(separator: " · ")
        case .assembling: "Joining \(voiceName.map { "the parts from \($0)" } ?? "the parts") into one file…"
        case .finished(let file):
            // The length and where it is; not the internal file name ("voice-1.m4a").
            [file.durationMs.map { Formatting.clock(ms: $0) }, "saved with this item"]
                .compactMap { $0 }.joined(separator: " · ")
        case .failed(let message): message
        }
    }

    static func title(_ phase: VoiceMessagePhase) -> String {
        switch phase {
        case .idle: "Not made"
        case .preparing: "Getting the voice ready"
        case .needsConfirmation: "Clinical text: asking first"
        case .synthesizing: "Speaking"
        case .assembling: "Saving"
        case .finished: "Voice message saved"
        case .failed: "Couldn’t make the voice message"
        }
    }

    /// Real progress: parts spoken of the total.
    static func fraction(_ phase: VoiceMessagePhase) -> Double? {
        guard case .synthesizing(let done, let total) = phase, total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    static func isIndeterminate(_ phase: VoiceMessagePhase) -> Bool {
        switch phase {
        case .preparing, .assembling: true
        default: false
        }
    }
}

// MARK: - The clinical question

/// What the voice-message confirmation's two buttons do (the M4 and plan 020 pattern).
///
/// **`userTappedMakeVoiceMessage(_:)` is the only app code that calls `confirmPendingSynthesis(requestID:)`, and the dialog's Send
/// button below is its only caller.** `AppTests/CreateAppTests` scans `App/Sources` for both rules.
@MainActor struct VoiceMessageConfirmationActions {
    let exporter: VoiceMessageExporter

    /// The user tapped Send on the dialog that showed `request`: this voice message only.
    func userTappedMakeVoiceMessage(_ request: VoiceConfirmationRequest) {
        exporter.confirmPendingSynthesis(requestID: request.id)
    }

    /// The user tapped Cancel: nothing is sent.
    func userTappedCancel() {
        exporter.declinePendingSynthesis()
    }
}

/// The per-message question before clinical text goes to a cloud voice (or a Mac the owner has not trusted). Never
/// remembered. With `source`, the message first says why an item not marked clinical counts as clinical (UX audit F51);
/// the question then shows once that reason is read.
struct VoiceMessageConfirmationModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    let exporter: VoiceMessageExporter?
    var source: VoiceSource?
    @State private var answeredRequestID: UUID?
    @State private var reason: VoiceQuestionReason.Resolved?

    func body(content: Content) -> some View {
        let request = pendingRequest
        content.alert(
            request.map(Self.title) ?? "",
            isPresented: Binding(get: { request != nil }, set: { _ in }),
            presenting: request
        ) { request in
            Button("Cancel", role: .cancel) {
                answeredRequestID = request.id
                if let exporter { VoiceMessageConfirmationActions(exporter: exporter).userTappedCancel() }
            }
            // The choice that sends clinical text away looks like one (UX audit F46).
            Button("Send", role: .destructive) {
                answeredRequestID = request.id
                if let exporter {
                    VoiceMessageConfirmationActions(exporter: exporter).userTappedMakeVoiceMessage(request)
                }
            }
        } message: { request in
            Text(VoiceQuestionReason.message(Self.message(request), reason: reason?.text))
        }
        .task(id: waitingRequestID) {
            guard let id = waitingRequestID else { return }
            let text = await VoiceQuestionReason.text(for: source, environment: environment)
            reason = VoiceQuestionReason.Resolved(requestID: id, text: text)
        }
    }

    private var waitingRequestID: UUID? {
        guard case .needsConfirmation(let request) = exporter?.phase, request.id != answeredRequestID else {
            return nil
        }
        return request.id
    }

    private var pendingRequest: VoiceConfirmationRequest? {
        guard case .needsConfirmation(let request) = exporter?.phase, request.id != answeredRequestID,
            reason?.requestID == request.id
        else {
            return nil
        }
        return request
    }

    /// "Make a voice message of this clinical text with Grok voices?"
    static func title(_ request: VoiceConfirmationRequest) -> String {
        "Make a voice message of this clinical text with \(request.providerName)?"
    }

    static func message(_ request: VoiceConfirmationRequest) -> String {
        switch request.locality {
        case .cloud:
            "The text will leave this iPhone and go to \(request.providerName) over the internet to be turned into "
                + "speech. This applies to this voice message only."
        case .localNetwork:
            "The text will go to \(request.host ?? "a computer") on your network, which you have not marked as "
                + "trusted. This applies to this voice message only."
        case .onDevice:
            "It stays on this iPhone."
        }
    }
}

extension View {
    /// Shows the voice-message confirmation whenever `exporter` waits for one (`source`: what is spoken, for the
    /// reason line).
    func voiceMessageConfirmation(for exporter: VoiceMessageExporter?, source: VoiceSource? = nil) -> some View {
        modifier(VoiceMessageConfirmationModifier(exporter: exporter, source: source))
    }
}
