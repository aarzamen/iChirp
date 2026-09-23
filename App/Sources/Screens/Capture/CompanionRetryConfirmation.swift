import SwiftUI

/// A Retry that would send a YouTube link to a Mac companion it was not confirmed for: the question, before anything
/// is sent.
struct PendingCompanionRetry: Identifiable, Equatable {
    /// The row's id.
    let id: UUID
    /// The companion's host, as Settings → Mac companion has it now.
    let host: String
    let title: String
}

/// "Send this link to your Mac?" for a Retry (review L1 M2): the same question and wording as the Paste a link sheet's,
/// asked again when Settings → Mac companion now points at another Mac, or the confirmation was in an earlier launch.
/// Cancel sends nothing. `RootTabView` applies it with one line.
struct CompanionRetryConfirmation: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        let pending = environment.pendingCompanionRetry
        content.alert(
            "Send this link to your Mac?",
            isPresented: Binding(
                get: { environment.pendingCompanionRetry != nil },
                set: { if !$0 { environment.cancelCompanionRetry() } }),
            presenting: pending
        ) { _ in
            Button("Cancel", role: .cancel) { environment.cancelCompanionRetry() }
            Button("Send link to my Mac") { environment.confirmCompanionRetry() }
        } message: { pending in
            Text(PasteLinkSheet.companionConfirmation(host: pending.host))
        }
    }
}

extension View {
    /// The Retry question for YouTube audio through the Mac companion.
    func companionRetryConfirmation() -> some View {
        modifier(CompanionRetryConfirmation())
    }
}
