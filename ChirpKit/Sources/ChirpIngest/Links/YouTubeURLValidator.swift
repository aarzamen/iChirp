// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Utilities/YouTubeURLValidator.swift @ bbae9e0e
// Changes: also accepts `music.youtube.com` and `youtube-nocookie.com` hosts and `/live/<id>` paths; otherwise unchanged.

import Foundation

/// Recognizes YouTube video links and extracts the 11-character video id. Pure string work: no network.
public enum YouTubeURLValidator {
    private static let youtubeHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    ]
    private static let shortHost = "youtu.be"
    private static let allowedVideoIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Whether `string` is a YouTube video link.
    public static func isYouTubeURL(_ string: String) -> Bool {
        extractVideoID(string) != nil
    }

    /// The video id of a YouTube video link, or nil when `string` is not one.
    public static func extractVideoID(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        let normalizedInput = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalizedInput),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        if host == shortHost || host == "www.\(shortHost)" {
            let pathComponents = components.path.split(separator: "/")
            guard let id = pathComponents.first.map(String.init), isValidVideoID(id) else {
                return nil
            }
            return id
        }

        guard youtubeHosts.contains(host) else { return nil }

        if components.path.lowercased() == "/watch" {
            let videoID = components.queryItems?
                .first(where: { $0.name == "v" })?
                .value
            guard let videoID, isValidVideoID(videoID) else { return nil }
            return videoID
        }

        let pathComponents = components.path.split(separator: "/")
        guard pathComponents.count >= 2 else { return nil }

        let firstSegment = pathComponents[0].lowercased()
        guard ["shorts", "embed", "v", "live"].contains(firstSegment) else {
            return nil
        }

        let videoID = String(pathComponents[1])
        guard isValidVideoID(videoID) else { return nil }
        return videoID
    }

    private static func isValidVideoID(_ id: String) -> Bool {
        guard id.count == 11 else { return false }
        return id.unicodeScalars.allSatisfy(allowedVideoIDCharacters.contains)
    }
}
