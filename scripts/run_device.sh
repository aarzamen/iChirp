#!/usr/bin/env bash
# Builds the Debug app for the owner's iPhone, installs it with devicectl and launches it.
#
# Usage: scripts/run_device.sh [--dry-run | --print-device | --print-pinned-device] [launch arguments passed to the app]
#        scripts/run_device.sh --classify-log <build|tool> <log file>    # prints locked, signing or other; see below
#   scripts/run_device.sh                          # build Debug, install, launch
#   scripts/run_device.sh -SomeLaunchArgument      # extra arguments reach the app at launch
#   scripts/run_device.sh -- -ChirpSmoke transcribe-sample   # a leading "--" is accepted and dropped
#   scripts/run_device.sh --dry-run                # show the chosen device, team and build command; build nothing
#   scripts/run_device.sh --print-device           # print only the chosen device identifier (used by device_smoke.sh)
#   scripts/run_device.sh --print-pinned-device    # like --print-device, but refuses (exit 1, clear message)
#                                                   # instead of ever falling back to "the one reachable iPhone" —
#                                                   # for a caller that writes real data to the phone and must never
#                                                   # guess which one (device_smoke.sh, device_llm_smoke.sh,
#                                                   # device_benchmark.sh)
#   PINNED_DEVICE_ONLY=1 scripts/run_device.sh     # the same refusal, for the build+install path: fails before
#                                                   # building rather than installing to a guessed phone
#   DEVELOPMENT_TEAM=<team> scripts/run_device.sh  # otherwise Config/Signing.local.xcconfig; neither = stop
#   SMOKE_CONSOLE=1 scripts/run_device.sh          # launch with `devicectl ... --console` instead, backgrounded,
#                                                   # streaming the app's stdout/stderr to .build/device-logs/
#
# Device selection never guesses between phones:
#   1. DEVICE_ID=<identifier> in the environment;
#   2. otherwise a DEVICE_ID=<identifier> line in Config/Device.local (gitignored; copy Config/Device.local.example).
#      A Config/Device.local without such a line (the example as it stands) counts as no file;
#   3. otherwise, unless --print-pinned-device or PINNED_DEVICE_ONLY=1 asked for the stricter rule above, the one
#      iPhone that devicectl lists as "available (paired)" or "connected";
#   4. more than one reachable iPhone and no DEVICE_ID: stop and list them.
#
# Signing uses the provisioning profiles that already exist on this Mac (Xcode's automatic-signing profile for
# com.aarzamen.ichirp; the Increased Memory Limit capability in project.yml lives on that App ID, so a profile that
# predates it needs one automatic-signing build in the Xcode app). This script never asks Xcode to create or update
# provisioning profiles or to register devices. Read APPLE_DEVELOPER_WARNING.md.
# Logs: .build/device-logs/
#
# A failed step is classified so the advice matches the failure: "locked" (unlock the phone), "signing" (an error line
# that names a signing problem), or "other" (a build or tool error; the error lines above say what). --classify-log
# runs only that classification, for scripts/check_scripts.sh and its fixtures; "build" logs are xcodebuild's,
# "tool" logs are devicectl's.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.aarzamen.ichirp"
APP_PATH=".build/xcode/Build/Products/Debug-iphoneos/iChirp.app"
LOG_DIR=".build/device-logs"
mkdir -p "$LOG_DIR"

MODE="run"
case "${1:-}" in
  --dry-run) MODE="dry-run"; shift ;;
  --print-device) MODE="print-device"; shift ;;
  --print-pinned-device) MODE="print-pinned-device"; shift ;;
  --classify-log) MODE="classify-log"; shift ;;
esac
if [ "$MODE" != "classify-log" ] && [ "${1:-}" = "--" ]; then
  shift
fi

# Some callers write real data (gigabytes, a synthetic clinical row) to the phone and must never guess it: they ask
# for step 3 in the header above to be skipped, so an unreachable-phone or Config/Device.local miss is a refusal,
# not a fallback to "the one reachable iPhone".
PINNED_ONLY=0
if [ "$MODE" = "print-pinned-device" ] || [ "${PINNED_DEVICE_ONLY:-0}" = "1" ]; then
  PINNED_ONLY=1
fi

signing_failed() {
  cat >&2 <<'EOF'

Signing failed. Do NOT try to fix the Apple Developer account from a script. Open iChirp.xcodeproj in Xcode once, select the iChirp target → Signing & Capabilities → your team (Automatic), build to the iPhone from the Xcode GUI, then rerun. See APPLE_DEVELOPER_WARNING.md.
EOF
}

phone_locked() {
  echo "" >&2
  echo "Unlock your iPhone and rerun." >&2
}

# What a failure log says went wrong. Prints locked, signing or other.
#   build: an xcodebuild log. It always carries signing words that prove nothing: the environment dump of every
#          "Stamp Build Identity" script phase (CODE_SIGNING_ALLOWED, CODESIGNING_FOLDER_PATH, ...), the "Signing
#          Identity:" and "Provisioning Profile:" lines and the CodeSign command lines. A Swift compile error is
#          therefore not a signing problem; only an error line that names one is (R8-2).
#   tool:  a devicectl log (short, no environment dump): the signing words anywhere in it count.
LOCKED_PATTERN='device (is|was) locked|passcode protected|could not be,? unlocked|unlock (your|the) (iPhone|device)'
SIGNING_ERROR_PATTERN='No profiles for|No Account for Team|requires a development team|provisioning profile|signing certificate|Automatic signing (is disabled|failed|is unable to resolve)|Code ?Sign(ing)? Error|Failed Registering Bundle Identifier|Your team has no devices|errSecInternalComponent|Command CodeSign failed'
SIGNING_ANY_PATTERN='signing|provisioning profile|No profiles for|No Account for Team|certificate|CodeSign|code signature|errSecInternalComponent'
classify_log() {
  local log="$1" kind="$2" error_lines
  if grep -qiE "$LOCKED_PATTERN" "$log"; then
    echo locked
    return
  fi
  if [ "$kind" = "build" ]; then
    # Here-strings, not pipes: with pipefail a `grep -q` that stops reading early would fail the whole pipeline.
    error_lines=$(grep -E 'error:|errSecInternalComponent|Command CodeSign failed' "$log" || true)
    if [ -n "$error_lines" ] && grep -qiE "$SIGNING_ERROR_PATTERN" <<<"$error_lines"; then
      echo signing
      return
    fi
  elif grep -qiE "$SIGNING_ANY_PATTERN" "$log"; then
    echo signing
    return
  fi
  echo other
}

# Reports a failed step with advice that matches what went wrong. Always exits non-zero.
# fail_with_log <log> <what> [build]   (the third word says the log is xcodebuild's; anything else is devicectl's)
fail_with_log() {
  local log="$1" what="$2" kind="${3:-tool}"
  echo "" >&2
  echo "error: $what failed. Full log: $log" >&2
  case "$(classify_log "$log" "$kind")" in
    locked) phone_locked ;;
    signing) signing_failed ;;
    *)
      if [ "$kind" = "build" ]; then
        echo "That is not a signing problem. The error lines above say what failed; fix them and rerun." >&2
      fi
      ;;
  esac
  exit 1
}

# Test hook for scripts/check_scripts.sh: classify a saved log without building or touching a phone.
if [ "$MODE" = "classify-log" ]; then
  if [ "$#" -ne 2 ] || { [ "$1" != "build" ] && [ "$1" != "tool" ]; } || [ ! -f "$2" ]; then
    echo "usage: scripts/run_device.sh --classify-log <build|tool> <log file>" >&2
    exit 2
  fi
  classify_log "$2" "$1"
  exit 0
fi

# 1. Resolve the device (see the order in the header). A Config/Device.local with no uncommented DEVICE_ID line (the
#    example copied as it stands, which older versions of bootstrap.sh did) is the same as no file (R8-10).
FILE_DEVICE_ID=""
if [ -f Config/Device.local ]; then
  FILE_DEVICE_ID=$(sed -nE 's/^[[:space:]]*DEVICE_ID[[:space:]]*=[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' \
    Config/Device.local | head -1)
fi
DEVICE_SOURCE=""
if [ -n "${DEVICE_ID:-}" ]; then
  DEVICE_SOURCE="DEVICE_ID environment variable"
elif [ -n "$FILE_DEVICE_ID" ]; then
  DEVICE_ID="$FILE_DEVICE_ID"
  DEVICE_SOURCE="Config/Device.local"
elif [ "$PINNED_ONLY" = "1" ]; then
  if [ -f Config/Device.local ]; then
    echo "error: no DEVICE_ID, and Config/Device.local has no DEVICE_ID=<identifier> line. This caller never guesses" >&2
    echo "the phone (it does not fall back to \"the one reachable iPhone\")." >&2
  else
    echo "error: no DEVICE_ID and no Config/Device.local, and this caller never guesses the phone (it does not fall" >&2
    echo "back to \"the one reachable iPhone\")." >&2
  fi
  echo "Set DEVICE_ID=<identifier>, or put a DEVICE_ID=<identifier> line in Config/Device.local (copy" >&2
  echo "Config/Device.local.example), then rerun." >&2
  exit 1
else
  if [ -f Config/Device.local ]; then
    echo "note: Config/Device.local has no DEVICE_ID=<identifier> line, so it pins nothing; looking for the one reachable iPhone." >&2
  fi
  DEVICES_JSON="$LOG_DIR/devices.json"
  rm -f "$DEVICES_JSON"
  if ! xcrun devicectl list devices --quiet --json-output "$DEVICES_JSON" >"$LOG_DIR/devices.log" 2>&1; then
    fail_with_log "$LOG_DIR/devices.log" "xcrun devicectl list devices"
  fi
  # "available (paired)" in the devicectl table is pairingState=paired + tunnelState=disconnected;
  # "connected" is tunnelState=connected. Everything else ("unavailable") is not reachable.
  REACHABLE=$(python3 - "$DEVICES_JSON" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for d in devices:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("deviceType") != "iPhone" or conn.get("pairingState") != "paired":
        continue
    if conn.get("tunnelState") not in ("connected", "disconnected"):
        continue
    name = d.get("deviceProperties", {}).get("name", "?")
    model = hw.get("marketingName") or hw.get("productType") or "?"
    print(f"{d.get('identifier')}\t{name}\t{model}")
PY
  )
  COUNT=$(printf '%s\n' "$REACHABLE" | grep -c . || true)
  if [ "$COUNT" -eq 0 ]; then
    echo "error: no reachable, paired iPhone in 'xcrun devicectl list devices'." >&2
    echo "Unlock the phone, keep it on the same Wi-Fi (or connect the cable), and make sure Developer Mode is on." >&2
    echo "See docs/distribution.md → Path A → One-time setup." >&2
    exit 1
  fi
  if [ "$COUNT" -gt 1 ]; then
    echo "error: more than one iPhone is reachable, and this script never guesses between them:" >&2
    printf '%s\n' "$REACHABLE" | while IFS=$'\t' read -r id name model; do
      echo "  $name — $model — $id" >&2
    done
    echo "Pick one: DEVICE_ID=<identifier> scripts/run_device.sh, or put DEVICE_ID=<identifier> in" >&2
    echo "Config/Device.local (copy Config/Device.local.example)." >&2
    exit 1
  fi
  DEVICE_ID=$(printf '%s\n' "$REACHABLE" | cut -f1)
  DEVICE_SOURCE="the only reachable iPhone"
fi

if [ "$MODE" = "print-device" ] || [ "$MODE" = "print-pinned-device" ]; then
  echo "$DEVICE_ID"
  exit 0
fi

# xcodebuild destinations take the hardware UDID; devicectl reports it in the device details.
INFO_JSON="$LOG_DIR/device-info.json"
rm -f "$INFO_JSON"
if ! xcrun devicectl device info details --device "$DEVICE_ID" --quiet --json-output "$INFO_JSON" >"$LOG_DIR/device-info.log" 2>&1; then
  echo "Is the phone unlocked, nearby and on the same network as this Mac?" >&2
  fail_with_log "$LOG_DIR/device-info.log" "Reading device details for $DEVICE_ID"
fi
DEVICE_META=$(python3 - "$INFO_JSON" <<'PY' || true
import json, sys
result = json.load(open(sys.argv[1])).get("result", {})
udid = result.get("hardwareProperties", {}).get("udid") or "-"
name = result.get("deviceProperties", {}).get("name") or "iPhone"
print(udid, name)
PY
)
UDID="${DEVICE_META%% *}"
DEVICE_NAME="${DEVICE_META#* }"
if [ -z "$UDID" ] || [ "$UDID" = "-" ]; then
  UDID="$DEVICE_ID"
fi
if [ -z "$DEVICE_NAME" ] || [ "$DEVICE_NAME" = "$DEVICE_META" ]; then
  DEVICE_NAME="iPhone"
fi

# 2. Team: env, then Config/Signing.local.xcconfig.
if [ -z "${DEVELOPMENT_TEAM:-}" ] && [ -f Config/Signing.local.xcconfig ]; then
  DEVELOPMENT_TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+).*/\1/p' \
    Config/Signing.local.xcconfig | head -1)
fi
# No built-in fallback: this repo is public, so the Team ID comes only from the environment or the gitignored file.
if [ -z "${DEVELOPMENT_TEAM:-}" ] || [ "$DEVELOPMENT_TEAM" = "YOUR_TEAM_ID" ]; then
  echo "error: no Apple Developer Team ID. Set DEVELOPMENT_TEAM=<your Team ID>, or copy" >&2
  echo "Config/Signing.local.xcconfig.example to Config/Signing.local.xcconfig and put your Team ID in it." >&2
  echo "Find it at developer.apple.com → Account → Membership details. See docs/distribution.md." >&2
  exit 1
fi

echo "Device: $DEVICE_NAME (CoreDevice $DEVICE_ID, UDID $UDID) — from $DEVICE_SOURCE"
echo "Team:   $DEVELOPMENT_TEAM (automatic signing, existing profiles only)"

XCODEBUILD_ARGS=(
  -project iChirp.xcodeproj
  -scheme iChirp
  -configuration Debug
  -destination "platform=iOS,id=$UDID"
  -derivedDataPath .build/xcode
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
  CODE_SIGN_STYLE=Automatic
  build
)

if [ "$MODE" = "dry-run" ]; then
  echo "Dry run. Would run:"
  echo "  scripts/gen.sh"
  echo "  xcodebuild ${XCODEBUILD_ARGS[*]}"
  echo "  xcrun devicectl device install app --device $DEVICE_ID $APP_PATH"
  echo "  xcrun devicectl device process launch --device $DEVICE_ID --terminate-existing $BUNDLE_ID${*:+ -- $*}"
  exit 0
fi

# 3. Regenerate the project and build Debug for the device.
scripts/gen.sh

BUILD_LOG="$LOG_DIR/xcodebuild-device.log"
echo "Building Debug for the device (log: $BUILD_LOG) ..."
if ! xcodebuild "${XCODEBUILD_ARGS[@]}" >"$BUILD_LOG" 2>&1; then
  grep -E 'error:|BUILD FAILED' "$BUILD_LOG" | tail -20 >&2 || true
  fail_with_log "$BUILD_LOG" "xcodebuild" build
fi
grep -E 'Stamped |BUILD SUCCEEDED' "$BUILD_LOG" | tail -2 || true

if [ ! -d "$APP_PATH" ]; then
  echo "error: build reported success but $APP_PATH is missing." >&2
  exit 1
fi

# 4. Install. Trust devicectl's result, not the build.
INSTALL_LOG="$LOG_DIR/install.log"
INSTALL_JSON="$LOG_DIR/install.json"
rm -f "$INSTALL_JSON"
echo "Installing $APP_PATH ..."
if ! xcrun devicectl device install app --device "$DEVICE_ID" --json-output "$INSTALL_JSON" "$APP_PATH" 2>&1 | tee "$INSTALL_LOG"; then
  fail_with_log "$INSTALL_LOG" "devicectl install"
fi
if ! python3 - "$INSTALL_JSON" "$BUNDLE_ID" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
apps = data.get("result", {}).get("installedApplications", [])
ids = [a.get("bundleID") for a in apps]
sys.exit(0 if sys.argv[2] in ids else 1)
PY
then
  echo "error: devicectl did not report $BUNDLE_ID as installed (see $INSTALL_JSON)." >&2
  exit 1
fi

# 5. Launch, replacing any running instance. Extra script arguments go to the app after a "--" terminator:
#    devicectl (Swift ArgumentParser) otherwise parses app flags like "-ChirpNetCheck" as its own bundled short
#    options ("-t" needs a value) and refuses to launch.
LAUNCH_LOG="$LOG_DIR/launch.log"
APP_ARGS=()
if [ "$#" -gt 0 ]; then APP_ARGS=(-- "$@"); fi
if [ "${SMOKE_CONSOLE:-0}" = "1" ]; then
  # --console streams the launched process's stdout/stderr (including FluidAudio's Debug-only logging, invisible
  # otherwise — final-review I3) instead of returning the usual --json-output result, and it blocks until the
  # process exits. Run it backgrounded so this script still returns once the launch is under way; read
  # $CONSOLE_LOG afterwards (or `tail -f` it live) for what the app printed.
  CONSOLE_LOG="$LOG_DIR/console-$(date -u +%Y%m%dT%H%M%SZ).log"
  echo "Launching $BUNDLE_ID $* with --console (background; log: $CONSOLE_LOG) ..."
  nohup xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing --console \
    "$BUNDLE_ID" ${APP_ARGS[@]+"${APP_ARGS[@]}"} >"$CONSOLE_LOG" 2>&1 &
  echo $! >"$LOG_DIR/console.pid"
  # Give devicectl a moment to attach and start the process before returning control to the caller.
  sleep 2
else
  echo "Launching $BUNDLE_ID $* ..."
  if ! xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
    --json-output "$LOG_DIR/launch.json" "$BUNDLE_ID" ${APP_ARGS[@]+"${APP_ARGS[@]}"} 2>&1 | tee "$LAUNCH_LOG"; then
    fail_with_log "$LAUNCH_LOG" "devicectl launch"
  fi
fi

echo "Installed and launched $BUNDLE_ID on $DEVICE_NAME."
