import ChirpCore
import Foundation

/// Builds the WhisperKit engines the app registers at launch: one per variant, all under one models folder.
public enum WhisperKitEngines {
    /// - Parameters:
    ///   - modelsDirectory: where downloads go (the app passes `<Application Support>/Models/WhisperKit`, outside the
    ///     backed-up library folder; it is marked excluded from backup after a download).
    ///   - availableMemory: what iOS lets the app use now, checked before every model load (fix/speech-memory-fit).
    public static func makeDefault(
        modelsDirectory: URL, availableMemory: any AvailableMemoryReading = ProcessAvailableMemory()
    ) -> [WhisperKitEngine] {
        WhisperKitVariant.allCases.map {
            WhisperKitEngine(variant: $0, modelsDirectory: modelsDirectory, availableMemory: availableMemory)
        }
    }
}
