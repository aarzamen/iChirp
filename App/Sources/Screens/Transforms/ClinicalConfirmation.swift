import ChirpCore
import ChirpFeatures
import SwiftUI

/// What the clinical confirmation's two buttons do (spec/12, ADR-002).
///
/// **`userTappedSend()` is the only app code that calls `confirmOverride()`, and the dialog's Send button below is
/// the only caller of `userTappedSend()`.** `AppTests/ClinicalConfirmationTests` scans `App/Sources` for both rules
/// and proves that every other path (Cancel, closing the sheet, a new question, Retry) sends nothing.
@MainActor struct ClinicalConfirmationActions {
    let run: DeliverableRunViewModel

    /// The user tapped Send in the dialog: this run only. The service mints a single-use token for this route.
    func userTappedSend() async {
        await run.confirmOverride()
    }

    /// The user tapped Cancel: nothing is sent.
    func userTappedCancel() {
        run.declineOverride()
    }
}

/// The per-run question before clinical text goes to a cloud or untrusted home-network model. The title and message
/// come from the service's `PrivacyOverrideRequest` ("Send this clinical text to Claude?"); the answer is never
/// remembered, so the next run asks again.
struct ClinicalConfirmationModifier: ViewModifier {
    let run: DeliverableRunViewModel?
    /// The request the user already answered, so the alert does not flash back while the answer is being applied.
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
                if let run { ClinicalConfirmationActions(run: run).userTappedCancel() }
            }
            Button("Send") {
                answeredRequestID = request.id
                guard let run else { return }
                Task { await ClinicalConfirmationActions(run: run).userTappedSend() }
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var pendingRequest: PrivacyOverrideRequest? {
        guard case .needsConfirmation(let request) = run?.phase, request.id != answeredRequestID else { return nil }
        return request
    }
}

extension View {
    /// Shows the clinical confirmation whenever `run` is waiting for one.
    func clinicalConfirmation(for run: DeliverableRunViewModel?) -> some View {
        modifier(ClinicalConfirmationModifier(run: run))
    }
}
