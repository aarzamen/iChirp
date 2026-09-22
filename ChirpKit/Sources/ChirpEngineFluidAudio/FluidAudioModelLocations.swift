// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Services/AppPaths.swift @ bbae9e0e
// L149–L213 only (FluidAudio model directory mapping), plus iChirp's cache checks and backup exclusion.

import ChirpCore
import FluidAudio
import Foundation

/// Where FluidAudio model files live and how to tell whether they are complete.
///
/// Layout (`root` defaults to FluidAudio's own cache, `Application Support/FluidAudio/Models`):
///
/// ```
/// <root>/parakeet-tdt-0.6b-v3/        Parakeet v3
/// <root>/parakeet-tdt-0.6b-v2/        Parakeet v2
/// <root>/speaker-diarization/         offline diarizer
/// ```
///
/// Folder names come from FluidAudio's `Repo.folderName`, never hard-coded here.
enum FluidAudioModelLocations {
    /// FluidAudio's default resolver, as upstream production uses it.
    static var defaultModelsRoot: URL {
        MLModelConfigurationUtils.defaultModelsDirectory().standardizedFileURL
    }

    static func asrVersion(for variant: ParakeetVariant) -> AsrModelVersion {
        switch variant {
        case .v3: return .v3
        case .v2: return .v2
        }
    }

    static func asrRepo(for variant: ParakeetVariant) -> Repo {
        switch variant {
        case .v3: return .parakeetV3
        case .v2: return .parakeetV2
        }
    }

    /// root/<Parakeet repo folder>
    static func parakeetDirectory(in root: URL, variant: ParakeetVariant) -> URL {
        root.appendingPathComponent(asrRepo(for: variant).folderName, isDirectory: true)
    }

    /// root/<diarizer repo folder>
    static func diarizerDirectory(in root: URL) -> URL {
        root.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    /// Every file `AsrModels.load` needs is on disk and came from the revision this FluidAudio build pins.
    static func parakeetModelsExist(in root: URL, variant: ParakeetVariant) -> Bool {
        let directory = parakeetDirectory(in: root, variant: variant)
        return AsrModels.modelsExist(at: directory, version: asrVersion(for: variant))
            && cacheMatchesPinnedRevision(directory, repo: asrRepo(for: variant))
    }

    /// Upstream `DiarizationService.isModelCached`, plus the revision check.
    static func diarizerModelsExist(in root: URL) -> Bool {
        let directory = diarizerDirectory(in: root)
        let filesPresent = ModelNames.OfflineDiarizer.requiredModels.allSatisfy { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        return filesPresent && cacheMatchesPinnedRevision(directory, repo: .diarizer)
    }

    /// Mirrors FluidAudio's internal `ModelCache.matchesRevision`. FluidAudio's loaders re-download a cache whose
    /// revision marker differs from the pinned revision (for example after a FluidAudio bump moves the diarizer
    /// pin), so such a cache counts as not downloaded: loading it would download silently.
    static func cacheMatchesPinnedRevision(_ repoDirectory: URL, repo: Repo) -> Bool {
        let marker = repoDirectory.appendingPathComponent(".fluidaudio-revision")
        guard let data = try? Data(contentsOf: marker) else {
            return repo.revision == "main"
        }
        let stored = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return stored == repo.revision
    }

    /// Model files are re-downloadable, so iOS backups must skip them (App Store storage guideline).
    static func excludeFromBackup(_ directory: URL) throws {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Allocated bytes of every regular file under `directory`; 0 when it does not exist.
    static func byteSize(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Removes `directory` if it exists.
    static func removeIfPresent(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}
