#!/usr/bin/env bash
# Writes git commit/branch/dirty + UTC build date + monotonic CFBundleVersion into the built app's Info.plist.
set -euo pipefail
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
cd "${SRCROOT}"
COMMIT=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
# Untracked files count as dirty (a build with new, uncommitted source files must not stamp "clean"); ignored
# paths (.build/, DerivedData/, etc.) are excluded by `git status`'s own .gitignore handling, same as tracked
# changes always were.
DIRTY=$([ -n "$(git status --porcelain 2>/dev/null)" ] && echo 1 || echo 0)
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD=$(date -u +%Y%m%d%H%M)
for kv in "ChirpGitCommit:$COMMIT" "ChirpGitBranch:$BRANCH" "ChirpGitDirty:$DIRTY" "ChirpBuildDateUTC:$DATE" "CFBundleVersion:$BUILD"; do
  /usr/libexec/PlistBuddy -c "Set :${kv%%:*} ${kv#*:}" "$PLIST"
done
echo "Stamped $COMMIT ($BRANCH, dirty=$DIRTY) build $BUILD"
