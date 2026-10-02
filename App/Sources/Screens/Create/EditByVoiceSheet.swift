import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// One edit for the sheet: builds the chosen model and runs `.edit` through `DeliverableService` (via
/// `DeliverableRunViewModel`, so the clinical question is the existing dialog). Sends nothing itself.
@MainActor @Observable final class EditRunHost {
    private(set) var run: DeliverableRunViewModel?
    /// The model could not even be built. Nothing was sent.
    private(set) var startError: String?

    @ObservationIgnored private let service: DeliverableService
    @ObservationIgnored private let models: LanguageModelsViewModel

    init(service: DeliverableService, models: LanguageModelsViewModel) {
        self.service = service
        self.models = models
    }

    convenience init(environment: AppEnvironment) {
        self.init(service: environment.deliverables, models: environment.languageModels)
    }

    /// - Parameter baseText: the document screen's unsaved draft, when it differs from the stored text (review R5-9):
    ///   the model rewrites the text on screen, and the service keeps that draft as a version before the rewrite.
    func start(
        document: Deliverable, instruction: String, spoken: Bool, choice: LanguageModelChoice, baseText: String?
    ) async {
        startError = nil
        let model: any LanguageModel
        do {
            model = try models.makeModel(for: choice)
        } catch {
            run = nil
            startError = Formatting.message(for: error)
            return
        }
        let run = DeliverableRunViewModel(
            service: service, model: model, transcriptionID: document.transcriptionID,
            request: .edit(
                deliverableID: document.id, instruction: instruction, spoken: spoken, baseText: baseText))
        self.run = run
        await run.start()
    }

    func cancel() { run?.cancel() }

    func reset() {
        cancel()
        run = nil
        startError = nil
    }
}

/// A document → Edit by voice (plan 022 Step 4): hold the button and say what to change ("make it shorter", "add a
/// follow-up in two weeks"), or type it; the instruction is transcribed on this iPhone by the dictation path's final
/// pass, then the chosen model rewrites the document. The result is saved as the document's **next version**; the
/// earlier text stays in Versions. Closing never silently drops a typed instruction or a rewrite in progress: swipe-down
/// is off and Cancel asks first.
///
/// Plan 024 Task 10: the model rewrites the text on screen, unsaved edits included (`baseText`, review R5-9), and the
/// result replaces that text on the document screen (`applyEdit`); speaking after typing adds to the typed
/// instruction instead of replacing it (R5-15).
struct EditByVoiceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let document: DeliverableDocumentViewModel
    /// Called after a version was saved (the document screen reloads).
    let onSaved: () -> Void

    @State private var recorder: SpokenInstructionRecorder
    @State private var host: EditRunHost
    @State private var choice: LanguageModelChoice
    /// The instruction and where its words came from (spoken, typed or both; review R5-15).
    @State private var field = InstructionField()
    @State private var isConfirmingCancel = false
    /// The document's class as the router uses it (raised by its transcript), for the clinical heads-up.
    @State private var effectiveClass: PrivacyClass?
    /// True while a finger is on the speak button (after the short hold that tells it from a scroll); reset by SwiftUI
    /// when the touch ends or is taken away, so a cancelled touch stops listening too.
    @GestureState private var isPressing = false
    @FocusState private var fieldFocused: Bool

    /// How long a touch must rest on the speak button before the microphone starts, so a scroll that begins on it
    /// never starts listening (UX audit F27).
    static let holdToSpeakDelay = 0.15

    static let suggestions = [
        "Make it shorter", "Turn it into bullet points", "Add a follow-up in two weeks", "Fix the grammar",
    ]

    init(document: DeliverableDocumentViewModel, environment: AppEnvironment, onSaved: @escaping () -> Void) {
        self.document = document
        self.onSaved = onSaved
        _recorder = State(initialValue: environment.makeInstructionRecorder())
        _host = State(initialValue: EditRunHost(environment: environment))
        _choice = State(initialValue: environment.languageModels.defaultChoice)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edit by voice")
                            .chirpTitleFont(26, .heavy)
                            .foregroundStyle(Tokens.Color.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(document.deliverable?.title ?? "Document")
                            .chirpFont(13)
                            .foregroundStyle(Tokens.Color.secondary)
                    }
                    if let run = host.run {
                        runStatus(run)
                    } else {
                        holdToSpeak
                        instructionField
                        suggestionChips
                        modelRow
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Tokens.Color.ground)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isSaved {  // once saved, the bar's Done closes
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            switch DiscardDecision.onCancel(hasInput: hasWorkToLose) {
                            case .close: close()
                            case .ask: isConfirmingCancel = true
                            }
                        }
                    }
                }
            }
        }
        .clinicalConfirmation(for: host.run)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(recorder.isBusy)
        .discardInputConfirmation(
            isRewriting ? "Stop the rewrite?" : "Discard this instruction?",
            message: isRewriting
                ? "Nothing is saved until it finishes. The document stays as it is."
                : "The document stays as it is.",
            hasInput: hasWorkToLose, isAsking: $isConfirmingCancel,
            discardLabel: isRewriting ? "Stop Rewriting" : "Discard",
            keepLabel: isRewriting ? "Keep Rewriting" : "Keep Editing"
        ) { close() }
        .task {
            effectiveClass = await DocumentPrivacy.effectiveClass(of: document.id, environment: environment)
            await environment.languageModels.refresh()
        }
        // Saved directly or after the clinical question's Send: the rewrite replaces the text on the document screen
        // (it was made from that text, so nothing typed there is hidden or lost), then the screen reloads.
        .onChange(of: isSaved) { _, saved in
            guard saved else { return }
            if case .completed(let edited) = host.run?.phase { document.applyEdit(edited) }
            onSaved()
        }
        // A rewrite that ends while "Stop the rewrite?" is up: the question no longer applies.
        .onChange(of: isRewriting) { _, rewriting in
            if !rewriting { isConfirmingCancel = false }
        }
        .onDisappear {
            host.cancel()
            Task { await recorder.cancel() }
        }
    }

    // MARK: - Speak

    private var holdToSpeak: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(AppColor.tintFill)
                    .frame(width: 132, height: 132)
                    .scaleEffect(recorder.phase == .listening ? 1 + CGFloat(recorder.levels.last ?? 0) * 0.35 : 1)
                    .animation(.easeOut(duration: 0.12), value: recorder.levels.last ?? 0)
                Circle()
                    .fill(recorder.phase == .listening ? Tokens.Color.recordRed : Tokens.Color.accent)
                    .shadow(color: Tokens.Color.accent.opacity(0.32), radius: 8, y: 6)
                    .frame(width: 92, height: 92)
                if recorder.phase == .transcribing || recorder.phase == .starting {
                    ProgressView().tint(Tokens.Color.onAccent)
                } else {
                    Image(systemName: recorder.phase == .listening ? "waveform" : "mic.fill")
                        .chirpGlyph(34, .semibold, relativeTo: .title, maxScale: 1.4)
                        .foregroundStyle(Tokens.Color.onAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            // A short hold first (a scroll that starts here moves away and never starts the microphone), then the
            // press lasts until the finger lifts.
            .gesture(
                LongPressGesture(minimumDuration: Self.holdToSpeakDelay)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($isPressing) { value, pressing, _ in
                        if case .second(true, _) = value { pressing = true }
                    }
            )
            .onChange(of: isPressing) { _, pressing in
                if pressing {
                    fieldFocused = false
                    recorder.dismissFailure()
                    recorder.start()
                } else {
                    Task { await finishSpeaking() }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(recorder.phase == .listening ? "Stop and use what you said" : "Speak an instruction")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                // VoiceOver cannot hold: a double tap starts, the next one stops.
                if recorder.phase == .listening {
                    Task { await finishSpeaking() }
                } else {
                    recorder.start()
                }
            }
            Text(speakCaption)
                .chirpFont(13.5, .semibold)
                .monospacedDigit()
                .foregroundStyle(isFailure ? AppColor.error : Tokens.Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }

    private var speakCaption: String {
        switch recorder.phase {
        case .idle: "Hold and say what to change"
        case .starting: "Starting the microphone…"
        case .listening: "Listening · \(Int(recorder.recordedSeconds))s — let go when you are done"
        case .transcribing: "Transcribing on this iPhone…"
        case .failed(let message): message
        }
    }

    private var isFailure: Bool {
        if case .failed = recorder.phase { return true }
        return false
    }

    private func finishSpeaking() async {
        guard let text = await recorder.stop() else { return }
        field.appendHeard(text)
    }

    private var instructionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Instruction")
            ChirpTextField("Or type what to change", text: $field.text, axis: .vertical)
                .chirpFont(15.5)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .padding(12)
                .background(CardBackground(radius: Tokens.Radius.s))
                .accessibilityLabel("Instruction")
            if field.isUnchangedSinceSpeech {
                Label("Heard on this iPhone. Edit it if a word is wrong.", systemImage: "waveform")
                    .chirpFont(12)
                    .foregroundStyle(Tokens.Color.secondary)
            }
        }
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        field.choose(suggestion)
                    } label: {
                        Text(suggestion)
                            .chirpFont(13, .semibold)
                            // Text-safe ink on the tint fill (F8): `accentText` alone is 4.39:1 there.
                            .foregroundStyle(AppColor.accentTextOnTint)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(Capsule().fill(AppColor.tintFill))
                            .frame(minHeight: 44)  // the hit area; the capsule stays 34 pt (UX audit F26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModelChoiceMenu(prefix: "Rewrites", choice: $choice)
            // One heads-up for every model chooser (review R6b-8), with the class the router uses for this document.
            ModelRunNotes(choice: choice, subject: .document, isClinical: effectiveClass == .clinical)
            if let error = host.startError {
                Text(error)
                    .chirpFont(13)
                    .foregroundStyle(AppColor.error)
            }
            Text("The rewrite is saved as a new version. The current text stays in Versions; nothing is overwritten.")
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Run

    @ViewBuilder private func runStatus(_ run: DeliverableRunViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                switch run.phase {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Color.success)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColor.error)
                default:
                    ProgressView().controlSize(.small)
                }
                Text(Self.statusTitle(run.phase))
                    .chirpFont(15.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
            }
            .accessibilityElement(children: .combine)
            Text("“\(field.text)”")
                .chirpFont(13.5)
                .italic()
                .foregroundStyle(Tokens.Color.secondary)
            if let route = run.route {
                LocalityChip(
                    text: "Rewrites \(route.placeWithName)", locality: route.locality,
                    trustedForClinical: choice.isTrustedForClinical)
            }
            if case .failed(let message) = run.phase {
                Text(message)
                    .chirpFont(13.5)
                    .foregroundStyle(AppColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !run.text.isEmpty {
                Text(run.text)
                    .chirpFont(14.5)
                    .lineSpacing(4)
                    .foregroundStyle(Tokens.Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(CardBackground(radius: Tokens.Radius.s))
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(CardBackground(radius: Tokens.Radius.m))
    }

    static func statusTitle(_ phase: DeliverableRunViewModel.Phase) -> String {
        switch phase {
        case .idle: "Not sent. Nothing left this iPhone."
        case .checking: "Checking where it runs…"
        case .needsConfirmation: "Waiting for your answer. Nothing has been sent."
        case .running: "Rewriting…"
        case .completed: "Saved as a new version"
        case .answered: "Done"
        case .failed: "Couldn’t edit the document"
        }
    }

    private var isSaved: Bool {
        if case .completed = host.run?.phase { return true }
        return false
    }

    /// A rewrite is being routed, asked about or written.
    private var isRewriting: Bool {
        guard let phase = host.run?.phase else { return false }
        return RunStatus.isActive(phase) || { if case .needsConfirmation = phase { true } else { false } }()
    }

    /// Closing now would drop a rewrite in progress or an instruction typed or heard.
    private var hasWorkToLose: Bool {
        isRewriting || (host.run == nil && DiscardDecision.holdsInput(field.text))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        ChirpBottomBar {
            ChirpButtonRow {
                if let run = host.run {
                    switch run.phase {
                    case .completed:
                        Button("Done") { close() }.buttonStyle(.chirpPrimary)
                    case .failed, .idle:
                        Button("Change instruction") { host.reset() }.buttonStyle(.chirpSecondary)
                        Button("Retry") { apply() }.buttonStyle(.chirpPrimary)
                    default:
                        Button("Stop") { host.cancel() }.buttonStyle(.chirp(.destructive))
                    }
                } else {
                    let ready =
                        !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recorder.isBusy
                        && environment.unavailableMessage(for: choice) == nil && document.deliverable != nil
                    Button("Apply edit") { apply() }
                        .buttonStyle(.chirpPrimary)
                        .disabled(!ready)
                }
            }
        }
    }

    /// The text the model rewrites: the document screen's draft when it has unsaved edits (review R5-9), else nil
    /// (the stored text).
    static func baseText(of document: DeliverableDocumentViewModel) -> String? {
        document.hasUnsavedChanges ? document.draft : nil
    }

    private func apply() {
        let text = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let current = document.deliverable else { return }
        fieldFocused = false
        // Marked spoken only when every word was heard on this iPhone; typed or mixed text is not (review fix round 1).
        let spoken = field.isSpoken
        // No save first (review R6b-11: a failed save used to stop here with no message). The draft goes with the
        // request; the service keeps it as a version and rewrites it, and any failure shows in this sheet with Retry.
        let baseText = Self.baseText(of: document)
        Task {
            await host.start(
                document: current, instruction: text, spoken: spoken, choice: choice, baseText: baseText)
        }
    }

    private func close() {
        host.cancel()
        dismiss()
    }
}

/// Edit by voice's instruction field and where its words came from (review R5-15; plan 024 Task 10 fix round 1).
///
/// Speaking always adds to what the field holds, so nothing typed, edited or heard before is ever replaced by a later
/// speech ("Make it shorter" + "add a follow-up" + "and fix the grammar" keeps all three; clear the field to start
/// over). The request is marked spoken only when every word was heard on this iPhone and none was typed or edited
/// since; typed or mixed text is not.
struct InstructionField: Equatable {
    /// The field's text, as typed, heard or edited.
    var text = ""
    /// The text right after the last speech; it differs once the person types or edits.
    private(set) var lastHeardText: String?
    /// Some words were typed, picked from a suggestion or edited, now or before an earlier speech.
    private(set) var hasTypedWords = false

    /// The field shows exactly what the last speech left (the "Heard on this iPhone" line).
    var isUnchangedSinceSpeech: Bool { lastHeardText != nil && lastHeardText == text }

    /// Every word was heard on this iPhone: the edit is recorded as spoken.
    var isSpoken: Bool { isUnchangedSinceSpeech && !hasTypedWords }

    /// Adds what the recorder heard after whatever the field holds.
    mutating func appendHeard(_ heard: String) {
        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.isEmpty {
            hasTypedWords = false
        } else if text != lastHeardText {
            hasTypedWords = true  // typed, or edited since the last speech
        }
        text = Self.appending(heard, to: kept)
        lastHeardText = text
    }

    /// A suggestion chip: its words were picked, not heard.
    mutating func choose(_ suggestion: String) {
        text = suggestion
        lastHeardText = nil
        hasTypedWords = true
    }

    /// `kept` then `heard`, continuing the sentence: "Make it shorter and" + "Add a follow-up." → "Make it shorter and
    /// add a follow-up."; after a sentence end the capital stays; "I", "SOAP" and "BP" keep their capitals.
    static func appending(_ heard: String, to kept: String) -> String {
        let new = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty else { return new }
        guard !new.isEmpty else { return kept }
        let endsSentence = kept.last.map { ".!?;:".contains($0) } ?? false
        let firstWord = new.prefix { !$0.isWhitespace && !$0.isPunctuation }
        let keepsCapital = firstWord.count < 2 || firstWord.dropFirst().contains(where: \.isUppercase)
        let continued = endsSentence || keepsCapital ? new : new.prefix(1).lowercased() + new.dropFirst()
        return kept + " " + continued
    }
}
