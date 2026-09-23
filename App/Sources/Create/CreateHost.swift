import ChirpCore
import ChirpFeatures
import Foundation
import Observation

/// The Create sheet across its presentations (plan 022 Step 3): whether it shows, the chain it runs, and the hand-off
/// to the Dictating screen for Speak (the sheet steps aside, the dictation runs full screen, and the sheet comes back
/// with the chain's progress when the Dictating screen closes). Hide keeps a chain running; Capture's Create card
/// shows it and brings the sheet back.
@MainActor @Observable final class CreateHost {
    /// The sheet is on screen (or about to be).
    var isSheetPresented = false
    /// The running or last chain; nil shows the questions.
    private(set) var flow: CreateFlow?
    /// What the chain was asked, for its header.
    private(set) var request: CreateRequest?
    /// The output's name while a spoken chain records ("Summary"), for the Dictating screen's chip.
    private(set) var speechOutputTitle: String?

    @ObservationIgnored private var pendingSpeech: (request: CreateRequest, choice: LanguageModelChoice, title: String)?
    @ObservationIgnored private var returnsAfterDictation = false

    /// Capture's Create card or a shortcut: shows the sheet (the running chain, or the questions).
    func open() {
        isSheetPresented = true
    }

    /// Hides the sheet; a running chain keeps going.
    func hide() {
        isSheetPresented = false
    }

    /// Done: closes the sheet and forgets a finished chain, so the next Create starts with the questions.
    func done() {
        if let flow, flow.isActive { return hide() }
        flow = nil
        request = nil
        isSheetPresented = false
    }

    /// Back to the questions from a finished, failed or stopped chain.
    func startOver() {
        if let flow, flow.isActive { flow.cancel() }
        flow = nil
        request = nil
    }

    /// Starts a chain. Speak first lets the sheet close (`sheetDidDismiss` then starts the dictation).
    func start(
        _ request: CreateRequest, choice: LanguageModelChoice, outputTitle: String, environment: AppEnvironment
    ) {
        if request.input == .speak {
            pendingSpeech = (request, choice, outputTitle)
            speechOutputTitle = outputTitle
            isSheetPresented = false
            return
        }
        run(request, choice: choice, environment: environment)
    }

    /// The sheet finished closing: a spoken chain starts now, so the Dictating screen can cover everything.
    func sheetDidDismiss(environment: AppEnvironment) {
        guard let pending = pendingSpeech else { return }
        pendingSpeech = nil
        returnsAfterDictation = true
        run(pending.request, choice: pending.choice, environment: environment)
    }

    /// The Dictating screen closed: the sheet comes back with the chain, unless the recording was discarded.
    func dictationDidClose() {
        guard returnsAfterDictation else { return }
        returnsAfterDictation = false
        speechOutputTitle = nil
        guard let flow, flow.phase != .cancelled else { return }
        isSheetPresented = true
    }

    /// Retry at the failed stage; a spoken chain that never got a recording records again.
    func retry(choice: LanguageModelChoice, environment: AppEnvironment) {
        guard let flow, let request, case .failed(let stage, _) = flow.phase else { return }
        if stage == .input, request.input == .speak {
            start(request, choice: choice, outputTitle: speechOutputTitle ?? "", environment: environment)
            return
        }
        Task { await flow.retry() }
    }

    private func run(_ request: CreateRequest, choice: LanguageModelChoice, environment: AppEnvironment) {
        let flow = environment.makeCreateFlow()
        self.flow = flow
        self.request = request
        let models = environment.languageModels
        Task { await flow.start(request, makeModel: { try models.makeModel(for: choice) }) }
    }
}
