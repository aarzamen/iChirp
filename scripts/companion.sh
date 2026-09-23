#!/usr/bin/env bash
# Starts the Parakeet companion on this Mac: the owner's local voices and YouTube audio for Parakeet on the iPhone
# (spec/contracts/mac-companion-v1.md). Prints the host, port and pairing token to enter in Settings → Mac companion.
# Usage: scripts/companion.sh                              start it (0.0.0.0:8765; Control-C stops it)
#        scripts/companion.sh --port 8766                  another port
#        scripts/companion.sh --list-models                which speech models are ready
#        scripts/companion.sh --download qwen3-tts-1.7b    download a speech model once (Hugging Face cache)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is not installed. Install it with: brew install uv" >&2
  exit 1
fi

host_name="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
exec uv run --project companion --python 3.12 parakeet-companion --advertise-host "$host_name" "$@"
