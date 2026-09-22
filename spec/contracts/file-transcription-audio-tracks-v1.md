# File Transcription Audio Tracks v1

> Status: ACTIVE — which audio track of an imported file is transcribed (M1.5, plan 010 Step 4).
> Adapted from upstream MacParakeet's `spec/contracts/file-transcription-audio-tracks.md` @ `bbae9e0e`.

## Purpose

Keep a media file with several audio tracks (a movie with a second language, a commentary track, a screen
recording with separate microphone and system audio) from being transcribed from the wrong track without anyone
noticing, while ordinary single-track files keep the zero-friction path.

## Producers

- `ChirpAudio.AVAudioNormalizer.audioTracks(in:)` (`ChirpCore.AudioTrackProbing`): lists the tracks from
  AVFoundation metadata, without decoding.
- `ChirpAudio.AVAudioNormalizer.normalize(sourceURL:outputURL:audioTrackOrdinal:)` (the additive
  `ChirpCore.AudioNormalizing` requirement): decodes the chosen track.
- `ChirpFeatures.TranscriptionJobCenter.start(filesAt:pipeline:)`, `selectAudioTrack(_:for:)`,
  `cancelAudioTrackSelection(_:)`: the pre-import check and the choice.
- `ChirpFeatures.FileTranscriptionPipeline.importFile(from:sourceType:audioTrackOrdinal:)`: stores the choice.
- `App/Sources/Screens/Shared/AudioTrackPickerSheet.swift`: the picker.
- Migration `v2-audio-track-ordinal` (ChirpStore).

## Consumers

- Capture's Import audio (document picker, one or many files) and files opened from other apps (Share sheet →
  Parakeet, Files → Open in).
- `FileTranscriptionPipeline.process(id:)` and `retry(id:)`: every run of a row decodes its stored track.

## Stable semantics

- **Numbering.** People see track numbers one-based ("Track 2"). `AudioTrackDescriptor.ordinal`,
  `Transcription.audioTrackOrdinal` and the normalizer's `audioTrackOrdinal` are zero-based **among audio tracks
  only**, in the order `AVAsset.loadTracks(withMediaType: .audio)` returns them. The container's own track id
  (`trackID`) is informational and never used to select a track (upstream: FFmpeg's `0:a:N`, never the
  container-wide stream index).
- **When to ask.** Exactly one audio track: no picker, automatic selection, nothing stored (`nil`). Two or more
  tracks: the person must choose **before any row exists or any work starts**; the app shows the tracks of the first
  multi-track file in the batch.
- **Labels** always have the numbered fallback ("Track 1"). A language (" — English") and " (Default)" are added
  when the file records them; "Default" is shown only when the file enables some tracks and not others.
- **One choice per batch.** A choice made for a batch applies to each of its multi-track files; its single-track
  files keep automatic selection and store `nil`. Cancelling the picker drops the whole batch: nothing is imported,
  and iOS's Inbox copies of shared files are deleted (the originals stay where they were).
- **Never fall back.** A stored ordinal the file does not have (a later file in the batch with fewer tracks) fails
  that file's row with `AudioTrackSelectionError.trackMissing` ("This file has no audio track N …"); no other track
  is transcribed in its place, and the rest of the batch continues.
- **Persistence.** `transcriptions.audioTrackOrdinal` is a nullable integer. `NULL` means automatic selection (the
  first audio track), which is what every row from before M1.5 has. A value records an explicit choice and is
  reused by Retry.
- **Batches wait their turn.** A batch that needs a choice while another is pending waits; choices are matched to
  their request id, so a stale tap does nothing.

## iChirp adaptations (differences from upstream)

- **No audio track, or tracks that cannot be read, keep M1's behavior.** Upstream rejects a file with no audio
  streams before a row exists. iChirp imports it as before and the row fails at normalization with the existing
  error (plan 010's "Must not change" protects M1's error semantics); a probe failure never shows the picker.
- AVFoundation replaces FFmpeg (probe and decode); there is no CLI `--audio-track` option.
- Several pending batches queue instead of refusing new imports while a choice is open.

## Non-stable details

- The sheet's copy, layout and symbols.
- `trackID` values and language display names (they come from the file and the system locale data).
- The exact error sentence, provided the failure stays visible on the row and nothing falls back.

## Versioning and compatibility

The column and the model field are additive and nullable: old rows read as automatic selection, and an older build
ignores both the unknown migration (GRDB tolerates applied migrations it does not know) and the extra column.
`AudioNormalizing.normalize(sourceURL:outputURL:)` keeps its meaning (first track); the ordinal overload has a
default implementation that accepts `nil` and refuses an explicit ordinal (`selectionUnsupported`), so other
normalizers keep compiling. Changing numbering, the ask/no-ask rule, the no-fallback rule or persistence needs a
`-v2` contract and focused tests.

## Tests that enforce this

- `ChirpAudioTests.AudioTrackSelectionTests`: a two-audio-track `.mov` built in `setUp` (English default plus a
  Spanish alternate of a different length and loudness): probe order, labels and default marker; automatic
  selection is the first track; an explicit ordinal decodes that track even when it is not the default; a missing
  ordinal throws and decodes nothing; the protocol's default overload.
- `ChirpStoreTests.AudioTrackOrdinalMigrationTests`: the nullable column; a v1 row reads as `nil` after migrating;
  an explicit ordinal survives insert, save, favorite and status transitions.
- `ChirpFeaturesTests.AudioTrackSelectionFlowTests`: no picker for one track; no row or work before the choice;
  the batch rule; no fallback for a later file; cancel drops the batch; Retry reuses the choice; queued batches and
  stale ids; an unreadable file never asks.
- `iChirpTests.ContinuedProcessingTests.testPickerMessageNamesTheFileAndTheBatchRule`.

## When this changes

Update this contract, [spec/01](../01-data-model.md) (the column), [spec/02](../02-features.md) (Transcribe),
[spec/05](../05-audio-pipeline.md) (decoding), the ChirpAudio, ChirpStore and ChirpFeatures READMEs, a new migration
if persistence changes, and the tests above, in the same commit.
