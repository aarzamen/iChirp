import ChirpFeatures
import SwiftUI

/// DEBUG-only launch arguments for checking the M6 structure-model screens in the Simulator without tapping
/// (screenshots, QA). Release builds ignore every one of them.
///
/// - `-ChirpStructureEngine stub|needle`: sets Settings → Structure models → Engine before anything runs.
/// - `-ChirpExtractFields`: once launch housekeeping is done, opens Extract fields on the newest Library item and
///   runs it (pair with `-ChirpImportDocument <path>` to import a synthetic note first).
/// - `-ChirpVoiceCommands`: opens Settings → Structure models → Try voice commands (the chip and the copied text).
/// - `-ChirpStructureEval <engines>`: opens the Eval view and runs the listed engines ("stub", "needle", "stub,needle").
enum StructurePreviewLaunch {
    static let engineArgument = "-ChirpStructureEngine"
    static let extractFieldsArgument = "-ChirpExtractFields"
    static let voiceCommandsArgument = "-ChirpVoiceCommands"
    static let evalArgument = "-ChirpStructureEval"

    enum Screen: Identifiable {
        case extract(id: UUID, title: String)
        case voiceCommands
        case eval([String])

        var id: String {
            switch self {
            case .eval: "eval"
            case .extract(let id, _): "extract-\(id)"
            case .voiceCommands: "voice-commands"
            }
        }
    }
}

extension View {
    /// Applies the DEBUG launch arguments above. A no-op in Release builds.
    func structurePreviewLaunch(environment: AppEnvironment) -> some View {
        #if DEBUG
        modifier(StructurePreviewLaunchModifier(environment: environment))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct StructurePreviewLaunchModifier: ViewModifier {
    let environment: AppEnvironment
    @State private var screen: StructurePreviewLaunch.Screen?

    func body(content: Content) -> some View {
        content
            .sheet(item: $screen) { screen in
                switch screen {
                case .extract(let id, let title):
                    ExtractFieldsSheet(
                        transcriptionID: id, transcriptTitle: title, environment: environment, autoStart: true,
                        onSeek: { _ in })
                case .voiceCommands:
                    NavigationStack { VoiceCommandTesterScreen() }
                case .eval(let engines):
                    NavigationStack { StructureEvalScreen(autoRun: engines) }
                }
            }
            .task { await apply() }
    }

    private func apply() async {
        let arguments = ProcessInfo.processInfo.arguments
        if let engine = IngestPreviewLaunch.value(after: StructurePreviewLaunch.engineArgument),
            let choice = StructureEngineChoice(rawValue: engine)
        {
            environment.structureSettings.settingsValue.engine = choice
        }
        if let engines = IngestPreviewLaunch.value(after: StructurePreviewLaunch.evalArgument) {
            await environment.launch()
            screen = .eval(engines.split(separator: ",").map(String.init))
            return
        }
        if arguments.contains(StructurePreviewLaunch.voiceCommandsArgument) {
            await environment.launch()
            screen = .voiceCommands
            return
        }
        guard arguments.contains(StructurePreviewLaunch.extractFieldsArgument) else { return }
        await environment.launch()
        // Wait (at most fifteen seconds) for an imported item to finish reading.
        for _ in 0..<60 where environment.library.items.first?.status != .completed {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await environment.structureSettings.refresh()
        if let newest = environment.library.items.first {
            screen = .extract(id: newest.id, title: newest.displayTitle)
        }
    }
}
#endif
