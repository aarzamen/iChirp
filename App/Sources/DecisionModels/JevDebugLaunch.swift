import Foundation

/// DEBUG-only: `-ChirpJevBaseURL <url>` points Jev at the synthetic QA stub (`scripts/jev_stub_server.py`), for the
/// simulator and the UI tour. Release builds ignore it, so a shipped app only ever talks to `api.typesafe.ai`. The
/// address is never stored; the engine still refuses plain http to anything but the local network.
enum JevDebugLaunch {
    static let baseURLArgument = "-ChirpJevBaseURL"

    static func baseURLOverride(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        #if DEBUG
        guard let index = arguments.firstIndex(of: baseURLArgument), arguments.indices.contains(index + 1),
            let url = URL(string: arguments[index + 1]), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host(percentEncoded: false)?.isEmpty == false
        else { return nil }
        return url
        #else
        return nil
        #endif
    }
}
