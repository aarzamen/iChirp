import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// The Transcript screen's Ask tab (canvas `Ask.dc.html`): a locality chip that picks the model and says where it
/// runs, questions and answers with timestamp chips that seek the player, suggestion chips, and the input bar.
/// Every question is its own routed run; a clinical transcript bound for a cloud model asks first.
struct AskView: View {
    @Environment(AppEnvironment.self) private var environment
    let transcription: Transcription
    let session: AskSessionViewModel
    /// Seeks the player to a cited moment and plays.
    let seek: (Int) -> Void

    @State private var question = ""
    @State private var choice: LanguageModelChoice
    /// The model could not be built (for example its key is gone); nothing was sent.
    @State private var failure: String?
    @FocusState private var inputFocused: Bool

    static let suggestions: [(title: String, question: String)] = [
        ("Action items", "What are the action items, and who owns each one?"),
        ("Decisions", "What was decided?"),
        ("Draft a summary", "Draft a short summary of this conversation."),
    ]

    init(
        transcription: Transcription, session: AskSessionViewModel, environment: AppEnvironment,
        seek: @escaping (Int) -> Void
    ) {
        self.transcription = transcription
        self.session = session
        self.seek = seek
        _choice = State(initialValue: environment.languageModels.defaultChoice)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            ModelChoiceMenu(prefix: "Answering", choice: $choice)
                            Spacer(minLength: 0)
                            SpeakAnswersToggle()  // plan 020
                        }
                        if let message = environment.unavailableMessage(for: choice) {
                            ModelUnavailableNote(message: message)
                        }
                        intro
                        if let failure {
                            Text(failure)
                                .chirpFont(13)
                                .foregroundStyle(AppColor.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(session.exchanges) { exchange in
                            ExchangeView(
                                exchange: exchange, seek: seek, retry: { ask(exchange.question) },
                                listenState: ListenButtonState.of(
                                    .askAnswer(id: exchange.id, transcriptionID: transcription.id),
                                    player: environment.voicePlayer),
                                listen: { listen(to: exchange) }
                            )
                            .id(exchange.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: session.exchanges.last?.run.text) { _, _ in
                    if let last = session.exchanges.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: session.exchanges.count) { _, _ in
                    if let last = session.exchanges.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            inputArea
        }
        .clinicalConfirmation(for: pendingRun)
        .task { await environment.languageModels.refresh() }
        .onChange(of: newestAnsweredID) { _, answered in
            // Plan 020: "Speak answers" reads each new answer once it is complete.
            guard let answered, environment.voiceSettings.settings.speakAskAnswers,
                let exchange = session.exchanges.first(where: { $0.id == answered })
            else { return }
            listen(to: exchange)
        }
    }

    /// The newest question's id once its answer is complete.
    private var newestAnsweredID: UUID? {
        guard let last = session.exchanges.last, case .answered = last.run.phase else { return nil }
        return last.id
    }

    /// Plan 020: reads one answer aloud (or stops it), routed with the class the answer was made with.
    private func listen(to exchange: AskSessionViewModel.Exchange) {
        guard case .answered(let answer) = exchange.run.phase else { return }
        environment.voicePlayer.toggleListening(
            to: .askAnswer(id: exchange.id, transcriptionID: transcription.id),
            privacyClass: transcription.privacyClass.stricter(answer.route.privacyClass)
        ) { answer.text }
    }

    /// The newest question's run, while it waits for the clinical confirmation.
    private var pendingRun: DeliverableRunViewModel? {
        guard let run = session.exchanges.last?.run, case .needsConfirmation = run.phase else { return nil }
        return run
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: 10) {
            // The Capture header's mark, at its size (smaller renders illegibly).
            ParakeetMarkView()
                .frame(width: 27, height: 27)
            Text(introText)
                .chirpFont(15)
                .foregroundStyle(Tokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var introText: String {
        let length = transcription.durationMs.map { " all \(Formatting.duration(ms: $0)) of" } ?? ""
        return "Ask about\(length) this transcript: decisions, commitments, or anything a speaker said. "
            + "Answers cite the moments they come from."
    }

    private var inputArea: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.title) { suggestion in
                        Button {
                            ask(suggestion.question)
                        } label: {
                            Text(suggestion.title)
                                .chirpFont(13, .semibold)
                                .foregroundStyle(AppColor.accentText)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .background(Capsule().fill(AppColor.tintFill))
                                .overlay(Capsule().strokeBorder(AppColor.tintStroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(session.isBusy)
                        .accessibilityHint("Asks: \(suggestion.question)")
                    }
                }
                .padding(.horizontal, 24)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this transcript", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .chirpFont(15.5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { ask(question) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(CardBackground(radius: 22))
                if session.isBusy, pendingRun == nil {
                    Button {
                        session.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Tokens.Color.ink))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop answering")
                } else {
                    Button {
                        ask(question)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(canSend ? Tokens.Color.accent : Tokens.Color.mutedText))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send question")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            Tokens.Color.ground.opacity(0.96)
                .overlay(alignment: .top) { Rectangle().fill(Tokens.Color.border).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isBusy
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.isBusy else { return }
        let model: any LanguageModel
        do {
            model = try environment.languageModels.makeModel(for: choice)
        } catch {
            question = trimmed
            failure = Formatting.message(for: error)
            return
        }
        question = ""
        inputFocused = false
        let choice = self.choice
        failure = nil
        Task { await session.ask(trimmed, model: model, choice: choice) }
    }
}

/// One question and its answer: the user's bubble, the answer (streaming, then with citation chips), the real route.
private struct ExchangeView: View {
    let exchange: AskSessionViewModel.Exchange
    let seek: (Int) -> Void
    let retry: () -> Void
    /// Plan 020: the answer's Listen button.
    let listenState: ListenButtonState
    let listen: () -> Void

    var body: some View {
        let run = exchange.run
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 48)
                Text(exchange.question)
                    .chirpFont(15.5)
                    .foregroundStyle(Tokens.Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppColor.tintFill)
                    )
                    .accessibilityLabel("You asked: \(exchange.question)")
            }
            if !run.text.isEmpty {
                Text(run.text)
                    .chirpFont(15.5)
                    .lineSpacing(4)
                    .foregroundStyle(Tokens.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .answered(let answer) = run.phase {
                citations(answer.citations)
                HStack(spacing: 10) {
                    Text("Answered \(ModelPlace.phrase(for: answer.route))")
                        .chirpFont(11.5)
                        .foregroundStyle(Tokens.Color.secondary)
                    Spacer(minLength: 0)
                    Button(action: listen) {
                        Label(listenState.title, systemImage: listenState.systemImage)
                            .labelStyle(.titleAndIcon)
                            .chirpFont(12.5, .semibold)
                            .foregroundStyle(AppColor.accentText)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .background(Capsule().fill(AppColor.tintFill))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(listenState == .listen ? "Listen to this answer" : "Stop reading this answer")
                }
            } else if let line = RunStatus.text(run.phase) {
                HStack(spacing: 8) {
                    if RunStatus.isActive(run.phase) {
                        ProgressView().controlSize(.small)
                    }
                    Text(line)
                        .chirpFont(13)
                        .foregroundStyle(isFailure(run.phase) ? AppColor.error : Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isFailure(run.phase) {
                    Button(action: retry) {
                        CapsuleButtonLabel(title: "Try again", kind: .tinted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func citations(_ citations: [TranscriptCitation]) -> some View {
        if !citations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(citations.enumerated()), id: \.offset) { _, citation in
                        Button {
                            seek(citation.startMs)
                        } label: {
                            Label(citation.label, systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                                .chirpFont(12.5, .semibold)
                                .monospacedDigit()
                                .foregroundStyle(AppColor.accentText)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 30)
                                .background(Capsule().fill(AppColor.tintFill))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play from \(citation.label)")
                    }
                }
            }
        }
    }

    private func isFailure(_ phase: DeliverableRunViewModel.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
}

/// Plan 020: Ask's "Speak answers" switch (saved in Settings → Voices' settings).
private struct SpeakAnswersToggle: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let voice = environment.voiceSettings
        let isOn = voice.settings.speakAskAnswers
        Button {
            voice.settings.speakAskAnswers.toggle()
        } label: {
            Label("Speak answers", systemImage: isOn ? "speaker.wave.2.fill" : "speaker.slash")
                .labelStyle(.titleAndIcon)
                .chirpFont(12.5, .semibold)
                .foregroundStyle(isOn ? AppColor.accentText : Tokens.Color.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Capsule().fill(isOn ? AppColor.tintFill : AppColor.quietFill))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speak answers")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
