#!/usr/bin/env bash
# M3 Step 1 harness (Mac only): writes a synthetic 440 Hz tone at 16 kHz in real time with four writers, kills the
# writer with SIGKILL after ~5.3 s (the process kills itself, like a crash or a force-quit), then reports how much of
# each file is still readable. Then one hour of audio written unpaced and killed at 3600 s.
# Results and the decision: docs/research/2026-09-22-meeting-crash-format.md. Writes only into a temp folder.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O "$here/writer.swift" -o "$work/writer"
swiftc -O "$here/reader.swift" -o "$work/reader"
cd "$work"
for pair in fmp4:rec.m4a caf:rec.caf wav:rec.wav m4a-plain:plain.m4a; do
  format="${pair%%:*}"; file="${pair##*:}"
  ./writer "$format" "$file" 30 5.3 >/dev/null 2>&1 || true
  ./reader "$file"
done
for pair in fmp4:long.m4a caf:long.caf; do
  format="${pair%%:*}"; file="${pair##*:}"
  NOPACE=1 ./writer "$format" "$file" 4000 3600 >/dev/null 2>&1 || true
  ./reader "$file"
done
