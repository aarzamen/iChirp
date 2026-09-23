import ChirpCore
import ChirpFeatures
import Foundation

/// The Mac companion configuration plan 020's voices read: the owner's Settings → Mac companion store
/// (`CompanionSettingsStore`, plan 019). **DEBUG builds only**, for simulator QA against
/// `scripts/voice_stub_server.py` (synthetic token, synthetic tones), these launch arguments replace it for this run:
///
/// - `-ChirpQACompanionHost <host>` (e.g. `127.0.0.1`), `-ChirpQACompanionPort <port>`,
///   `-ChirpQACompanionToken <token>`, `-ChirpQACompanionTrusted YES`.
///
/// Nothing is written: the saved companion and its Keychain token are untouched, and Settings → Mac companion keeps
/// showing them. Release builds ignore the arguments. `UITests/VoiceScreenTourUITests` uses them.
enum CompanionDebugLaunch {
    static let hostArgument = "-ChirpQACompanionHost"

    static func configuration(
        store: CompanionSettingsStore,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> any CompanionConfiguration {
        #if DEBUG
        if let host = value(after: hostArgument, in: arguments) {
            let port =
                value(after: "-ChirpQACompanionPort", in: arguments).flatMap(Int.init) ?? CompanionEndpoint.defaultPort
            let trusted = value(after: "-ChirpQACompanionTrusted", in: arguments) == "YES"
            let token = value(after: "-ChirpQACompanionToken", in: arguments).map(SecretValue.init)
            return FixedCompanionConfiguration(
                endpoint: CompanionEndpoint(host: host, port: port, isTrustedForClinicalText: trusted), token: token)
        }
        #endif
        return store
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
