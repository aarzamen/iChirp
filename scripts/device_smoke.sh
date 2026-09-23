#!/usr/bin/env bash
# On the iPhone: installs the Debug build, runs the DEBUG smoke transcription of the bundled synthetic two-voice
# sample, fetches Documents/smoke-result.json from the app container and asserts the words. Prints SMOKE PASS.
#
# Usage: scripts/device_smoke.sh
#   DEVICE_ID=<identifier> scripts/device_smoke.sh     # same device choice as scripts/run_device.sh
#   SMOKE_TIMEOUT_S=900 scripts/device_smoke.sh        # wait longer than the default 600 s
#   SMOKE_CONSOLE=1 scripts/device_smoke.sh            # also launch with `devicectl ... --console`, backgrounded,
#                                                       # saving the app's stdout/stderr (including FluidAudio's
#                                                       # Debug-only download logging) to .build/device-logs/
#
# The first run downloads ~0.5 GB of models on the phone: keep it unlocked and on Wi-Fi.
# Needs the app's DEBUG smoke runner (launch argument -ChirpSmoke transcribe-sample). The smoke always transcribes with
# Parakeet, whatever engine Settings → Speech engines has saved for Transcripts (the saved choice is never changed), and
# the result's "engine" must say so.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.aarzamen.ichirp"
APP_PATH=".build/xcode/Build/Products/Debug-iphoneos/iChirp.app"
RESULT_LOCAL=".build/smoke-result.json"
COPY_LOG=".build/device-logs/smoke-copy.log"
TIMEOUT_S="${SMOKE_TIMEOUT_S:-600}"
POLL_S=10

# Same device rules as run_device.sh (DEVICE_ID, Config/Device.local, or the single reachable iPhone).
DEVICE_ID="$(scripts/run_device.sh --print-device)"
export DEVICE_ID

scripts/run_device.sh -- -ChirpSmoke transcribe-sample

# The build we just installed; a smoke-result.json left over from an older install is ignored.
EXPECTED_BUILD_DATE=$(/usr/libexec/PlistBuddy -c "Print :ChirpBuildDateUTC" "$APP_PATH/Info.plist" 2>/dev/null || true)

echo "Waiting up to ${TIMEOUT_S}s for Documents/smoke-result.json (polling every ${POLL_S}s) ..."
start=$(date +%s)
state=""
while :; do
  rm -f "$RESULT_LOCAL"
  if xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/smoke-result.json --destination "$RESULT_LOCAL" --quiet >"$COPY_LOG" 2>&1 \
    && [ -s "$RESULT_LOCAL" ]; then
    # pending = still running or a stale file from an older build; done = terminal status
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
elif str(data.get("status", "")).lower() in ("completed", "failed", "error", "cancelled"):
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
    echo "SMOKE FAIL: Documents/smoke-result.json from this build never appeared in the $BUNDLE_ID container" >&2
    echo "on device $DEVICE_ID within ${TIMEOUT_S}s." >&2
    echo "Check, in order:" >&2
    echo "  1. The phone is unlocked, on Wi-Fi, and Parakeet stayed in the foreground (first run downloads ~0.5 GB)." >&2
    echo "  2. The installed Debug build contains the smoke runner (-ChirpSmoke transcribe-sample)." >&2
    echo "  3. The app did not crash: Xcode → Window → Devices and Simulators → View Device Logs." >&2
    if [ -s "$RESULT_LOCAL" ]; then
      echo "Last file seen (older build or unfinished): $RESULT_LOCAL" >&2
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

python3 - "$RESULT_LOCAL" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
text = str(data.get("text", ""))
problems = []
if data.get("status") != "completed":
    problems.append(f"status is {data.get('status')!r}, expected 'completed'" +
                    (f" (error: {data.get('error')})" if data.get("error") else ""))
if "quick brown fox" not in text.lower():
    problems.append("text does not contain 'quick brown fox'")
if "iphone" not in text.lower():
    problems.append("text does not contain 'iphone'")
engine = str(data.get("engine") or "")
if data.get("status") == "completed" and not engine.startswith("fluidaudio.parakeet-tdt"):
    problems.append(f"engine is {engine!r}, expected Parakeet (fluidaudio.parakeet-tdt)")

print(f"text:          {text}")
for key in ("engine", "elapsedMs", "modelLoadMs", "speakerCount", "peakMemoryMB", "wordCount", "build"):
    print(f"{key + ':':<15}{data.get(key, 'n/a')}")
if problems:
    for problem in problems:
        print(f"SMOKE FAIL: {problem}", file=sys.stderr)
    sys.exit(1)
print("SMOKE PASS")
PY
