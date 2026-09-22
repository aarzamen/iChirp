#!/usr/bin/env bash
# Builds the Debug app for the paired iPhone, installs it with devicectl and launches it.
#
# Usage: scripts/run_device.sh [launch arguments passed to the app]
#   scripts/run_device.sh                          # build Debug, install, launch
#   scripts/run_device.sh -SomeLaunchArgument      # extra arguments reach the app at launch
#   scripts/run_device.sh -- -ChirpSmoke transcribe-sample   # a leading "--" is accepted and dropped
#   DEVICE_ID=<CoreDevice identifier> scripts/run_device.sh  # pick a device when several are paired
#   DEVELOPMENT_TEAM=<team> scripts/run_device.sh             # otherwise Config/Signing.local.xcconfig, else XM6E4PUXTU
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

# 1. Resolve the device: DEVICE_ID wins; otherwise the first paired iPhone in the list whose state is
#    "available (paired)" or "connected" (devicectl shows "connected" while a tunnel to it is open).
if [ -z "${DEVICE_ID:-}" ]; then
  DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
    | grep -E 'available \(paired\)|[[:space:]]connected[[:space:]]' | grep 'iPhone' | head -1 \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1 || true)
fi
if [ -z "$DEVICE_ID" ]; then
  echo "error: no available, paired iPhone found in 'xcrun devicectl list devices'." >&2
  echo "Connect the phone (cable once, then same Wi-Fi), unlock it, tap Trust, and make sure Developer Mode is on." >&2
  echo "See docs/distribution.md → Path A → One-time setup. Or set DEVICE_ID=<identifier>." >&2
  exit 1
fi

# xcodebuild destinations take the hardware UDID; devicectl reports it in the device details.
INFO_JSON="$LOG_DIR/device-info.json"
rm -f "$INFO_JSON"
if ! xcrun devicectl device info details --device "$DEVICE_ID" --quiet --json-output "$INFO_JSON" >"$LOG_DIR/device-info.log" 2>&1; then
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

echo "Device: $DEVICE_NAME (CoreDevice $DEVICE_ID, UDID $UDID)"
echo "Team:   $DEVELOPMENT_TEAM (automatic signing, existing profiles only)"

# 3. Regenerate the project and build Debug for the device.
scripts/gen.sh

BUILD_LOG="$LOG_DIR/xcodebuild-device.log"
echo "Building Debug for the device (log: $BUILD_LOG) ..."
if ! xcodebuild \
  -project iChirp.xcodeproj \
  -scheme iChirp \
  -configuration Debug \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath .build/xcode \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  build >"$BUILD_LOG" 2>&1; then
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

# 5. Launch, replacing any running instance. Extra script arguments go to the app.
LAUNCH_LOG="$LOG_DIR/launch.log"
echo "Launching $BUNDLE_ID $* ..."
if ! xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing \
  --json-output "$LOG_DIR/launch.json" "$BUNDLE_ID" "$@" 2>&1 | tee "$LAUNCH_LOG"; then
  fail_with_log "$LAUNCH_LOG" "devicectl launch"
fi

echo "Installed and launched $BUNDLE_ID on $DEVICE_NAME."
