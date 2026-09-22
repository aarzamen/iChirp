import ChirpFeatures
import Foundation

/// Runs the M2 App Intents (`App/Shared/DictationIntents.swift`) against the app's one dictation coordinator. The
/// intents run in the app's process; when the Action Button or a Control launches Parakeet, the environment is built
/// here the same way the scene builds it (`AppEnvironment.shared`).
@MainActor enum DictationIntentRouter {
    /// Starts dictating; returns once recording runs (the Live Activity exists) or the start failed.
    static func start() async {
        guard let dictation = await readyDictation() else { return }
        if dictation.state.isFinished {
            dictation.dismiss()
            dictation.start()
        }
        await dictation.waitForState { $0.isCapturing || $0.isFinished }
    }

    /// Stops and copies; returns once the dictation has ended, so iOS keeps the app running for the final pass.
    static func stop() async {
        guard let dictation = await readyDictation() else { return }
        guard dictation.state.isCapturing || dictation.state == .starting || dictation.state == .pendingStop else {
            return
        }
        dictation.stop()
        await dictation.waitForState(\.isFinished)
    }

    static func toggle() async {
        guard let dictation = await readyDictation() else { return }
        if dictation.state.isCapturing || dictation.state == .starting {
            await stop()
        } else {
            await start()
        }
    }

    private static func readyDictation() async -> DictationCoordinator? {
        guard case .ready(let environment) = AppEnvironment.shared else { return nil }
        await environment.launch()
        return environment.dictation
    }
}
