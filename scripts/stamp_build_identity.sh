#!/usr/bin/env bash
# Writes git commit/branch/dirty + UTC build date + a CFBundleVersion into the built Info.plist of the app and of its
# widget extension (an Xcode script phase of each target; project.yml).
#
# One build date and one CFBundleVersion per build, shared by both targets: the App Store wants the extension's
# CFBundleVersion to equal its parent app's, and each target used to take the time on its own at minute resolution, so
# a build that crossed a minute boundary stamped two numbers (R8-24). The extension is built before the app that
# embeds it, so:
#   stamp_build_identity.sh --new-build   (the extension) takes the time now and keeps it in $OBJROOT;
#   stamp_build_identity.sh               (the app) uses the time the extension kept, when that is less than two hours
#                                         old; otherwise (an app-only run, a stale file) it takes the time now.
# CFBundleVersion is the build date's digits, YYYYMMDDHHMMSS: a larger number is a later build (two builds in the same
# second would tie).
set -euo pipefail
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
cd "${SRCROOT}"
COMMIT=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
# Untracked files count as dirty (a build with new, uncommitted source files must not stamp "clean"); ignored
# paths (.build/, DerivedData/, etc.) are excluded by `git status`'s own .gitignore handling, same as tracked
# changes always were.
DIRTY=$([ -n "$(git status --porcelain 2>/dev/null)" ] && echo 1 || echo 0)

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAMP_FILE="${OBJROOT:-${TARGET_TEMP_DIR:-/tmp}}/ChirpBuildDate.txt"
DATE="$NOW"
if [ "${1:-}" = "--new-build" ]; then
  printf '%s\n' "$NOW" >"$STAMP_FILE"
elif [ -f "$STAMP_FILE" ] && [ -n "$(find "$STAMP_FILE" -mmin -120 2>/dev/null)" ]; then
  KEPT=$(head -1 "$STAMP_FILE")
  case "$KEPT" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) DATE="$KEPT" ;;
  esac
fi
BUILD=$(printf '%s' "$DATE" | tr -d ':TZ-')

for kv in "ChirpGitCommit:$COMMIT" "ChirpGitBranch:$BRANCH" "ChirpGitDirty:$DIRTY" "ChirpBuildDateUTC:$DATE" "CFBundleVersion:$BUILD"; do
  /usr/libexec/PlistBuddy -c "Set :${kv%%:*} ${kv#*:}" "$PLIST"
done
echo "Stamped $COMMIT ($BRANCH, dirty=$DIRTY) build $BUILD"
