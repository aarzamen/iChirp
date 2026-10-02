#!/usr/bin/env bash
# Fast local gate: SwiftPM build, optional filtered test, and format lint.
# Usage: scripts/check.sh [TestFilter]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --package-path ChirpKit

if [ "$#" -ge 1 ]; then
  swift test --package-path ChirpKit --filter "$1"
fi

swift format lint --strict --recursive ChirpKit/Sources App/Sources App/Shared Widgets

# Plan 025 R1: no consumer reads the baseline text fields outside the one accessor.
scripts/check_transcript_text_reads.sh
