#!/usr/bin/env bash
# Builds iChirp and launches it on the iPhone 17 Pro simulator.
# Usage: scripts/run_sim.sh [args passed through to the launched app]
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/gen.sh

xcodebuild build \
  -project iChirp.xcodeproj \
  -scheme iChirp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

xcrun simctl boot "iPhone 17 Pro" || true
xcrun simctl install booted .build/xcode/Build/Products/Debug-iphonesimulator/iChirp.app
xcrun simctl launch booted com.aarzamen.ichirp "$@"
