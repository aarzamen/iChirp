import Foundation

/// On-disk layout of the app's user data:
///
/// ```
/// <root>/ichirp.sqlite
/// <root>/media/<transcription uuid>/source.m4a
/// ```
///
/// Rows store media paths relative to `root` so they survive container moves (restores, reinstalls).
public struct AppPaths: Sendable, Equatable {
    /// Application Support/iChirp
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Creates Application Support/iChirp if needed and keeps it in device backups: it holds user data.
    /// (Re-downloadable model files are excluded from backup where they are stored, not here.)
    public static func applicationSupport() throws -> AppPaths {
        let fileManager = FileManager.default
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var root = base.appendingPathComponent("iChirp", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try root.setResourceValues(values)
        return AppPaths(root: root)
    }

    /// root/ichirp.sqlite
    public var databaseURL: URL {
        root.appendingPathComponent("ichirp.sqlite", isDirectory: false)
    }

    /// root/media/<uuid>
    public func mediaDirectory(for id: UUID) -> URL {
        root.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Inverse of `relativePath(for:)`.
    public func absoluteURL(forRelativePath path: String) -> URL {
        root.appending(path: path, directoryHint: .inferFromPath)
    }

    /// The "/"-joined path of `url` below `root`, or nil when `url` is not strictly inside `root`.
    public func relativePath(for url: URL) -> String? {
        if let path = Self.relativePath(of: url.standardizedFileURL, under: root.standardizedFileURL) {
            return path
        }
        // Tolerates the same location spelled through a symlink (e.g. /var vs /private/var).
        return Self.relativePath(of: url.resolvingSymlinksInPath(), under: root.resolvingSymlinksInPath())
    }

    private static func relativePath(of url: URL, under base: URL) -> String? {
        guard url.isFileURL, base.isFileURL else { return nil }
        let baseComponents = base.pathComponents
        let components = url.pathComponents
        guard components.count > baseComponents.count,
            components.starts(with: baseComponents)
        else {
            return nil
        }
        return components.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
