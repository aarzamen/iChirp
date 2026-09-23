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
                Picker("Engine", selection: $structure.settingsValue.engine) {
                    Text("Needle").tag(StructureEngineChoice.needle)
                    Text("STUB").tag(StructureEngineChoice.stub)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .labelsHidden()
            }
            SettingsRow(
                title: "Voice commands (experimental)",
                caption: "“New paragraph”, “scratch that”, “send to SOAP”… said as their own sentence. Off by default. "
                    + NeedleExperimental.commandChip + "."
            ) {
                Toggle("Voice commands", isOn: $structure.settingsValue.voiceCommandsEnabled)
                    .labelsHidden()
                    .tint(Tokens.Color.success)
            }
            NavigationLink {
                VoiceCommandTesterScreen()
            } label: {
                SettingsRow(title: "Try voice commands") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Color.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                StructureEvalScreen()
            } label: {
                SettingsRow(title: "Eval", caption: "STUB vs Needle on invented cases; export the report") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Color.mutedText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NavigationLink {
                StructureGateScreen()
            } label: {
                SettingsRow(title: "Confidence gate") {
                    Text(
                        "\(Int((structure.settingsValue.actThreshold * 100).rounded())) / "
                            + "\(Int((structure.settingsValue.provisionalThreshold * 100).rounded()))"
                    )
                    .chirpFont(15)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Color.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.Color.mutedText)
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
struct StructureGateScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var structure = environment.structureSettings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup(
                    title: "Confidence gate",
                    footer:
                        "At or above Act, a field is shown solid; at or above Provisional, dashed; below, it waits in "
                        + "Needs review. A failed check (a number that does not trace to the transcript, out of range, a "
                        + "spoken correction) always needs review. Every field stays a draft until you review it. "
                        + "Act never goes below 70 and Provisional never below 50."
                ) {
                    SettingsRow(title: "Act", caption: "Default 85") {
                        Slider(
                            value: $structure.settingsValue.actThreshold, in: StructureSettings.actFloor...0.99,
                            step: 0.01
                        )
                        .frame(width: 150)
                        Text("\(Int((structure.settingsValue.actThreshold * 100).rounded()))")
                            .chirpFont(15)
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                    SettingsRow(title: "Provisional", caption: "Default 60") {
                        Slider(
                            value: $structure.settingsValue.provisionalThreshold,
                            in: StructureSettings.provisionalFloor...0.95, step: 0.01
                        )
                        .frame(width: 150)
                        Text("\(Int((structure.settingsValue.provisionalThreshold * 100).rounded()))")
                            .chirpFont(15)
                            .monospacedDigit()
                            .frame(width: 30)
                    }
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
}
