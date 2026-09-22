// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Utilities/PodcastURLValidator.swift @ bbae9e0e
// Changes: adds `episodeSlug(_:)` (the title slug in an episode link, used by the RSS fallback); otherwise unchanged.

import Foundation

/// Recognizes Apple Podcasts share links and extracts the show (collection) id, the episode id and the episode's
/// title slug needed to resolve a downloadable enclosure through the iTunes Lookup API. Pure string work: no network.
///
/// Apple Podcasts links take the shape `https://podcasts.apple.com/us/podcast/{slug}/id{collectionID}?i={episodeID}`.
/// The trailing `?i=` is present for a single episode and absent for a show (where the latest episode is resolved).
public enum PodcastURLValidator {
    private static let podcastHosts: Set<String> = [
        "podcasts.apple.com",
        "podcast.apple.com",
    ]

    /// Whether `string` is an Apple Podcasts link with a show id.
    public static func isApplePodcastsURL(_ string: String) -> Bool {
        extractCollectionID(string) != nil
    }

    /// The numeric show id from the `id{digits}` path segment, or nil for anything else.
    public static func extractCollectionID(_ string: String) -> String? {
        guard let components = normalizedComponents(string) else { return nil }
        // From the end: the `id<digits>` segment is always last, so a slug that happens to start with "id" + digits
        // cannot be mistaken for it.
        for rawSegment in components.path.split(separator: "/").reversed() {
            let segment = rawSegment.lowercased()
            guard segment.hasPrefix("id") else { continue }
            let digits = segment.dropFirst(2)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                return String(digits)
            }
        }
        return nil
    }

    /// The numeric episode id from the `i=` query item, or nil for a show link.
    public static func extractEpisodeID(_ string: String) -> String? {
        guard let components = normalizedComponents(string) else { return nil }
        let value = components.queryItems?.first(where: { $0.name == "i" })?.value
        guard let value, !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    /// The path segment just before `id{digits}`: the episode's title slug in an episode link (the show's in a show
    /// link), e.g. "a-synthetic-episode-title". Nil when there is none.
    public static func episodeSlug(_ string: String) -> String? {
        guard let components = normalizedComponents(string) else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        guard let idIndex = segments.lastIndex(where: { $0.lowercased().hasPrefix("id") }), idIndex > 0 else {
            return nil
        }
        let slug = segments[idIndex - 1]
        guard slug.lowercased() != "podcast", !slug.isEmpty else { return nil }
        return slug.removingPercentEncoding ?? slug
    }

    // MARK: - Private

    private static func normalizedComponents(_ string: String) -> URLComponents? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        let normalizedInput = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalizedInput),
            let host = components.host?.lowercased(),
            podcastHosts.contains(host)
        else {
            return nil
        }
        return components
    }
}
