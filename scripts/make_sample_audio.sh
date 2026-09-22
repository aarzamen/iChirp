#!/usr/bin/env bash
# Regenerates the synthetic two-voice sample with macOS `say` (no real recordings, no PHI).
#
# Usage: scripts/make_sample_audio.sh [--wav [out.wav]]
#   scripts/make_sample_audio.sh            # writes App/Resources/Samples/sample-two-voices.m4a (AAC)
#   scripts/make_sample_audio.sh --wav      # writes ChirpKit/Tests/ChirpEngineFluidAudioTests/Fixtures/two-voices-16k.wav
#   scripts/make_sample_audio.sh --wav x.wav   # writes the 16 kHz 16-bit mono WAV to x.wav (relative to where you ran it)
#
# Voice A (Samantha, else the first other English voice): "The quick brown fox jumps over the lazy dog."
# Voice B (Daniel, else a second, different English voice): "Parakeet runs entirely on this iPhone."
# Each line is rendered as 16 kHz 16-bit PCM WAV, then joined with 0.6 s of silence.
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "$0")/.."

LINE_A="The quick brown fox jumps over the lazy dog."
LINE_B="Parakeet runs entirely on this iPhone."
M4A_OUT="App/Resources/Samples/sample-two-voices.m4a"
WAV_DEFAULT="ChirpKit/Tests/ChirpEngineFluidAudioTests/Fixtures/two-voices-16k.wav"

MODE="m4a"
WAV_OUT="$WAV_DEFAULT"
if [ "${1:-}" = "--wav" ]; then
  MODE="wav"
  if [ -n "${2:-}" ]; then
    case "$2" in
      /*) WAV_OUT="$2" ;;
      *) WAV_OUT="$CALLER_PWD/$2" ;;
    esac
  fi
elif [ -n "${1:-}" ]; then
  echo "usage: scripts/make_sample_audio.sh [--wav [out.wav]]" >&2
  exit 2
fi

for tool in say afconvert python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found (this script needs macOS)." >&2
    exit 1
  fi
done

# Pick two distinct English voices, preferring Samantha and Daniel.
VOICES=$(say -v '?' | awk '$2 ~ /^en[_-]/ {print $1}')
has_voice() { printf '%s\n' "$VOICES" | grep -qx "$1"; }
VOICE_A="Samantha"
VOICE_B="Daniel"
if ! has_voice "$VOICE_A"; then
  VOICE_A=$(printf '%s\n' "$VOICES" | grep -vx "$VOICE_B" | head -1)
fi
if ! has_voice "$VOICE_B" || [ "$VOICE_B" = "$VOICE_A" ]; then
  VOICE_B=$(printf '%s\n' "$VOICES" | grep -vx "$VOICE_A" | head -1)
fi
if [ -z "$VOICE_A" ] || [ -z "$VOICE_B" ]; then
  echo "error: need two different English voices for 'say' (System Settings → Accessibility → Spoken Content)." >&2
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ichirp-sample.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

say -v "$VOICE_A" -o "$WORK/a.wav" --file-format=WAVE --data-format=LEI16@16000 "$LINE_A"
say -v "$VOICE_B" -o "$WORK/b.wav" --file-format=WAVE --data-format=LEI16@16000 "$LINE_B"

python3 - "$WORK/a.wav" "$WORK/b.wav" "$WORK/two-voices-16k.wav" <<'PY'
import array
import sys
import wave

first, second, out = sys.argv[1:4]
RATE, WIDTH, CHANNELS, GAP_SECONDS = 16000, 2, 1, 0.6

def read_pcm(path):
    with wave.open(path, "rb") as w:
        params = (w.getframerate(), w.getsampwidth(), w.getnchannels())
        if params != (RATE, WIDTH, CHANNELS):
            sys.exit(f"{path}: expected 16 kHz 16-bit mono, got {params}")
        return w.readframes(w.getnframes())

silence = array.array("h", [0] * int(RATE * GAP_SECONDS)).tobytes()
with wave.open(out, "wb") as w:
    w.setnchannels(CHANNELS)
    w.setsampwidth(WIDTH)
    w.setframerate(RATE)
    w.writeframes(read_pcm(first) + silence + read_pcm(second))
PY

if [ "$MODE" = "wav" ]; then
  mkdir -p "$(dirname "$WAV_OUT")"
  cp "$WORK/two-voices-16k.wav" "$WAV_OUT"
  OUT="$WAV_OUT"
else
  mkdir -p "$(dirname "$M4A_OUT")"
  afconvert -f m4af -d aac "$WORK/two-voices-16k.wav" "$M4A_OUT"
  OUT="$M4A_OUT"
fi

echo "Voices: A=$VOICE_A, B=$VOICE_B"
echo "Wrote $OUT"
afinfo "$OUT" | grep -E 'Data format|estimated duration' || true
