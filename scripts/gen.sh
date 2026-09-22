#!/usr/bin/env bash
# Regenerates iChirp.xcodeproj from project.yml via XcodeGen.
# Usage: scripts/gen.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate --quiet
