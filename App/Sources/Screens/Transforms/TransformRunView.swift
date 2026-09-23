import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// One Transform as the screens drive it: builds the chosen model, runs the template through `DeliverableService`
/// (via `DeliverableRunViewModel`), and hands the stored result to a document editor. Sends nothing itself.
@MainActor @Observable final class TransformRunHost {
    struct Request: Equatable {
        var template: PromptTemplate
        var transcriptionID: UUID
        var choice: LanguageModelChoice
        var notes: String?
    }

    private(set) var run: DeliverableRunViewModel?
    private(set) var request: Request?
    /// The model could not even be built (for example its key is gone). Nothing was sent.
    private(set) var startError: String?

    @ObservationIgnored private let service: DeliverableService
    @ObservationIgnored private let models: LanguageModelsViewModel
    @ObservationIgnored private let documents: any DeliverableStoring
    @ObservationIgnored private var document: DeliverableDocumentViewModel?

    init(service: DeliverableService, models: LanguageModelsViewModel, documents: any DeliverableStoring) {
        self.service = service
        self.models = models
        self.documents = documents
    }

    convenience init(environment: AppEnvironment) {
        self.init(
            service: environment.deliverables, models: environment.languageModels,
            documents: environment.deliverableStore)
    }

    /// Routes and runs. Returns when the run finished, failed, or is waiting for the clinical confirmation.
    func start(_ request: Request) async {
        self.request = request
        startError = nil
        document = nil
        let model: any LanguageModel
        do {
            model = try models.makeModel(for: request.choice)
        } catch {
            run = nil
            startError = Formatting.message(for: error)
            return
        }
        let notes = request.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = DeliverableRunViewModel(
            service: service, model: model, transcriptionID: request.transcriptionID,
            request: .template(id: request.template.id, userNotes: notes?.isEmpty == false ? notes : nil))
        self.run = run
        await run.start()
    }

    /// Runs the same template again with a fresh run (and a fresh confirmation if one is needed).
    func retry() async {
        guard let request else { return }
        await start(request)
    }

    /// Stops a run in progress (the sheet's Cancel, or the sheet closing). Nothing is stored for it.
    func cancel() {
        run?.cancel()
    }

    /// Back to choosing a template.
    func reset() {
        cancel()
        run = nil
        request = nil
        startError = nil
        document = nil
    }

    /// The editor for the stored result, made once per document.
    func document(for deliverable: Deliverable) -> DeliverableDocumentViewModel {
        if let document, document.id == deliverable.id { return document }
        let made = DeliverableDocumentViewModel(deliverable: deliverable, store: documents)
        document = made
        return made
    }
}

/// A shareable piece of text for `ActivityView`.
struct ShareText: Identifiable {
    let id = UUID()
    let text: String
}

/// The running or finished Transform: status, streaming text, then the editable document with Copy and Share. A run in
/// progress is never dropped silently (UX audit F38): Done asks "Stop writing this document?" and swipe-down is off.
struct TransformRunView: View {
    @Environment(AppEnvironment.self) private var environment
    let host: TransformRunHost
    let run: DeliverableRunViewModel
    let request: TransformRunHost.Request
    let transcriptTitle: String
    let onChooseAnother: () -> Void
    let onDone: () -> Void

    @State private var shareText: ShareText?
    @State private var copied = false
    @State private var isConfirmingStop = false

    /// Done closes a finished or stopped run at once; a run still writing asks first (nothing is saved until it ends).
    static func doneDecision(_ phase: DeliverableRunViewModel.Phase) -> DiscardDecision {
        DiscardDecision.onCancel(hasInput: RunStatus.isActive(phase))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    status
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .voiceReading(environment.voicePlayer) { source in  // plan 020: the result's reading
                if case .deliverable = source { return true }
                return false
            }
            if case .completed(let deliverable) = run.phase {
                bottomBar(text: host.document(for: deliverable).draft, deliverable: deliverable)
            }
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if RunStatus.isActive(run.phase) {
                    Button("Stop") { host.cancel() }
                        .accessibilityHint("Stops this run; nothing is saved")
                } else {
                    Button {
                        onChooseAnother()
                    } label: {
                        Label("Templates", systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    switch Self.doneDecision(run.phase) {
                    case .close: onDone()
                    case .ask: isConfirmingStop = true
                    }
                }
                .bold()
            }
        }
        .interactiveDismissDisabled(RunStatus.isActive(run.phase))
        // A run that ends while "Stop writing this document?" is up: the question no longer applies.
        .onChange(of: RunStatus.isActive(run.phase)) { _, active in
            if !active { isConfirmingStop = false }
        }
        .confirmationDialog("Stop writing this document?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button("Stop and Close", role: .destructive) {
                host.cancel()
                onDone()
            }
            Button("Keep Writing", role: .cancel) {}
        } message: {
            Text("Nothing is saved until it finishes.")
        }
        .sheet(item: $shareText) { item in
            ActivityView(items: [item.text])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.template.name)
                .chirpTitleFont(24, .heavy)
                .foregroundStyle(Tokens.Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(transcriptTitle)
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                // The real route once the router has answered; the chosen model before that.
                if let route = run.route {
                    LocalityChip(
                        text: "Runs \(route.placeWithName)",
                        staysPrivate: route.locality == .onDevice
                            || (route.locality == .localNetwork && request.choice.isTrustedForClinical))
                    PrivacyClassBadge(privacyClass: route.privacyClass)
                } else {
                    LocalityChip(
                        text: "Runs \(request.choice.placeWithName)", staysPrivate: request.choice.staysPrivate)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let line = RunStatus.text(run.phase) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if RunStatus.isActive(run.phase), RunStatus.fraction(run.phase) == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(line)
                        .chirpFont(14, .semibold)
                        .foregroundStyle(isFailure ? AppColor.error : Tokens.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let fraction = RunStatus.fraction(run.phase) {
                    ProgressView(value: fraction).tint(Tokens.Color.accent)
                }
                if isFailure {
                    HStack(spacing: 10) {
                        Button {
                            Task { await host.retry() }
                        } label: {
                            CapsuleButtonLabel(title: "Retry", kind: .filled)
                        }
                        .buttonStyle(.plain)
                        Button(action: onChooseAnother) {
                            CapsuleButtonLabel(title: "Choose another", kind: .tinted)
                        }
                        .buttonStyle(.plain)
                    }
                } else if run.phase == .idle {
                    Button(action: onChooseAnother) {
                        CapsuleButtonLabel(title: "Choose another model", kind: .tinted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chirpCard(radius: Tokens.Radius.m, padding: 14)
        }
    }

    @ViewBuilder private var content: some View {
        if case .completed(let deliverable) = run.phase {
            let document = host.document(for: deliverable)
            if deliverable.privacyClass == .clinical {
                ClinicalDraftNote()
            }
            DocumentEditor(document: document)
                .frame(minHeight: 320)
            Text(savedCaption(document))
                .chirpFont(12)
                .foregroundStyle(document.saveError == nil ? Tokens.Color.secondary : AppColor.error)
        } else if !run.text.isEmpty {
            Text(run.text)
                .chirpFont(16)
                .lineSpacing(5)
                .foregroundStyle(Tokens.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chirpCard(radius: Tokens.Radius.m, padding: 14)
                .accessibilityLabel("Text so far")
        }
    }

    private var isFailure: Bool {
        if case .failed = run.phase { return true }
        return false
    }

    private func savedCaption(_ document: DeliverableDocumentViewModel) -> String {
        if let error = document.saveError { return "Couldn’t save your edit: \(error)" }
        return document.hasUnsavedChanges ? "Editing…" : "Saved in Transforms. Your edits save as you type."
    }

    private func bottomBar(text: String, deliverable: Deliverable) -> some View {
        HStack(spacing: 0) {
            // Plan 020: Listen to the result as edited now.
            ListenBarButton(source: .deliverable(id: deliverable.id), privacyClass: deliverable.privacyClass) {
                host.document(for: deliverable).draft
            }
            Button {
                // UX audit F23: clean plain text on the clipboard, not raw `**`/`##`. Share (below) is unchanged.
                LocalPasteboard.copy(PlainTextFlattener.flatten(text))
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                barLabel(copied ? "Copied" : "Copy", copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            Button {
                shareText = ShareText(text: text)
            } label: {
                barLabel("Share", "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: 58)
        .background(
            Tokens.Color.ground.opacity(0.94)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.Color.border).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func barLabel(_ title: String, _ systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .frame(height: 22)  // one icon box for every bar item, so the labels line up (UX audit F40)
            Text(title)
                .chirpFont(11, .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(Tokens.Color.ink)
        .frame(maxWidth: .infinity, minHeight: 58)
        .contentShape(Rectangle())
    }
}
