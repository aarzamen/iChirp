# Media Storage Layout v1

> Status: ACTIVE — where user data lives on the device and how rows point at it.

## Purpose

Keep the user's database and media findable and intact across app updates, restores and reinstalls, and keep
temporary files from leaking. Every job, player, exporter and future recovery flow depends on these paths.

## Producers

- `ChirpCore.AppPaths` (root, database URL, per-item media directory, relative/absolute mapping).
- `FileTranscriptionPipeline.importFile` (copies the source) and `process` (writes and deletes the normalized WAV).
- `FileTranscriptionPipeline.sweepOrphanedTemporaryAudio()` at launch (deletes `normalized-16k.wav` left by a killed
  process; never a source file).
- `ChirpStore.DatabaseManager` (the database file).
- The Library delete flow (removes the row and its media folder).

## Consumers

- `TranscriptViewModel.mediaURL` (the player), retry and re-transcription.
- `TranscriptionStoring` rows (`mediaRelativePath`).
- Future: meeting sessions (M3), the share-extension inbox (M1.5), backups and restore.

## Stable fields

```
<Application Support>/iChirp/                 AppPaths.root (created on first launch; included in backups)
├── ichirp.sqlite                              AppPaths.databaseURL (plus SQLite -wal / -shm siblings)
└── media/
    └── <UUID>/                                AppPaths.mediaDirectory(for: id); <UUID> = id.uuidString
        ├── source.<ext>                       the imported file; <ext> is the original file's extension
        └── normalized-16k.wav                 temporary decode for the engine (see below)
```

- `Transcription.mediaRelativePath` stores the path **relative to the root** with `/` separators, e.g.
  `media/1F0C…/source.m4a`. `AppPaths.absoluteURL(forRelativePath:)` and `relativePath(for:)` are inverses; a URL
  outside the root has no relative path (nil).
- The root is kept in device backups (`isExcludedFromBackup = false`). Downloaded model folders live outside the root
  and are excluded from backups.
- `normalized-16k.wav` is deleted when the job completes. A copy left by a failed, cancelled or interrupted job is
  temporary: nothing may depend on it, and cleanup may delete it at any time. The source file stays until the user
  deletes the transcript.
- Deleting a transcript deletes exactly its `media/<UUID>/` folder and its row, nothing else.

## Non-stable fields

- The absolute container path (changes across installs and restores; never store it).
- File sizes, timestamps, and the presence of SQLite sidecar files.

## Versioning and compatibility

Adding new files inside `media/<UUID>/` (for example a waveform cache or a meeting's `recording.lock`) is additive if
existing files keep their names. Renaming `source.<ext>`, moving the database, or changing to absolute paths is
breaking: write `media-storage-layout-v2.md` and a migration that moves files and rewrites `mediaRelativePath` in one
recoverable step.

## Tests that enforce this

- `AppPathsTests.testDatabaseURLLivesInRoot`, `testMediaRelativePathRoundTrips`, `testRelativePathOutsideRootIsNil`.
- `FileTranscriptionPipelineTests.testProcessProducesCompletedTranscriptWithSpeakersAndSegments` (normalized WAV
  deleted, source kept), `testSweepDeletesOnlyOrphanedNormalizedAudio` (orphaned WAVs only).
- `LibraryViewModelTests.testDeleteRemovesRowAndItsMediaFolder` (exactly the item's folder).

## When this changes

Update this contract, [spec/01](../01-data-model.md), the `ChirpCore` README, any migration, and the tests above in
the same commit. Changes that could orphan or delete user files need the owner's review.
