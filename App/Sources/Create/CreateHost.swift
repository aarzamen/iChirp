import ChirpCore
import ChirpFeatures
import Foundation
import Observation

/// The Create sheet across its presentations (plan 022 Step 3): whether it shows, the chain it runs, and the hand-off
/// to the Dictating screen for Speak (the sheet steps aside, the dictation runs full screen, and the sheet comes back
/// with the chain's progress when the Dictating screen closes). Hide keeps a chain running; Capture's Create card
/// shows it and brings the sheet back. Plan 023 lane 2: it also holds the owner's recipes, and runs one the way Create
/// would (Speak straight to the Dictating screen, Type and Link into the sheet with the recipe's choices, a picked file
/// into a chain).
@MainActor @Observable final class CreateHost {
    /// The owner's recipes: Capture's tiles, Create's "Save as recipe", the Recipes sheet.
    let recipes: CreateRecipesViewModel
    /// The sheet is on screen (or about to be).
    var isSheetPresented = false
    /// The running or last chain; nil shows the questions.
    private(set) var flow: CreateFlow?
    /// What the chain was asked, for its header.
    private(set) var request: CreateRequest?
    /// The output's name while a spoken chain records ("Summary"), for the Dictating screen's chip.
    private(set) var speechOutputTitle: String?
    /// The chain's output name ("Summary"), kept for as long as the chain: Record again shows it on the Dictating
    /// screen's chip again (review M6; `speechOutputTitle` is cleared when that screen closes).
    private(set) var outputTitle: String?
    /// Text or a link typed into the questions when the sheet went away without Cancel → Discard (a dictation started
    /// from the Action Button hides the sheet): the next open starts from it, so nothing typed is lost (UX audit F19).
    /// In memory only, never saved.
    @ObservationIgnored var keptDraft: CreateDraft?
    /// A Type or Link recipe the next sheet opens with (its choices and model), cleared once the sheet shows. In memory
    /// only.
    @ObservationIgnored var pendingRecipe: CreateRecipe?

    @ObservationIgnored private var pendingSpeech: (request: CreateRequest, choice: LanguageModelChoice, title: String)?
    @ObservationIgnored private var returnsAfterDictation = false

    init(recipeStore: any CreateRecipeStoring = UserDefaultsCreateRecipeStore()) {
        recipes = CreateRecipesViewModel(store: recipeStore)
    }

    /// Capture's Create card or a shortcut: shows the sheet (the running chain, or the questions).
    func open() {
        isSheetPresented = true
    }

    /// Hides the sheet; a running chain keeps going.
    func hide() {
        isSheetPresented = false
    }

    /// Done: closes the sheet and forgets a finished chain, so the next Create starts with the questions. The dropped
    /// chain is reset first (review M2: a failed voice message's chunk audio is removed now, not at the next launch).
    func done() {
        if let flow, flow.isActive { return hide() }
        flow?.reset()
        flow = nil
        request = nil
        outputTitle = nil
        isSheetPresented = false
    }

    /// Back to the questions from a finished, failed or stopped chain (an active one is stopped; review M2: the
    /// dropped chain is reset, so its voice message's work goes too).
    func startOver() {
        flow?.reset()
        flow = nil
        request = nil
        outputTitle = nil
    }

    /// Starts a chain. Speak first lets the sheet close (`sheetDidDismiss` then starts the dictation).
    func start(
        _ request: CreateRequest, choice: LanguageModelChoice, outputTitle: String, environment: AppEnvironment
    ) {
        if request.input == .speak { return queueSpeech(request, choice: choice, outputTitle: outputTitle) }
        self.outputTitle = outputTitle
        run(request, choice: choice, environment: environment)
    }

    /// Speak: the sheet closes first; `sheetDidDismiss` starts the dictation with "Then: <outputTitle>" on its chip.
    func queueSpeech(_ request: CreateRequest, choice: LanguageModelChoice, outputTitle: String) {
        pendingSpeech = (request, choice, outputTitle)
        speechOutputTitle = outputTitle
        self.outputTitle = outputTitle
        isSheetPresented = false
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

    // MARK: - Recipes (plan 023 lane 2)

    /// A Type or Link recipe: Create opens with its choices and model, for the text or the link. A finished chain is
    /// dropped first (what it made stays in the Library); the caller never passes an active one
    /// (`CreateRecipeLaunch.busy`).
    func open(recipe: CreateRecipe) {
        startOver()
        pendingRecipe = recipe
        isSheetPresented = true
    }

    /// A Speak recipe: straight to the Dictating screen with "Then: <outputTitle>" on its chip, exactly as Create's
    /// Speak once its sheet has stepped aside; the sheet comes back with the chain when the Dictating screen closes.
    func startSpeech(
        _ request: CreateRequest, choice: LanguageModelChoice, outputTitle: String, environment: AppEnvironment
    ) {
        startOver()
        queueSpeech(request, choice: choice, outputTitle: outputTitle)
        sheetDidDismiss(environment: environment)
    }

    /// A File recipe once the file is picked: the chain starts and the sheet shows its progress.
    func startAndShow(
        _ request: CreateRequest, choice: LanguageModelChoice, outputTitle: String, environment: AppEnvironment
    ) {
        startOver()
        start(request, choice: choice, outputTitle: outputTitle, environment: environment)
        isSheetPresented = true
    }

    /// Retry at the failed stage; a spoken chain that never got a recording records again.
    func retry(choice: LanguageModelChoice, environment: AppEnvironment) {
        guard let flow, let request, case .failed(let stage, _) = flow.phase else { return }
        if stage == .input, request.input == .speak {
            queueSpeech(request, choice: choice, outputTitle: outputTitle ?? speechOutputTitle ?? "")
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
