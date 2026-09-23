#!/usr/bin/env bash
# Regenerates the synthetic ASR benchmark reference set with macOS `say` (known text, no real recordings, no PHI).
#
# Usage: scripts/make_benchmark_audio.sh [out-dir]
#   scripts/make_benchmark_audio.sh              # writes App/Resources/Benchmark/ (bundled in the app)
#   scripts/make_benchmark_audio.sh /tmp/bench   # writes the same set somewhere else
#
# Writes asr-bench-<id>.m4a (AAC, from 16 kHz 16-bit mono PCM) plus asr-benchmark-reference.json, the manifest
# `ASRBenchmarkReferenceSet` reads (id, file, voice, text). The texts avoid digits and number words so every engine is
# scored by the same simple normalizer (upstream benchmarks/asr/score.py --simple). Voices are chosen from the
# installed English voices, preferring Samantha, Daniel, Karen, Moira and Tessa; each clip's voice is recorded.
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "$0")/.."

OUT="App/Resources/Benchmark"
if [ -n "${1:-}" ]; then
  case "$1" in
    /*) OUT="$1" ;;
    *) OUT="$CALLER_PWD/$1" ;;
  esac
fi

for tool in say afconvert python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found (this script needs macOS)." >&2
    exit 1
  fi
done

IDS=(fox meeting clinic science directions)
TEXTS=(
  "The quick brown fox jumps over the lazy dog while the farmer watches from the porch."
  "Let's move the design review to Thursday afternoon and ask the team to send their notes before lunch."
  "The patient reports a mild headache and a sore throat since yesterday. No fever. Plan rest, fluids and a follow up visit next week."
  "Photosynthesis turns sunlight, water and carbon dioxide into sugar and oxygen inside the leaves of green plants."
  "Turn left at the old library, walk past the bakery, and the museum entrance is on your right."
)
PREFERRED=(Samantha Daniel Karen Moira Tessa)

VOICES=$(say -v '?' | awk '$2 ~ /^en[_-]/ {print $1}')
has_voice() { printf '%s\n' "$VOICES" | grep -qx "$1"; }
FALLBACK=$(printf '%s\n' "$VOICES" | head -1)
if [ -z "$FALLBACK" ]; then
  echo "error: no English voice for 'say' (System Settings → Accessibility → Spoken Content)." >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ichirp-bench.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

MANIFEST="$WORK/entries.tsv"
: > "$MANIFEST"
for i in "${!IDS[@]}"; do
  id="${IDS[$i]}"
  text="${TEXTS[$i]}"
  voice="${PREFERRED[$i]}"
  has_voice "$voice" || voice="$FALLBACK"
  say -v "$voice" -o "$WORK/$id.wav" --file-format=WAVE --data-format=LEI16@16000 "$text"
  afconvert -f m4af -d aac "$WORK/$id.wav" "$OUT/asr-bench-$id.m4a"
  printf '%s\t%s\t%s\t%s\n' "$id" "asr-bench-$id.m4a" "$voice" "$text" >> "$MANIFEST"
  echo "Wrote $OUT/asr-bench-$id.m4a ($voice)"
done

python3 - "$MANIFEST" "$OUT/asr-benchmark-reference.json" <<'PY'
import json
import sys

entries = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        ident, file, voice, text = line.rstrip("\n").split("\t")
        entries.append({"id": ident, "file": file, "voice": voice, "text": text})
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump({"version": 1, "entries": entries}, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
echo "Wrote $OUT/asr-benchmark-reference.json"
