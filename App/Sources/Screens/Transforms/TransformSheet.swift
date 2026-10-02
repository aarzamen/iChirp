import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Transcript → Transform: pick the model and a template, add optional notes, then watch the result stream into an
/// editable document. Clinical text bound for a cloud or untrusted model waits for the per-run confirmation.
///
/// With `repeating` (plan 024 Task 10: "Make it again" on a document the model cut off), the sheet is titled "Make it
/// again", lists that document's template first, starts with its notes and, when it is still set up, its model. The
/// run makes a new document; the cut-off one stays.
struct TransformSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let transcriptionID: UUID
    let transcriptTitle: String
    let privacyClass: PrivacyClass
    /// M6a: a built-in's canonical key Jev suggested, shown first as "Suggested by Jev" (never run automatically).
    let suggestedTemplateKey: String?
    /// A document to make again (its template, notes and model); nil for a plain Transform.
    let repeating: Deliverable?

    @State private var host: TransformRunHost
    @State private var choice: LanguageModelChoice
    @State private var notes = ""
    /// The transcript's class as the router uses it, with why (UX audit F51).
    @State private var explanation: EffectivePrivacyExplanation?
    @State private var isConfirmingDiscard = false

    init(
        transcriptionID: UUID, transcriptTitle: String, privacyClass: PrivacyClass, environment: AppEnvironment,
        suggestedTemplateKey: String? = nil, repeating: Deliverable? = nil
    ) {
        self.transcriptionID = transcriptionID
        self.transcriptTitle = transcriptTitle
        self.privacyClass = privacyClass
        self.suggestedTemplateKey = suggestedTemplateKey
        self.repeating = repeating
        _host = State(initialValue: TransformRunHost(environment: environment))
        let models = environment.languageModels
        _choice = State(
            initialValue: repeating.flatMap { Self.originalChoice(of: $0, in: models.choices) } ?? models.defaultChoice)
        _notes = State(initialValue: repeating?.userNotes ?? "")
    }

    /// The model a document was written with, when it is still one of the choices (same name and place); nil
    /// otherwise, so the Settings default is offered and the chip says where it runs.
    static func originalChoice(of document: Deliverable, in choices: [LanguageModelChoice]) -> LanguageModelChoice? {
        choices.first { $0.name == document.provider && $0.locality == document.locality }
    }

    var body: some View {
        NavigationStack {
            if let run = host.run, let request = host.request {
                TransformRunView(
                    host: host, run: run, request: request, transcriptTitle: transcriptTitle,
                    onChooseAnother: { host.reset() }, onDone: { dismiss() })
            } else {
                picker
            }
        }
        .clinicalConfirmation(for: host.run)
        .onDisappear { host.cancel() }
        .task {
            explanation = try? await EffectivePrivacyExplanation.current(
                transcriptionID: transcriptionID, transcripts: environment.store,
                deliverables: environment.deliverableStore)
            await environment.languageModels.refresh()
        }
    }

    private var picker: some View {
        let library = environment.deliverableLibrary
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(repeating == nil ? "Transform" : "Make it again")
                    .chirpTitleFont(26, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(transcriptTitle)
                    .chirpFont(13)
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(1)
                TransformSetup(
                    choice: $choice, notes: $notes, privacyClass: explanation?.effective ?? privacyClass,
                    explanation: explanation, startError: host.startError)
                if let error = library.loadError {
                    Text("Couldn’t read the templates: \(error)")
                        .chirpFont(13)
                        .foregroundStyle(AppColor.error)
                }
                if let key = suggestedTemplateKey,
                    let suggested = (library.documentTemplates + library.transformTemplates).first(where: {
                        $0.canonicalKey == key
                    })
                {
                    templateSection("Suggested by Jev", [suggested])
                }
                if let repeating,
                    let original = (library.documentTemplates + library.transformTemplates).first(where: {
                        $0.id == repeating.promptID
                    })
                {
                    templateSection("Same template", [original])
                } else if repeating != nil {
                    Text("The template this document was made with is gone. Pick another below.")
                        .chirpFont(13)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                templateSection("Documents", library.documentTemplates)
                templateSection("Rewrites", library.transformTemplates)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Tokens.Color.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    switch DiscardDecision.onCancel(hasInput: DiscardDecision.holdsInput(notes)) {
                    case .close: dismiss()
                    case .ask: isConfirmingDiscard = true
                    }
                }
            }
        }
        .discardInputConfirmation(
            "Discard your notes?", message: "The notes you typed for the model are not kept.",
            hasInput: DiscardDecision.holdsInput(notes), isAsking: $isConfirmingDiscard
        ) { dismiss() }
    }

    @ViewBuilder private func templateSection(_ title: String, _ templates: [PromptTemplate]) -> some View {
        if !templates.isEmpty {
            SectionLabel(title)
                .padding(.leading, 4)
                .padding(.top, 8)
            VStack(spacing: 8) {
                ForEach(templates) { template in
                    Button {
                        start(template)
                    } label: {
                        TemplateRow(template: template, trailing: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Runs \(template.name) \(choice.place)")
                }
            }
        }
    }

    private func start(_ template: PromptTemplate) {
        let request = TransformRunHost.Request(
            template: template, transcriptionID: transcriptionID, choice: choice, notes: notes)
        Task { await host.start(request) }
    }
}

/// Transforms tab → a template: pick the transcript it runs on, then the same run view.
struct TemplateLaunchSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let template: PromptTemplate

    @State private var host: TransformRunHost
    @State private var choice: LanguageModelChoice
    @State private var notes = ""
    @State private var runTranscript: TranscriptionSummary?
    @State private var isConfirmingDiscard = false

    init(template: PromptTemplate, environment: AppEnvironment) {
        self.template = template
        _host = State(initialValue: TransformRunHost(environment: environment))
        _choice = State(initialValue: environment.languageModels.defaultChoice)
    }

    var body: some View {
        NavigationStack {
            if let run = host.run, let request = host.request {
                TransformRunView(
                    host: host, run: run, request: request, transcriptTitle: runTranscript?.displayTitle ?? "",
                    onChooseAnother: { host.reset() }, onDone: { dismiss() })
            } else {
                picker
            }
        }
        .clinicalConfirmation(for: host.run)
        .onDisappear { host.cancel() }
        .task { await environment.languageModels.refresh() }
    }

    private var picker: some View {
        let transcripts = environment.library.items.filter { $0.status == .completed }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TemplateRow(template: template)
                TransformSetup(
                    choice: $choice, notes: $notes, privacyClass: nil, explanation: nil, startError: host.startError)
                SectionLabel("Choose a transcript")
                    .padding(.leading, 4)
                    .padding(.top, 8)
                if transcripts.isEmpty {
                    Text("No finished transcripts yet. Import a file in Capture, then come back.")
                        .chirpFont(14)
                        .foregroundStyle(Tokens.Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .chirpCard(radius: Tokens.Radius.m, padding: 14)
                }
                VStack(spacing: 8) {
                    ForEach(transcripts) { item in
                        Button {
                            runTranscript = item
                            let request = TransformRunHost.Request(
                                template: template, transcriptionID: item.id, choice: choice, notes: notes)
                            Task { await host.start(request) }
                        } label: {
                            transcriptRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Tokens.Color.ground)
        .navigationTitle("Run \(template.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    switch DiscardDecision.onCancel(hasInput: DiscardDecision.holdsInput(notes)) {
                    case .close: dismiss()
                    case .ask: isConfirmingDiscard = true
                    }
                }
            }
        }
        .discardInputConfirmation(
            "Discard your notes?", message: "The notes you typed for the model are not kept.",
            hasInput: DiscardDecision.holdsInput(notes), isAsking: $isConfirmingDiscard
        ) { dismiss() }
    }

    private func transcriptRow(_ item: TranscriptionSummary) -> some View {
        HStack(spacing: 12) {
            TranscriptionCover(item: item, size: 40, radius: Tokens.Radius.coverSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .chirpFont(15, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                    .lineLimit(1)
                Text(Formatting.meta(for: item))
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
            Spacer(minLength: 8)
            if item.privacyClass == .clinical {
                PrivacyClassBadge(privacyClass: .clinical)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background(CardBackground(radius: Tokens.Radius.m))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Runs \(template.name) on this transcript")
    }
}

/// The model chooser, availability note, clinical heads-up and notes field shared by both Transform sheets.
private struct TransformSetup: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var choice: LanguageModelChoice
    @Binding var notes: String
    /// The transcript's class when it is already known (Transcript → Transform): the effective class once read.
    let privacyClass: PrivacyClass?
    /// Why the effective class is stricter than the transcript's mark, when it is ("Clinical (it has a SOAP note)").
    let explanation: EffectivePrivacyExplanation?
    let startError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 4) { chips }
            }
            // One heads-up for every model chooser (review R6b-8).
            ModelRunNotes(
                choice: choice, subject: .transcript, isClinical: privacyClass == .clinical, makesDocuments: true)
            if let startError {
                Text(startError)
                    .chirpFont(13)
                    .foregroundStyle(AppColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ChirpTextField("Notes for the model (optional)", text: $notes, axis: .vertical)
                .lineLimit(1...4)
                .chirpFont(15)
                .padding(12)
                .background(CardBackground(radius: Tokens.Radius.s))
                .accessibilityHint("Added where a template asks for your notes")
        }
    }

    @ViewBuilder private var chips: some View {
        ModelChoiceMenu(prefix: "Runs", choice: $choice)
        if let privacyClass {
            PrivacyClassBadge(
                privacyClass: privacyClass, text: explanation?.isRaised == true ? explanation?.label : nil)
        }
    }
}
