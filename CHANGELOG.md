# Changelog

All notable changes to iChirp (home-screen name Parakeet). The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions are the `MARKETING_VERSION` in `Config/Shared.xcconfig`. No git tag exists yet: the owner tags `v1.0.0` on
`main` when v1.0 is cut, and a build's exact commit is always in Settings → About.

## [1.0.0] - 2026-11-05

The version that ships today, as decided in [`docs/SCOPE.md`](docs/SCOPE.md) (as-is, 2026-10-27): backup
speech-to-text on the iPhone plus the YouTube transcript reviewer. Built on milestones M0–M8
([`spec/README.md`](spec/README.md#milestones)).

### Added

- Dictation: Action Button, Lock Screen Live Activity or a tap starts recording; stop runs Parakeet on the phone and
  copies the text. Custom words, snippets and optional clean-up.
- YouTube captions to the Library: paste a link, or share one from the YouTube app or Safari to Parakeet; a share from
  Parakeet's own extension starts on its own, anything else only fills in the link.
- Share a link, and Files → Open in Parakeet for audio, video and documents.
- File transcription with speaker labels, meetings with crash recovery, language-model documents (summaries, meeting
  notes, SOAP notes, Ask), PDF and Word export, Apple Speech and WhisperKit as alternative engines, small language
  models on the phone, Needle 3 (experimental), the Mac companion script for voices and YouTube audio.
- Privacy classes (general, personal, clinical) with one routing rule: clinical content stays on the phone or on a Mac
  you marked trusted unless you confirm otherwise for one run.
- Settings → About shows the build stamp: version, build number, commit, branch, build date, dirty flag.

### Known limits (from `docs/SCOPE.md` and the open items on the plans board)

- A Mac companion app is v1.1 and out of scope. The optional Python companion script in `companion/` (local voices,
  YouTube audio for videos without captions) is not that app and nothing in 1.0 depends on it.
- Only the release ladder remains: no tag, no TestFlight or App Store path yet (`docs/distribution.md`).
- Voice Memos → Share → Parakeet does nothing (it never worked); Files → Open in Parakeet works.
- Needle round 4 (clinical safety) is open: do not use Extract fields on real clinical dictation.
- Live streaming Parakeet, Laya and the Jev live eval are not built; the M8 keyboard, Transforms extension,
  home-screen widgets, iPad layout and localization are not started.
- Owner device QA is still pending for most milestones; "built" means the code and tests are in and the milestone
  passed on the simulator.
