import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Shared pieces of the M4 screens: privacy classes, template styles, the model chooser and locality chip, the
// document editor and the run status line.

// MARK: - Privacy classes

extension PrivacyClass {
    var title: String {
        switch self {
        case .general: "General"
        case .personal: "Personal"
        case .clinical: "Clinical"
        }
    }

    var detail: String {
        switch self {
        case .general: "Nothing sensitive. Any model you set up may read it."
        case .personal: "The default. Any model you set up may read it."
        case .clinical:
            "Patient information. Only this iPhone or a Mac you trust; anything else asks you before each run."
        }
    }

    var systemImage: String {
        switch self {
        case .general: "globe"
        case .personal: "person"
        case .clinical: "cross.case"
        }
    }
}

/// A small capsule naming a privacy class; clinical is emphasized.
struct PrivacyClassBadge: View {
    let privacyClass: PrivacyClass

    var body: some View {
        Label(privacyClass.title, systemImage: privacyClass.systemImage)
            .labelStyle(.titleAndIcon)
            .chirpFont(11.5, .semibold)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(privacyClass == .clinical ? Tokens.Color.privacyBadgeInk : Tokens.Color.secondary)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(
                Capsule().fill(privacyClass == .clinical ? Tokens.Color.privacyBadgeFill : AppColor.quietFill)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Privacy: \(privacyClass.title)")
    }
}

/// The Transcript screen's privacy-class control. Changes go through `DeliverableService.setPrivacyClass` (the
/// caller's `apply`), which also raises the transcript's documents. Lowering a clinical transcript asks first.
struct PrivacyClassControl: View {
    let current: PrivacyClass
    let apply: (PrivacyClass) async throws -> Void

    @State private var pendingLowering: PrivacyClass?
    @State private var error: String?

    var body: some View {
        Menu {
            Picker("Privacy", selection: Binding(get: { current }, set: { choose($0) })) {
                ForEach(PrivacyClass.allCases, id: \.self) { value in
                    Label {
                        Text(value.title)
                        Text(value.detail)
                    } icon: {
                        Image(systemName: value.systemImage)
                    }
                    .tag(value)
                }
            }
        } label: {
            HStack(spacing: 3) {
                PrivacyClassBadge(privacyClass: current)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tokens.Color.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Privacy class: \(current.title)")
        .accessibilityHint("Changes who may read this transcript")
        .alert(
            "Mark as \(pendingLowering?.title ?? "")?",
            isPresented: Binding(get: { pendingLowering != nil }, set: { if !$0 { pendingLowering = nil } }),
            presenting: pendingLowering
        ) { value in
            Button("Mark as \(value.title)") { Task { await set(value) } }
            Button("Keep Clinical", role: .cancel) {}
        } message: { _ in
            Text(
                "Parakeet will no longer ask before sending this transcript to a cloud model. Documents already made "
                    + "from it stay clinical.")
        }
        .alert(
            "Couldn’t change the privacy class",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func choose(_ value: PrivacyClass) {
        guard value != current else { return }
        if current == .clinical {
            pendingLowering = value
        } else {
            Task { await set(value) }
        }
    }

    private func set(_ value: PrivacyClass) async {
        do {
            try await apply(value)
        } catch {
            self.error = Formatting.message(for: error)
        }
    }
}

// MARK: - Templates

/// How a template looks in lists: an icon and one line on what it makes. Built-ins by canonical key; user templates
/// get a generic style.
struct TemplateStyle: Equatable {
    let systemImage: String
    let summary: String

    static let builtIns: [String: TemplateStyle] = [
        "summary": TemplateStyle(systemImage: "text.alignleft", summary: "The main points in a few paragraphs"),
        "meeting-notes": TemplateStyle(systemImage: "person.2", summary: "Summary, decisions and owners"),
        "action-items": TemplateStyle(systemImage: "checklist", summary: "Who does what, by when"),
        "agenda": TemplateStyle(systemImage: "list.number", summary: "Topics and time boxes for the next meeting"),
        "soap-note": TemplateStyle(
            systemImage: "stethoscope", summary: "Subjective, objective, assessment and plan"),
        "polish": TemplateStyle(systemImage: "wand.and.stars", summary: "Clean up the wording, keep your voice"),
        "distill": TemplateStyle(systemImage: "line.3.horizontal.decrease", summary: "Cut to the essential points"),
        "decide": TemplateStyle(systemImage: "scalemass", summary: "Turn this into a recommendation"),
        "brief": TemplateStyle(systemImage: "doc.text", summary: "BLUF, then three bullets"),
    ]

    static func of(_ template: PromptTemplate) -> TemplateStyle {
        template.canonicalKey.flatMap { builtIns[$0] }
            ?? TemplateStyle(systemImage: "doc.badge.gearshape", summary: "Your template")
    }
}

/// A template in a list: icon tile, name and summary, a clinical badge when its output is clinical.
struct TemplateRow: View {
    let template: PromptTemplate
    var trailing: String?

    var body: some View {
        let style = TemplateStyle.of(template)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppColor.tintFill)
                Image(systemName: style.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tokens.Color.accentInk)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .chirpFont(15.5, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
                Text(style.summary)
                    .chirpFont(12.5)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if template.outputPrivacyClass == .clinical {
                PrivacyClassBadge(privacyClass: .clinical)
            }
            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.mutedText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .background(CardBackground(radius: Tokens.Radius.m))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Model choice and locality

/// The locality chip: where content goes. Green lock when it stays on the iPhone or a trusted Mac.
struct LocalityChip: View {
    let text: String
    let staysPrivate: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: staysPrivate ? "lock.fill" : "icloud")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(staysPrivate ? Tokens.Color.success : Tokens.Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .chirpFont(12.5, .semibold)
                .foregroundStyle(Tokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(Capsule().fill(staysPrivate ? Tokens.Color.privacyBadgeFill.opacity(0.7) : AppColor.quietFill))
    }
}

extension LanguageModelChoice {
    /// Content stays on the iPhone or a Mac the user trusted.
    var staysPrivate: Bool { isTrustedForClinical }
}

/// A menu chip that picks the model for this run: "Runs on this iPhone ▾". Lists Apple's model, the downloaded small
/// models and every provider, then the small models that are not ready, disabled, with why.
struct ModelChoiceMenu: View {
    @Environment(AppEnvironment.self) private var environment
    let prefix: String
    @Binding var choice: LanguageModelChoice

    var body: some View {
        Menu {
            Picker("Model", selection: $choice) {
                ForEach(environment.languageModels.choices) { option in
                    Label {
                        Text(option.name)
                        Text(option.place.prefix(1).uppercased() + option.place.dropFirst())
                    } icon: {
                        Image(systemName: option.locality == .cloud ? "icloud" : "lock")
                    }
                    .tag(option)
                }
            }
            // Small models that cannot be picked yet, with why (review I3d).
            let notReady = environment.languageModels.unavailableLocalModels
            if !notReady.isEmpty {
                Section("Not ready on this iPhone") {
                    ForEach(notReady) { item in
                        Button {
                        } label: {
                            Text(item.option.name)
                            Text(item.reason)
                        }
                        .disabled(true)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                LocalityChip(text: "\(prefix) \(choice.place)", staysPrivate: choice.staysPrivate)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tokens.Color.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(prefix) \(choice.place)")
        .accessibilityHint("Chooses the model")
    }
}

/// An on-device model (Apple's or a small one) is picked but cannot run right now: the honest sentence, with where to
/// fix it.
struct ModelUnavailableNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(AppColor.error)
                .accessibilityHidden(true)
            Text(message + " You can also add a model in Settings → Models.")
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(radius: Tokens.Radius.s, fill: AppColor.quietFill, stroke: .clear))
    }
}

extension AppEnvironment {
    /// The sentence to show when `choice` cannot run now, or nil: Apple's model and the small models on this iPhone
    /// (not downloaded, would not fit in memory; review I3d). Providers are checked when the run starts.
    func unavailableMessage(for choice: LanguageModelChoice) -> String? {
        languageModels.unavailableReason(for: choice)
    }
}

// MARK: - Runs

/// A run's phase as one line: "Checking where this can run…", "Reading part 2 of 5", "Writing…".
enum RunStatus {
    static func text(_ phase: DeliverableRunViewModel.Phase) -> String? {
        switch phase {
        case .idle: "Not sent. Nothing left this iPhone."
        case .checking: "Checking where this can run…"
        case .needsConfirmation: "Waiting for your answer…"
        case .running(let step):
            switch step {
            case nil: "Starting…"
            case .reading(let part, let total): "Reading part \(part) of \(total)"
            case .combining(let level): level > 1 ? "Combining notes (round \(level))" : "Combining notes"
            case .writing: "Writing…"
            }
        case .completed, .answered: nil
        case .failed(let message): message
        }
    }

    /// Real progress while a long transcript is read in parts; nil otherwise.
    static func fraction(_ phase: DeliverableRunViewModel.Phase) -> Double? {
        guard case .running(.reading(let part, let total)) = phase, total > 0 else { return nil }
        return Double(part) / Double(total)
    }

    static func isActive(_ phase: DeliverableRunViewModel.Phase) -> Bool {
        switch phase {
        case .checking, .running: true
        default: false
        }
    }
}

// MARK: - Documents

/// Copies text to this iPhone's clipboard only: `.localOnly` keeps it off Universal Clipboard, which would sync it to
/// the owner's other Apple devices (the same rule as the Transcript's Copy).
enum LocalPasteboard {
    static func copy(_ text: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: [.localOnly: true])
    }
}

/// An editable generated document. Edits save about a second after typing stops, and when the editor goes away.
struct DocumentEditor: View {
    @Bindable var document: DeliverableDocumentViewModel

    var body: some View {
        TextEditor(text: $document.draft)
            .chirpFont(16)
            .lineSpacing(5)
            .foregroundStyle(Tokens.Color.ink)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(CardBackground(radius: Tokens.Radius.m))
            .accessibilityLabel("Document text")
            .task(id: document.draft) {
                guard document.hasUnsavedChanges else { return }
                // Debounce: a newer keystroke cancels this wait (task(id:) restarts), so only a pause saves.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await document.save()
            }
            .onDisappear {
                Task { await document.save() }
            }
    }
}

/// Clinical output is a draft the clinician reviews before use (spec/12).
struct ClinicalDraftNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "stethoscope")
                .foregroundStyle(Tokens.Color.privacyBadgeInk)
                .accessibilityHidden(true)
            Text("Draft for your review. Check doses, dates and durations before you use it.")
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.privacyBadgeInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous).fill(Tokens.Color.privacyBadgeFill))
    }
}
