import ChirpCore
import Foundation

/// The speech engine a job resolved has no model on this iPhone (review I2 of the M7 merge). The sentence names that
/// engine and says what to do, so a route that points at a deleted or never-restored model is never a dead end:
///
/// - Parakeet (the default) keeps the M1 sentence, "Download the Parakeet speech model in Settings → Speech model".
/// - Any other engine a route chose: "Whisper Base isn’t downloaded on this iPhone. Download it in Settings → Speech
///   engines, or switch Transcripts to Parakeet". It never says "download Parakeet" while Parakeet may be right there.
///
/// Consumers build it from the engine they resolved for the job (`init(engine:configured:route:)`) and map an
/// engine's own `SpeechEngineError.modelNotDownloaded` onto it with `mapping(_:engine:configured:route:)`. The message
/// has no final period, so callers can extend it (a meeting adds ", then tap Retry.").
public struct SpeechModelMissingError: Error, Equatable, LocalizedError {
    public let engineID: String
    public let engineName: String
    public let route: SpeechRoute
    /// A route chose this engine (the consumer was given a router): the message offers switching back to Parakeet.
    public let isRouteChoice: Bool

    public init(engineID: String, engineName: String, route: SpeechRoute, isRouteChoice: Bool) {
        self.engineID = engineID
        self.engineName = engineName
        self.route = route
        self.isRouteChoice = isRouteChoice
    }

    /// - Parameters:
    ///   - engine: the descriptor of the engine the job resolved.
    ///   - configured: what the consumer was given: a router (routes exist) or one engine (no choice to offer).
    public init(engine: EngineDescriptor, configured: any SpeechEngine, route: SpeechRoute = .final) {
        self.init(
            engineID: engine.id, engineName: engine.displayName, route: route,
            isRouteChoice: configured is any SpeechEngineRouting)
    }

    /// Parakeet is the default and the fallback: its sentence says to download it.
    public var isDefaultEngine: Bool {
        engineID == SpeechEngineCapabilityRegistry.parakeetEngineID
    }

    /// Settings wording for the route ("Transcripts", "Live text").
    public var routeName: String {
        route == .final ? "Transcripts" : "Live text"
    }

    /// What the person reads, without a final period.
    public var message: String {
        guard isRouteChoice, !isDefaultEngine else { return FileTranscriptionPipeline.modelMissingMessage }
        return "\(engineName) isn’t downloaded on this iPhone. Download it in Settings → Speech engines, or switch "
            + "\(routeName) to Parakeet"
    }

    public var errorDescription: String? { message }

    /// `error` as a `SpeechModelMissingError` for `engine` when it is the engine's `modelNotDownloaded`; any other
    /// error unchanged.
    public static func mapping(
        _ error: any Error, engine: EngineDescriptor, configured: any SpeechEngine, route: SpeechRoute = .final
    ) -> any Error {
        guard case .modelNotDownloaded = error as? SpeechEngineError else { return error }
        return SpeechModelMissingError(engine: engine, configured: configured, route: route)
    }
}
