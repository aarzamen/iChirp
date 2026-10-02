import ChirpCore
import Foundation

/// Plain-http links to internet hosts, upgraded to https before any request.
///
/// iOS's App Transport Security refuses plain http to internet hosts, and Parakeet allows it only on the home network
/// (`NSAllowsLocalNetworking`; the ATS settings are not loosened). Older podcast feeds and pasted links still use
/// `http://`, so instead of failing every time, each link request (`IngestHTTPClient`, `MediaDownloader`, and every
/// redirect they follow) asks for the same address over https. Home-network hosts (`LocalNetworkHost`) and
/// single-label names (`http://nas/…`), which iOS allows over http, are left alone. When the https attempt fails, the
/// error says so in plain words (`IngestNetworkError.httpsUnavailable`).
enum SecureLink {
    /// `url` over https when it is plain http to an internet host (an explicit port 80 is dropped); nil when it needs
    /// no change.
    static func upgraded(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http",
            let host = url.host(percentEncoded: false)?.lowercased(), host.contains("."),
            !LocalNetworkHost.isLocal(host),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url
    }

    /// `request` with its URL upgraded (`upgraded(_:)`), and whether it changed. Headers and method are kept.
    static func upgrade(_ request: URLRequest) -> (request: URLRequest, upgraded: Bool) {
        guard let url = request.url, let secure = upgraded(url) else { return (request, false) }
        var request = request
        request.url = secure
        return (request, true)
    }
}
