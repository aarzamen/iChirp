import ChirpCore
import Foundation

/// Where Parakeet's configured routes send text and audio right now, in words: the Capture header's chip and its
/// "Where things run" sheet (UX audit F13), and any other screen that would claim "on device" (F74). An "On device"
/// claim is made only when it is true for the current settings.
///
/// Speech engines always run on this iPhone (spec/12). The rest follow Settings: the default model for Ask,
/// Transforms and Create, the voice for Listen and voice messages, and Jev. Providers set up but not chosen as the
/// default are listed, since a run can pick them (each run's own chip then says where it goes). Nothing here sends or
/// reads content.
public struct ContentReach: Sendable, Equatable {
    /// The farthest any default route reaches.
    public enum Level: Sendable, Equatable {
        /// Everything on this iPhone.
        case onDevice
        /// A computer on the home network too; nothing over the internet.
        case homeNetwork
        /// At least one route goes over the internet.
        case cloud
    }

    /// One feature and where it runs.
    public struct Route: Sendable, Equatable, Identifiable {
        public var id: String { feature }
        /// "Speech to text", "Ask, Transforms and Create", "Read aloud and voice messages", "Jev".
        public let feature: String
        /// "Parakeet on this iPhone", "Claude, over the internet", "Not set up", "Off".
        public let place: String
        /// Where it runs, or nil when it is off or not set up.
        public let locality: EngineLocality?
        /// What happens to clinical text on this route, or another short fact; nil when there is nothing to add.
        public let note: String?
    }

    public let routes: [Route]
    public let level: Level
    /// Cloud providers set up in Settings → Models that are not the default ("Claude"), used only when a run picks one.
    public let otherCloudModels: [String]

    /// The header chip: "On device", "Home network", "Cloud on".
    public var chipTitle: String {
        switch level {
        case .onDevice: "On device"
        case .homeNetwork: "Home network"
        case .cloud: "Cloud on"
        }
    }

    /// The sheet's first sentence.
    public var summary: String {
        switch level {
        case .onDevice:
            "With your settings, everything runs on this iPhone."
        case .homeNetwork:
            "With your settings, some steps use a computer on your home network. Nothing goes over the internet."
        case .cloud:
            "With your settings, some steps send text over the internet. Clinical text always asks you first."
        }
    }

    /// The chip's VoiceOver label.
    public var accessibilityLabel: String {
        switch level {
        case .onDevice: "Everything runs on this iPhone"
        case .homeNetwork: "Some steps use your home network"
        case .cloud: "Some steps use the cloud"
        }
    }

    public init(routes: [Route], otherCloudModels: [String] = []) {
        self.routes = routes
        self.otherCloudModels = otherCloudModels
        let localities = routes.compactMap(\.locality)
        if localities.contains(.cloud) {
            level = .cloud
        } else if localities.contains(.localNetwork) {
            level = .homeNetwork
        } else {
            level = .onDevice
        }
    }

    /// The routes as Settings has them now.
    /// - Parameters:
    ///   - speechEngineName: the Transcripts route's engine ("Parakeet"); every speech engine runs on this iPhone.
    ///   - defaultModel: what Ask, Transforms and Create start with.
    ///   - otherProviders: every provider in Settings → Models (the default among them is skipped).
    ///   - voice: Settings → Voices' choice, nil when none is chosen.
    ///   - companionTrusted: Settings → Mac companion's "trusted for clinical text".
    ///   - jevEnabled: Settings → Models → Jev.
    public static func current(
        speechEngineName: String,
        defaultModel: LanguageModelChoice,
        otherProviders: [LanguageModelChoice],
        voice: VoiceProviderKind?,
        companionTrusted: Bool,
        jevEnabled: Bool
    ) -> ContentReach {
        var routes = [
            Route(
                feature: "Speech to text", place: "\(speechEngineName) on this iPhone", locality: .onDevice,
                note: nil)
        ]
        routes.append(modelRoute(defaultModel))
        routes.append(voiceRoute(voice, companionTrusted: companionTrusted))
        routes.append(
            jevEnabled
                ? Route(
                    feature: "Jev", place: "TypeSafe AI, over the internet", locality: .cloud,
                    note: "Never sees clinical items.")
                : Route(feature: "Jev", place: "Off", locality: nil, note: nil))
        let others = otherProviders.filter { $0.locality == .cloud && $0.id != defaultModel.id }.map(\.name)
        return ContentReach(routes: routes, otherCloudModels: others)
    }

    private static func modelRoute(_ choice: LanguageModelChoice) -> Route {
        let feature = "Ask, Transforms and Create"
        switch choice.locality {
        case .onDevice:
            return Route(feature: feature, place: "\(choice.name) on this iPhone", locality: .onDevice, note: nil)
        case .localNetwork:
            return Route(
                feature: feature, place: "\(choice.name), on your home network", locality: .localNetwork,
                note: choice.isTrustedForClinical
                    ? "Trusted for clinical text." : "Asks before it sends clinical text.")
        case .cloud:
            return Route(
                feature: feature, place: "\(choice.name), over the internet", locality: .cloud,
                note: "Asks before it sends clinical text.")
        }
    }

    private static func voiceRoute(_ voice: VoiceProviderKind?, companionTrusted: Bool) -> Route {
        let feature = "Read aloud and voice messages"
        switch voice {
        case nil:
            return Route(feature: feature, place: "Not set up", locality: nil, note: nil)
        case .companion?:
            return Route(
                feature: feature, place: "Your Mac, over your home network", locality: .localNetwork,
                note: companionTrusted ? "Trusted for clinical text." : "Asks before it sends clinical text.")
        case .xai?:
            return Route(
                feature: feature, place: "Grok voices (xAI), over the internet", locality: .cloud,
                note: "Asks before it sends clinical text.")
        }
    }
}
