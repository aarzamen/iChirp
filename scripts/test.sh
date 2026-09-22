#!/usr/bin/env bash
# Full test pass: SwiftPM unit tests, then the generated app's XCTest bundle
# on the iOS Simulator.
# Usage: scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --package-path ChirpKit

scripts/gen.sh

xcodebuild test \
  -project iChirp.xcodeproj \
  -scheme iChirp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  -quiet
