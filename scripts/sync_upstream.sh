#!/usr/bin/env bash
# Replaces upstream/macparakeet/ with a newer MacParakeet ref, byte for byte, and commits it as its own commit.
#
# Usage: scripts/sync_upstream.sh <ref>          # a branch, tag or commit SHA of MacParakeet
#   UPSTREAM_URL=<git url or path> scripts/sync_upstream.sh <ref>   # default https://github.com/moona3k/macparakeet.git
#
# Steps: fetch <ref>; replace upstream/macparakeet with `git archive FETCH_HEAD`; point the pinned SHA in
# upstream/README.md at the new commit; verify the tree equals FETCH_HEAD^{tree}; commit
# "Upstream: sync MacParakeet reference to <sha>"; print what changed under Sources/.
# Afterwards, port the deltas that matter (AGENTS.md, section 6). Never edit upstream/macparakeet by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: scripts/sync_upstream.sh <ref>" >&2
  exit 2
fi
REF="$1"
URL="${UPSTREAM_URL:-https://github.com/moona3k/macparakeet.git}"

if [ -n "$(git status --porcelain -- upstream)" ]; then
  echo "error: upstream/ has uncommitted changes; commit or discard them first." >&2
  exit 1
fi
if ! git diff --cached --quiet; then
  echo "error: other changes are staged; the sync must be its own commit. Commit or unstage them first." >&2
  exit 1
fi

echo "Fetching $REF from $URL ..."
git fetch --quiet "$URL" "$REF"
NEW_SHA=$(git rev-parse --short=8 FETCH_HEAD)
NEW_TREE=$(git rev-parse 'FETCH_HEAD^{tree}')
OLD_SHA=$(sed -nE 's/.*A verbatim copy of MacParakeet at commit `([0-9a-f]+)`.*/\1/p' upstream/README.md | head -1)

if [ "$(git rev-parse HEAD:upstream/macparakeet 2>/dev/null || true)" = "$NEW_TREE" ]; then
  echo "upstream/macparakeet already matches $REF ($NEW_SHA). Nothing to do."
  exit 0
fi

rm -rf upstream/macparakeet
mkdir -p upstream/macparakeet
git archive FETCH_HEAD | tar -x -C upstream/macparakeet

python3 - upstream/README.md "$OLD_SHA" "$NEW_SHA" "$REF" "$(date -u +%Y-%m-%d)" <<'PY'
import re, sys
path, old, new, ref, day = sys.argv[1:6]
text = open(path).read()
sentence = (f"A verbatim copy of MacParakeet at commit `{new}` (upstream ref `{ref}`, synced {day} "
            f"with `scripts/sync_upstream.sh`).")
text, count = re.subn(r"A verbatim copy of MacParakeet at commit `[0-9a-f]+`.*?\)\.", sentence, text,
                      count=1, flags=re.S)
if count != 1:
    sys.exit(f"{path}: could not find the 'A verbatim copy of MacParakeet at commit `<sha>` (...).' sentence")
if old and old != new:
    text = text.replace(old, new)  # the tree check and provenance-header examples name the pinned SHA too
open(path, "w").write(text)
PY

# -f: the repo's own .gitignore must not drop upstream files; the reference is the whole upstream tree.
git add -A -f upstream/macparakeet
git add upstream/README.md

STAGED_TREE=$(git write-tree --prefix=upstream/macparakeet/)
if [ "$STAGED_TREE" != "$NEW_TREE" ]; then
  echo "error: upstream/macparakeet ($STAGED_TREE) does not match $REF^{tree} ($NEW_TREE)." >&2
  echo "Nothing was committed. Inspect with: git status -- upstream; undo with: git reset -q -- upstream && git checkout -- upstream && git clean -fdq -- upstream" >&2
  exit 1
fi

git commit -q -m "Upstream: sync MacParakeet reference to $NEW_SHA"
echo "Committed $(git rev-parse --short HEAD): upstream/macparakeet is now $REF ($NEW_SHA, was ${OLD_SHA:-unknown})."
echo ""
echo "Changed under upstream/macparakeet/Sources:"
git diff --stat HEAD~1 -- upstream/macparakeet/Sources
