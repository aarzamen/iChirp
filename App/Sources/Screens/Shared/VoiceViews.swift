import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// What the voice player is doing, in words.
enum VoiceStatus {
    /// "Preparing…", "Reading 2 of 5", "Paused at 2 of 5", or the failure sentence; nil when idle.
    static func text(_ state: VoicePlayer.State) -> String? {
        switch state {
        case .idle: nil
        case .preparing: "Preparing…"
        case .needsConfirmation: "Waiting for your answer"
        case .speaking(let chunk, let count): count > 1 ? "Reading \(chunk) of \(count)" : "Reading"
        case .paused(let chunk, let count): count > 1 ? "Paused at \(chunk) of \(count)" : "Paused"
        case .failed(let message): message
        }
    }

    static func isFailure(_ state: VoicePlayer.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

/// What the voice confirmation's two buttons do (plan 020, the M4 pattern).
///
/// **`userTappedReadAloud(_:)` is the only app code that calls `confirmPendingSpeech(requestID:)`, and the dialog's
/// Read aloud button below is its only caller.** `AppTests/VoiceListenTests` scans `App/Sources` for both rules.
@MainActor struct VoiceConfirmationActions {
    let player: VoicePlayer

    /// The user tapped Read aloud on the dialog that showed `request`: this reading only. When another question has
    /// replaced it meanwhile (a newer spoken answer), nothing is confirmed and the newer question shows.
    func userTappedReadAloud(_ request: VoiceConfirmationRequest) {
        player.confirmPendingSpeech(requestID: request.id)
    }

    /// The user tapped Cancel: nothing is sent.
    func userTappedCancel() {
        player.declinePendingSpeech()
    }
}

/// The per-reading question before clinical text goes to a cloud voice (or a Mac the owner has not trusted). Title and
/// message come from `VoiceConfirmationRequest`; the answer is never remembered. When the item is not marked clinical
/// the message first says why it counts as clinical ("Marked Personal, but … a SOAP note was made from it."; UX audit
/// F51): the question shows once that reason is read from the stores (a local read).
struct VoiceConfirmationModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    let player: VoicePlayer
    /// False while this screen presents a sheet that shows the question itself (only one view presents it).
    var isEnabled = true
    @State private var answeredRequestID: UUID?
    @State private var reason: VoiceQuestionReason.Resolved?

    func body(content: Content) -> some View {
        let request = pendingRequest
        content.alert(
            request?.title ?? "",
            isPresented: Binding(get: { request != nil }, set: { _ in }),
            presenting: request
        ) { request in
            Button("Cancel", role: .cancel) {
                answeredRequestID = request.id
                VoiceConfirmationActions(player: player).userTappedCancel()
            }
            // The choice that sends clinical text away looks like one (UX audit F46).
            Button("Read aloud", role: .destructive) {
                answeredRequestID = request.id
                VoiceConfirmationActions(player: player).userTappedReadAloud(request)
            }
        } message: { request in
            Text(VoiceQuestionReason.message(request.message, reason: reason?.text))
        }
        .task(id: waitingRequestID) {
            guard let id = waitingRequestID else { return }
            let text = await VoiceQuestionReason.text(for: player.source, environment: environment)
            reason = VoiceQuestionReason.Resolved(requestID: id, text: text)
        }
    }

    /// The question the player waits on, whether or not its reason is read yet.
    private var waitingRequestID: UUID? {
        guard isEnabled, case .needsConfirmation(let request) = player.state, request.id != answeredRequestID else {
            return nil
        }
        return request.id
    }

    private var pendingRequest: VoiceConfirmationRequest? {
        guard isEnabled, case .needsConfirmation(let request) = player.state, request.id != answeredRequestID,
            reason?.requestID == request.id
        else {
            return nil
        }
        return request
    }
}

/// Why a voice question's text counts as clinical when its item is not marked clinical (UX audit F51), from
/// `EffectivePrivacyExplanation` as stored now. Nil when the item is marked clinical, is not raised, or cannot be read.
enum VoiceQuestionReason {
    struct Resolved: Equatable {
        let requestID: UUID
        let text: String?
    }

    /// The reason, then the question's own message.
    static func message(_ message: String, reason: String?) -> String {
        guard let reason else { return message }
        return reason + " " + message
    }

    @MainActor static func text(for source: VoiceSource?, environment: AppEnvironment?) async -> String? {
        guard let source, let environment else { return nil }
        let transcripts = environment.store
        let deliverables = environment.deliverableStore
        switch source {
        case .transcript(let id), .document(let id), .askAnswer(_, let id), .dictationReadBack(let id?):
            let explanation = try? await EffectivePrivacyExplanation.current(
                transcriptionID: id, transcripts: transcripts, deliverables: deliverables)
            return explanation?.sentence
        case .deliverable(let id):
            guard let document = try? await deliverables.fetchDeliverable(id: id) else { return nil }
            let explanation = try? await EffectivePrivacyExplanation.current(
                transcriptionID: document.transcriptionID, transcripts: transcripts, deliverables: deliverables)
            return explanation?.sentence(forDocumentOfClass: document.privacyClass)
        case .dictationReadBack(nil), .voiceTest:
            return nil
        }
    }
}

extension View {
    /// Shows the voice confirmation whenever `player` waits for one.
    func voiceConfirmation(for player: VoicePlayer, isEnabled: Bool = true) -> some View {
        modifier(VoiceConfirmationModifier(player: player, isEnabled: isEnabled))
    }
}

// MARK: - Listen (plan 020 Step 5)

/// What a Listen button shows for `source`, from the one voice player's state.
enum ListenButtonState: Equatable {
    /// Nothing is read, another text is, or this one failed (the now-playing bar says why and offers Retry).
    case listen
    /// This text is being prepared or waits for the clinical confirmation: tapping stops it.
    case preparing
    /// This text is being read or is paused: tapping stops it.
    case stop

    static func of(_ source: VoiceSource, current: VoiceSource?, state: VoicePlayer.State) -> ListenButtonState {
        guard current == source else { return .listen }
        switch state {
        case .idle, .failed: return .listen
        case .preparing, .needsConfirmation: return .preparing
        case .speaking, .paused: return .stop
        }
    }

    @MainActor static func of(_ source: VoiceSource, player: VoicePlayer) -> ListenButtonState {
        of(source, current: player.source, state: player.state)
    }

    var title: String {
        self == .listen ? "Listen" : "Stop"
    }

    var systemImage: String {
        switch self {
        case .listen: "speaker.wave.2"
        case .preparing: "hourglass"
        case .stop: "stop.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .listen: "Listen"
        case .preparing: "Stop preparing to read aloud"
        case .stop: "Stop reading aloud"
        }
    }
}

extension VoicePlayer {
    /// A Listen button's tap: stops this text when it is the one being read, otherwise reads it (display text is
    /// cleaned of citations and Markdown first).
    func toggleListening(to source: VoiceSource, privacyClass: PrivacyClass, text: () -> String) {
        guard ListenButtonState.of(source, player: self) == .listen else {
            stop()
            return
        }
        let speakable = SpeakableText.prepare(text())
        Task { await speak(text: speakable, privacyClass: privacyClass, source: source) }
    }
}

/// A toolbar Listen button (document screens).
struct ListenToolbarButton: View {
    @Environment(AppEnvironment.self) private var environment
    let source: VoiceSource
    let privacyClass: PrivacyClass
    let text: () -> String

    var body: some View {
        let player = environment.voicePlayer
        let state = ListenButtonState.of(source, player: player)
        Button {
            player.toggleListening(to: source, privacyClass: privacyClass, text: text)
        } label: {
            Label(state.title, systemImage: state.systemImage)
        }
        .accessibilityLabel(state.accessibilityLabel)
    }
}

/// A Listen item for the bottom action bars (icon over a small title, like Copy and Share).
struct ListenBarButton: View {
    @Environment(AppEnvironment.self) private var environment
    let source: VoiceSource
    let privacyClass: PrivacyClass
    let text: () -> String
    /// Runs before reading starts (the Transcript screen pauses its media player).
    var willListen: () -> Void = {}

    var body: some View {
        let player = environment.voicePlayer
        let state = ListenButtonState.of(source, player: player)
        Button {
            if state == .listen { willListen() }
            player.toggleListening(to: source, privacyClass: privacyClass, text: text)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: state.systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)  // the same icon box as Copy and Share, so the labels line up (UX audit F40)
                Text(state.title)
                    .chirpFont(11, .semibold)
            }
            .foregroundStyle(Tokens.Color.ink)
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.accessibilityLabel)
    }
}

/// The mini now-playing bar: what is read and by which voice, progress in chunks, pause/resume and stop; on a
/// failure the sentence, Retry and close. Hidden while idle and while the clinical question is up.
struct VoiceNowPlayingBar: View {
    let player: VoicePlayer

    var body: some View {
        if let source = player.source, isShown {
            HStack(spacing: 12) {
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFailed ? AppColor.error : AppColor.accentText)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFailed ? "Couldn’t read aloud" : title(source))
                        .chirpFont(14, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                        .lineLimit(1)
                    Text(VoiceStatus.text(player.state) ?? "")
                        .chirpFont(12.5)
                        .monospacedDigit()
                        .foregroundStyle(isFailed ? AppColor.error : Tokens.Color.secondary)
                        .lineLimit(isFailed ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                controls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(CardBackground(radius: Tokens.Radius.m))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Read aloud")
        }
    }

    @ViewBuilder private var controls: some View {
        if isFailed, player.canRetry {
            Button {
                Task { await player.retry() }
            } label: {
                CapsuleButtonLabel(title: "Retry", kind: .filled)
            }
            .buttonStyle(.plain)
        } else if case .paused = player.state {
            iconButton("play.fill", label: "Resume reading") { player.resume() }
        } else if case .speaking = player.state {
            iconButton("pause.fill", label: "Pause reading") { player.pause() }
        } else if !isFailed {
            ProgressView().controlSize(.small)
        }
        iconButton("xmark", label: isFailed ? "Close" : "Stop reading") { player.stop() }
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tokens.Color.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(AppColor.quietFill))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var isShown: Bool {
        switch player.state {
        case .idle, .needsConfirmation: false
        default: true
        }
    }

    private var isFailed: Bool { VoiceStatus.isFailure(player.state) }

    private func title(_ source: VoiceSource) -> String {
        [source.title, player.voiceName].compactMap { $0 }.joined(separator: " · ")
    }
}

extension View {
    /// The now-playing bar above the screen's bottom edge, plus the voice confirmation (only one view on screen
    /// should present it: pass `confirmationEnabled: false` while this screen shows a sheet that has its own). A
    /// reading this screen `owns` stops when the screen goes away, so audio never plays without its Stop button.
    func voiceReading(
        _ player: VoicePlayer, confirmationEnabled: Bool = true, owns: @escaping (VoiceSource) -> Bool
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VoiceNowPlayingBar(player: player)
        }
        .voiceConfirmation(for: player, isEnabled: confirmationEnabled)
        .onDisappear {
            if let source = player.source, owns(source) { player.stop() }
        }
    }
}
