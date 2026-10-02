import ChirpCore
import ChirpFeatures
import ChirpText
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

/// A small capsule naming a privacy class; clinical is emphasized. `text` replaces the class name with a longer label
/// ("Clinical (it has a SOAP note)"), which may wrap to two lines.
struct PrivacyClassBadge: View {
    let privacyClass: PrivacyClass
    var text: String?

    var body: some View {
        Label(text ?? privacyClass.title, systemImage: privacyClass.systemImage)
            .labelStyle(.titleAndIcon)
            .chirpFont(11.5, .semibold)
            .lineLimit(text == nil ? 1 : 2)
            .fixedSize(horizontal: text == nil, vertical: true)
            .foregroundStyle(privacyClass == .clinical ? Tokens.Color.privacyBadgeInk : Tokens.Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, text == nil ? 0 : 3)
            .frame(minHeight: 24)
            .background(
                Capsule().fill(privacyClass == .clinical ? Tokens.Color.privacyBadgeFill : AppColor.quietFill)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Privacy: \(text ?? privacyClass.title)")
    }
}

/// A generated document's class as the privacy rules use it: its own class raised by its transcript's effective class
/// (the transcript and every document made from it). The same class the Library row badges, Listen reads and an
/// export marks (known issue K4: the document screen used to show only the stored class).
enum DocumentPrivacy {
    /// Nil when the document is gone; clinical when it could not be read.
    @MainActor
    static func effectiveClass(of documentID: UUID, environment: AppEnvironment) async -> PrivacyClass? {
        await VoiceSourcePrivacy.current(
            for: .deliverable(id: documentID), transcripts: environment.store,
            deliverables: environment.deliverableStore)
    }
}

/// The Transcript and Document screens' privacy-class control. Changes go through `DeliverableService.setPrivacyClass`
/// (the caller's `apply`), which also raises the transcript's documents. Lowering a clinical transcript asks first.
///
/// UX audit F51: with `effective`, the badge shows the class the privacy rules use and why it is stricter than the mark
/// ("Clinical (it has a SOAP note)"), and the menu says so above the choices, so a label never reads "Personal" while
/// Listen or Transform asks about clinical text. The menu still sets the item's own mark (`current`).
struct PrivacyClassControl: View {
    let current: PrivacyClass
    /// The class as the routers use it (`EffectivePrivacyExplanation`); nil shows `current` only.
    var effective: EffectivePrivacyExplanation?
    let apply: (PrivacyClass) async throws -> Void

    @State private var pendingLowering: PrivacyClass?
    @State private var error: String?

    /// The raised explanation, when the effective class is stricter than the mark.
    private var raised: EffectivePrivacyExplanation? {
        guard let effective, effective.isRaised, effective.stored == current else { return nil }
        return effective
    }

    var body: some View {
        Menu {
            // Why the badge reads stricter than the mark, above the choices (a menu shows text as an inert line).
            if let sentence = raised?.sentence {
                Text(sentence)
                Divider()
            }
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
                PrivacyClassBadge(privacyClass: raised?.effective ?? current, text: raised?.label)
                Image(systemName: "chevron.down")
                    .chirpGlyph(9, .bold, relativeTo: .caption)
                    .foregroundStyle(Tokens.Color.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            raised.map { "Privacy class: \($0.label). Marked \(current.title)" } ?? "Privacy class: \(current.title)"
        )
        .accessibilityHint("Changes who may read it")
        .alert(
            "Mark as \(pendingLowering?.title ?? "")?",
            isPresented: Binding(get: { pendingLowering != nil }, set: { if !$0 { pendingLowering = nil } }),
            presenting: pendingLowering
        ) { value in
            Button("Mark as \(value.title)") { Task { await set(value) } }
            Button("Keep Clinical", role: .cancel) {}
        } message: { _ in
            Text(Self.loweringMessage)
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

    /// What lowering a clinical mark changes (review R6b-9). The routers use the stricter of the item and every
    /// document made from it (`EffectivePrivacyClass`), so a clinical document such as a SOAP note keeps the item
    /// clinical while it exists; the sentence says so instead of promising that nothing will ask any more. It names
    /// no noun: the control is on transcripts, typed text and imported documents.
    static let loweringMessage =
        "Parakeet stops asking before sending it to a cloud model, unless a clinical document made from it, such as "
        + "a SOAP note, still makes it count as clinical. Documents already made from it keep their own class."

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

/// One symbol per kind of output (R7-11): Create's tiles, the Create run's header and the Transforms template list use
/// the same glyph for the same thing, and no glyph means two things (Summary is not the text-item cover's
/// `text.alignleft`, nor Extract fields' `list.bullet.rectangle`).
enum OutputSymbol {
    static let transcript = "text.quote"
    static let summary = "list.bullet.clipboard"
    static let document = "doc.richtext"
    static let voiceMessage = "waveform.badge.plus"
}

/// How a template looks in lists: an icon and one line on what it makes. Built-ins by canonical key; user templates
/// get a generic style.
struct TemplateStyle: Equatable {
    let systemImage: String
    let summary: String

    static let builtIns: [String: TemplateStyle] = [
        "summary": TemplateStyle(systemImage: OutputSymbol.summary, summary: "The main points in a few paragraphs"),
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
                    .chirpGlyph(16, .semibold, relativeTo: .body)
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
                    .chirpGlyph(13, .semibold, relativeTo: .subheadline)
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

/// The locality chip: where content goes. A lock only where clinical text may go without a question (this iPhone, or a
/// home-network host the person trusts), a network glyph for a home-network host that asks, a cloud for the internet
/// (review R6b-21: the menu and the chip used to disagree). The private chip draws its lock and words in
/// `privacyBadgeInk` on an opaque `privacyBadgeFill` (R7-10: no opacity blend, a measured pair). The text wraps to a
/// second line, left-aligned, rather than hiding the model's name, and "on-device" never breaks at its hyphen.
struct LocalityChip: View {
    let text: String
    let systemImage: String
    let staysPrivate: Bool

    init(text: String, locality: EngineLocality, trustedForClinical: Bool) {
        self.text = text
        systemImage = LocalityGlyph.symbol(locality: locality, trustedForClinical: trustedForClinical)
        staysPrivate = LocalityGlyph.staysPrivate(locality: locality, trustedForClinical: trustedForClinical)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .chirpGlyph(11, .bold, relativeTo: .footnote)
                .foregroundStyle(staysPrivate ? Tokens.Color.privacyBadgeInk : Tokens.Color.secondary)
                .accessibilityHidden(true)
            Text(LocalityGlyph.unbroken(text))
                .chirpFont(12.5, .semibold)
                .foregroundStyle(staysPrivate ? Tokens.Color.privacyBadgeInk : Tokens.Color.ink)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 28)
        .background(Capsule().fill(staysPrivate ? Tokens.Color.privacyBadgeFill : AppColor.quietFill))
    }
}

/// The one map from where a model runs to its glyph (review R6b-21), for the chooser's menu, its chip and a run's
/// route chip.
enum LocalityGlyph {
    /// Clinical text may go there without a question: this iPhone, or a home-network host the person trusts.
    static func staysPrivate(locality: EngineLocality, trustedForClinical: Bool) -> Bool {
        locality == .onDevice || (locality == .localNetwork && trustedForClinical)
    }

    static func symbol(locality: EngineLocality, trustedForClinical: Bool) -> String {
        if staysPrivate(locality: locality, trustedForClinical: trustedForClinical) { return "lock.fill" }
        return locality == .localNetwork ? "network" : "icloud"
    }

    /// "Apple on-device model" with a non-breaking hyphen, so a wrapped chip never reads "on-" / "device" (R7-10).
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: "on-device", with: "on\u{2011}device")
    }
}

extension LanguageModelChoice {
    /// Content stays on the iPhone or a Mac the user trusted.
    var staysPrivate: Bool { isTrustedForClinical }

    /// Where it runs and which model (UX audit F41): "on this iPhone · Apple on-device model". A home-network or cloud
    /// place already names it ("in the cloud (Claude)").
    var placeWithName: String {
        locality == .onDevice ? "\(place) · \(name)" : place
    }

    var localitySymbol: String {
        LocalityGlyph.symbol(locality: locality, trustedForClinical: isTrustedForClinical)
    }
}

extension ModelRoute {
    /// A run's real route with the model's name when the place does not say it: "on this iPhone · Apple on-device model".
    var placeWithName: String {
        let place = ModelPlace.phrase(for: self)
        return locality == .onDevice ? "\(place) · \(providerName)" : place
    }
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
                        Image(systemName: option.localitySymbol)
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
                LocalityChip(
                    text: "\(prefix) \(choice.placeWithName)", locality: choice.locality,
                    trustedForClinical: choice.isTrustedForClinical)
                Image(systemName: "chevron.down")
                    .chirpGlyph(9, .bold, relativeTo: .caption)
                    .foregroundStyle(Tokens.Color.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(prefix) \(choice.placeWithName)")
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

/// What a run is about, for the clinical heads-up's words.
enum ModelRunSubject {
    /// Create: whatever the person brings (a dictation, text, a link, a file).
    case item
    case transcript
    case document

    var noun: String {
        switch self {
        case .item: "item"
        case .transcript: "transcript"
        case .document: "document"
        }
    }
}

/// The one clinical heads-up under every model chooser (Create, Transform, Ask, Edit by voice; review R6b-8): one rule,
/// one wording, matching what `PrivacyRoutingPolicy` does. Clinical text goes to this iPhone, or to a home-network host
/// the person trusts, without a question; to anything else (the internet, or a home-network host that is not trusted)
/// it asks before each run.
enum ModelClinicalNote {
    /// - Parameters:
    ///   - isClinical: the subject counts as clinical now (its effective class; Create: the Clinical switch).
    ///   - makesDocuments: the run writes a document, so a SOAP note template asks too.
    static func text(
        for choice: LanguageModelChoice, subject: ModelRunSubject, isClinical: Bool, makesDocuments: Bool
    ) -> String? {
        if choice.locality == .onDevice { return nil }
        if choice.isTrustedForClinical {
            guard isClinical else { return nil }
            return "This \(subject.noun) is clinical. You trust \(choice.name) for clinical text, so it goes there "
                + "without asking."
        }
        if isClinical {
            return "This \(subject.noun) is clinical, so Parakeet asks before sending it to \(choice.name)."
        }
        let what = makesDocuments ? "Clinical \(subject.noun)s and SOAP notes" : "Clinical \(subject.noun)s"
        return "\(what) ask before anything is sent to \(choice.name)."
    }
}

/// The notes under a model chooser: why the picked model cannot run now, or the clinical heads-up.
struct ModelRunNotes: View {
    @Environment(AppEnvironment.self) private var environment
    let choice: LanguageModelChoice
    let subject: ModelRunSubject
    let isClinical: Bool
    var makesDocuments = false

    var body: some View {
        if let message = environment.unavailableMessage(for: choice) {
            ModelUnavailableNote(message: message)
        } else if let note = ModelClinicalNote.text(
            for: choice, subject: subject, isClinical: isClinical, makesDocuments: makesDocuments)
        {
            Text(note)
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// iChirp's own colors for `MarkdownDocument` (UX audit F23): `Tokens` colors so light/dark both look right, and
/// relative system text styles (not a fixed-size `chirpFont`) so headings and body text both track Dynamic Type —
/// `ChirpText` cannot import `ChirpUI`'s `chirpFont` helper (it lives in the App target), and a fixed-size
/// `.system(size:)` font does not scale with the user's text-size setting the way a relative style does.
extension MarkdownDocumentStyle {
    static let chirp = MarkdownDocumentStyle(
        textColor: Tokens.Color.ink,
        secondaryColor: Tokens.Color.secondary,
        bodyFont: .system(.body),
        codeFont: .system(.body, design: .monospaced),
        headingFont: { level in
            (level <= 1 ? Font.system(.title2, design: .rounded) : Font.system(.headline, design: .rounded)).bold()
        })
}

/// An editable generated document. Formatted (the default) renders the Markdown with `MarkdownDocument`; Edit shows
/// the raw source in a `TextEditor` — the interaction UX audit F23 asked us to pick and document. Both write the
/// same `document.draft`, so autosave (about a second after typing stops, and when the editor goes away) and
/// Versions are unaffected by which one is showing.
///
/// Plan 024 Task 10: the Formatted | Edit switch is ChirpUI's segmented control (warm palette, Dynamic Type; R7-4,
/// R7-5), and a screen may put its own controls on the same row (`accessory`: the document screen's Edit by voice and
/// Versions, R7-6), which stack under it when they do not fit.
struct DocumentEditor: View {
    @Bindable var document: DeliverableDocumentViewModel
    var accessory: AnyView?
    @State private var mode: Mode = .formatted

    enum Mode: String, CaseIterable, Identifiable {
        case formatted = "Formatted"
        case edit = "Edit"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let accessory {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Spacing.s) {
                        modePicker
                        Spacer(minLength: 0)
                        accessory
                    }
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                        modePicker
                        accessory
                    }
                }
            } else {
                modePicker
            }

            switch mode {
            case .formatted: formatted
            case .edit: edit
            }
        }
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

    private var modePicker: some View {
        ChirpSegmentedControl(
            "Document view", selection: $mode,
            segments: Mode.allCases.map { .init($0.rawValue, value: $0) },
            width: accessory == nil ? .fill : .fit)
    }

    /// UX audit F23: headings, bulleted and numbered lists, bold and italics rendered instead of raw `**`/`##`. No
    /// inner `ScrollView` — both call sites (`DeliverableDetailScreen`, `TransformRunView`) already scroll the
    /// whole screen, and nesting a second vertical scroll view here would fight it for scroll gestures.
    private var formatted: some View {
        MarkdownDocument(document.draft, style: .chirp)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(CardBackground(radius: Tokens.Radius.m))
            .accessibilityLabel("Document text, formatted")
    }

    private var edit: some View {
        TextEditor(text: $document.draft)
            .chirpFont(16)
            .lineSpacing(5)
            .foregroundStyle(Tokens.Color.ink)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(CardBackground(radius: Tokens.Radius.m))
            .accessibilityLabel("Document text, editable Markdown source")
    }
}

/// Clinical output is a draft the clinician reviews before use (spec/12).
/// Plan 024 Task 8 (reviews R3-1, R4-2): the model stopped at its length limit, so the text above is kept but
/// incomplete. Says so in plain words and, when the screen can, offers to try again.
struct CutOffNote: View {
    let message: String
    var tryAgainTitle = "Try again"
    var onTryAgain: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppColor.error)
                    .accessibilityHidden(true)
                Text(message)
                    .chirpFont(13, .semibold)
                    .foregroundStyle(AppColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onTryAgain {
                Button(tryAgainTitle, action: onTryAgain)
                    .buttonStyle(.chirp(.tinted, size: .compact))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.s, style: .continuous).stroke(AppColor.error, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

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
