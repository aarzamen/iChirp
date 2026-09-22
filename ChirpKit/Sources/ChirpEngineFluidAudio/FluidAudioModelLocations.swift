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

    /// `ModelHub.download`'s `variant` for Parakeet, as `AsrModels.download` passes it (default int8 encoder on v3).
    static func downloadVariant(for variant: ParakeetVariant) -> String? {
        switch variant {
        case .v3: return ParakeetEncoderPrecision.int8.rawValue
        case .v2: return nil
        }
    }

    /// What `AsrModels.loadLocal` reads, relative to the repo folder: the compiled bundles (int8 encoder, its
    /// default) and the vocabulary JSON, which `AsrModels.download` writes last.
    static func parakeetRequiredFiles(variant: ParakeetVariant) -> Set<String> {
        let bundles: Set<String>
        switch variant {
        case .v3: bundles = ModelNames.ASR.requiredModelsV3(precision: .int8)
        case .v2: bundles = ModelNames.ASR.requiredModels
        }
        return bundles.union([ModelNames.ASR.vocabularyFile])
    }

    /// Ready means complete: every file `AsrModels.loadLocal` needs is on disk and whole, and came from the revision
    /// this FluidAudio build pins. `AsrModels.modelsExist` alone only checks that each bundle folder exists.
    static func parakeetModelsExist(in root: URL, variant: ParakeetVariant) -> Bool {
        let directory = parakeetDirectory(in: root, variant: variant)
        return AsrModels.modelsExist(at: directory, version: asrVersion(for: variant))
            && incompleteFiles(in: directory, requiredFiles: parakeetRequiredFiles(variant: variant)).isEmpty
            && cacheMatchesPinnedRevision(directory, repo: asrRepo(for: variant))
    }

    /// True when the cache is incomplete but `AsrModels.download` would still stop early on its looser
    /// folder-exists check. The download hook then runs `ModelHub.download` first, which fetches the missing files
    /// and resumes `.partial` ones without deleting anything.
    static func parakeetNeedsRepair(in root: URL, variant: ParakeetVariant) -> Bool {
        let directory = parakeetDirectory(in: root, variant: variant)
        return AsrModels.modelsExist(at: directory, version: asrVersion(for: variant))
            && !parakeetModelsExist(in: root, variant: variant)
    }

    /// Upstream `DiarizationService.isModelCached`, made strict (every bundle whole) plus the revision check.
    /// `ModelHub.download` has no early exit of its own, so a partial cache is repaired by the next Download.
    static func diarizerModelsExist(in root: URL) -> Bool {
        let directory = diarizerDirectory(in: root)
        return incompleteFiles(in: directory, requiredFiles: ModelNames.OfflineDiarizer.requiredModels).isEmpty
            && cacheMatchesPinnedRevision(directory, repo: .diarizer)
    }

    /// Mirrors FluidAudio's internal `ModelCache.incompleteFiles` (issue #819): a `.mlmodelc` bundle counts only
    /// with its root `coremldata.bin` and no `*.partial` file left by an interrupted `FileDownloader` fetch; any
    /// other file must exist. Returns the incomplete names, sorted.
    static func incompleteFiles(in repoDirectory: URL, requiredFiles: Set<String>) -> [String] {
        let fileManager = FileManager.default
        return requiredFiles.filter { name in
            let url = repoDirectory.appendingPathComponent(name)
            guard name.hasSuffix(".mlmodelc") else {
                return !fileManager.fileExists(atPath: url.path)
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                fileManager.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path)
            else { return true }
            return containsPartialDownload(url)
        }.sorted()
    }

    private static func containsPartialDownload(_ directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let item as URL in enumerator where item.pathExtension == "partial" {
            return true
        }
        return false
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
