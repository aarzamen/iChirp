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
/// **`userTappedReadAloud()` is the only app code that calls `confirmPendingSpeech()`, and the dialog's Read aloud
/// button below is its only caller.** `AppTests/VoiceConfirmationTests` scans `App/Sources` for both rules.
@MainActor struct VoiceConfirmationActions {
    let player: VoicePlayer

    /// The user tapped Read aloud: this reading only.
    func userTappedReadAloud() {
        player.confirmPendingSpeech()
    }

    /// The user tapped Cancel: nothing is sent.
    func userTappedCancel() {
        player.declinePendingSpeech()
    }
}

/// The per-reading question before clinical text goes to a cloud voice (or a Mac the owner has not trusted). Title and
/// message come from `VoiceConfirmationRequest`; the answer is never remembered.
struct VoiceConfirmationModifier: ViewModifier {
    let player: VoicePlayer
    /// False while this screen presents a sheet that shows the question itself (only one view presents it).
    var isEnabled = true
    @State private var answeredRequestID: UUID?

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
            Button("Read aloud") {
                answeredRequestID = request.id
                VoiceConfirmationActions(player: player).userTappedReadAloud()
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var pendingRequest: VoiceConfirmationRequest? {
        guard isEnabled, case .needsConfirmation(let request) = player.state, request.id != answeredRequestID else {
            return nil
        }
        return request
    }
}

extension View {
    /// Shows the voice confirmation whenever `player` waits for one.
    func voiceConfirmation(for player: VoicePlayer, isEnabled: Bool = true) -> some View {
        modifier(VoiceConfirmationModifier(player: player, isEnabled: isEnabled))
    }
}
