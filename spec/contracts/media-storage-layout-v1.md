# Media Storage Layout v1

> Status: ACTIVE — where user data lives on the device and how rows point at it.

## Purpose

Keep the user's database and media findable and intact across app updates, restores and reinstalls, and keep
temporary files from leaking. Every job, player, exporter and future recovery flow depends on these paths.

## Producers

- `ChirpCore.AppPaths` (root, database URL, per-item media directory, relative/absolute mapping).
- `FileTranscriptionPipeline.importFile` (copies the source) and `process` (writes and deletes the normalized WAV).
- `DictationRecorder` (M2) writes `media/<id>/dictation.wav`; the dictation coordinator creates the folder, inserts
  the row pointing at it, and removes the folder only when the person cancels (discard) the dictation.
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
        ├── dictation.wav                      M2 (additive): a dictation recording, 16 kHz mono Float32 WAV
        ├── download.part, download.part.json  M5 (additive): an unfinished link download and its resume record
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
- `dictation.wav` (M2, additive) is the dictation's source: `mediaRelativePath` points at it, playback and Retry read
  it, and it is written at 16 kHz already, so the file pipeline never has to normalize it for the final pass. It is
  kept until the person deletes the transcript, unless they turned off "Keep dictation audio" (Settings → Capture),
  in which case it is deleted right after a successful final pass and `mediaRelativePath` becomes nil. A dictation
  the person cancels leaves no row and no folder. Recordings shorter than 0.3 s are rejected and their file removed.
- M5 (additive, [document-items-v1](document-items-v1.md)): `source.<ext>` is also a document's copy (`.pdf`,
  `.docx`, …) or a downloaded episode. `download.part` / `download.part.json` exist only while a link download is
  unfinished; Retry resumes from them, and completing the download removes both.
- `Documents/Inbox/` (outside the root) is where iOS copies a file another app opens in Parakeet (M1.5 "Open in").
  That copy is temporary, never referenced by a row, and deleted once its import settles
  (`IncomingFileInbox.removeIfInside`, which touches nothing outside that folder).

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
- `IncomingFileInboxTests` (only files inside `Documents/Inbox/` are deleted; the imported copy stays).
- `DictationRecorderTests` (the WAV's format and duration; a too-short recording and a cancelled one leave no file)
  and `DictationCoordinatorTests` (cancel leaves no row or folder; failure keeps the audio; the keep-audio setting).

## When this changes

Update this contract, [spec/01](../01-data-model.md), the `ChirpCore` README, any migration, and the tests above in
the same commit. Changes that could orphan or delete user files need the owner's review.
