import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Transcript → Extract fields (M6, plan 015): SOAP fields and medications from a dictated note as a **draft card**.
/// Solid = at or above the act threshold, dashed = provisional, and everything that failed a check or scored low sits
/// in "Needs review", outside the draft. Every field stays a draft until the person marks it reviewed. Tap a field →
/// the player seeks to the words it came from. Nothing leaves the phone.
struct ExtractFieldsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let transcriptionID: UUID
    let transcriptTitle: String
    let onSeek: (Int) -> Void
    /// Runs the extraction as soon as the sheet opens (the DEBUG screenshot launch argument).
    var autoStart = false

    @State private var model: ExtractFieldsViewModel
    @State private var soapNotes: SOAPNotes?

    struct SOAPNotes: Identifiable {
        let id = UUID()
        let text: String
    }

    init(
        transcriptionID: UUID, transcriptTitle: String, environment: AppEnvironment, autoStart: Bool = false,
        onSeek: @escaping (Int) -> Void
    ) {
        self.transcriptionID = transcriptionID
        self.transcriptTitle = transcriptTitle
        self.autoStart = autoStart
        self.onSeek = onSeek
        _model = State(
            initialValue: ExtractFieldsViewModel(
                service: environment.structuredExtraction, transcriptionID: transcriptionID))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Tokens.Color.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        }
        .task {
            await environment.structureSettings.refresh()
            await model.load()
            if autoStart { await model.extract() }
        }
        .sheet(item: $soapNotes) { notes in
            SOAPFromFieldsSheet(transcriptionID: transcriptionID, transcriptTitle: transcriptTitle, notes: notes.text)
        }
        .sheet(
            item: Binding(get: { model.reviewRequest }, set: { if $0 == nil { model.cancelReview() } })
        ) { item in
            ReviewFieldSheet(
                item: item, onAccept: { edits in Task { await model.confirmReview(item, edits: edits) } },
                onCancel: { model.cancelReview() })
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extract fields")
                .chirpTitleFont(26, .heavy)
                .foregroundStyle(Tokens.Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(transcriptTitle)
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .lineLimit(1)
            engineBadge
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityHidden(true)
                Text("Draft. Check every field against the transcript before you use it. Read on this iPhone only.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .chirpFont(12.5, .semibold)
            .foregroundStyle(Tokens.Color.partialAudioInk)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tokens.Color.partialAudioFill))
        }
    }

    /// Always visible: which engine answers (STUB is never labelled Needle), the model hash, why Needle did not run.
    @ViewBuilder private var engineBadge: some View {
        let settings = environment.structureSettings
        let text: String = {
            // A finished run names the engine that answered; before and during a run, the chosen one.
            if model.draft != nil, !isRunning { return model.engineBadge }
            switch settings.settingsValue.engine {
            case .stub: return "STUB · rules, not Needle"
            case .needle:
                if !settings.needleInBuild { return "STUB · Needle is not in this build" }
                return settings.isNeedleReady
                    ? "Needle 3 · model \(settings.needleModelSHA256?.prefix(8) ?? "") · \(NeedleExperimental.chip)"
                    : "STUB · Needle 3 not downloaded"
            }
        }()
        let isStub = text.hasPrefix("STUB")
        StatusChip(
            text, icon: .system(isStub ? "wrench.adjustable" : "cpu"),
            ink: isStub ? Tokens.Color.partialAudioInk : Tokens.Color.privacyBadgeInk,
            fill: isStub ? Tokens.Color.partialAudioFill : Tokens.Color.privacyBadgeFill
        )
        .accessibilityLabel("Engine: \(text)")
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            Text(
                "Reads each sentence, finds vitals, medications (dose, route, how often, started or stopped), "
                    + "allergies, problems and plan items, and cites the words each came from."
            )
            .chirpFont(14)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .running(let done, let total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: total == 0 ? 0 : Double(done), total: Double(max(total, 1)))
                    .tint(Tokens.Color.accent)
                Text(total == 0 ? "Starting…" : "Reading sentence \(done) of \(total)")
                    .chirpFont(13)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
        case .failed(let message):
            Text(message)
                .chirpFont(14)
                .foregroundStyle(AppColor.error)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            if let sections = model.sections { card(sections) }
        }
    }

    @ViewBuilder private func card(_ sections: DraftSections) -> some View {
        if sections.isEmpty {
            Text("Nothing to record was found.")
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
        }
        legend
        section("Vitals", sections.vitals)
        section("Medications", sections.medications)
        section("Allergies", sections.allergies)
        section("Problems", sections.problems)
        section("Plan", sections.plan)
        if !sections.needsReview.isEmpty {
            SectionLabel("Needs review (\(sections.needsReview.count))")
                .padding(.top, 6)
            Text(
                "Not in the draft: low confidence, or a check failed. Review to add one; a failed check shows why first."
            )
            .chirpFont(12.5)
            .foregroundStyle(Tokens.Color.secondary)
            ForEach(sections.needsReview) { item in row(item) }
        }
        if !sections.draftItems.isEmpty {
            Text(
                "“Use in SOAP note” sends only the fields you reviewed (\(model.reviewedDraftCount) of "
                    + "\(sections.draftItems.count)). Tap the circle to review one."
            )
            .chirpFont(12.5)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if sections.skippedCount > 0 {
            Text("\(sections.skippedCount) sentence\(sections.skippedCount == 1 ? "" : "s") held nothing to record.")
                .chirpFont(12.5)
                .foregroundStyle(Tokens.Color.mutedText)
        }
        if let seconds = model.draft?.seconds {
            Text(String(format: "Read in %.1f s", seconds))
                .chirpFont(12)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.mutedText)
        }
    }

    /// Re-review minor 8: the STUB is never "confident", so its legend does not offer a solid style.
    private var legend: some View {
        HStack(spacing: 14) {
            if model.draft?.isStub == true {
                Label("Dashed: provisional (STUB fields are never solid)", systemImage: "square.dashed")
            } else {
                Label("Solid: confident", systemImage: "square")
                Label("Dashed: provisional", systemImage: "square.dashed")
            }
        }
        .chirpFont(11.5)
        .foregroundStyle(Tokens.Color.secondary)
    }

    @ViewBuilder private func section(_ title: String, _ items: [DraftItem]) -> some View {
        if !items.isEmpty {
            SectionLabel(title)
                .padding(.top, 6)
            ForEach(items) { item in row(item) }
        }
    }

    private func row(_ item: DraftItem) -> some View {
        let dashed = item.isProvisional && !item.field.reviewed
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if let ms = item.seekMs { onSeek(ms) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .chirpFont(15, .semibold)
                            .foregroundStyle(Tokens.Color.ink)
                        Spacer(minLength: 6)
                        Text(item.detail)
                            .chirpFont(14)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.Color.ink)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(Self.evidence(item))
                        .chirpFont(12)
                        .italic()
                        .foregroundStyle(Tokens.Color.secondary)
                        .lineLimit(4)
                    Text(statusLine(item))
                        .chirpFont(11.5, .semibold)
                        .monospacedDigit()
                        .foregroundStyle(item.needsReview ? AppColor.error : Tokens.Color.secondary)
                    ForEach(item.field.reviewReasons, id: \.self) { reason in
                        Text(reason)
                            .chirpFont(11.5)
                            .foregroundStyle(AppColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.seekMs == nil ? "" : "Plays the words it came from")

            Button {
                Task { await model.toggleReviewed(item) }
            } label: {
                Image(systemName: item.field.reviewed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.field.reviewed ? Tokens.Color.success : Tokens.Color.mutedText)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                item.field.reviewed
                    ? "Reviewed. Tap to undo."
                    : item.needsReviewSheet ? "Review: shows why it was flagged" : "Mark reviewed")
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    item.needsReview ? AppColor.error.opacity(0.6) : Tokens.Color.border,
                    style: StrokeStyle(lineWidth: dashed ? 1.5 : 1, dash: dashed ? [5, 4] : [])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tokens.Color.surface))
        )
        .accessibilityElement(children: .contain)
    }

    /// The whole sentence, the field's own words in bold on a tint (review L3 I2).
    static func evidence(_ item: DraftItem) -> AttributedString {
        let sentence = item.evidenceSentence.isEmpty ? item.evidence : item.evidenceSentence
        let ns = sentence as NSString
        guard let highlight = item.highlight, highlight.upperBound <= ns.length else {
            return AttributedString("“\(sentence)”")
        }
        var middle = AttributedString(
            ns.substring(with: NSRange(location: highlight.lowerBound, length: highlight.count)))
        middle.inlinePresentationIntent = .stronglyEmphasized
        middle.foregroundColor = Tokens.Color.ink
        middle.backgroundColor = Tokens.Color.accent.opacity(0.18)
        return AttributedString("“" + ns.substring(to: highlight.lowerBound)) + middle
            + AttributedString(ns.substring(from: highlight.upperBound) + "”")
    }

    private func statusLine(_ item: DraftItem) -> String {
        let verdict: String =
            switch item.field.verdict {
            case .act: "Confident"
            case .provisional: "Provisional"
            case .needsReview: "Needs review"
            }
        let confidence = "\(Int((item.field.confidence * 100).rounded()))%"
        let review = item.field.reviewed ? (item.isEdited ? "Reviewed, edited" : "Reviewed") : "Draft"
        let stub = model.draft?.isStub == true ? " (STUB pseudo-confidence)" : ""
        return "\(verdict) · \(confidence)\(stub) · \(review)"
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.extract() }
            } label: {
                CapsuleButtonLabel(title: model.draft == nil ? "Extract fields" : "Extract again", kind: .tinted)
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            Spacer(minLength: 0)
            Button {
                if let text = model.soapNotes { soapNotes = SOAPNotes(text: text) }
            } label: {
                CapsuleButtonLabel(title: "Use in SOAP note", kind: .filled)
            }
            .buttonStyle(.plain)
            .disabled(model.soapNotes == nil || isRunning)
            .opacity(model.soapNotes == nil ? 0.5 : 1)
            .accessibilityHint("Drafts a SOAP note with the on-device model; nothing leaves this iPhone")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Tokens.Color.ground)
    }

    private var isRunning: Bool {
        if case .running = model.phase { return true }
        return false
    }
}

/// A field that failed a check (review L3 I8): its reasons first, the sentence it came from, and every value editable
/// before "Accept". The reasons stay with the field and go into the SOAP hand-off with it.
struct ReviewFieldSheet: View {
    let item: DraftItem
    let onAccept: ([String: String]) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String]

    init(item: DraftItem, onAccept: @escaping ([String: String]) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.onAccept = onAccept
        self.onCancel = onCancel
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: item.editableFields.map { ($0.key, $0.value) }))
    }

    private var edited: Bool {
        item.editableFields.contains { values[$0.key, default: ""] != $0.value }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Why it needs review") {
                    ForEach(item.field.reviewReasons, id: \.self) { reason in
                        Text(reason)
                            .foregroundStyle(AppColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("What was said") {
                    Text(ExtractFieldsSheet.evidence(item))
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    ForEach(item.editableFields) { field in
                        LabeledContent(field.label) {
                            TextField(
                                field.label,
                                text: Binding(get: { values[field.key, default: ""] }, set: { values[field.key] = $0 })
                            )
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                    }
                } header: {
                    Text("Correct it if needed")
                } footer: {
                    Text(
                        "Accepting keeps these reasons with the field; the SOAP note hand-off lists them next to it. "
                            + "Nothing leaves this iPhone.")
                }
            }
            .navigationTitle(item.title.isEmpty ? "Review field" : item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edited ? "Accept edited" : "Accept anyway") { onAccept(values) }
                        .accessibilityHint(
                            edited ? "Marks the field reviewed with your changes" : "Marks the field reviewed as shown")
                }
            }
        }
    }
}

/// "Use in SOAP note": the SOAP template with the reviewed draft as `{{userNotes}}`, run by the Apple on-device model
/// only (`SOAPDraftHandoff.modelChoice`), so the clinical draft never leaves the phone.
struct SOAPFromFieldsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let transcriptionID: UUID
    let transcriptTitle: String
    let notes: String

    @State private var host: TransformRunHost?
    @State private var missingTemplate = false

    var body: some View {
        NavigationStack {
            Group {
                if let host, let run = host.run, let request = host.request {
                    TransformRunView(
                        host: host, run: run, request: request, transcriptTitle: transcriptTitle,
                        onChooseAnother: { dismiss() }, onDone: { dismiss() })
                } else if let error = host?.startError {
                    message(error)
                } else if missingTemplate {
                    message("The SOAP note template is missing. Open the Transforms tab once, then try again.")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        host?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .clinicalConfirmation(for: host?.run)
        .task { await start() }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .chirpFont(15)
            .foregroundStyle(AppColor.error)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func start() async {
        guard host == nil else { return }
        await environment.deliverableLibrary.load()
        guard
            let template = environment.deliverableLibrary.templates.first(where: {
                $0.canonicalKey == SOAPDraftHandoff.templateKey
            })
        else {
            missingTemplate = true
            return
        }
        let host = TransformRunHost(environment: environment)
        self.host = host
        await host.start(
            TransformRunHost.Request(
                template: template, transcriptionID: transcriptionID, choice: SOAPDraftHandoff.modelChoice,
                notes: notes))
    }
}
