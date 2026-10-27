import Foundation

/// Plan 028/029: the hand-off from Parakeet's share extension to the app, `ichirp://share-link?url=<link>&v=1`, and
/// finding the web link in what was shared (a URL item, or text such as "Watch this https://youtu.be/…").
///
/// Only `http` and `https` links pass, both ways: the hand-off never carries a `file:`, `mailto:` or `javascript:`
/// link. The URL is built with `URLComponents`, so `&`, `#` and `%` inside the shared link survive byte for byte.
public enum SharedLink {
    public static let scheme = "ichirp"
    public static let host = "share-link"
    public static let version = "1"

    /// The hand-off URL for `link`, or nil when `link` is not an http or https link.
    public static func handOffURL(for link: URL) -> URL? {
        guard isWebLink(link) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "url", value: link.absoluteString),
            URLQueryItem(name: "v", value: version),
        ]
        return components.url
    }

    /// The shared link inside a hand-off URL, or nil unless the scheme, host and version match and the link is an
    /// http or https link.
    public static func link(fromHandOff url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            items.first(where: { $0.name == "v" })?.value == version,
            let value = items.first(where: { $0.name == "url" })?.value,
            let link = URL(string: value), isWebLink(link)
        else { return nil }
        return link
    }

    /// The first http or https link in `text`; other schemes (a "mailto:" an address turns into) are skipped.
    public static func firstWebLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let link = match.url, isWebLink(link) { return link }
        }
        return nil
    }

    private static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
