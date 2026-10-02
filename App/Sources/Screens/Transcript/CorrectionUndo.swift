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
/// - the offer stays until its Undo succeeds, so a failed Undo can be tried again, and its reason is said in plain
///   words ("Those words were corrected again, so this can't be undone.");
/// - the timer runs only while the bar is on screen (`CorrectionUndoBar`), from the latest revert.
@MainActor @Observable final class CorrectionUndoController {
    private(set) var offer: CorrectionUndoOffer?
    /// The last action's failure, shown where the person acted; cleared by the next action.
    private(set) var error: String?

    func revert(_ ids: Set<UUID>, model: TranscriptViewModel) async {
        await perform(message: "Reverted.") { try await model.revert(ids) }
    }

    func revertAll(model: TranscriptViewModel) async {
        await perform(message: "Reverted all.") { try await model.revertAll() }
    }

    /// Deletes corrections kept from an earlier transcript (no Undo: the dialog said so).
    func deleteDetached(_ ids: Set<UUID>, model: TranscriptViewModel) async {
        error = nil
        do {
            try await model.deleteDetached(ids)
        } catch {
            self.error = Self.message(for: error)
        }
    }

    func undo(model: TranscriptViewModel) async {
        guard let offer else { return }
        error = nil
        do {
            try await model.undo(offer.plan)
            self.offer = nil
            AccessibilityNotification.Announcement("Undone.").post()
        } catch {
            self.error = Self.message(for: error)
            AccessibilityNotification.Announcement("Couldn’t undo. \(self.error ?? "")").post()
        }
    }

    /// An offer handed over from a sheet that closed (its passage has no corrections left).
    func adopt(_ handed: CorrectionUndoOffer) {
        offer =
            offer.map {
                CorrectionUndoOffer(message: handed.message, plan: CorrectionUndoOffer.merged($0.plan, handed.plan))
            } ?? handed
    }

    /// The bar's timer ran out while it was on screen.
    func expire(_ id: UUID) {
        // A failed Undo keeps its offer until the person tries again or does something else.
        guard error == nil else { return }
        if offer?.id == id { offer = nil }
    }

    private func perform(message: String, _ action: () async throws -> CorrectionOutcome) async {
        error = nil
        do {
            let outcome = try await action()
            guard !outcome.undo.isEmpty else { return }
            let plan = offer.map { CorrectionUndoOffer.merged($0.plan, outcome.undo) } ?? outcome.undo
            offer = CorrectionUndoOffer(message: message, plan: plan)  // a new id restarts the timer
            AccessibilityNotification.Announcement("\(message) Undo is available.").post()
        } catch {
            self.error = Self.message(for: error)
        }
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
                        .task(id: offer.id) {
                            try? await Task.sleep(for: .seconds(CorrectionUndoOffer.seconds))
                            guard !Task.isCancelled else { return }
                            controller.expire(offer.id)
                        }
                    }
                }
            }
        }
    }
}
