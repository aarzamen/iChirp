import ChirpCore
import Foundation

/// The app's `Documents/Inbox/` folder: where iOS puts its own copy of every file another app hands to Parakeet
/// (Share sheet → Parakeet, Files → Open in) before calling the app's open-URL handler.
///
/// The app declares `LSSupportsOpeningDocumentsInPlace = false`, so iOS always copies; that copy is temporary and is
/// not user data (the original stays in Voice Memos or Files, and the import copies it into `media/<id>/`). Once its
/// import has settled (imported, failed, or declined at the track picker) the app deletes it with `removeIfInside`.
/// Nothing outside this folder is ever deleted: a file picked with the document picker is the user's own file.
public struct IncomingFileInbox: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Documents/Inbox/` in the app's container, or nil when the Documents folder cannot be located.
    public static func appDefault() -> IncomingFileInbox? {
        guard
            let documents = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else {
            return nil
        }
        return IncomingFileInbox(directory: documents.appendingPathComponent("Inbox", isDirectory: true))
    }

    /// Whether `url` is a file strictly inside the inbox (any depth). Tolerates the same location spelled through a
    /// symlink (`/var` vs `/private/var`).
    public func contains(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let inbox = AppPaths(root: directory)
        return inbox.relativePath(for: url) != nil
    }

    /// Deletes `url` when it is inside the inbox; does nothing otherwise. Returns whether a file was deleted.
    @discardableResult public func removeIfInside(_ url: URL) -> Bool {
        guard contains(url) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            Self.logger.info("inbox_copy_removed")
            return true
        } catch {
            // Already gone, or not removable: harmless, it is only iOS's temporary copy.
            Self.logger.notice("inbox_copy_remove_failed error_type=\(error.logTypeName, privacy: .public)")
            return false
        }
    }

    private static let logger = Log.logger("inbox")
}
