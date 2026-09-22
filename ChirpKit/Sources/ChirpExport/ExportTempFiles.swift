import ChirpCore
import Foundation

/// Where `TranscriptViewModel.exportFile(_:)` writes a share-sheet export (`<tmp>/export-<id>/`), and how those
/// folders get cleaned up. Exported files hold transcript text, so they should not outlive the row they came from
/// or a killed process (final-review Task 12b).
public enum ExportTempFiles {
    private static let prefix = "export-"
    private static let logger = Log.logger("export-temp")

    /// The folder `exportFile(_:)` writes `id`'s export into: `<tmp>/export-<id>/`. Kept in sync with
    /// `TranscriptViewModel.exportFile(_:)`, which builds the same path.
    public static func directory(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(id.uuidString)", isDirectory: true)
    }

    /// Removes `id`'s export folder, if any. Call when the row is deleted so a share export does not keep
    /// transcript text around after the user asked for the row to be gone. Best-effort: a leftover folder is only
    /// disk space, and `sweepStale()` clears it on the next launch regardless.
    public static func remove(for id: UUID) {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.error(
                "export_temp_delete_failed id=\(id, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    /// Removes every `export-*` folder under the system temp directory. Call once at launch: `NSTemporaryDirectory`
    /// is not guaranteed to survive between launches, and a folder left by a process that was killed mid-share
    /// (or whose row was later deleted while the app was not running) would otherwise keep transcript text on disk
    /// indefinitely.
    public static func sweepStale() {
        let tempDirectory = FileManager.default.temporaryDirectory
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: tempDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            logger.error(
                "export_temp_sweep_list_failed error_type=\(String(describing: type(of: error)), privacy: .public)")
            return
        }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1
            } catch {
                logger.error(
                    "export_temp_sweep_delete_failed error_type=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
        if removed > 0 {
            logger.notice("export_temp_swept count=\(removed, privacy: .public)")
        }
    }
}
