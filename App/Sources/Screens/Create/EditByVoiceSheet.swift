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

    init(environment: AppEnvironment) {
        service = environment.deliverables
        models = environment.languageModels
    }

    func start(document: Deliverable, instruction: String, spoken: Bool, choice: LanguageModelChoice) async {
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
            request: .edit(deliverableID: document.id, instruction: instruction, spoken: spoken))
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
/// earlier text stays in Versions.
struct EditByVoiceSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let document: DeliverableDocumentViewModel
    /// Called after a version was saved (the document screen reloads).
    let onSaved: () -> Void

    @State private var recorder: SpokenInstructionRecorder
    @State private var host: EditRunHost
    @State private var choice: LanguageModelChoice
    @State private var instruction = ""
    /// The text the recorder gave, to tell a spoken instruction from a typed one.
    @State private var spokenText: String?
    @State private var isHolding = false
    @FocusState private var fieldFocused: Bool

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
                        Button("Cancel") { close() }
                    }
                }
            }
        }
        .clinicalConfirmation(for: host.run)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(recorder.isBusy)
        .task { await environment.languageModels.refresh() }
        // Saved directly or after the clinical question's Send: the document screen reloads either way.
        .onChange(of: isSaved) { _, saved in
            if saved { onSaved() }
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
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: recorder.phase == .listening ? "waveform" : "mic.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding else { return }
                        isHolding = true
                        fieldFocused = false
                        recorder.dismissFailure()
                        recorder.start()
                    }
                    .onEnded { _ in
                        isHolding = false
                        Task { await finishSpeaking() }
                    }
            )
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
        instruction = text
        spokenText = text
    }

    private var instructionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Instruction")
            TextField("Or type what to change", text: $instruction, axis: .vertical)
                .chirpFont(15.5)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .padding(12)
                .background(CardBackground(radius: Tokens.Radius.s))
                .accessibilityLabel("Instruction")
            if spokenText != nil, spokenText == instruction {
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
                        instruction = suggestion
                        spokenText = nil
                    } label: {
                        Text(suggestion)
                            .chirpFont(13, .semibold)
                            .foregroundStyle(AppColor.accentText)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(Capsule().fill(AppColor.tintFill))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModelChoiceMenu(prefix: "Rewrites", choice: $choice)
            if let message = environment.unavailableMessage(for: choice) {
                ModelUnavailableNote(message: message)
            } else if !choice.isTrustedForClinical {
                Text(
                    document.deliverable?.privacyClass == .clinical
                        ? "This document is clinical. Parakeet will ask before sending it to \(choice.name)."
                        : "Clinical documents ask before anything is sent to \(choice.name)."
                )
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
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
            Text("“\(instruction)”")
                .chirpFont(13.5)
                .italic()
                .foregroundStyle(Tokens.Color.secondary)
            if let place = run.route.map({ ModelPlace.phrase(locality: $0.locality, name: $0.providerName) }) {
                LocalityChip(text: "Rewrites \(place)", staysPrivate: run.route?.locality != .cloud)
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

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let run = host.run {
                switch run.phase {
                case .completed:
                    primaryButton("Done") { close() }
                case .failed, .idle:
                    secondaryButton("Change instruction") { host.reset() }
                    primaryButton("Retry") { apply() }
                default:
                    secondaryButton("Stop") { host.cancel() }
                }
            } else {
                let ready =
                    !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recorder.isBusy
                    && environment.unavailableMessage(for: choice) == nil && document.deliverable != nil
                primaryButton("Apply edit", enabled: ready) { apply() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            Tokens.Color.ground
                .overlay(alignment: .top) { Rectangle().fill(Tokens.Color.border).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom))
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .chirpFont(16, .bold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(enabled ? Tokens.Color.accentInk : Tokens.Color.mutedText))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .chirpFont(15.5, .semibold)
                .foregroundStyle(AppColor.accentText)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Capsule().fill(AppColor.tintFill))
        }
        .buttonStyle(.plain)
    }

    private func apply() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        fieldFocused = false
        let spoken = spokenText != nil && spokenText == instruction
        Task {
            // The editor's unsaved typing is saved first, so it becomes a version rather than being lost.
            guard await document.save(), let current = document.deliverable else { return }
            await host.start(document: current, instruction: text, spoken: spoken, choice: choice)
        }
    }

    private func close() {
        host.cancel()
        dismiss()
    }
}
