import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI
import UIKit

/// Settings → Structure models → Eval (M6, plan 015 Step 8; the Needle Bench Eval view): the STUB and Needle over 8
/// invented encounters and 30 invented command utterances. Tool shape, arguments and numeric hard fails are separate
/// numbers. Export writes the JSON report; "Copy for LLM" copies a Markdown digest.
struct StructureEvalScreen: View {
    @Environment(AppEnvironment.self) private var environment
    /// DEBUG screenshot launch argument: run these engines on appear ("stub", "needle").
    var autoRun: [String] = []

    @State private var shareURL: ShareURL?
    @State private var copiedEngine: String?

    struct ShareURL: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        @Bindable var eval = environment.structureEval
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Invented cases with known answers: 8 clinic encounters (48 sentences) and 30 short utterances, 10 "
                        + "of them dictated text that must never become a command. Nothing here is a real patient."
                )
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Toggle("Numeric normalizer (the model copies tags)", isOn: $eval.normalizerOn)
                    .chirpFont(14)
                    .tint(Tokens.Color.success)
                    .disabled(eval.isRunning)

                HStack(spacing: 10) {
                    Button {
                        Task { await eval.runStub() }
                    } label: {
                        CapsuleButtonLabel(title: "Run STUB", kind: .tinted)
                    }
                    .buttonStyle(.plain)
                    Button {
                        Task { await eval.runNeedle() }
                    } label: {
                        CapsuleButtonLabel(title: "Run Needle", kind: .filled)
                    }
                    .buttonStyle(.plain)
                    .disabled(eval.needleUnavailableReason != nil)
                    .opacity(eval.needleUnavailableReason == nil ? 1 : 0.5)
                }
                .disabled(eval.isRunning)
                if let reason = eval.needleUnavailableReason {
                    Text("Needle: \(reason)")
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                }
                status(eval.phase)

                ForEach(["needle.needle3", StubStructureModel.engineID], id: \.self) { id in
                    if let report = eval.report(for: id) { reportCard(report) }
                }

                if !eval.history.isEmpty {
                    SectionLabel("Saved runs")
                        .padding(.top, 6)
                    ForEach(eval.history.prefix(8)) { run in
                        HStack {
                            Text(StructureEngines.displayName(for: run.engineID))
                                .chirpFont(13.5, .semibold)
                            Spacer()
                            Text(
                                "shape \(Self.percent(run.toolShapeAccuracy)) · args "
                                    + "\(Self.percent(run.argumentAccuracy)) · hard fails \(run.numericHardFails)"
                            )
                            .chirpFont(12.5)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.Color.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Tokens.Color.ground)
        .navigationTitle("Structure eval")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .task {
            await eval.refresh()
            for engine in autoRun {
                if engine == "stub" { await eval.runStub() }
                if engine == "needle" { await eval.runNeedle() }
            }
        }
    }

    @ViewBuilder private func status(_ phase: StructureEvalViewModel.Phase) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .running(let engine, let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(Tokens.Color.accent)
                Text(total == 0 ? "Starting \(engine)…" : "\(engine): \(done) of \(total)")
                    .chirpFont(12.5)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
            }
        case .failed(let message):
            Text(message)
                .chirpFont(13)
                .foregroundStyle(AppColor.error)
        }
    }

    private func reportCard(_ report: StructureEvalReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusChip(
                    report.isStub
                        ? "STUB · rules, not a model"
                        : "\(report.engineName) · model \(report.modelSHA256?.prefix(8) ?? "?")",
                    icon: .system(report.isStub ? "wrench.adjustable" : "cpu"),
                    ink: report.isStub ? Tokens.Color.partialAudioInk : Tokens.Color.privacyBadgeInk,
                    fill: report.isStub ? Tokens.Color.partialAudioFill : Tokens.Color.privacyBadgeFill)
                Spacer()
                Text(report.normalizer ? "normalizer on" : "normalizer off")
                    .chirpFont(11.5)
                    .foregroundStyle(Tokens.Color.secondary)
            }
            if !report.isStub, report.soap.argumentAccuracy < 0.9 {
                Text(
                    "Experimental: argument accuracy is below the 90% bar (ADR-012). Every field is a draft: a failed "
                        + "check waits in Needs review, and only fields you reviewed go to a SOAP note."
                )
                .chirpFont(12.5, .semibold)
                .foregroundStyle(AppColor.error)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("SOAP fields and medications · \(report.soap.sentences) sentences")
                .chirpFont(13, .semibold)
            metric("Tool shape", Self.percent(report.soap.toolShapeAccuracy))
            metric("Arguments", Self.percent(report.soap.argumentAccuracy))
            metric("Field exact match", Self.percent(report.soap.fieldExactMatch))
            metric("Numeric hard fails", "\(report.soap.numericHardFails)")
            metric("Sent to Needs review", "\(report.soap.needsReviewCount)")
            metric("Seconds per sentence", String(format: "%.2f", report.soap.meanSecondsPerSentence))
            Text("Dictation commands · \(report.commands.utterances) utterances")
                .chirpFont(13, .semibold)
                .padding(.top, 4)
            metric("Engine (gated)", Self.percent(report.commands.engineAccuracy))
            metric("Feature (phrase + engine)", Self.percent(report.commands.featureAccuracy))
            metric("Dictation eaten as a command", "\(report.commands.falseCommands)")
            HStack(spacing: 10) {
                Button {
                    if let url = try? environment.structureEval.exportFile(for: report.engineID) {
                        shareURL = ShareURL(url: url)
                    }
                } label: {
                    CapsuleButtonLabel(title: "Export JSON", kind: .tinted)
                }
                .buttonStyle(.plain)
                Button {
                    UIPasteboard.general.string = report.markdown
                    copiedEngine = report.engineID
                } label: {
                    CapsuleButtonLabel(
                        title: copiedEngine == report.engineID ? "Copied" : "Copy for LLM", kind: .tinted)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(CardBackground(radius: 16))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .chirpFont(13.5)
                .foregroundStyle(Tokens.Color.ink)
            Spacer()
            Text(value)
                .chirpFont(13.5, .semibold)
                .monospacedDigit()
                .foregroundStyle(Tokens.Color.ink)
        }
        .accessibilityElement(children: .combine)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}
