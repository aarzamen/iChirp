import ChirpCore
import ChirpFeatures
import ChirpText
import ChirpUI
import SwiftUI

/// The Undo a revert offers (plan 025 D5): what it says and the plan that puts the corrections back.
struct CorrectionUndoOffer: Identifiable, Equatable {
    /// How long the offer stays once its bar is on screen.
    static let seconds: Double = 6
    let id = UUID()
    let message: String
    let plan: TranscriptCorrectionPlan

    /// Two undo plans as one (a revert inside the window of an earlier one): Undo restores both.
    static func merged(_ first: TranscriptCorrectionPlan, _ second: TranscriptCorrectionPlan)
        -> TranscriptCorrectionPlan
    {
        TranscriptCorrectionPlan(remove: first.remove.union(second.remove), add: first.add + second.add)
    }
}

/// Reverts, Revert All and earlier-correction deletes for one place the person acts (the Transcript screen, the Original
/// sheet, the Corrections sheet), with that place's own Undo offer and error line (fix round 1, I1): an outcome is never
/// shown behind a sheet. Rules (M5):
/// - a revert inside the window of an open offer joins it, so Undo restores everything reverted since the offer
///   appeared (the simplest honest choice: nothing reverted is silently left without its Undo);
/// - a joined Undo is all or nothing: it is one strict plan (`TranscriptViewModel.undo`), so when any of its words
///   were corrected again since, nothing is put back and the newer correction stays as it is (N2, N3);
/// - a failed Undo says why in plain words ("Those words were corrected again, so this can't be undone."). A
///   permanent failure (`isPermanent`: corrected again, the transcript is gone, a newer build's corrections) drops the
///   offer, leaving only the error line; any other failure keeps the offer with a new id, so it can be tried again
///   and its six seconds start again (N1);
/// - one timer, from the latest revert or failure, clears the offer and the error line together; it runs only while
///   the bar is on screen (`CorrectionUndoBar`).
@MainActor @Observable final class CorrectionUndoController {
    private(set) var offer: CorrectionUndoOffer?
    /// The last action's failure, shown where the person acted; cleared by the next action or the timer.
    private(set) var error: String?
    /// The id of the bar's current six seconds: the offer's, else the error line's own. Nil when the bar is hidden.
    var timerID: UUID? { offer?.id ?? errorID }
    private var errorID: UUID?

    func revert(_ ids: Set<UUID>, model: TranscriptViewModel) async {
        await perform(message: "Reverted.") { try await model.revert(ids) }
    }

    func revertAll(model: TranscriptViewModel) async {
        await perform(message: "Reverted all.") { try await model.revertAll() }
    }

    /// Deletes corrections kept from an earlier transcript (no Undo: the dialog said so).
    func deleteDetached(_ ids: Set<UUID>, model: TranscriptViewModel) async {
        clearError()
        do {
            try await model.deleteDetached(ids)
        } catch {
            show(error)
        }
    }

    func undo(model: TranscriptViewModel) async {
        guard let offer else { return }
        clearError()
        do {
            try await model.undo(offer.plan)
            self.offer = nil
            AccessibilityNotification.Announcement("Undone.").post()
        } catch {
            undoFailed(error)
            AccessibilityNotification.Announcement("Couldn’t undo. \(self.error ?? "")").post()
        }
    }

    /// What a failed Undo leaves: the error line, plus the offer (with a new id, so its six seconds start again) only
    /// when trying again could work.
    func undoFailed(_ failure: any Error) {
        show(failure)
        guard let offer else { return }
        self.offer = Self.isPermanent(failure) ? nil : CorrectionUndoOffer(message: offer.message, plan: offer.plan)
    }

    /// Undo failures that trying again cannot fix.
    static func isPermanent(_ failure: any Error) -> Bool {
        switch failure as? TranscriptCorrectionError {
        case .correctedAgain, .notFound, .newerVersion: true
        default: false
        }
    }

    /// An offer handed over from a sheet that closed (its passage has no corrections left).
    func adopt(_ handed: CorrectionUndoOffer) {
        clearError()
        offer =
            offer.map {
                CorrectionUndoOffer(message: handed.message, plan: CorrectionUndoOffer.merged($0.plan, handed.plan))
            } ?? handed
    }

    /// The bar's six seconds (`timerID`) ran out while it was on screen: the offer and the error line both go. An
    /// older timer does nothing.
    func expire(_ id: UUID) {
        guard timerID == id else { return }
        offer = nil
        clearError()
    }

    private func perform(message: String, _ action: () async throws -> CorrectionOutcome) async {
        clearError()
        do {
            let outcome = try await action()
            guard !outcome.undo.isEmpty else { return }
            let plan = offer.map { CorrectionUndoOffer.merged($0.plan, outcome.undo) } ?? outcome.undo
            offer = CorrectionUndoOffer(message: message, plan: plan)  // a new id restarts the timer
            AccessibilityNotification.Announcement("\(message) Undo is available.").post()
        } catch {
            show(error)
        }
    }

    private func show(_ failure: any Error) {
        error = Self.message(for: failure)
        errorID = UUID()
    }

    private func clearError() {
        error = nil
        errorID = nil
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? Formatting.message(for: error)
    }
}

/// "Reverted. Undo" (and the last action's error, when there is one) in the bottom bar of the place the person acted.
/// The offer's six seconds count only while this bar is on screen.
struct CorrectionUndoBar: View {
    let controller: CorrectionUndoController
    let model: TranscriptViewModel

    var body: some View {
        if controller.offer != nil || controller.error != nil {
            ChirpBottomBar {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    if let error = controller.error {
                        Text(error)
                            .chirpFont(13.5)
                            .foregroundStyle(AppColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let offer = controller.offer {
                        HStack(spacing: Tokens.Spacing.s) {
                            Text(offer.message)
                                .chirpFont(14.5, .semibold)
                                .foregroundStyle(Tokens.Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Undo") { Task { await controller.undo(model: model) } }
                                .buttonStyle(.chirp(.tinted, size: .compact))
                                .accessibilityHint("Puts the reverted corrections back")
                        }
                    }
                }
                // One timer for the offer and the error line, restarted by every new offer or failure.
                .task(id: controller.timerID) {
                    guard let id = controller.timerID else { return }
                    try? await Task.sleep(for: .seconds(CorrectionUndoOffer.seconds))
                    guard !Task.isCancelled else { return }
                    controller.expire(id)
                }
            }
        }
    }
}
