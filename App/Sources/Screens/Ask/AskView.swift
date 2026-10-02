import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// The Transcript screen's Ask tab (canvas `Ask.dc.html`): a locality chip that picks the model and says where it
/// runs, questions and answers with timestamp chips that seek the player, suggestion chips, and the input bar.
/// Every question is its own routed run; a clinical transcript bound for a cloud model asks first.
///
/// Polish (UX audit W): 44 pt targets for the suggestion and citation chips and Send / Stop (the visuals keep their
/// canvas sizes), rows that stack at accessibility sizes, and an honest intro: answers cite moments when they can, and
/// an answer without one says so.
///
/// Plan 024 Task 10: the picked model and the unsent question live in the session (review R6b-1), so switching to the
/// Transcript tab and back keeps both; the clinical heads-up is the one every chooser shows (R6b-8); an item without
/// word timings (typed text, an imported document) is answered with quotations, so it never says "No timestamp found";
/// a cited time shows once, as its chip (R7-16).
struct AskView: View {
    @Environment(AppEnvironment.self) private var environment
    let transcription: Transcription
    let session: AskSessionViewModel
    /// Seeks the player to a cited moment and plays.
    let seek: (Int) -> Void

    /// The Settings default, shown until the person picks a model here (the pick lives in `session`, review R6b-1).
    private let defaultChoice: LanguageModelChoice
    /// The model could not be built (for example its key is gone); nothing was sent.
    @State private var failure: String?
    /// The transcript's class as the router uses it (stricter when a document made from it is clinical), for the
    /// clinical heads-up under the chooser (review R6b-8).
    @State private var effectiveClass: PrivacyClass?
    @FocusState private var inputFocused: Bool

    static let suggestions: [(title: String, question: String)] = [
        ("Action items", "What are the action items, and who owns each one?"),
        ("Decisions", "What was decided?"),
        // F62: a question Transform does not already answer (and save) better.
        ("What's the plan?", "What's the plan, and what happens next?"),
    ]

    /// The item has word timings, so answers cite moments (`[mm:ss]`); otherwise they quote (Task 8, R4-14).
    private let citesTimestamps: Bool

    init(
        transcription: Transcription, session: AskSessionViewModel, environment: AppEnvironment,
        seek: @escaping (Int) -> Void
    ) {
        self.transcription = transcription
        self.session = session
        self.seek = seek
        defaultChoice = environment.languageModels.defaultChoice
        citesTimestamps = Self.citesTimestamps(transcription)
    }

    /// The same test the service uses to ask for timestamps or for quotations.
    static func citesTimestamps(_ transcription: Transcription) -> Bool {
        !TranscriptTokens.of(transcription).isEmpty
    }

    /// The model picked here, else the Settings default.
    private var choice: LanguageModelChoice { session.choice(default: defaultChoice) }

    private var choiceBinding: Binding<LanguageModelChoice> {
        Binding(get: { session.choice(default: defaultChoice) }, set: { session.choice = $0 })
    }

    private var questionBinding: Binding<String> {
        Binding(get: { session.draftQuestion }, set: { session.draftQuestion = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                ModelChoiceMenu(prefix: "Answering", choice: choiceBinding)
                                Spacer(minLength: 8)
                                SpeakAnswersToggle()  // plan 020
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ModelChoiceMenu(prefix: "Answering", choice: choiceBinding)
                                SpeakAnswersToggle()
                            }
                        }
                        // One heads-up for every model chooser (review R6b-8; Ask had none).
                        ModelRunNotes(
                            choice: choice, subject: .transcript,
                            isClinical: (effectiveClass ?? transcription.privacyClass) == .clinical)
                        intro
                        if let failure {
                            Text(failure)
                                .chirpFont(13)
                                .foregroundStyle(AppColor.error)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(session.exchanges) { exchange in
                            ExchangeView(
                                exchange: exchange, citesTimestamps: citesTimestamps, seek: seek,
                                retry: { ask(exchange.question) },
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
        .task {
            effectiveClass = await VoiceSourcePrivacy.current(
                for: .transcript(id: transcription.id), transcripts: environment.store,
                deliverables: environment.deliverableStore)
            await environment.languageModels.refresh()
        }
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
            // The mark fills its frame since plan 024 Task 11: about 24 pt beside the intro, growing with the text.
            ParakeetMarkView()
                .chirpScaledFrame(width: 24, height: 24, relativeTo: .title2)
                .accessibilityHidden(true)
            Text(introText)
                .chirpFont(15)
                .foregroundStyle(Tokens.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var introText: String {
        let length = transcription.durationMs.map { " all \(Formatting.duration(ms: $0)) of" } ?? ""
        guard citesTimestamps else {
            // Typed text or an imported document: no moments to cite; the model is asked for short quotations.
            return "Ask about this \(transcription.isDocument ? "document" : "text"): decisions, commitments, or "
                + "anything it says. Answers quote the passages they come from."
        }
        return "Ask about\(length) this transcript: decisions, commitments, or anything a speaker said. "
            + "Answers cite the moments they come from when they can."  // F61
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
                                // Text-safe ink on the tint fill (F8): `accentText` alone is 4.39:1 there.
                                .foregroundStyle(AppColor.accentTextOnTint)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .background(Capsule().fill(AppColor.tintFill))
                                .overlay(Capsule().strokeBorder(AppColor.tintStroke, lineWidth: 1))
                                .frame(minHeight: 44)  // F60: a 32 pt chip in a 44 pt target
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(session.isBusy)
                        .accessibilityHint("Asks: \(suggestion.question)")
                    }
                }
                .padding(.horizontal, 24)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ChirpTextField(
                    citesTimestamps ? "Ask about this transcript" : "Ask about this text", text: questionBinding,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .chirpFont(15.5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { ask(session.draftQuestion) }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(CardBackground(radius: Tokens.Radius.input))
                if session.isBusy, pendingRun == nil {
                    Button {
                        session.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .chirpGlyph(15, .bold, relativeTo: .body, maxScale: 1.3)
                            .foregroundStyle(Tokens.Color.ground)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Tokens.Color.ink))
                            .frame(width: 44, height: 44)  // F60
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop answering")
                } else {
                    Button {
                        ask(session.draftQuestion)
                    } label: {
                        Image(systemName: "arrow.up")
                            .chirpGlyph(16, .bold, relativeTo: .body, maxScale: 1.3)
                            // Disabled: the quiet fill with a `secondary` arrow, as every ChirpUI button.
                            .foregroundStyle(canSend ? Tokens.Color.onAccent : Tokens.Color.secondary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(canSend ? Tokens.Color.accentFill : AppColor.quietFill))
                            .frame(width: 44, height: 44)  // F60
                            .contentShape(Rectangle())
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
        .chirpBarBackground()
    }

    private var canSend: Bool {
        !session.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isBusy
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.isBusy else { return }
        let model: any LanguageModel
        do {
            model = try environment.languageModels.makeModel(for: choice)
        } catch {
            // Nothing was sent; the typed question stays in the field.
            failure = Formatting.message(for: error)
            return
        }
        inputFocused = false
        let choice = self.choice
        failure = nil
        Task { await session.ask(trimmed, model: model, choice: choice) }
    }
}

/// One question and its answer: the user's bubble, the answer (streaming, then with citation chips), the real route.
private struct ExchangeView: View {
    let exchange: AskSessionViewModel.Exchange
    /// The item has timings, so an answer without a cited moment says so; quotations need no such line.
    let citesTimestamps: Bool
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
                        RoundedRectangle(cornerRadius: Tokens.Radius.bubble, style: .continuous)
                            .fill(AppColor.tintFill)
                    )
                    .accessibilityLabel("You asked: \(exchange.question)")
            }
            if !run.text.isEmpty {
                Text(AskAnswerText.shown(run.text, phase: run.phase))
                    .chirpFont(15.5)
                    .lineSpacing(4)
                    .foregroundStyle(Tokens.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .answered(let answer) = run.phase {
                if let notice = run.cutOffNotice {
                    // Plan 024 Task 8 (reviews R3-1, R4-2).
                    CutOffNote(message: notice + " Ask again, or ask for a shorter answer.")
                }
                citations(answer.citations)
                if answer.citations.isEmpty, citesTimestamps {
                    // F61: the intro promises citations "when they can"; say when this one has none.
                    Text("No timestamp found for this answer.")
                        .chirpFont(11.5)
                        .foregroundStyle(Tokens.Color.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        answeredLine(answer)
                        Spacer(minLength: 0)
                        listenButton
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        answeredLine(answer)
                        listenButton
                    }
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

    private func answeredLine(_ answer: AskAnswer) -> some View {
        Text("Answered \(ModelPlace.phrase(for: answer.route))")
            .chirpFont(11.5)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var listenButton: some View {
        Button(action: listen) {
            Label(listenState.title, systemImage: listenState.systemImage)
                .labelStyle(.titleAndIcon)
                .chirpFont(12.5, .semibold)
                // Text-safe ink on the tint fill (F8): `accentText` alone is 4.39:1 there.
                .foregroundStyle(AppColor.accentTextOnTint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Capsule().fill(AppColor.tintFill))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listenState == .listen ? "Listen to this answer" : "Stop reading this answer")
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
                                // Text-safe ink on the tint fill (F8): `accentText` alone is 4.39:1 there.
                                .foregroundStyle(AppColor.accentTextOnTint)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .frame(minHeight: 30)
                                .background(Capsule().fill(AppColor.tintFill))
                                .frame(minHeight: 44)  // F60: a 30 pt chip in a 44 pt target
                                .contentShape(Rectangle())
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
                // Text-safe ink on the tint fill (F8): `accentText` alone is 4.39:1 there.
                .foregroundStyle(isOn ? AppColor.accentTextOnTint : Tokens.Color.secondary)
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

/// The answer as the screen shows it (review R7-16): each cited moment shows once, as its chip under the answer, so
/// the `[mm:ss]` tokens that became chips are taken out of the text. A time the model made up (not a line it was shown)
/// is not a chip and stays in the text. Copy, Listen and the run keep the model's own text.
enum AskAnswerText {
    static func shown(_ text: String, phase: DeliverableRunViewModel.Phase) -> String {
        guard case .answered(let answer) = phase else { return text }
        return withoutCitations(text, labels: answer.citations.map(\.label))
    }

    static func withoutCitations(_ text: String, labels: [String]) -> String {
        guard !labels.isEmpty else { return text }
        var result = text
        for label in labels {
            result = result.replacingOccurrences(of: "[\(label)]", with: "")
        }
        // Tidy the gaps a token leaves: "said [00:12] that" → "said that", "this [00:12]." → "this.", "( )" → "".
        let tidy: [(String, String)] = [(#"\(\s*\)"#, ""), (#"[ \t]{2,}"#, " "), (#"[ \t]+([.,;:!?])"#, "$1")]
        for (pattern, template) in tidy {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
