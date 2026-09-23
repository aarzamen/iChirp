import ChirpCore
import Foundation

/// Builds the Apple Speech engine the app registers at launch.
public enum AppleSpeechEngines {
    /// `SpeechTranscriber` in this device's language (a job's language hint picks another supported one).
    public static func makeDefault(locale: Locale = .current) -> AppleSpeechEngine {
        AppleSpeechEngine(locale: locale)
    }
}
