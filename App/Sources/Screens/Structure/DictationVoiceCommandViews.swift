import ChirpCore
import ChirpFeatures
import ChirpUI
import SwiftUI

/// The chip a heard voice command shows on the Dictating screen (M6). Display only: the live text is never edited;
/// the command is applied on the final pass. Says STUB when the rule-based stand-in answered.
struct VoiceCommandChipView: View {
    let chip: VoiceCommandChip

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityHidden(true)
            Text(chip.title)
                .chirpFont(15, .semibold)
            Text("\(Int((chip.confidence * 100).rounded()))%")
                .chirpFont(13)
                .monospacedDigit()
                .opacity(0.8)
            // STUB, or Needle's experimental label (review L3 I10).
            Text(chip.isStub ? "STUB" : "Experimental")
                .chirpFont(11, .bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Tokens.Color.partialAudioFill))
                .foregroundStyle(Tokens.Color.partialAudioInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(Tokens.Color.dictationAccent)
        .background(Capsule().strokeBorder(Tokens.Color.dictationAccent.opacity(0.7), lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Voice command heard: \(chip.title)\(chip.isStub ? ", rule-based stub" : ", experimental"). "
                + "Applied when you stop.")
    }
}

/// The Dictating screen's voice-command strip: the live chip while recording; after the copy, what was applied, and a
/// sentence when "read back" had no voice to use.
struct DictationVoiceCommandBar: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let commands = environment.dictationVoiceCommands
        let state = environment.dictation.state
        VStack(alignment: .leading, spacing: 8) {
            if state.isCapturing || state == .stopping || state == .pendingStop, let chip = commands.chip {
                VoiceCommandChipView(chip: chip)
            }
            // Round 3: a "scratch that" whose sentence boundary was not certain was not applied; the copied text still
            // holds the words, so say it where the person looks before pasting.
            if state == .done, let warning = commands.unresolvedSummary {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .chirpFont(14, .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Tokens.Color.dictationAccent.opacity(0.35)))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Voice command not applied. \(warning)")
            }
            if state == .done, let summary = commands.appliedSummary {
                Text(summary)
                    .chirpFont(13)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state == .done, commands.readBackUnavailable {
                Text("“Read back” needs a voice. Set one up in Settings → Voices.")
                    .chirpFont(13)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// "Send to SOAP" / "Send to Transform" said during a dictation: opens after the copy.
    func dictationVoiceCommandSheets(environment: AppEnvironment) -> some View {
        modifier(DictationVoiceCommandSheets(environment: environment))
    }
}

private struct DictationVoiceCommandSheets: ViewModifier {
    let environment: AppEnvironment

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: {
                    environment.dictation.state == .done ? environment.dictationVoiceCommands.pendingTransform : nil
                },
                set: { if $0 == nil { environment.dictationVoiceCommands.consumePendingTransform() } })
        ) { pending in
            let item = environment.library.items.first { $0.id == pending.transcriptionID }
            switch pending.target {
            case .soap:
                // The SOAP template on the on-device model: a dictated clinical note never leaves the phone.
                SOAPFromFieldsSheet(
                    transcriptionID: pending.transcriptionID, transcriptTitle: item?.displayTitle ?? "Dictation",
                    notes: "")
            case .picker:
                TransformSheet(
                    transcriptionID: pending.transcriptionID, transcriptTitle: item?.displayTitle ?? "Dictation",
                    privacyClass: item?.privacyClass ?? .personal, environment: environment)
            }
        }
    }
}

/// Settings → Structure models → Try voice commands: type what the live preview would show, and what the final pass
/// would say, and see the chip and the copied text the same resolver produces. A QA tool; nothing is recorded.
struct VoiceCommandTesterScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State var liveText = "Patient seen today. New paragraph"
    @State var finalPass = "Patient seen today. New paragraph. Plan as discussed. Scratch that. Recheck in two weeks."
    @State private var chip: VoiceCommandChip?
    @State private var checkedLive = false
    @State private var result: VoiceCommandResult?
    @State private var engineName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(
                    "Commands count only as their own short sentence. The chip is display only; the copied text is the "
                        + "final pass with commands applied."
                )
                .chirpFont(13)
                .foregroundStyle(Tokens.Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                StatusChip(
                    engineName, icon: .system(engineName.hasPrefix("STUB") ? "wrench.adjustable" : "cpu"),
                    ink: engineName.hasPrefix("STUB") ? Tokens.Color.partialAudioInk : Tokens.Color.privacyBadgeInk,
                    fill: engineName.hasPrefix("STUB") ? Tokens.Color.partialAudioFill : Tokens.Color.privacyBadgeFill)

                SectionLabel("Live preview")
                TextField("What the live preview shows", text: $liveText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tokens.Color.night)
                    if let chip {
                        VoiceCommandChipView(chip: chip).padding(12)
                    } else {
                        Text(checkedLive ? "No command at the act threshold" : "…")
                            .chirpFont(14)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(12)
                    }
                }
                .frame(minHeight: 60)

                SectionLabel("Final pass")
                TextField("What the final pass says", text: $finalPass, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                if let result {
                    Text("Copied text")
                        .chirpFont(13, .semibold)
                        .foregroundStyle(Tokens.Color.secondary)
                    Text(result.text)
                        .chirpFont(15)
                        .foregroundStyle(Tokens.Color.ink)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(CardBackground(radius: 14))
                    Text(summary(result))
                        .chirpFont(12.5)
                        .foregroundStyle(Tokens.Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await run() }
                } label: {
                    CapsuleButtonLabel(title: "Check", kind: .filled)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(Tokens.Color.ground)
        .navigationTitle("Try voice commands")
        .navigationBarTitleDisplayMode(.inline)
        .task { await run() }
    }

    private func summary(_ result: VoiceCommandResult) -> String {
        var parts: [String] = []
        if !result.applied.isEmpty {
            parts.append(
                "Applied: "
                    + result.applied.map { DictationVoiceCommands.title(for: $0.command) }.joined(separator: ", "))
        }
        if !result.ignored.isEmpty {
            parts.append(
                "Below the act threshold, kept as dictated: " + result.ignored.map(\.utterance).joined(separator: " "))
        }
        if !result.unresolved.isEmpty {
            parts.append("Not applied: \(VoiceCommandResult.unresolvedMessage)")
        }
        if !result.actions.isEmpty {
            parts.append("After copy: " + result.actions.map(\.rawValue).joined(separator: ", "))
        }
        return parts.isEmpty ? "No commands." : parts.joined(separator: " · ")
    }

    private func run() async {
        let settings = environment.structureSettings.settingsValue
        let (engine, fallback) = await environment.structureEngines.resolve(settings.engine)
        engineName =
            engine.descriptor.id == StubStructureModel.engineID
            ? "STUB · rules, not Needle" + (fallback.map { " · \($0)" } ?? "")
            : "\(engine.descriptor.displayName) · \(NeedleExperimental.commandChip)"
        let resolver = VoiceCommandResolver(engine: engine, gate: settings.gate)
        if let match = await resolver.liveCommand(in: liveText) {
            chip = VoiceCommandChip(
                command: match.command, title: DictationVoiceCommands.title(for: match.command),
                confidence: match.confidence, isStub: match.engineID == StubStructureModel.engineID)
        } else {
            chip = nil
        }
        checkedLive = true
        result = await resolver.resolve(finalPass)
    }
}
