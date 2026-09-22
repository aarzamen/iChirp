# Transcript JSON v1

> Status: ACTIVE — the `ichirp.transcript/v1` JSON export produced by Share → JSON.

## Purpose

Give the user (and any tool or agent they hand the file to) a lossless, machine-readable transcript: text, words
with timings, speakers and segments, plus enough provenance to know which engine produced it. It must stay readable
by future iChirp versions and by simple scripts.

## Producers

- `ChirpExport.TranscriptExporter.render(_:as: .json)` and `write(_:as: .json, to:)`.

## Consumers

- The user, through the Share sheet (saved to Files, sent to a computer).
- Scripts and agents that post-process transcripts.
- A future iChirp import (not built), which must accept every v1 file.

## Stable fields

A single JSON object encoded with sorted keys, pretty-printed, UTF-8:

| Key | Type | Meaning |
|---|---|---|
| `schema` | string | Always `"ichirp.transcript/v1"` |
| `id` | string (UUID) | The transcript's id |
| `title` | string | `displayTitle` (user rename, else derived title, else file name without extension) |
| `createdAt` | string | ISO-8601 date-time |
| `durationMs` | integer or absent/null | Source duration |
| `engine` | string or absent/null | `EngineDescriptor.id`, e.g. `fluidaudio.parakeet-tdt` |
| `engineVariant` | string or absent/null | e.g. `v3` |
| `language` | string or absent/null | BCP-47 when known |
| `text` | string | Plain text in the exporter's clean-up mode (Raw: the engine text; Clean: `cleanTranscript` when present) |
| `speakers` | array | `{ "id": "S1", "label": "Speaker 1" }`; empty when no speakers |
| `segments` | array | `{ "id", "startMs", "endMs", "speakerId", "speakerLabel", "text", "wordRange": { "startIndex", "endIndexExclusive" } }` |
| `words` | array | `{ "word", "startMs", "endMs", "confidence", "speakerId" }`, times in milliseconds from the start of the source |

Semantics: `words` are in time order; `segments[i].wordRange` indexes into `words` (half-open); every `speakerId`
that appears in `words` or `segments` appears in `speakers`.

## Non-stable fields

- Whitespace and indentation; key order beyond "sorted".
- Whether an absent optional value is omitted or written as `null`: consumers must accept both.
- Floating-point formatting of `confidence`.
- The exported file name (sanitized title plus `.json`).

## Versioning and compatibility

New optional keys may be added to v1 (consumers ignore unknown keys). Removing or renaming a key, changing a unit
(milliseconds), or changing `wordRange` semantics requires `ichirp.transcript/v2`, a new contract document, and an
importer that still reads v1.

## Tests that enforce this

- `TranscriptExporterTests.testJSONSchemaKey` (the `schema` value).
- `TranscriptExporterTests` JSON round-trip cases ported from upstream `ExportServiceTests`.
- `TranscriptionCodingTests.testJSONRoundTripPreservesEveryField` (the nested record shapes in `ChirpCore`).

## When this changes

Update this contract, [spec/07](../07-text-processing.md#exports-chirpexport), the `ChirpExport` README and the
tests above in the same commit.
