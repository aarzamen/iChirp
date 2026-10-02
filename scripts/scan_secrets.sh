#!/usr/bin/env bash
# Secret scan before a merge or a push: TruffleHog over the full git history (every branch) and over the working
# tree (including lane worktrees under .claude/worktrees), plus two checks on every file name ever committed:
#   - no key, certificate, signing request, provisioning profile, keychain, .env or database file (SQLite's -wal and
#     -shm files included);
#   - no recording, video or caption/transcript file (m4a, wav, mp3, mp4, srt, vtt, ...) outside the folders that hold
#     the repo's synthetic ones. Real recordings and transcripts are the repo's main PHI risk, and the repo is public.
#
# Usage: scripts/scan_secrets.sh
# Exit:  0 clean · 1 findings (printed with the value redacted) · 2 trufflehog missing (brew install trufflehog) or
#        failed (its own message is printed: a broken scan is not a clean one)
#
# Verification is OFF: found values are never sent to any service to test whether they are live.
# GitHub's secret scanning and push protection are repository settings on github.com (Settings -> Code security); the
# owner switches them on. This script is the local gate and does not replace them.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v trufflehog >/dev/null || { echo "trufflehog is not installed: brew install trufflehog" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# companion/.venv is the Mac companion's gitignored virtualenv (third-party packages, never committed).
printf '%s\n' '/\.git/' '/\.build[^/]*/' '/DerivedData/' '/\.swiftpm/' '\.xcodeproj/' '/SourcePackages/' \
  '/node_modules/' '/\.venv/' '/__pycache__/' '/vendor/needle-rs/target/' >"$TMP/exclude.txt"

# trufflehog exits 0 whether or not it found anything, so a non-zero exit means the scan itself broke. Say why instead
# of dying silently with the status the header documents as "findings" (R8-6).
scan() { # scan <name> <trufflehog arguments...>: JSON lines to $TMP/<name>.json
  local name="$1"
  shift
  if ! trufflehog "$@" --no-verification --no-update --json >"$TMP/$name.json" 2>"$TMP/$name.err"; then
    echo "error: trufflehog failed while scanning ($name); this is a broken scan, not a finding. Its message:" >&2
    tail -n 20 "$TMP/$name.err" >&2
    exit 2
  fi
}

# In a lane worktree `.git` is a file, which trufflehog's git mode cannot open; scan the main repository instead (its
# history holds every branch, including the worktree's).
REPO_ROOT=$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
echo "Scanning git history (all branches) ..."
scan git git "file://$REPO_ROOT"
echo "Scanning the working tree ..."
scan tree filesystem "$PWD" --exclude-paths="$TMP/exclude.txt"

# Known false positive: MacParakeet's URL-parsing test uses a user:password placeholder URL. Allowed only at the two
# paths that file has ever had (inside the read-only upstream mirror, and at the repo root before the mirror existed),
# not "anywhere a file has that name".
FINDINGS=$(python3 - "$TMP/git.json" "$TMP/tree.json" <<'PY'
import json, os, sys
root = os.getcwd()
allow = {
    "upstream/macparakeet/Tests/MacParakeetTests/Utilities/MediaPlatformTests.swift",
    "Tests/MacParakeetTests/Utilities/MediaPlatformTests.swift",
}
seen = set()
for path in sys.argv[1:]:
    for line in open(path):
        d = json.loads(line)
        data = d.get("SourceMetadata", {}).get("Data", {})
        where = data.get("Git", {}).get("file") or data.get("Filesystem", {}).get("file") or "?"
        relative = os.path.relpath(where, root) if os.path.isabs(where) else where
        if relative in allow:
            continue
        raw = d.get("Raw", "")
        key = (d.get("DetectorName"), where, len(raw))
        if key in seen:
            continue
        seen.add(key)
        commit = (data.get("Git", {}).get("commit") or "")[:10]
        print(f"{d.get('DetectorName')} | {where} | {commit or 'working tree'} | {raw[:4]}…({len(raw)} chars)")
PY
)

ALL_FILES=$(git log --all --name-only --format= | sort -u)

FILES=$(grep -Ei \
  '\.(p12|p8|pem|pfx|key|cer|csr|certSigningRequest|keychain|keychain-db|mobileprovision|provisionprofile|keystore|jks|sqlite|sqlite3|db)$|\.(sqlite|sqlite3|db)-(wal|shm)$|(^|/)\.env$|(^|/)\.env\.[^e]|id_rsa|id_ed25519|Signing\.local\.xcconfig$|Device\.local$' \
  <<<"$ALL_FILES" || true)

# Recordings, videos and captions may be committed only where the synthetic ones live: the app's bundled samples and
# benchmark set, the package tests' fixtures, MacParakeet's read-only mirror, and that mirror's one demo video at the
# path it had before the mirror existed.
ALLOWED_MEDIA='^(App/Resources/(Samples|Benchmark)/|ChirpKit/Tests/[^/]+/Fixtures/|upstream/macparakeet/|docs/research/2026-09-19-jev-voice-control/demo/browser-proof\.mp4$)'
MEDIA=$(grep -Ei '\.(m4a|wav|caf|aif|aiff|aac|flac|mp3|mp4|mov|ogg|opus|srt|vtt)$' <<<"$ALL_FILES" \
  | grep -Ev "$ALLOWED_MEDIA" || true)

if [ -z "$FINDINGS" ] && [ -z "$FILES" ] && [ -z "$MEDIA" ]; then
  echo "SECRET SCAN CLEAN: no credentials in history or working tree; no key, profile, keychain, .env or database file committed; no recording or transcript outside the synthetic-fixture folders."
  exit 0
fi
[ -n "$FINDINGS" ] && { echo "Possible secrets:"; echo "$FINDINGS"; }
[ -n "$FILES" ] && { echo "Sensitive file types committed:"; echo "$FILES"; }
[ -n "$MEDIA" ] && { echo "Recordings, videos or captions committed outside the synthetic-fixture folders:"; echo "$MEDIA"; }
exit 1
