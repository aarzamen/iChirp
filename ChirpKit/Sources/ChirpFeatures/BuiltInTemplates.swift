// Ported from MacParakeet (GPL-3.0): Sources/MacParakeetCore/Models/Prompt.swift @ bbae9e0e
// Changes: Summary, Action items (upstream "Action Items & Decisions"), Polish, Distill and Decide keep upstream's
// wording, lightly trimmed and retargeted from "selected text" to "the transcript"; Meeting notes, Agenda, SOAP note
// and Brief are new for iChirp (spec/08). iChirp ids and canonical keys are its own. The transcript is appended by
// `DeliverablePromptAssembler` unless a template places `{{transcript}}` itself.

import ChirpCore
import Foundation

/// The templates shipped with the app, installed by `DeliverableStoring.installBuiltInTemplates`.
///
/// **Ids and canonical keys are reserved forever**: never reuse one for a different template. Bump `revision` when a
/// template's content changes; uncustomized copies then get the new text as a new immutable version.
public enum BuiltInTemplates {
    public static let all: [BuiltInPromptTemplate] = [
        summary, meetingNotes, actionItems, agenda, soapNote, polish, distill, decide, brief,
    ]

    public static let summary = BuiltInPromptTemplate(
        id: uuid("67FA684E-6DB2-4961-AA6A-5106175E7C6D"),
        canonicalKey: "summary",
        revision: 1,
        name: "Summary",
        category: .deliverable,
        content: """
            Analyze this transcript and produce a structured summary.

            Open with a single sentence that captures what this is about and why it matters. Then organize the rest \
            under clear headings:

            **Key Points** — The 3–7 most important ideas, findings, or arguments. Each should be a complete thought, \
            not a fragment. If speakers are identified, attribute claims to them.

            **Decisions & Outcomes** — Anything that was agreed upon, concluded, or resolved. If nothing was decided, \
            omit this section entirely — don't fabricate consensus.

            **Open Questions** — Unresolved threads, disagreements, or topics raised but not settled. Only include \
            these if they're genuinely unresolved in the transcript.

            Be direct. Prefer specifics over generalizations — names, numbers, and concrete details beat vague \
            summaries. If the transcript is short or straightforward, keep the output proportionally brief. Don't pad.
            """,
        sortOrder: 0
    )

    public static let meetingNotes = BuiltInPromptTemplate(
        id: uuid("8A7AB376-3ABF-4F15-81C4-4CF05EE18A78"),
        canonicalKey: "meeting-notes",
        revision: 1,
        name: "Meeting notes",
        category: .deliverable,
        content: """
            Write meeting notes from this transcript.

            **Attendees** — List the speakers as labeled in the transcript (for example "Speaker 1"). Use a real name \
            only when the transcript clearly says who a speaker is.

            **Summary** — Two to four sentences on what the meeting covered.

            **Decisions** — Each decision as one clear statement, with who made or endorsed it when identifiable. Only \
            decisions actually made, not proposals.

            **Action items** — A checklist: what, who owns it, and when it is due, using the timing exactly as spoken. \
            Write "Owner not stated" or leave the date out rather than guessing.

            **Open questions** — Topics raised but not settled.

            Keep the notes factual and in the order things were discussed. Omit a section that would be empty.

            {{userNotes}}
            """,
        sortOrder: 1
    )

    public static let actionItems = BuiltInPromptTemplate(
        id: uuid("7AEA501F-D375-4D55-9CDB-BF8143157C41"),
        canonicalKey: "action-items",
        revision: 1,
        name: "Action items",
        category: .deliverable,
        content: """
            Extract every concrete commitment, task, and decision from this transcript.

            **Decisions Made**
            List each decision as a single clear statement. Include who made or endorsed it if identifiable. Only list \
            things that were actually decided — not proposals that were merely floated.

            **Action Items**
            For each task or commitment, as a checklist item (- [ ]):
            - What needs to happen (specific enough to act on)
            - Who owns it (if stated or clearly implied)
            - When it's due (if any timeline was mentioned — use exact wording as spoken, don't convert or guess)

            **Needs Follow-Up**
            Anything flagged as needing attention but with no clear owner or next step yet.

            If the transcript contains no clear actions or decisions, say so plainly — don't invent structure where \
            none exists. Order items by the sequence they appeared.
            """,
        sortOrder: 2
    )

    public static let agenda = BuiltInPromptTemplate(
        id: uuid("D8858BDB-266D-4C21-AA12-79B57FA2BDA5"),
        canonicalKey: "agenda",
        revision: 1,
        name: "Agenda",
        category: .deliverable,
        content: """
            Draft the agenda for the next meeting, based on this transcript.

            Build it from what is still open: unfinished action items, open questions, decisions that were deferred, \
            and follow-ups people promised to bring back. For each agenda item give a short title, one line of \
            context, and the owner when the transcript names one.

            Start with a one-line purpose for the meeting. Order items by importance, most important first. Do not add \
            topics that the transcript does not support. If nothing is left open, say so in one sentence.

            {{userNotes}}
            """,
        sortOrder: 3
    )

    public static let soapNote = BuiltInPromptTemplate(
        id: uuid("0D628138-2784-44E5-8A95-E7CC29A6C455"),
        canonicalKey: "soap-note",
        revision: 1,
        name: "SOAP note",
        category: .deliverable,
        content: """
            Draft a SOAP note from this clinical encounter transcript, for the clinician to review and sign.

            **Subjective** — Chief complaint, history of present illness, and pertinent history, medications and \
            allergies as the patient or clinician stated them.
            **Objective** — Vital signs, examination findings and results that were actually spoken in the transcript.
            **Assessment** — The clinician's stated assessment or differential. Do not add diagnoses the clinician did \
            not state.
            **Plan** — Tests, treatments, medications (with dose, route and frequency exactly as spoken), referrals, \
            patient education and follow-up.

            Rules: never invent findings, vital signs, doses, dates or durations; copy every number exactly as spoken. \
            When a section has nothing in the transcript, write "Not documented." Mark anything uncertain or inaudible \
            with [unclear]. Keep it concise and in standard clinical style. This is a draft, not a signed record.

            {{userNotes}}
            """,
        outputPrivacyClass: .clinical,
        sortOrder: 4
    )

    public static let polish = BuiltInPromptTemplate(
        id: uuid("A7D13F58-7BA5-47B6-84BA-30E91987F319"),
        canonicalKey: "polish",
        revision: 1,
        name: "Polish",
        category: .transform,
        content: """
            Rewrite the text so it reads like the best version of itself: clear, specific, finished. Preserve the \
            speaker's intent, factual claims, structure, and level of formality.

            Remove hedging, filler, repetition, throat-clearing, and vague intensifiers. Prefer plain words over \
            performative polish. Keep technical terms, names, numbers, and quoted text exactly intact.

            Do not change the register. If the input is casual, keep it casual; if formal, keep it formal. Do not add \
            new ideas, examples, claims, apologies, or enthusiasm. Do not make it sound like marketing copy.

            Return ONLY the rewritten text. No preamble, no quoting, no commentary, no headings.
            """,
        sortOrder: 100
    )

    public static let distill = BuiltInPromptTemplate(
        id: uuid("539222A3-AF45-438C-A3A4-C282F4A2E1CA"),
        canonicalKey: "distill",
        revision: 1,
        name: "Distill",
        category: .transform,
        content: """
            Compress the text to its signal. Reduce volume by 40–60% while keeping 100% of the actionable meaning.

            Identify the core point, the primary insight, or the bottom line. Discard the preamble, the connective \
            tissue, and the throat-clearing. Replace passive voice and weak phrasing with active, precise verbs.

            Use bullets when the input is a list of points or a sequence of ideas; use compact prose when it's a \
            single argument. Don't lose the "why" behind a decision, and don't lose the "who": if the input names \
            people, parties, or systems, keep them.

            Return ONLY the distilled text. No preamble, no meta-commentary.
            """,
        sortOrder: 101
    )

    public static let decide = BuiltInPromptTemplate(
        id: uuid("E7847CD7-ADAA-4875-AD2B-F7109780490D"),
        canonicalKey: "decide",
        revision: 1,
        name: "Decide",
        category: .transform,
        content: """
            Rewrite the text as a decision-ready note. The reader is busy and needs to understand what is being \
            decided and what should happen next.

            - **The question** — what's actually being decided, stated explicitly.
            - **The options** — the live choices, named clearly.
            - **The tradeoffs** — what each option costs and what it buys. One clean line each.
            - **The recommendation** — the suggested next move, with a single-sentence reason. If the input already \
            chose, make the choice explicit.
            - **The block** — if there isn't enough information to decide yet, the smallest concrete question that \
            must be answered next.

            Honor unresolved disagreement — don't flatten it into false consensus. Don't invent data.

            Return ONLY the note. No preamble.
            """,
        sortOrder: 102
    )

    public static let brief = BuiltInPromptTemplate(
        id: uuid("7113913C-51FA-464A-B044-8079220EAF9B"),
        canonicalKey: "brief",
        revision: 1,
        name: "Brief",
        category: .transform,
        content: """
            Write a brief in BLUF form (bottom line up front).

            First line: **Bottom line:** the single most important conclusion or request, in one sentence.
            Then exactly three bullets with the supporting facts, each one line, most important first.

            Use only facts in the text. Keep names and numbers exact. Return ONLY the brief.
            """,
        sortOrder: 103
    )

    private static func uuid(_ string: String) -> UUID {
        guard let id = UUID(uuidString: string) else { preconditionFailure("invalid built-in template id") }
        return id
    }
}
