#!/usr/bin/env bash
# First run on a Mac: checks Xcode 26+, XcodeGen and swift-format, offers to create the gitignored local config
# files from their examples, then generates iChirp.xcodeproj.
#
# Usage: scripts/bootstrap.sh          # asks before creating each local file
#        scripts/bootstrap.sh --yes    # creates missing local files without asking (never overwrites)
set -euo pipefail
cd "$(dirname "$0")/.."

ASSUME_YES=0
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
  ASSUME_YES=1
fi

problems=0

# Xcode 26 or newer (iOS 26 SDK).
if XCODE_VERSION_LINE=$(xcodebuild -version 2>/dev/null | head -1) && [ -n "$XCODE_VERSION_LINE" ]; then
  XCODE_MAJOR=$(printf '%s\n' "$XCODE_VERSION_LINE" | sed -nE 's/^Xcode ([0-9]+).*/\1/p')
  if [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -ge 26 ]; then
    echo "ok    $XCODE_VERSION_LINE ($(xcode-select -p))"
  else
    echo "FAIL  $XCODE_VERSION_LINE — iChirp needs Xcode 26 or newer (iOS 26 SDK). Install it from the App Store or"
    echo "      developer.apple.com, then: sudo xcode-select -s /Applications/Xcode.app"
    problems=$((problems + 1))
  fi
else
  echo "FAIL  xcodebuild not found. Install Xcode 26+, open it once, then: sudo xcode-select -s /Applications/Xcode.app"
  problems=$((problems + 1))
fi

# XcodeGen generates iChirp.xcodeproj from project.yml.
if command -v xcodegen >/dev/null 2>&1; then
  echo "ok    XcodeGen $(xcodegen --version 2>/dev/null | sed -E 's/^Version: *//')"
else
  echo "FAIL  XcodeGen not found. Install with: brew install xcodegen"
  problems=$((problems + 1))
fi

# swift-format ships with Xcode (scripts/check.sh and scripts/format.sh use it).
if SWIFT_FORMAT_VERSION=$(xcrun swift-format --version 2>/dev/null); then
  echo "ok    swift-format $SWIFT_FORMAT_VERSION (bundled with Xcode)"
else
  echo "FAIL  swift-format not found via xcrun. It is bundled with Xcode 16+; check xcode-select -p."
  problems=$((problems + 1))
fi

if [ "$problems" -gt 0 ]; then
  echo ""
  echo "Fix the $problems item(s) above, then rerun scripts/bootstrap.sh."
  exit 1
fi

# Offers to copy <file>.example to <file> when the file is missing. Never overwrites.
offer_local_file() {
  local target="$1" example="$1.example" what="$2"
  if [ -f "$target" ]; then
    echo "ok    $target exists"
    return
  fi
  local answer="n"
  if [ "$ASSUME_YES" -eq 1 ]; then
    answer="y"
  elif [ -t 0 ]; then
    read -r -p "Create $target from $example ($what)? [y/N] " answer || answer="n"
  else
    echo "skip  $target is missing (not a terminal; rerun with --yes, or: cp $example $target)"
    return
  fi
  case "$answer" in
    y | Y | yes | YES)
      cp "$example" "$target"
      echo "ok    created $target (gitignored) — check its contents"
      ;;
    *)
      echo "skip  $target not created (later: cp $example $target)"
      ;;
  esac
}

echo ""
offer_local_file "Config/Signing.local.xcconfig" "device builds: set DEVELOPMENT_TEAM to your Team ID"
offer_local_file "Config/Device.local" "which iPhone scripts/run_device.sh installs to"

echo ""
scripts/gen.sh
echo "ok    generated iChirp.xcodeproj"
echo ""
echo "Next: scripts/check.sh (package build + lint), scripts/run_sim.sh (simulator), scripts/run_device.sh (iPhone)."
