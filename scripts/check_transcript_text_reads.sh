#!/usr/bin/env bash
# Fails when code reads a transcript's baseline text fields directly instead of through the one accessor
# (`Transcription.text(_:context:)` / `plainText(_:context:)` in ChirpKit/Sources/ChirpText/TranscriptText.swift).
# Plan 025 D3 / requirement R1 (contract spec/contracts/transcript-corrections-v1.md): the person's corrections and a
# dictation's voice commands enter the text there and nowhere else, so a consumer that reads `rawTranscript`,
# `cleanTranscript`, `displayText`, `wordTimestamps` or `transcriptSegments` itself would show, export or send the
# uncorrected words.
#
# Usage: scripts/check_transcript_text_reads.sh
#
# Scans ChirpKit/Sources and App/Sources (Swift files). Comment lines are ignored. A line may carry the marker
# `text-read-guard: evidence` when it deliberately reads the words as heard (the JSON export's `words`).
# Allowed everywhere in:
#   - ChirpCore and ChirpStore (the model and its persistence),
#   - ChirpText/TranscriptText.swift (the accessor),
#   - the writers of the baseline (plan 025 C7 row W): FileTranscriptionPipeline, MeetingFinalizer,
#     DictationCoordinator, LinkIngestService, DocumentImportPipeline, TextItemService,
#   - ChirpFeatures/Benchmark/ and App/Sources/Debug/SmokeTestRunner.swift (they measure the engine's own words).
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='\.(rawTranscript|cleanTranscript|displayText|wordTimestamps|transcriptSegments)\b'

allowed() {
  case "$1" in
    ChirpKit/Sources/ChirpCore/* | ChirpKit/Sources/ChirpStore/*) return 0 ;;
    ChirpKit/Sources/ChirpText/TranscriptText.swift) return 0 ;;
    ChirpKit/Sources/ChirpFeatures/FileTranscriptionPipeline.swift) return 0 ;;
    ChirpKit/Sources/ChirpFeatures/Meeting/MeetingFinalizer.swift) return 0 ;;
    ChirpKit/Sources/ChirpFeatures/Dictation/DictationCoordinator.swift) return 0 ;;
    ChirpKit/Sources/ChirpFeatures/LinkIngestService.swift) return 0 ;;
    ChirpKit/Sources/ChirpFeatures/DocumentImportPipeline.swift) return 0 ;;
    ChirpKit/Sources/ChirpFeatures/Create/TextItemService.swift) return 0 ;;
    ChirpKit/Sources/ChirpFeatures/Benchmark/*) return 0 ;;
    App/Sources/Debug/SmokeTestRunner.swift) return 0 ;;
  esac
  return 1
}

# Nothing is pending: plan 025 Step A8 routed every App screen. Keep the hook for a later staged migration.
pending() {
  return 1
}

offenders=0
waiting=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file=${hit%%:*}
  rest=${hit#*:}
  code=${rest#*:}
  # Comment lines and lines marked as deliberate reads of the evidence.
  if [[ "$code" =~ ^[[:space:]]*// ]] || [[ "$code" == *"text-read-guard: evidence"* ]]; then
    continue
  fi
  if allowed "$file"; then
    continue
  fi
  if pending "$file"; then
    echo "pending: $hit" >&2
    waiting=$((waiting + 1))
    continue
  fi
  echo "baseline text read outside the accessor: $hit" >&2
  offenders=$((offenders + 1))
done < <(grep -rnE "$pattern" ChirpKit/Sources App/Sources --include='*.swift' || true)

if [ "$offenders" -gt 0 ]; then
  echo "FAIL: $offenders baseline text read(s) outside the allow-list; read Transcription.text(_:context:) instead" >&2
  exit 1
fi
if [ "$waiting" -gt 0 ]; then
  echo "OK: no baseline text reads outside the allow-list ($waiting pending)"
else
  echo "OK: no baseline text reads outside the allow-list"
fi
