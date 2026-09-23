import ChirpCore
import Foundation

/// The Mac companion's configuration until plan 019's Settings → Mac companion store is merged (lane L1), which
/// replaces this in `AppEnvironment`. Release builds: not set up. DEBUG builds only, for simulator QA against
/// `scripts/voice_stub_server.py` (synthetic token, synthetic audio):
///
/// - `-ChirpQACompanionHost <host>` (e.g. `127.0.0.1`), `-ChirpQACompanionPort <port>`,
///   `-ChirpQACompanionToken <token>`, `-ChirpQACompanionTrusted YES`.
enum StandInCompanionConfiguration {
    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> any CompanionConfiguration {
        #if DEBUG
        guard let host = value(after: "-ChirpQACompanionHost", in: arguments) else {
            return FixedCompanionConfiguration(endpoint: nil, token: nil)
        }
        let port =
            value(after: "-ChirpQACompanionPort", in: arguments).flatMap(Int.init) ?? CompanionEndpoint.defaultPort
        let trusted = value(after: "-ChirpQACompanionTrusted", in: arguments) == "YES"
        let token = value(after: "-ChirpQACompanionToken", in: arguments).map(SecretValue.init)
        return FixedCompanionConfiguration(
            endpoint: CompanionEndpoint(host: host, port: port, isTrustedForClinicalText: trusted), token: token)
        #else
        return FixedCompanionConfiguration(endpoint: nil, token: nil)
        #endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
