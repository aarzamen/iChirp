import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// One Jev decision (M6a, plan 021): the chosen option with its confidence in words and as a number, every option as a
/// labelled bar, the gate verdict, latency and model, and one Apply action per recipe. Errors show their message and a
/// Retry. A real request runs while "Asking Jev…" shows; nothing is simulated.
struct DecisionResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let run: DecisionRunViewModel
    /// Where the request went, for the footnote (`api.typesafe.ai`, or the DEBUG stub).
    let host: String
    let markClinical: () async throws -> Void
    let useTemplate: (String) -> Void
    let showTags: ([Int: String]) -> Void

    @State private var confirmingClinical = false
    @State private var applyError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Tokens.Color.ground)
            .navigationTitle(run.recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Mark this transcript as clinical?", isPresented: $confirmingClinical, titleVisibility: .visible
            ) {
                Button("Mark as Clinical") { Task { await applyClinical() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Clinical transcripts only go to this iPhone or a Mac you trust, and Jev will not see this one again."
                )
            }
            .alert(
                "Couldn’t apply",
                isPresented: Binding(get: { applyError != nil }, set: { if !$0 { applyError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(applyError ?? "")
            }
        }
        .tint(AppColor.accentText)
        .task {
            if run.phase == .idle { await run.start() }
        }
        .onDisappear { run.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch run.phase {
        case .idle, .running:
            HStack(spacing: 10) {
                ProgressView()
                Text("Asking Jev…")
                    .chirpFont(16, .semibold)
                    .foregroundStyle(Tokens.Color.ink)
            }
            .padding(.top, 12)
            sentNote
        case .blocked(let message):
            Label(message, systemImage: "lock.shield")
                .chirpFont(16, .semibold)
                .foregroundStyle(Tokens.Color.ink)
                .padding(.top, 12)
            Text("Nothing was sent.")
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
        case .failed(let message):
            Text("Jev couldn’t answer")
                .chirpFont(17, .semibold)
                .foregroundStyle(AppColor.error)
                .padding(.top, 12)
            Text(message)
                .chirpFont(14)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await run.retry() }
            } label: {
                CapsuleButtonLabel(title: "Retry", kind: .filled)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry")
        case .decided(let report):
            decided(report)
        }
    }

    // MARK: - Decided

    @ViewBuilder private func decided(_ report: DecisionReport) -> some View {
        switch report.recipe {
        case .recordingKind, .templateSuggestion:
            if let item = report.items.first {
                answerHeader(item)
                SectionLabel("All options")
                    .padding(.top, 6)
                VStack(spacing: 8) {
                    ForEach(item.options) { OptionBar(option: $0, isChoice: $0.id == item.choice) }
                }
                .chirpCard(radius: Tokens.Radius.s, padding: 14)
            }
        case .paragraphTags:
            Text("\(report.items.count) paragraphs tagged")
                .chirpFont(20, .bold)
                .foregroundStyle(Tokens.Color.ink)
                .padding(.top, 8)
            ForEach(report.items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Paragraph \((item.paragraphIndex ?? 0) + 1)")
                            .chirpFont(13, .semibold)
                            .foregroundStyle(Tokens.Color.secondary)
                        Spacer()
                        VerdictBadge(verdict: item.verdict)
                    }
                    Text("\(item.choiceTitle) · confidence \(Self.number(item.confidence))")
                        .chirpFont(15.5, .semibold)
                        .foregroundStyle(Tokens.Color.ink)
                    ForEach(item.options) { OptionBar(option: $0, isChoice: $0.id == item.choice, compact: true) }
                }
                .chirpCard(radius: Tokens.Radius.s, padding: 14)
            }
        }
        applyAction(report)
        Text("Model \(report.model) · answered in \(report.latencyMs) ms")
            .chirpFont(12.5)
            .monospacedDigit()
            .foregroundStyle(Tokens.Color.secondary)
            .padding(.top, 4)
        sentNote
    }

    private func answerHeader(_ item: DecisionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(run.recipe == .recordingKind ? "Jev thinks this is" : "Jev suggests")
            Text(item.choiceTitle)
                .chirpTitleFont(28, .heavy)
                .foregroundStyle(Tokens.Color.ink)
            HStack(spacing: 8) {
                VerdictBadge(verdict: item.verdict)
                Text("\(Self.words(item.verdict)) · confidence \(Self.number(item.confidence))")
                    .chirpFont(14)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func applyAction(_ report: DecisionReport) -> some View {
        switch report.recipe {
        case .recordingKind:
            if report.suggestsMarkingClinical {
                applyButton("Mark as clinical…") { confirmingClinical = true }
            } else {
                applyNote("Nothing to apply. Jev only ever suggests; it changes nothing on its own.")
            }
        case .templateSuggestion:
            if let key = report.suggestedTemplateKey {
                applyButton("Use this template") {
                    useTemplate(key)
                    dismiss()
                }
            } else {
                applyNote("No template is suggested with enough confidence.")
            }
        case .paragraphTags:
            if report.paragraphTags.isEmpty {
                applyNote("No paragraph was tagged with enough confidence.")
            } else {
                applyButton("Show tags") {
                    showTags(report.paragraphTags)
                    dismiss()
                }
            }
        }
    }

    private func applyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CapsuleButtonLabel(title: title, kind: .filled)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .accessibilityLabel(title)
    }

    private func applyNote(_ text: String) -> some View {
        Text(text)
            .chirpFont(13.5)
            .foregroundStyle(Tokens.Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    private var sentNote: some View {
        Text(
            "Jev saw an excerpt of this transcript (up to 3,000 characters) and a few counts, sent to \(host). "
                + "Clinical items are never sent."
        )
        .chirpFont(12.5)
        .foregroundStyle(Tokens.Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func applyClinical() async {
        do {
            try await markClinical()
            dismiss()
        } catch {
            applyError = Formatting.message(for: error)
        }
    }

    static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func words(_ verdict: DecisionVerdict) -> String {
        switch verdict {
        case .act: "High confidence"
        case .suggest: "Medium confidence"
        case .unsure: "Low confidence"
        }
    }
}

/// The gate verdict as a small capsule: "Confident", "Likely", "Unsure".
struct VerdictBadge: View {
    let verdict: DecisionVerdict

    var body: some View {
        Text(verdict.title)
            .chirpFont(12, .bold)
            .foregroundStyle(verdict == .unsure ? Tokens.Color.secondary : Tokens.Color.privacyBadgeInk)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background(
                Capsule().fill(verdict == .unsure ? AppColor.quietFill : Tokens.Color.privacyBadgeFill)
            )
            .accessibilityLabel("Verdict: \(verdict.title)")
    }
}

/// One option: its name, a bar as long as its probability, and the percentage (labels and numbers, not color alone).
struct OptionBar: View {
    let option: DecisionOption
    let isChoice: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Text(option.title)
                .chirpFont(compact ? 12.5 : 13.5, isChoice ? .bold : .regular)
                .foregroundStyle(Tokens.Color.ink)
                .lineLimit(1)
                .frame(width: compact ? 96 : 128, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColor.quietFill)
                    Capsule()
                        .fill(isChoice ? Tokens.Color.accent : Tokens.Color.mutedText)
                        .frame(width: max(2, proxy.size.width * min(max(option.probability, 0), 1)))
                }
            }
            .frame(height: compact ? 6 : 8)
            Text("\(Int((option.probability * 100).rounded()))%")
                .chirpFont(compact ? 12 : 13, .semibold)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(option.title), \(Int((option.probability * 100).rounded())) percent" + (isChoice ? ", chosen" : ""))
    }
}
