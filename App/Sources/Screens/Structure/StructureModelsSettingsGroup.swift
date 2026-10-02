import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// Settings → Structure models (M6, plan 015): Needle 3's model file, the engine (Needle or the labelled STUB), dictation
/// voice commands, the confidence gate and the Eval view.
struct StructureModelsSettingsGroup: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var structure = environment.structureSettings
        SettingsGroup(
            title: "Structure models",
            footer:
                "Needle 3 turns dictated text into typed fields on this iPhone. \(NeedleExperimental.sentence) "
                + "Numbers are re-checked in code, only fields you reviewed go to a SOAP note, and the STUB is a "
                + "rule-based stand-in, never a model."
        ) {
            if structure.needleInBuild {
                ModelAssetRow(
                    title: "Needle 3",
                    value: "Cactus Compute",
                    status: structure.needleStatus,
                    approximateDownloadBytes: structure.needleDownloadBytes,
                    runsOn: "CPU",
                    onDownload: { environment.downloadNeedleModel() },
                    onDelete: { Task { await structure.deleteNeedle() } }
                )
            } else {
                SettingsRow(title: "Needle 3", caption: structure.notInBuildMessage, captionColor: AppColor.error) {
                    EmptyView()
                }
            }
            SettingsRow(title: "Engine", caption: structure.engineCaption) {
                // F86: "Needle" stays disabled (not selectable) while it isn't actually running — the caption
                // beside it already says why ("Download Needle 3 below; the STUB runs until then."), so a tap here
                // can't silently pick an engine nothing runs. "Rules (basic)", not the internal name "STUB".
                ChirpSegmentedControl(
                    "Engine", selection: $structure.settingsValue.engine,
                    segments: [
                        .init("Needle", value: StructureEngineChoice.needle, isEnabled: structure.isNeedleReady),
                        .init("Rules (basic)", value: StructureEngineChoice.stub),
                    ])
            }
            SettingsRow(
                title: "Voice commands (experimental)",
                caption: "“New paragraph”, “scratch that”, “send to SOAP”… said as their own sentence. Off by default. "
                    + NeedleExperimental.commandChip + "."
            ) {
                Toggle("Voice commands", isOn: $structure.settingsValue.voiceCommandsEnabled)
                    .toggleStyle(.chirpSwitch)
            }
            NavigationLink {
                VoiceCommandTesterScreen()
            } label: {
                SettingsRow(title: "Try voice commands", showsChevron: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                StructureEvalScreen()
            } label: {
                SettingsRow(
                    title: "Eval", caption: "STUB vs Needle on invented cases; export the report", showsChevron: true
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                StructureGateScreen()
            } label: {
                SettingsRow(title: "Confidence gate", showsChevron: true) {
                    // The gate as it applies (floors and provisional ≤ act; R6b-14), not the raw stored numbers.
                    Text(StructureGateScreen.summary(structure.settingsValue))
                        .chirpFont(15)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .task { await structure.refresh() }
        .alert(
            "Structure model",
            isPresented: Binding(get: { structure.lastError != nil }, set: { if !$0 { structure.dismissError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(structure.lastError ?? "")
        }
    }
}

/// The gate's two thresholds (Needle Bench knobs): act (solid) and provisional (dashed); below → needs review.
///
/// R6b-14 (plan 024 Task 10): Provisional can never be set above Act (moving Act below it pulls it down too), so the
/// screen and the Settings row show the gate that really applies; the sliders have VoiceOver names and values; the
/// numbers grow with the text instead of truncating in a fixed 30 pt column.
struct StructureGateScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var numberWidth: CGFloat = 32

    /// Act set to `value`; Provisional follows it down when it would be above.
    static func settingAct(_ value: Double, in settings: StructureSettings) -> StructureSettings {
        var changed = settings
        changed.actThreshold = value
        changed.provisionalThreshold = min(changed.provisionalThreshold, value)
        return changed
    }

    /// Provisional set to `value`, never above Act.
    static func settingProvisional(_ value: Double, in settings: StructureSettings) -> StructureSettings {
        var changed = settings
        changed.provisionalThreshold = min(value, settings.actThreshold)
        return changed
    }

    /// "85 / 60": the thresholds the gate uses (`StructureSettings.gate`).
    static func summary(_ settings: StructureSettings) -> String {
        let gate = settings.gate
        return "\(percent(gate.act)) / \(percent(gate.provisional))"
    }

    static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

    var body: some View {
        @Bindable var structure = environment.structureSettings
        let act = Binding(
            get: { structure.settingsValue.actThreshold },
            set: { structure.settingsValue = Self.settingAct($0, in: structure.settingsValue) })
        let provisional = Binding(
            get: { structure.settingsValue.provisionalThreshold },
            set: { structure.settingsValue = Self.settingProvisional($0, in: structure.settingsValue) })
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup(
                    title: "Confidence gate",
                    footer:
                        "At or above Act, a field is shown solid; at or above Provisional, dashed; below, it waits in "
                        + "Needs review. A failed check (a number that does not trace to the transcript, out of range, a "
                        + "spoken correction) always needs review. Every field stays a draft until you review it. "
                        + "Act never goes below 70, Provisional never below 50, and Provisional never above Act."
                ) {
                    thresholdRow(
                        "Act", caption: "Default 85", value: act, range: StructureSettings.actFloor...0.99)
                    thresholdRow(
                        "Provisional", caption: "Default 60", value: provisional,
                        range: StructureSettings.provisionalFloor...0.95)
                    Button("Reset to 85 / 60") { structure.resetThresholds() }
                        .chirpFont(15)
                        .foregroundStyle(AppColor.accentText)
                        .padding(14)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .background(Tokens.Color.ground)
        .navigationTitle("Confidence gate")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func thresholdRow(
        _ title: String, caption: String, value: Binding<Double>, range: ClosedRange<Double>
    ) -> some View {
        SettingsRow(title: title, caption: caption) {
            Slider(value: value, in: range, step: 0.01) { Text(title) }
                .tint(Tokens.Color.accent)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 150)
                .frame(minWidth: 150)
                .accessibilityValue("\(Self.percent(value.wrappedValue)) percent")
            Text("\(Self.percent(value.wrappedValue))")
                .chirpFont(15)
                .monospacedDigit()
                .frame(minWidth: numberWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}
