#!/usr/bin/env bash
# Formats Swift sources in place across ChirpKit and the app target.
# Usage: scripts/format.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swift format format --in-place --recursive ChirpKit/Sources ChirpKit/Tests App/Sources App/Shared Widgets
