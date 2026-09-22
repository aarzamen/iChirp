import Foundation

/// Which revision of the app is running, as stamped into Info.plist at build time by
/// `scripts/stamp_build_identity.sh` (keys `ChirpGitCommit`, `ChirpGitBranch`, `ChirpGitDirty`,
/// `ChirpBuildDateUTC`, plus the standard `CFBundleShortVersionString` / `CFBundleVersion`).
public struct BuildIdentity: Sendable, Equatable {
    public var version: String
    public var build: String
    public var commit: String
    public var branch: String
    public var isDirty: Bool
    public var buildDateUTC: String

    /// The value used for every key that is missing or blank.
    static let unknown = "unknown"

    /// Missing keys → "unknown", dirty "1" → true.
    public static func from(infoDictionary: [String: Any]?) -> BuildIdentity {
        func string(_ key: String) -> String {
            guard let value = infoDictionary?[key] as? String else { return unknown }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? unknown : trimmed
        }
        let dirtyValue = infoDictionary?["ChirpGitDirty"]
        let isDirty: Bool
        if let flag = dirtyValue as? Bool {
            isDirty = flag
        } else if let text = dirtyValue as? String {
            isDirty = ["1", "true", "yes"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
        } else {
            isDirty = false
        }
        return BuildIdentity(
            version: string("CFBundleShortVersionString"),
            build: string("CFBundleVersion"),
            commit: string("ChirpGitCommit"),
            branch: string("ChirpGitBranch"),
            isDirty: isDirty,
            buildDateUTC: string("ChirpBuildDateUTC")
        )
    }

    /// Reads `Bundle.main.infoDictionary`.
    public static var current: BuildIdentity {
        from(infoDictionary: Bundle.main.infoDictionary)
    }

    /// "0.1.0 (202609221830) · a1b2c3d4e5f6 · ichirp/foundation · 2026-09-22T18:30:00Z" plus " · dirty" when dirty
    public var summary: String {
        let base = "\(version) (\(build)) · \(commit) · \(branch) · \(buildDateUTC)"
        return isDirty ? base + " · dirty" : base
    }
}
