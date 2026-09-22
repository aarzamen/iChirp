#!/usr/bin/env bash
# Builds the Debug app for the owner's iPhone, installs it with devicectl and launches it.
#
# Usage: scripts/run_device.sh [--dry-run | --print-device] [launch arguments passed to the app]
#   scripts/run_device.sh                          # build Debug, install, launch
#   scripts/run_device.sh -SomeLaunchArgument      # extra arguments reach the app at launch
#   scripts/run_device.sh -- -ChirpSmoke transcribe-sample   # a leading "--" is accepted and dropped
#   scripts/run_device.sh --dry-run                # show the chosen device, team and build command; build nothing
#   scripts/run_device.sh --print-device           # print only the chosen device identifier (used by device_smoke.sh)
#   DEVELOPMENT_TEAM=<team> scripts/run_device.sh  # otherwise Config/Signing.local.xcconfig, else XM6E4PUXTU
#   SMOKE_CONSOLE=1 scripts/run_device.sh          # launch with `devicectl ... --console` instead, backgrounded,
#                                                   # streaming the app's stdout/stderr to .build/device-logs/
#
# Device selection never guesses between phones:
#   1. DEVICE_ID=<identifier> in the environment;
#   2. otherwise Config/Device.local (gitignored), one line DEVICE_ID=<identifier>
#      (copy Config/Device.local.example);
#   3. otherwise the one iPhone that devicectl lists as "available (paired)" or "connected";
#   4. more than one reachable iPhone and no DEVICE_ID: stop and list them.
#
# Signing uses the provisioning profiles that already exist on this Mac (the team's wildcard
# "iOS Team Provisioning Profile: *" covers com.aarzamen.ichirp). This script never asks Xcode to
# create or update provisioning profiles or to register devices. Read APPLE_DEVELOPER_WARNING.md.
# Logs: .build/device-logs/
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
esac
if [ "${1:-}" = "--" ]; then
  shift
fi

signing_failed() {
  cat >&2 <<'EOF'

Signing failed. Do NOT try to fix the Apple Developer account from a script. Open iChirp.xcodeproj in Xcode once, select the iChirp target → Signing & Capabilities → Team XM6E4PUXTU (Automatic), build to the iPhone from the Xcode GUI, then rerun. See APPLE_DEVELOPER_WARNING.md.
EOF
}

phone_locked() {
  echo "" >&2
  echo "Unlock your iPhone and rerun." >&2
}

# Classifies a failure log: locked phone, signing, or generic. Always exits non-zero.
fail_with_log() {
  local log="$1" what="$2"
  echo "" >&2
  echo "error: $what failed. Full log: $log" >&2
  if grep -qiE 'device (is|was) locked|passcode protected|could not be,? unlocked|unlock (your|the) (iPhone|device)' "$log"; then
    phone_locked
  elif grep -qiE 'signing|provisioning profile|No profiles for|No Account for Team|certificate|CodeSign|code signature|errSecInternalComponent' "$log"; then
    signing_failed
  fi
  exit 1
}

# 1. Resolve the device (see the order in the header).
DEVICE_SOURCE=""
if [ -n "${DEVICE_ID:-}" ]; then
  DEVICE_SOURCE="DEVICE_ID environment variable"
elif [ -f Config/Device.local ]; then
  DEVICE_ID=$(sed -nE 's/^[[:space:]]*DEVICE_ID[[:space:]]*=[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' \
    Config/Device.local | head -1)
  if [ -z "$DEVICE_ID" ]; then
    echo "error: Config/Device.local has no DEVICE_ID=<identifier> line (see Config/Device.local.example)." >&2
    exit 1
  fi
  DEVICE_SOURCE="Config/Device.local"
else
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

if [ "$MODE" = "print-device" ]; then
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

# 2. Team: env, then Config/Signing.local.xcconfig, then the owner's team.
if [ -z "${DEVELOPMENT_TEAM:-}" ] && [ -f Config/Signing.local.xcconfig ]; then
  DEVELOPMENT_TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+).*/\1/p' \
    Config/Signing.local.xcconfig | head -1)
fi
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-XM6E4PUXTU}"

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
  fail_with_log "$BUILD_LOG" "xcodebuild"
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
