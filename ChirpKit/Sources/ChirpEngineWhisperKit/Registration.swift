import ChirpCore
import Foundation

/// Builds the WhisperKit engines the app registers at launch: one per variant, all under one models folder.
public enum WhisperKitEngines {
    /// - Parameter modelsDirectory: where downloads go (the app passes `<Application Support>/Models/WhisperKit`,
    ///   outside the backed-up library folder; it is marked excluded from backup after a download).
    public static func makeDefault(modelsDirectory: URL) -> [WhisperKitEngine] {
        WhisperKitVariant.allCases.map { WhisperKitEngine(variant: $0, modelsDirectory: modelsDirectory) }
    }
}
