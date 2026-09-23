# Structured Results v1

> Status: ACTIVE — the evidence ledger for structure-model output (M6, plan 015): the gate, the review state and the
> `v7-structured-results` tables. Decisions: [ADR-012](../adr/012-needle-from-needle-rs-source.md),
> [ADR-002](../adr/002-local-first-and-privacy-classes.md). Engine side: [structure-model-plugin-v1](structure-model-plugin-v1.md).

## Purpose

Make every field a structure model extracts traceable (which words, which audio, which engine and model file, how
confident, what the gate said, whether a person reviewed it), and make it impossible to show an extracted clinical
number as final without that trail.

## Producers

- `ChirpKit/Sources/ChirpCore/Models/StructuredResult.swift`: `StructuredRun`, `StructuredField`,
  `StructuredSourceSpan`, `StructuredVerdict`, `StructuredEvalRun`, `StructuredResultStoring`.
- `ChirpKit/Sources/ChirpStore/StructuredResultStore.swift`: migration `v7-structured-results`, `GRDBStructuredResultStore`.
- `ChirpKit/Sources/ChirpFeatures/Structure/StructuredResultGate.swift`: `StructuredResultGate` (and its
  `review(_:engineID:)`, the one place a run's verdicts are decided), `SentenceCalls`, `ReviewedCall`,
  `StructuredCallValidator`, `StructureSettings`.
- `ChirpKit/Sources/ChirpFeatures/Structure/ClinicalFieldProof.swift`: the round-3 allow-list proof and its grammar.
- `ChirpFeatures.StructuredExtractionService` (writes runs and fields) and `StructureEvalRunner` (eval runs).

## Consumers

The Extract fields card on the Transcript screen, the SOAP note hand-off, the Eval view and its export.

## Stable fields and semantics

- **Tables** (local database only, never exported by default): `structured_runs` (`id`, `transcriptionId` →
  `transcriptions` ON DELETE CASCADE, `catalogVersion`, `engineId`, `modelSha256`, `actThreshold`,
  `provisionalThreshold`, `createdAt`), `structured_fields` (`id`, `runId` → `structured_runs` ON DELETE CASCADE,
  `ordinal`, `tool`, `argumentsJson`, `spanCharStart`, `spanCharEnd`, `spanWordStart`, `spanWordEnd`, `spanStartMs`,
  `spanEndMs`, `confidence`, `verdict`, `reviewReasons` JSON array, `reviewed`, `reviewedAt`) and
  `structured_eval_runs` (synthetic cases only: engine, model hash, catalog version, case count, tool-shape accuracy,
  argument accuracy, numeric hard fails, the JSON report).
- **Gate:** act ≥ `actThreshold` (default 0.85), provisional ≥ `provisionalThreshold` (default 0.60), else
  `needsReview`; any validator problem forces `needsReview`. Thresholds are settings and are stored with each run.
  An unknown stored verdict reads as `needsReview`, never `act`. Every run path (the Extract fields run, the eval
  runner) gets its verdicts from `StructuredResultGate.review(_:engineID:)` and nothing else.
- **Clean means proven (round 3, the allow-list).** A clean field is `act` or `provisional`: what one tap accepts. A
  medication or vital field may be clean **only** when `ClinicalFieldProof` proves all four of:
  1. its sentence parses completely under the written grammar (`ClinicalFieldProof.grammar`). Medication: an optional
     lead from a closed list (subject, helper or status verb: "she takes", "continue", "started", "gave", "hold", "no
     longer"), exactly one drug said once (no other known drug in the sentence), then its one dose (an amount and a
     unit), then how often, then how long, in that order, and words with no number after them; the route said is the
     field's route ("unknown" when none is said, and one route only); the status is the one the verbs say (started for
     start or give, taking for take, continue or no verb, stopped for stop, hold or "no longer", considering for
     consider or might; mixed verbs never pass). Vitals: each value right after its own vital-sign name, with only
     "is", "was", "of", "today", ":" and the like between, the name deciding the kind; a closed list of words before
     the first name ("vitals", "repeat", …; never "last", "prior" or "home");
  2. every number is digits exactly as written, or spoken number words read as one number with no comma, ellipsis or
     period inside, and no number anywhere in the sentence is left outside the tags the grammar placed;
  3. no disqualifier in its sentence or in the next two sentences: a correction cue (every `CrossSentenceCorrection`
     cue plus "my mistake", "that should be", "should read", "instead", …; a following dose with no drug right before
     it; a following short sentence that is a bare number), a limit or condition (less than, greater than, over, under,
     above, below, goal, target, if, unless, when, hold for, up to, at least), a titration (titrate, increase, decrease,
     taper, wean), a range ("4 to 8", "25-50", "between"), a tablet, puff, spray or drop count, "each", a fraction, or
     a day-by-day schedule ("day one", "followed by", weekdays); in its own sentence also "then", a negation ("not",
     "never", "denies") and another time ("yesterday", "previously", "last");
  4. a vital's name is unambiguous: "pulse ox", "sats", "O2" and "SpO2" are oxygen saturation and never a heart rate;
     "rate" or "pressure" alone name nothing.
  A field the proof cannot prove is `needsReview` with **one** reason starting "Couldn't confirm: " in one line
  (for example "Couldn't confirm: the next sentence says “sorry”, which may correct it."), after the more specific
  reasons below. Problems, plan items and allergies are held to one rule only: a number in them, from a sentence that
  says a dose or a vital, is never clean. The STUB stays capped below `act`.
- **Numbers:** a model only copies normalizer tags. Every number is mapped back through the side table, then
  re-read **independently of the normalizer** (`IndependentNumberCheck`: digits by regex, spelled numbers by
  Foundation's spell-out `NumberFormatter`, its own unit list) from its source words, and the words right around it
  are checked (a number said just before a dose, also across "and" / "a" inside a spoken number, which is re-read
  whole: "a hundred and twenty-five micrograms" is 125, never 25; "per kg", "/min", "an hour" just after one, a
  correction word next to any value, a range such as "4 to" before a dose or "to 120" after a rate); any
  disagreement forces review. A range ("4 to 8 mg", "heart rate 100 to 120") is one tag with **no** `value`, a
  display such as "4–8 mg" and a review reason starting "Range:" (the same shape as a correction without a full
  value). A tablet or puff count other than one, or a fraction ("half", "1/2"), near a strength ("25 mg, half a
  tablet") keeps the strength's value and forces review with a reason starting "Tablet count differs from strength:";
  code never computes the dose given. A slash pair followed by a dose unit ("160/25 mg") is a combination strength:
  a dose tag with no `value`, a display as said and a reason starting "Combination strength"; it is never a blood
  pressure. A unit-less slash pair without a pressure word ("BP", "pressure", "vitals", …) before it or "mmHg" after
  it is a blood pressure that needs review. Then it is range-checked (BP 50–260 / 20–160 and systolic above
  diastolic, HR 20–250, RR 4–60, SpO₂ 50–100, temperature 90–110 °F or 32–43.5 °C; a dose > 0 with a unit and at most
  5000 mg, 2000 mcg, 10 g, 50,000 units, 5000 mL, 10 tablets, 12 puffs, 20 drops or 200 mEq; a frequency at most 24 a
  day). A number that traces to nothing is a numeric hard fail. A spoken self-correction always needs review,
  including one said in the next sentence: a sentence that starts with or contains a correction cue
  (`CrossSentenceCorrection.cues`: "sorry", "I mean", "correction", "no wait", "actually", "rather", "make that",
  "scratch that", …) sends every field of the sentence before it to needs review with a reason starting "Corrected in
  the next sentence"; a dose it restates without a drug is named in the previous medication fields, never applied.
- **Every call from a sentence** (review L3 I2–I5): a flagged tag (number or side) or a spoken correction anywhere in
  the sentence forces review on every call from it; a dose or frequency must sit next to its own drug: it belongs to
  the drug right before it, or to the drug right after it when only "of" or a route lies between and that drug has no
  value of its own ("levothyroxine 50 mcg and lisinopril 10 mg": 50 mcg is levothyroxine's; "2 mg of morphine" is
  not ondansetron's), with no same-kind value between and at most eight words apart (re-review I2-R); a vital right after a drug name, or two values for one vital
  in a sentence, needs review; numbers in free text (plan items, problems, names) must be numbers the sentence said;
  an argument the tool does not define, or a non-text value for a text argument, is dropped and flagged.
- **Review state:** `reviewed` is false when saved. Screens show every field as a draft until the person reviews
  it; `act` renders solid, `provisional` dashed, `needsReview` only in the "Needs review" bin, never in the draft. A
  field with review reasons (a failed check) is never accepted in one tap: the review sheet shows its reasons and lets
  the person edit each value first; edits are saved in `argumentsJson` (a tag value becomes
  `{"display", "editedInReview": true}`, and the object gets `"editedInReview": true`), and the reasons stay with the
  field. "Use in SOAP note" sends **only reviewed fields**, each accepted-despite or edited one with its reasons
  (review L3 I7, I8).
- **Spans:** `spanChar*` are UTF-16 offsets into the run's source text (the transcript's words joined by single
  spaces, or its text when it has no words); `spanWord*` index `Transcription.wordTimestamps`; `spanStartMs` /
  `spanEndMs` let a tap seek the player. A field with a number spans that number's words; otherwise its sentence. The card
  shows the whole sentence with the number's words highlighted, so the reviewer sees which drug or vital it belongs to
  (review L3 I2).
- **Privacy:** clinical items only ever run on `.onDevice` structure engines. Logs carry run ids and counts only.

## Non-stable fields

Wording of review reasons, `argumentsJson` key order, eval report layout beyond the three headline numbers.

## Versioning and compatibility

Migrations are never edited; a schema change is a new migration. A new catalog version is a new `catalogVersion`
value; old runs keep theirs.

## Tests that enforce this

- `ChirpStoreTests.StructuredResultsMigrationTests` (tables, upgrade from `v6-documents`, round trip, review,
  cascade delete, eval runs).
- `ChirpFeaturesTests.ClinicalSafetyCorpusTests` (round 3: every phrase of `Fixtures/clinical-safety-corpus.json`,
  243 invented entries, through the real normalizer, STUB, validator, independent check, proof and gate: never clean
  and wrong; about 11,500 hand-built right and wrong Needle answers at 0.9: a wrong one is never clean; "scratch that"
  never drops an earlier order or keeps part of one).
- `ChirpFeaturesTests.StructuredResultGateTests` (0.849 / 0.85 / 0.599 / 0.60 boundaries, forced review, the
  independent re-parse against hand-built wrong side tables, neighbour checks, drug adjacency, sentence-wide
  corrections, free-text numbers, unknown arguments, per-unit ranges, hard fails, spans to words and milliseconds;
  round 3: only a proven field is clean, one reason per condition, the next two sentences, the written grammar).
- `ChirpFeaturesTests.StructuredExtractionServiceTests` (clinical never reaches a non-on-device engine; runs saved
  with spans; the evidence sentence; the STUB never `act`; only reviewed fields in the SOAP hand-off; a failed check
  needs the review sheet, keeps its reasons and saves edits; a correction in the next sentence, in the service and
  the eval).
- `ChirpTextTests.NumericNormalizerTests` (spoken numbers across "and", ranges, tablet counts near a strength,
  combination strengths and the blood-pressure word).

## When this changes

Update this file, `spec/01-data-model.md`, the ChirpStore and ChirpFeatures READMEs and the tests above together.
