# Meeting Session v1

> Status: ACTIVE (M3) — a meeting's session folder, its `recording.lock`, the lock states, recovery and retention
> safety. Port of upstream MacParakeet's `meeting-artifacts-v1` and `meeting-recovery-retention` (ADR-019), cut down
> to one microphone source and one process.

## Purpose

A meeting is the recording the owner can least afford to lose. This contract fixes what is on disk while a meeting
records, how a meeting interrupted by a crash or a kill is found and recovered, and which predicates keep automatic
code (retention, sweeps) away from audio that is not finished.

## Producers

- `MeetingCoordinator` (ChirpFeatures): creates the folder, writes `recording.lock` (state `recording`) **before the
  first audio buffer**, rewrites it with the notes while recording, moves it to `awaitingTranscription` after the
  recorder closed the audio, inserts the row, runs the final pass.
- `MeetingRecorder` (ChirpAudio): writes `meeting.caf`.
- `MeetingLiveTranscriber` (ChirpFeatures): writes and deletes `chunks/chunk-<startMs>-<endMs>.wav`.
- `MeetingFinalizer` (ChirpFeatures): writes and deletes `normalized-16k.wav`; saves the completed row; is the only
  code that deletes a lock after a success (settlement).
- `MeetingRecoveryService` (ChirpFeatures): discovers orphaned locks, recovers (inserts or reuses the row, then
  finalizes), discards after the person confirms.
- `MeetingAudioRetentionSweeper` (ChirpFeatures): deletes old meeting audio only per the person's setting.

## Consumers

- The recovery sheet at launch and the Library's "Meetings to recover" banner (App).
- The Transcript player and exporters (the row's `mediaRelativePath`).
- Launch housekeeping (`FileTranscriptionPipeline.sweepOrphanedTemporaryAudio` removes a leftover
  `normalized-16k.wav`; the dictation orphan adoption ignores meeting folders because it looks only for
  `dictation.wav`).

## Stable fields

### Folder

```
media/<UUID>/                  the meeting's Transcription id (media-storage-layout-v1, additive files)
├── recording.lock             JSON (below); present from before the first buffer until the transcript is saved
├── meeting.caf                CAF, 16 kHz, mono, 16-bit signed-integer PCM; readable up to the last written buffer
├── chunks/                    temporary live-preview chunks; nothing depends on them; removed at stop and recovery
└── normalized-16k.wav         temporary decode for the final pass (media-storage-layout-v1 rule)
```

`meeting.caf` is the meeting's source: the row's `mediaRelativePath` is `media/<UUID>/meeting.caf`. Why CAF:
[the Step 1 measurement](../../docs/research/2026-09-22-meeting-crash-format.md).

### `recording.lock`

```json
{
  "schemaVersion": 1,
  "sessionId": "<UUID, equals the folder name and the row id>",
  "startedAt": "<ISO 8601>",
  "launchId": "<UUID of the app launch that owns the session>",
  "displayName": "Meeting Sep 22 at 9:41",
  "state": "recording",
  "speechEngine": "fluidaudio.parakeet-tdt",
  "speechEngineVariant": "v3",
  "privacyClass": "personal",
  "notes": "optional; what the person typed so far"
}
```

- Stable keys: `schemaVersion`, `sessionId`, `startedAt`, `launchId`, `displayName`, `state`, `speechEngine`,
  `speechEngineVariant`, `privacyClass`, `notes`. The file is written atomically (write to a temporary name, then
  rename), so it is either the old or the new version, never half of one.
- `speechEngine` / `speechEngineVariant` are the final-pass route captured at start; recovery reports it (the app
  has one speech engine today, so recovery runs Parakeet either way; M7 honors a captured route).
- `notes` is decoded on its own: a malformed value loses only the notes, never the recovery.
- Readers accept `schemaVersion` up to the current one and treat a newer one as opaque (skipped by discovery, still
  a retention barrier).

### States

| State | Meaning | Written when |
|---|---|---|
| `recording` | The recorder may still be writing `meeting.caf`. Recovered audio is partial ("Partial audio" badge). | Before the recorder starts |
| `awaitingTranscription` | The recorder closed the audio; the transcript is not saved yet. | After `stop` returned, before the row is inserted |

The lock is deleted only after `savePreservingUserMetadata` returned a **completed** meeting row, or when the person
confirmed Discard. A failed final pass leaves it (`awaitingTranscription`) and the row shows the error with Retry.

## Safety predicates

- **Orphan (recoverable):** a readable lock whose `launchId` is not this launch's. iOS runs one app process, so a
  lock from an earlier launch has no live owner. A lock this launch owns (the recording in progress, or its final
  pass) is never offered for recovery.
- **Offered at launch:** an orphan whose row is missing, `.processing` or `.interrupted`. An orphan whose row is
  `.failed` or `.cancelled` is left to the Library's Retry; a `.completed` row means the lock outlived a save and
  recovery only settles it (deletes the lock).
- **Recover:** reuses or inserts the row (`sourceType = meeting`, `isPartialAudio` true when the lock said
  `recording`), moves the lock to `awaitingTranscription`, removes `chunks/`, and runs the normal final pass.
- **Discard:** only after the person confirms; deletes the row (if any) and the whole folder.
- **Retention:** deletes `meeting.caf` of a `.completed` meeting row older than the person's N days, sets
  `mediaRelativePath` to nil and `audioRemovedAt` to now. It never touches a folder that contains any file named
  `recording.lock` (readable or not), a row that is not completed, or any non-meeting row. The default keeps audio
  forever.

## Non-stable fields

- `displayName` wording, the chunk file names, timestamps, file sizes.

## Versioning and compatibility

Adding optional lock keys or folder files is additive. Changing the audio format, the file names above, the state
names or the orphan rule is breaking: write `meeting-session-v2.md` and keep reading v1 locks.

## Tests that enforce this

- `MeetingSessionLockStoreTests` (round trip, atomic rewrite, malformed notes, newer schema skipped, orphan rule).
- `MeetingRecorderTests` (CAF format, samples written, pause writes nothing, mute writes silence, file kept on stop).
- `MeetingCoordinatorTests` (lock written before the first buffer; state transitions; files closed on stop; lock
  removed only after the completed save; discard deletes only after the call; failed final pass keeps lock and audio).
- `MeetingRecoveryServiceTests` (fixture folders with synthetic audio: discovery, recover, discard, completed rows
  settled, this launch's session never offered).
- `MeetingAudioRetentionPolicyTests` and `MeetingAudioRetentionSweeperTests` (locked or unfinished sessions never
  deleted; keep-forever default; the transcript stays).

## When this changes

Update this contract, [media-storage-layout-v1](media-storage-layout-v1.md), the ChirpFeatures and ChirpAudio
READMEs, and the tests above in the same commit. Anything that could delete a recording needs the owner's review.
