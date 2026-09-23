#!/usr/bin/env bash
# On the iPhone: installs the Debug build, runs the DEBUG on-device ASR benchmark over the bundled synthetic reference
# set, copies Documents/asr-device-benchmark.json off the phone and prints one line per engine (WER, × real time, load
# time, peak memory). Exits non-zero when the run failed or any requested engine failed.
#
# Usage: scripts/device_benchmark.sh [engines]
#   scripts/device_benchmark.sh                                   # parakeet,whisper-base,whisper-turbo,apple-speech
#   scripts/device_benchmark.sh parakeet,whisper-base             # a subset (names: parakeet, whisper-base,
#                                                                 # whisper-turbo, apple-speech, or all)
#   DEVICE_ID=<identifier> scripts/device_benchmark.sh            # the device: DEVICE_ID, else Config/Device.local
#                                                                 # — nothing else. This downloads models to the
#                                                                 # phone, so it uses run_device.sh's
#                                                                 # --print-pinned-device / PINNED_DEVICE_ONLY,
#                                                                 # which never falls back to "the one reachable
#                                                                 # iPhone".
#   BENCH_TIMEOUT_S=3600 scripts/device_benchmark.sh              # wait longer than the default 1800 s
#   scripts/device_benchmark.sh --report <file.json>              # print the table for a result file; no phone
#
# Engines whose model is missing are downloaded on the phone (Whisper Base about 150 MB, Large v3 Turbo about 650 MB,
# Parakeet about 0.5 GB): keep the phone unlocked, on Wi-Fi, with Parakeet in the foreground. The first use of a
# Whisper model also compiles it for the Neural Engine, which can take minutes. Apple Speech is skipped with
# "permission-needed" until Speech Recognition has been allowed once (Settings → Speech engines → Apple Speech →
# Download): that system prompt cannot be tapped from here.
#
# Needs the app's DEBUG device benchmark (launch argument -ChirpBenchmarkDevice). Like the other device scripts it
# never passes xcodebuild's provisioning-update or device-registration flags (see scripts/run_device.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.aarzamen.ichirp"
APP_PATH=".build/xcode/Build/Products/Debug-iphoneos/iChirp.app"
RESULT_NAME="asr-device-benchmark.json"
RESULT_LOCAL=".build/$RESULT_NAME"
KEEP_DIR=".build/device-benchmarks"
COPY_LOG=".build/device-logs/benchmark-copy.log"
TIMEOUT_S="${BENCH_TIMEOUT_S:-1800}"
POLL_S=15

# Prints the table for a result file; exits 1 when the run failed or any engine failed.
print_report() {
  python3 - "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))

def number(value, fmt):
    return format(value, fmt) if isinstance(value, (int, float)) else "–"

print(f"device:   {data.get('deviceModel', '?')} ({data.get('device', '?')})")
print(f"build:    {data.get('build', '?')}")
print(f"commit:   {data.get('buildSHA', '?')}")
print(f"status:   {data.get('status')}" + (f" ({data.get('error')})" if data.get("error") else ""))
print("")
header = f"{'engine':<15}{'outcome':<10}{'WER':>8}{'x RT':>9}{'load ms':>10}{'peak MB':>10}{'dl ms':>9}  reason"
print(header)
print("-" * len(header))
failed = []
for engine in data.get("engines", []):
    wer = engine.get("wordErrorRate")
    peak = engine.get("peakMemoryBytes")
    print(
        f"{engine.get('name', '?'):<15}{engine.get('outcome', '?'):<10}"
        f"{(number(wer * 100, '.1f') + '%') if isinstance(wer, (int, float)) else '–':>8}"
        f"{number(engine.get('timesRealTime'), '.1f'):>9}"
        f"{number(engine.get('loadMs'), 'd'):>10}"
        f"{number(peak / 1048576 if isinstance(peak, (int, float)) else None, '.0f'):>10}"
        f"{number(engine.get('downloadMs'), 'd'):>9}"
        f"  {engine.get('reason') or ''}"
    )
    if engine.get("outcome") == "failed":
        failed.append(engine.get("name", "?"))
print("")
print("WER: word error rate over the synthetic set (lower is better). x RT: audio length / transcription time")
print("(higher is faster). load: model load after an unload. peak: the app's peak memory while the engine ran.")
if data.get("status") != "completed":
    print(f"BENCH FAIL: {data.get('error') or 'status ' + str(data.get('status'))}", file=sys.stderr)
    sys.exit(1)
if failed:
    print(f"BENCH FAIL: engine(s) failed: {', '.join(failed)}", file=sys.stderr)
    sys.exit(1)
print("BENCH DONE")
PY
}

if [ "${1:-}" = "--report" ]; then
  if [ -z "${2:-}" ] || [ ! -f "$2" ]; then
    echo "usage: scripts/device_benchmark.sh --report <asr-device-benchmark.json>" >&2
    exit 2
  fi
  print_report "$2"
  exit $?
fi

ENGINES="${1:-parakeet,whisper-base,whisper-turbo,apple-speech}"
case "$ENGINES" in
  -*) echo "error: unknown option $ENGINES (see the usage at the top of this script)" >&2; exit 2 ;;
esac

# This downloads models to the phone, so it never guesses the device: --print-pinned-device refuses, with a clear
# message, instead of falling back to "the one reachable iPhone" the way plain --print-device would.
DEVICE_ID="$(scripts/run_device.sh --print-pinned-device)"
export DEVICE_ID
export PINNED_DEVICE_ONLY=1

mkdir -p .build/device-logs "$KEEP_DIR"
scripts/run_device.sh -- -ChirpBenchmarkDevice "$ENGINES"

# The build we just installed; a result file left over from an older install is ignored.
EXPECTED_BUILD_DATE=$(/usr/libexec/PlistBuddy -c "Print :ChirpBuildDateUTC" "$APP_PATH/Info.plist" 2>/dev/null || true)

echo "Waiting up to ${TIMEOUT_S}s for Documents/$RESULT_NAME (polling every ${POLL_S}s) ..."
start=$(date +%s)
state=""
while :; do
  rm -f "$RESULT_LOCAL"
  if xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "Documents/$RESULT_NAME" --destination "$RESULT_LOCAL" --quiet >"$COPY_LOG" 2>&1 \
    && [ -s "$RESULT_LOCAL" ]; then
    # pending = still running or a file from an older build; done = a terminal status from this build
    state=$(python3 - "$RESULT_LOCAL" "$EXPECTED_BUILD_DATE" <<'PY'
import json, sys
path, expected = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except ValueError:
    print("pending")  # partially written
    sys.exit(0)
build = str(data.get("build", ""))
if expected and build and expected not in build:
    print("pending")  # from an older install
elif data.get("status") in ("completed", "failed"):
    print("done")
else:
    print("pending")
PY
    )
    [ "$state" = "done" ] && break
  fi
  elapsed=$(($(date +%s) - start))
  if [ "$elapsed" -ge "$TIMEOUT_S" ]; then
    echo "" >&2
    echo "BENCH FAIL: Documents/$RESULT_NAME from this build did not finish in the $BUNDLE_ID container" >&2
    echo "on device $DEVICE_ID within ${TIMEOUT_S}s." >&2
    echo "Check, in order:" >&2
    echo "  1. The phone is unlocked, on Wi-Fi, and Parakeet stayed in the foreground (downloads and first compiles)." >&2
    echo "  2. The installed Debug build contains the device benchmark (-ChirpBenchmarkDevice)." >&2
    echo "  3. The app did not crash: Xcode → Window → Devices and Simulators → View Device Logs." >&2
    echo "  4. A slow first Whisper Large v3 Turbo compile: rerun with BENCH_TIMEOUT_S=3600." >&2
    if [ -s "$RESULT_LOCAL" ]; then
      echo "Last file seen (still running, or from an older build): $RESULT_LOCAL" >&2
    elif [ -s "$COPY_LOG" ]; then
      echo "Last devicectl message: $(tail -1 "$COPY_LOG")" >&2
    fi
    if grep -qiE 'device (is|was) locked|passcode protected|could not be,? unlocked' "$COPY_LOG" 2>/dev/null; then
      echo "Unlock your iPhone and rerun." >&2
    fi
    exit 1
  fi
  sleep "$POLL_S"
done

KEPT="$KEEP_DIR/asr-device-benchmark-$(date -u +%Y%m%dT%H%M%SZ).json"
cp "$RESULT_LOCAL" "$KEPT"
echo "Result: $KEPT"
echo ""
print_report "$KEPT"
