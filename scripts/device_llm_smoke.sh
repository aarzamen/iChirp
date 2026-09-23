#!/usr/bin/env bash
# On the iPhone: installs the Debug build and runs the DEBUG on-device language-model measurement (review I3). The app
# downloads the model if it is missing (1.3 GB for the 2B, 2.5 GB for the 4B), writes a SOAP note of an invented,
# number-dense visit twice (cold load, then warm) through the real DeliverableService path, and saves
# Documents/llm-smoke.json. This script fetches that file, prints the numbers and says LLM SMOKE PASS when the run
# completed and every number survived verbatim.
#
# Usage: scripts/device_llm_smoke.sh [model]            # model: qwen3.5-2b (default) or qwen3-4b, or a full catalog id
#   DEVICE_ID=<identifier> scripts/device_llm_smoke.sh  # the device: DEVICE_ID, else Config/Device.local — nothing
#                                                       # else. Unlike run_device.sh's other callers, this script
#                                                       # never falls back to "the one reachable iPhone": it
#                                                       # downloads 1.3-2.5 GB to the phone and writes a synthetic
#                                                       # clinical row to its Library, so guessing the device is not
#                                                       # acceptable (review N4). Neither set: refuses, exit 1.
#   LLM_SMOKE_TIMEOUT_S=3600 scripts/device_llm_smoke.sh qwen3-4b   # wait longer than the default 1800 s
#   SMOKE_CONSOLE=1 scripts/device_llm_smoke.sh         # also stream the app's stdout/stderr to .build/device-logs/
#
# Keep the phone unlocked, on Wi-Fi, with Parakeet in the foreground: the model runs only while the app is on screen
# (the runner keeps the screen awake). Nothing here is a real patient. Needs the app's DEBUG runner
# (launch argument -ChirpLLMSmoke <model>).
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${1:-qwen3.5-2b}"
BUNDLE_ID="com.aarzamen.ichirp"
APP_PATH=".build/xcode/Build/Products/Debug-iphoneos/iChirp.app"
SAFE_MODEL=$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9._-' '_')
RESULT_LOCAL=".build/llm-smoke-${SAFE_MODEL}.json"
COPY_LOG=".build/device-logs/llm-smoke-copy.log"
TIMEOUT_S="${LLM_SMOKE_TIMEOUT_S:-1800}"
POLL_S=10
RUN_ID="$(uuidgen)"
mkdir -p .build/device-logs

# This script downloads 1.3-2.5 GB to the phone and writes a synthetic clinical row to its Library, so — unlike
# run_device.sh's other callers, which may fall back to "the one reachable iPhone" — it never guesses the device
# (review N4). Refuse here, before run_device.sh runs at all, unless the device is named explicitly.
if [ -z "${DEVICE_ID:-}" ]; then
  CONFIG_DEVICE_ID=""
  if [ -f Config/Device.local ]; then
    CONFIG_DEVICE_ID=$(sed -nE 's/^[[:space:]]*DEVICE_ID[[:space:]]*=[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' \
      Config/Device.local | head -1)
  fi
  if [ -z "$CONFIG_DEVICE_ID" ]; then
    echo "error: device_llm_smoke.sh never guesses which iPhone to use (it downloads 1.3-2.5 GB and writes a" >&2
    echo "synthetic clinical row to the phone's Library). Set DEVICE_ID=<identifier>, or add" >&2
    echo "DEVICE_ID=<identifier> to Config/Device.local (copy Config/Device.local.example), then rerun." >&2
    exit 1
  fi
fi

# DEVICE_ID (just checked above) or Config/Device.local (just confirmed to have one): never the reachable-iPhone
# fallback, because one of those two is now guaranteed.
DEVICE_ID="$(scripts/run_device.sh --print-device)"
export DEVICE_ID
echo "Device: $DEVICE_ID   model: $MODEL   run: $RUN_ID"

scripts/run_device.sh -- -ChirpLLMSmoke "$MODEL" -ChirpLLMSmokeRun "$RUN_ID"

echo "Waiting up to ${TIMEOUT_S}s for Documents/llm-smoke.json of run $RUN_ID (polling every ${POLL_S}s) ..."
start=$(date +%s)
state=""
last_line=""
while :; do
  rm -f "$RESULT_LOCAL"
  if xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/llm-smoke.json --destination "$RESULT_LOCAL" --quiet >"$COPY_LOG" 2>&1 \
    && [ -s "$RESULT_LOCAL" ]; then
    # "pending <what>" while running, "done" at a terminal status; files from another run are ignored.
    state=$(python3 - "$RESULT_LOCAL" "$RUN_ID" <<'PY'
import json, sys
path, run_id = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except ValueError:
    print("pending partial")
    sys.exit(0)
if data.get("runID") != run_id:
    print("pending waiting for this run to start")
elif str(data.get("status", "")).lower() in ("completed", "failed"):
    print("done")
elif data.get("status") == "downloading":
    fraction = data.get("downloadFraction") or 0
    print(f"pending downloading {data.get('modelID', '')} {fraction * 100:.0f}%")
else:
    print(f"pending {data.get('status', 'running')} {data.get('modelID', '')}")
PY
    )
    [ "$state" = "done" ] && break
    if [ "$state" != "$last_line" ]; then
      echo "  ${state#pending }"
      last_line="$state"
    fi
  fi
  elapsed=$(($(date +%s) - start))
  if [ "$elapsed" -ge "$TIMEOUT_S" ]; then
    echo "" >&2
    echo "LLM SMOKE FAIL: Documents/llm-smoke.json for run $RUN_ID never reached a final status in the $BUNDLE_ID" >&2
    echo "container on device $DEVICE_ID within ${TIMEOUT_S}s." >&2
    echo "Check, in order:" >&2
    echo "  1. The phone is unlocked, on Wi-Fi, and Parakeet stayed on screen (the first run downloads the model)." >&2
    echo "  2. The installed Debug build contains the runner (-ChirpLLMSmoke) and llama.cpp (scripts/build_llamacpp.sh)." >&2
    echo "  3. The app did not crash or get terminated for memory: Xcode → Window → Devices and Simulators → View" >&2
    echo "     Device Logs (a JetsamEvent report means the model did not fit)." >&2
    if [ -s "$RESULT_LOCAL" ]; then
      echo "Last file seen: $RESULT_LOCAL" >&2
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
problems = []
if data.get("status") != "completed":
    problems.append(f"status is {data.get('status')!r}, expected 'completed'" +
                    (f" (error: {data.get('error')})" if data.get("error") else ""))
elif data.get("numbersSurvived") is not True:
    problems.append(f"numbers did not survive: missing {data.get('missingNumbers')}, "
                    f"unexpected {data.get('unexpectedNumbers')}")

warm = data.get("warm") or {}
rows = [
    ("model", data.get("modelID") or data.get("requested")),
    ("device", data.get("device")),
    ("build", data.get("build")),
    ("gpu", data.get("usesGPU")),
    ("downloaded now", data.get("downloaded")),
    ("download ms", data.get("downloadMs")),
    ("available MB before load", data.get("availableMemoryBeforeMB")),
    ("estimated MB", data.get("estimatedMemoryMB")),
    ("load ms (cold)", data.get("loadMs")),
    ("first token ms (cold)", data.get("firstTokenMs")),
    ("time to first text ms (cold)", data.get("timeToFirstTextMs")),
    ("prompt tokens", data.get("promptTokens")),
    ("completion tokens", data.get("completionTokens")),
    ("prompt tok/s", data.get("promptTokensPerSecond")),
    ("tok/s (cold)", data.get("tokensPerSecond")),
    ("whole note ms (cold)", data.get("totalMs")),
    ("peak memory MB", data.get("peakMemoryMB")),
    ("first token ms (warm)", warm.get("firstTokenMs")),
    ("tok/s (warm)", warm.get("tokensPerSecond")),
    ("whole note ms (warm)", warm.get("totalMs")),
    ("numbers survived", data.get("numbersSurvived")),
]
for key, value in rows:
    print(f"{key + ':':<31}{value if value is not None else 'n/a'}")
if problems:
    for problem in problems:
        print(f"LLM SMOKE FAIL: {problem}", file=sys.stderr)
    print(f"Result file: {sys.argv[1]}", file=sys.stderr)
    sys.exit(1)
print(f"Result file: {sys.argv[1]}")
print("LLM SMOKE PASS")
PY
