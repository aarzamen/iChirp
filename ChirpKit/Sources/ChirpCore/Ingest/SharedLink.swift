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

    /// The hand-off URL for `link`, or nil when `link` is not an http or https link. `token` is the share's one-time
    /// token (the extension also puts it on Parakeet's private pasteboard); nil leaves it out.
    public static func handOffURL(for link: URL, token: String? = nil) -> URL? {
        guard isWebLink(link) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [URLQueryItem(name: "url", value: link.absoluteString)]
        if let token { items.append(URLQueryItem(name: "t", value: token)) }
        items.append(URLQueryItem(name: "v", value: version))
        components.queryItems = items
        return components.url
    }

    /// The shared link and its token inside a hand-off URL, or nil unless the scheme, host and version match and the
    /// link is an http or https link.
    public static func handOff(from url: URL) -> (link: URL, token: String?)? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            items.first(where: { $0.name == "v" })?.value == version,
            let value = items.first(where: { $0.name == "url" })?.value,
            let link = URL(string: value), isWebLink(link)
        else { return nil }
        return (link, items.first(where: { $0.name == "t" })?.value)
    }

    /// The shared link inside a hand-off URL (see `handOff(from:)`).
    public static func link(fromHandOff url: URL) -> URL? {
        handOff(from: url)?.link
    }

    // MARK: - The one-time share token

    /// How long a share's token stays valid: the app opens within a second or two of the tap.
    public static let tokenLifetime: TimeInterval = 60

    /// A fresh random token for one share.
    public static func newToken() -> String {
        UUID().uuidString
    }

    /// What the extension writes to Parakeet's private pasteboard: `<token>|<seconds since 1970>`.
    public static func tokenRecord(token: String, at date: Date) -> String {
        "\(token)|\(Int(date.timeIntervalSince1970))"
    }

    /// Whether `token` (from the hand-off URL) is the one in `record` (from the pasteboard) and the record is at most
    /// `tokenLifetime` old. An empty token never matches.
    public static func tokenMatches(record: String?, token: String?, now: Date) -> Bool {
        guard let record, let token, !token.isEmpty else { return false }
        let parts = record.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == token, let seconds = TimeInterval(parts[1]) else { return false }
        let age = now.timeIntervalSince1970 - seconds
        return age >= -5 && age <= tokenLifetime
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
