# 00 - Vision

> Status: ACTIVE — the end goal, the north star and the principles every feature is judged against.

## The end goal

In the owner's words:

> "An iOS, highly polished, competent, accurate, flexible, and easy-to-use application that's used for
> transcription of voice files, meetings, YouTube links, device files, text files, and PDFs into all manner of
> transcription, raw documents, large language model polished documents, meeting notes, agendas, SOAP notes,
> transcripts, and all manner of other deliverable text formats and documents. It should do this with the utmost
> flexibility, being able to plug and play various different speech-to-text engines, large language models, and
> small language models"

He also named miscellaneous models: Needle (a tiny on-device model for structured extraction, tool calls and
embeddings), Jev (a cloud "decision" model), Laya (an open alternative to Jev) and Cactus (an on-device inference
runtime). iChirp calls these **structure models**.

## North star

**Parakeet is the private speech-to-document workbench in your pocket.** Anything you can hear or read goes in:
voice memos, meetings, dictation, podcasts and videos, files, PDFs. What comes out is the document you actually
need: an exact transcript, clean text, meeting notes, an agenda, a SOAP note, subtitles. Every step runs on the
iPhone by default, and every engine is replaceable.

It inherits MacParakeet's direction ("the private speech memory of your Mac") and extends it in two ways that matter
on a phone: more kinds of input, and finished deliverables rather than raw text.

## Principles

1. **Accuracy first, then speed.** Parakeet v3 on the Neural Engine is the default because it is both. A final
   pass over the recorded file is always the authoritative text; live text is a preview.
2. **Private by default.** Audio and transcripts stay on the device. Anything that leaves it is an explicit,
   visible choice ([`12-privacy.md`](12-privacy.md)). Clinical content has stricter rules than anything else.
3. **Honest.** The app never pretends. No simulated progress, no demo rows, no stand-in code that "works" by doing
   something else. An unbuilt feature says "Not built yet — milestone Mx".
4. **Plug and play.** Speech engines, language models and structure models are plug-ins behind stable protocols
   ([`06-speech-engines.md`](06-speech-engines.md), [`08-language-and-structure-models.md`](08-language-and-structure-models.md)).
   Swapping one never touches the screens.
5. **Never lose the user's work.** Source media is kept, jobs survive being killed (they come back as
   "Interrupted" with Retry), and nothing is deleted without the user asking.
6. **Polished and simple.** Four tabs, warm and calm visual language from the design canvas, one obvious action
   per screen. Features earn their place by producing a better document or a more useful library.

## Who it is for

The first user is the owner: a physician who records meetings, dictates notes and turns long recordings into
structured documents, including clinical notes. That sets the bar:

- **Clinical accuracy matters.** Numbers, doses and names must be right, so structured extraction is re-validated
  in code and always reviewed by the user ([`08-language-and-structure-models.md`](08-language-and-structure-models.md)).
- **PHI never leaks by accident.** Clinical items are routed only to on-device engines or a trusted home-network
  host unless the user overrides a single run.
- **Works on the owner's devices.** iPhone 17 Pro first; iPhone 15 Pro, iPhone 12 Pro Max and iPad Pro M1 later.

## What it is

- A transcription app for files first (M1), then dictation (M2) and meetings (M3).
- A document factory: templates that turn a transcript into meeting notes, agendas, SOAP notes and summaries (M4).
- An ingest hub for links, podcasts, YouTube, PDFs and text documents (M5).
- A plug-in host for many engines, with on-device benchmarks to choose between them (M6, M7).

## What it is not

- Not a cloud service. There is no account and no server.
- Not an App Store product today. It is GPL-3.0 and installed as a developer build ([ADR-008](adr/008-distribution-and-build-identity.md)).
- Not a fork that edits MacParakeet in place. Upstream is a read-only reference ([ADR-001](adr/001-port-with-pinned-upstream-reference.md)).
- Not a medical device. Clinical documents are drafts the clinician reviews and signs.

## The experience

| Mode | What the user does | Milestone |
|---|---|---|
| Transcribe a file | Capture → Import audio → pick a Voice Memo or file → it appears in Recent with real progress → open the transcript, play, tap timestamps, share | M1 |
| Share into Parakeet | Share sheet from Voice Memos or Files → Parakeet → transcribed in the background | M1.5 |
| Dictate | Press the Action Button (or tap Dictate) → speak → stop → clean text on the clipboard | M2 |
| Record a meeting | Record Meeting → notes while recording → stop → speaker-labelled transcript, then notes | M3 |
| Make a document | Transcript → Transform → Meeting notes / SOAP note / Agenda / Summary → edit, copy, share | M4 |
| Bring in anything | Paste a podcast, video or YouTube link, or import a PDF or document | M5 |
