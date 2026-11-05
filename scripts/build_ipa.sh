#!/usr/bin/env bash
# Builds an ad-hoc-signed IPA for the optional SideStore fallback: dist/Parakeet-<version>-<commit>.ipa, named from
# the build stamp in the archived app's Info.plist (the values Settings → About shows), so the file says which build it is.
# The everyday install path is scripts/run_device.sh; see docs/distribution.md (Path B) before using this.
#
# Usage: scripts/build_ipa.sh
#
# 1. Archives a Release build for generic/platform=iOS with code signing off (no team, no profiles involved).
# 2. Ad-hoc signs (`codesign -s -`) nested frameworks, then each PlugIns/*.appex with its .entitlements file, then the
#    app with App/iChirp.entitlements when that file exists. SideStore reads entitlements from the binary's code
#    signature, so an unsigned IPA silently loses App Groups and other entitlements.
# 3. Zips Payload/iChirp.app into dist/Parakeet-<version>-<commit>.ipa ("-dirty" appended when the working tree had
#    uncommitted changes, as About says). One file per build; attach it to a release as it is.
# Logs: .build/ipa-logs/
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE=".build/iChirp.xcarchive"
STAGE=".build/ipa-staging"
LOG_DIR=".build/ipa-logs"
mkdir -p "$LOG_DIR" dist

# Finds <name>.entitlements in the repo's own sources (never upstream/ or build output).
find_entitlements() {
  find . \( -path ./upstream -o -path ./.build -o -path ./dist -o -path ./.git -o -path ./.claude \) \
    -prune -o -type f -name "$1.entitlements" -print | head -1
}

# Ad-hoc signs one bundle, with entitlements when a file is given. Rejects $(...) placeholders,
# which SideStore cannot resolve.
adhoc_sign() {
  local bundle="$1" entitlements="${2:-}"
  if [ -n "$entitlements" ]; then
    if grep -q '\$(' "$entitlements"; then
      echo "error: $entitlements contains a \$(...) placeholder; SideStore needs literal identifiers." >&2
      exit 1
    fi
    echo "  codesign -f -s - --entitlements $entitlements $(basename "$bundle")"
    codesign -f -s - --entitlements "$entitlements" "$bundle"
  else
    echo "  codesign -f -s - $(basename "$bundle")"
    codesign -f -s - "$bundle"
  fi
}

scripts/gen.sh

ARCHIVE_LOG="$LOG_DIR/archive.log"
echo "Archiving Release for generic/platform=iOS, unsigned (log: $ARCHIVE_LOG) ..."
rm -rf "$ARCHIVE"
if ! xcodebuild archive \
  -project iChirp.xcodeproj \
  -scheme iChirp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath .build/xcode-archive \
  CODE_SIGNING_ALLOWED=NO >"$ARCHIVE_LOG" 2>&1; then
  grep -E 'error:|ARCHIVE FAILED' "$ARCHIVE_LOG" | tail -20 >&2 || true
  echo "error: xcodebuild archive failed. Full log: $ARCHIVE_LOG" >&2
  exit 1
fi

APP_IN_ARCHIVE="$ARCHIVE/Products/Applications/iChirp.app"
if [ ! -d "$APP_IN_ARCHIVE" ]; then
  echo "error: $APP_IN_ARCHIVE is missing from the archive." >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP_IN_ARCHIVE" "$STAGE/Payload/"
APP="$STAGE/Payload/iChirp.app"

# The file name comes from the build stamp scripts/stamp_build_identity.sh wrote into the app's Info.plist during the
# archive (the same values Settings → About shows), so dist/ never holds an IPA that cannot say which build it is.
plist_value() { # plist_value <key>: the key's value in the staged app's Info.plist, or "unknown"
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist" 2>/dev/null || echo unknown
}
VERSION=$(plist_value CFBundleShortVersionString)
COMMIT=$(plist_value ChirpGitCommit)
DIRTY=$(plist_value ChirpGitDirty)
case "${VERSION}${COMMIT}" in
  *[!A-Za-z0-9._-]*)
    echo "error: the build stamp holds unexpected characters (version '$VERSION', commit '$COMMIT')." >&2
    exit 1
    ;;
esac
IPA="dist/Parakeet-${VERSION}-${COMMIT}.ipa"
if [ "$DIRTY" = "1" ]; then
  IPA="dist/Parakeet-${VERSION}-${COMMIT}-dirty.ipa"
fi

echo "Ad-hoc signing (inside out) ..."
shopt -s nullglob
for framework in "$APP"/Frameworks/*.framework "$APP"/Frameworks/*.dylib; do
  adhoc_sign "$framework"
done
for appex in "$APP"/PlugIns/*.appex; do
  name=$(basename "$appex" .appex)
  for nested in "$appex"/Frameworks/*.framework "$appex"/Frameworks/*.dylib; do
    adhoc_sign "$nested"
  done
  entitlements=$(find_entitlements "$name")
  if [ -z "$entitlements" ]; then
    echo "  warning: no $name.entitlements found; $name.appex is signed without entitlements." >&2
  fi
  adhoc_sign "$appex" "$entitlements"
done
shopt -u nullglob
if [ -f App/iChirp.entitlements ]; then
  adhoc_sign "$APP" App/iChirp.entitlements
else
  adhoc_sign "$APP"
fi
codesign --verify --deep --strict "$APP"

rm -f "$IPA"
(cd "$STAGE" && zip -qry "../../$IPA" Payload)

echo ""
echo "IPA: $PWD/$IPA ($(du -h "$IPA" | cut -f1 | tr -d ' '))"
echo "Build: $VERSION ($(plist_value CFBundleVersion)) · $COMMIT$([ "$DIRTY" = "1" ] && echo ' · dirty' || true)"
cat <<'EOF'

SideStore notes (optional fallback; the everyday path is scripts/run_device.sh):
  - Use SideStore 0.7.0-alpha or later; 0.6.4 and earlier cannot sign in since 2026-09.
  - Free Apple ID limits: 3 active apps and 10 App IDs per 7 days; each app extension uses one App ID.
  - SideStore appends the Team ID to the bundle, App Group and background-task identifiers, so a SideStore
    install is a separate app with separate data.
  Install: AirDrop or Files the IPA to the phone, open SideStore, tap +, choose the file.
EOF
