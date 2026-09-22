import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Transcript → Transform: pick the model and a template, add optional notes, then watch the result stream into an
/// editable document. Clinical text bound for a cloud or untrusted model waits for the per-run confirmation.
struct TransformSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let transcriptionID: UUID
    let transcriptTitle: String
    let privacyClass: PrivacyClass

    @State private var host: TransformRunHost
    @State private var choice: LanguageModelChoice
    @State private var notes = ""

    init(transcriptionID: UUID, transcriptTitle: String, privacyClass: PrivacyClass, environment: AppEnvironment) {
        self.transcriptionID = transcriptionID
        self.transcriptTitle = transcriptTitle
        self.privacyClass = privacyClass
        _host = State(initialValue: TransformRunHost(environment: environment))
        _choice = State(initialValue: environment.languageModels.defaultChoice)
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
        .task { await environment.languageModels.refresh() }
    }

    private var picker: some View {
        let library = environment.deliverableLibrary
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transform")
                    .chirpTitleFont(26, .heavy)
                    .foregroundStyle(Tokens.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(transcriptTitle)
                    .chirpFont(13)
                    .foregroundStyle(Tokens.Color.secondary)
                    .lineLimit(1)
                TransformSetup(choice: $choice, notes: $notes, privacyClass: privacyClass, startError: host.startError)
                if let error = library.loadError {
                    Text("Couldn’t read the templates: \(error)")
                        .chirpFont(13)
                        .foregroundStyle(AppColor.error)
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
                Button("Cancel") { dismiss() }
            }
        }
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
    @State private var runTranscript: Transcription?

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
                TransformSetup(choice: $choice, notes: $notes, privacyClass: nil, startError: host.startError)
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
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func transcriptRow(_ item: Transcription) -> some View {
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
    /// The transcript's class when it is already known (Transcript → Transform).
    let privacyClass: PrivacyClass?
    let startError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ModelChoiceMenu(prefix: "Runs", choice: $choice)
                if let privacyClass {
                    PrivacyClassBadge(privacyClass: privacyClass)
                }
            }
            if let message = environment.unavailableMessage(for: choice) {
                ModelUnavailableNote(message: message)
            }
            if !choice.isTrustedForClinical {
                Text(
                    privacyClass == .clinical
                        ? "This transcript is clinical. Parakeet will ask before sending it to \(choice.name)."
                        : "Clinical transcripts and SOAP notes ask before anything is sent to \(choice.name)."
                )
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let startError {
                Text(startError)
                    .chirpFont(13)
                    .foregroundStyle(AppColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Notes for the model (optional)", text: $notes, axis: .vertical)
                .lineLimit(1...4)
                .chirpFont(15)
                .padding(12)
                .background(CardBackground(radius: Tokens.Radius.s))
                .accessibilityHint("Added where a template asks for your notes")
        }
    }
}
