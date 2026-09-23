#!/usr/bin/env bash
# Secret scan before a merge or a push: TruffleHog over the full git history (every branch) and over the working
# tree (including lane worktrees under .claude/worktrees), plus a check that no key, certificate, provisioning
# profile, .env or database file was ever committed.
#
# Usage: scripts/scan_secrets.sh
# Exit:  0 clean · 1 findings (printed with the value redacted) · 2 trufflehog missing (brew install trufflehog)
#
# Verification is OFF: found values are never sent to any service to test whether they are live.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v trufflehog >/dev/null || { echo "trufflehog is not installed: brew install trufflehog" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '/\.git/' '/\.build[^/]*/' '/DerivedData/' '/\.swiftpm/' '\.xcodeproj/' '/SourcePackages/' \
  '/node_modules/' '/\.venv/' '/vendor/needle-rs/target/' >"$TMP/exclude.txt"

# In a lane worktree `.git` is a file, which trufflehog's git mode cannot open; scan the main repository instead (its
# history holds every branch, including the worktree's).
REPO_ROOT=$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
echo "Scanning git history (all branches) ..."
trufflehog git "file://$REPO_ROOT" --no-verification --no-update --json 2>/dev/null >"$TMP/git.json"
echo "Scanning the working tree ..."
trufflehog filesystem "$PWD" --no-verification --no-update --json --exclude-paths="$TMP/exclude.txt" \
  2>/dev/null >"$TMP/fs.json"

# Known false positive: MacParakeet's URL-parsing test (MediaPlatformTests.swift) uses a user:password placeholder URL.
FINDINGS=$(python3 - "$TMP/git.json" "$TMP/fs.json" <<'PY'
import json, sys
allow = ("MediaPlatformTests.swift",)
seen = set()
for path in sys.argv[1:]:
    for line in open(path):
        d = json.loads(line)
        data = d.get("SourceMetadata", {}).get("Data", {})
        where = data.get("Git", {}).get("file") or data.get("Filesystem", {}).get("file") or "?"
        if where.endswith(allow):
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

FILES=$(git log --all --name-only --format= | sort -u | grep -Ei \
  '\.(p12|p8|pem|pfx|key|cer|mobileprovision|provisionprofile|keystore|jks|sqlite|sqlite3|db)$|(^|/)\.env$|(^|/)\.env\.[^e]|id_rsa|id_ed25519|Signing\.local\.xcconfig$|Device\.local$' \
  || true)

if [ -z "$FINDINGS" ] && [ -z "$FILES" ]; then
  echo "SECRET SCAN CLEAN: no credentials in history or working tree; no key, profile, .env or database file committed."
  exit 0
fi
[ -n "$FINDINGS" ] && { echo "Possible secrets:"; echo "$FINDINGS"; }
[ -n "$FILES" ] && { echo "Sensitive file types committed:"; echo "$FILES"; }
exit 1
