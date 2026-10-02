#!/usr/bin/env bash
# Checks the scripts themselves: that every script parses under macOS's bash 3.2, and the logic that nothing else runs
# automatically because it needs a phone, signing or a scanner. Nothing here builds the app (section 7 compiles a few
# three-line C programs with cc to read their imports), signs, installs, reaches the network or touches
# Config/Device.local, Config/Signing.local.xcconfig or a phone: each check runs a copy of the script in a temporary
# folder, with stubs where the real tool would be.
#
# Usage: scripts/check_scripts.sh      (CI runs it; a few seconds)
# Exit:  0 all checks passed · 1 at least one failed (each failure is printed)
set -euo pipefail
cd "$(dirname "$0")/.."

failures=0
checks=0
pass() {
  checks=$((checks + 1))
  echo "ok    $*"
}
fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL  $*" >&2
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# 1. Syntax under /bin/bash, macOS's 3.2: the oldest bash any script here must run under (no mapfile, no associative
#    arrays, no ${x,,}). Python scripts are compiled instead.
for script in scripts/*.sh; do
  if /bin/bash -n "$script" 2>"$SANDBOX/syntax.err"; then
    pass "$script parses under /bin/bash $(/bin/bash -c 'echo "$BASH_VERSION"')"
  else
    fail "$script does not parse: $(head -1 "$SANDBOX/syntax.err")"
  fi
done
for script in scripts/*.py; do
  if python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$script" 2>"$SANDBOX/syntax.err"; then
    pass "$script compiles"
  else
    fail "$script does not compile: $(tail -1 "$SANDBOX/syntax.err")"
  fi
done

# run_device.sh is only ever run from a copy in the sandbox, with a stub `xcrun` first on PATH: it never reaches
# xcodebuild, devicectl, a phone or the real Config/Device.local (sections 2 and 3).
mkdir -p "$SANDBOX/rd/scripts" "$SANDBOX/rd/Config" "$SANDBOX/rd/bin"
cp scripts/run_device.sh "$SANDBOX/rd/scripts/run_device.sh"
cat >"$SANDBOX/rd/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
# Stands in for `xcrun devicectl list devices --json-output <file>`: one paired iPhone.
if [ "${1:-}" = "devicectl" ] && [ "${2:-}" = "list" ] && [ "${3:-}" = "devices" ]; then
  out=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--json-output" ]; then out="$2"; fi
    shift
  done
  cat >"$out" <<'JSON'
{"result": {"devices": [{"identifier": "AAAAAAAA-0000-0000-0000-000000000001",
  "hardwareProperties": {"deviceType": "iPhone", "marketingName": "iPhone Test"},
  "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"},
  "deviceProperties": {"name": "Test iPhone"}}]}}
JSON
  exit 0
fi
echo "unexpected xcrun call: $*" >&2
exit 1
STUB
chmod +x "$SANDBOX/rd/bin/xcrun" "$SANDBOX/rd/scripts/run_device.sh"
run_in_sandbox() { # run_in_sandbox <args...>: the sandboxed run_device.sh with no DEVICE_ID in the environment
  env -u DEVICE_ID -u PINNED_DEVICE_ONLY PATH="$SANDBOX/rd/bin:$PATH" "$SANDBOX/rd/scripts/run_device.sh" "$@"
}

# 2. run_device.sh tells a locked phone, a signing problem and any other failure apart (R8-2). xcodebuild's log always
#    carries signing words (the environment dump of the Stamp Build Identity phases, CodeSign lines), so a Swift compile
#    error must not be called a signing failure. Fixture logs are named <kind>--<expected>--<what>.log; --classify-log
#    only reads the file.
for log in scripts/fixtures/device-logs/*.log; do
  name=$(basename "$log" .log)
  kind=${name%%--*}
  rest=${name#*--}
  expected=${rest%%--*}
  actual=$(run_in_sandbox --classify-log "$kind" "$PWD/$log")  # absolute: the copy changes into the sandbox folder
  if [ "$actual" = "$expected" ]; then
    pass "run_device.sh classifies $name as $expected"
  else
    fail "run_device.sh classifies $name as $actual, expected $expected"
  fi
done

# 3. run_device.sh device selection reads the sandbox's Config/Device.local, never the real one.
# The example copied as it stands: older versions of bootstrap.sh created exactly this file.
cp Config/Device.local.example "$SANDBOX/rd/Config/Device.local"
if run_in_sandbox --print-pinned-device >"$SANDBOX/out" 2>"$SANDBOX/err"; then
  fail "a pinned caller (device_smoke.sh and friends) must refuse a Device.local without a DEVICE_ID line"
elif grep -q "has no DEVICE_ID" "$SANDBOX/err"; then
  pass "pinned callers refuse a Device.local without a DEVICE_ID line, and say so"
else
  fail "the pinned refusal does not name the missing DEVICE_ID line: $(head -1 "$SANDBOX/err")"
fi
if [ "$(run_in_sandbox --print-device 2>"$SANDBOX/err")" = "AAAAAAAA-0000-0000-0000-000000000001" ] \
  && grep -q "pins nothing" "$SANDBOX/err"; then
  pass "run_device.sh treats a Device.local without a DEVICE_ID line as no file (the one reachable iPhone, with a note)"
else
  fail "run_device.sh does not fall back to the one reachable iPhone for a Device.local without a DEVICE_ID line"
fi
printf '%s\n' 'DEVICE_ID=11111111-2222-3333-4444-555555555555  # a pinned phone' >"$SANDBOX/rd/Config/Device.local"
if [ "$(run_in_sandbox --print-pinned-device 2>/dev/null)" = "11111111-2222-3333-4444-555555555555" ]; then
  pass "run_device.sh reads DEVICE_ID from Config/Device.local"
else
  fail "run_device.sh does not read DEVICE_ID from Config/Device.local"
fi

# 4. bootstrap.sh --yes does not leave a Config/Device.local that pins nothing (R8-10: the next run_device.sh stopped on
#    it). The copy runs with stub tools and a stub gen.sh in a temporary folder.
mkdir -p "$SANDBOX/bs/scripts" "$SANDBOX/bs/Config" "$SANDBOX/bs/bin"
cp scripts/bootstrap.sh "$SANDBOX/bs/scripts/bootstrap.sh"
cp Config/*.example "$SANDBOX/bs/Config/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SANDBOX/bs/scripts/gen.sh"
cat >"$SANDBOX/bs/bin/tool" <<'STUB'
#!/usr/bin/env bash
case "$(basename "$0")" in
  xcodebuild) echo "Xcode 26.0" ;;
  xcode-select) echo "/Applications/Xcode.app/Contents/Developer" ;;
  xcodegen) echo "Version: 2.45.4" ;;
  xcrun) echo "600.0.0" ;;
esac
STUB
for tool in xcodebuild xcode-select xcodegen xcrun; do
  cp "$SANDBOX/bs/bin/tool" "$SANDBOX/bs/bin/$tool"
  chmod +x "$SANDBOX/bs/bin/$tool"
done
chmod +x "$SANDBOX/bs/scripts/bootstrap.sh" "$SANDBOX/bs/scripts/gen.sh"
if PATH="$SANDBOX/bs/bin:$PATH" "$SANDBOX/bs/scripts/bootstrap.sh" --yes >"$SANDBOX/out" 2>&1; then
  if [ -e "$SANDBOX/bs/Config/Device.local" ]; then
    fail "bootstrap.sh --yes created a Config/Device.local (a copy of the example pins nothing)"
  elif [ ! -f "$SANDBOX/bs/Config/Signing.local.xcconfig" ]; then
    fail "bootstrap.sh --yes did not create Config/Signing.local.xcconfig"
  elif ! grep -q "Config/Device.local is optional" "$SANDBOX/out"; then
    fail "bootstrap.sh --yes does not say how to pin a phone"
  else
    pass "bootstrap.sh --yes creates the signing config, not a Device.local, and says how to pin a phone"
  fi
else
  fail "bootstrap.sh --yes failed in the sandbox: $(tail -2 "$SANDBOX/out" | tr '\n' ' ')"
fi

# 5. scan_secrets.sh (R8-6): it must flag a recording, caption, keychain, signing-request or SQLite -wal/-shm file committed
#    outside the synthetic-fixture folders, accept the synthetic ones, report a broken trufflehog instead of dying
#    silently, and allow MacParakeet's placeholder-URL test only at its real paths. The copy runs in a throwaway git
#    repository with a stub trufflehog; nothing is scanned for real and nothing leaves the machine.
mkdir -p "$SANDBOX/ss/bin"
cat >"$SANDBOX/ss/bin/trufflehog" <<'STUB'
#!/usr/bin/env bash
# Stub: `git` mode reports what $STUB_FINDING_FILE names (a repository-relative path, as trufflehog's git mode does),
# `filesystem` mode reports what $STUB_FS_FINDING_FILE names (an ABSOLUTE path, as its filesystem mode does), both with
# the matched value $STUB_RAW (default: not-a-secret); STUB_FAIL=1 stands for a trufflehog that errors.
if [ "${STUB_FAIL:-0}" = "1" ]; then
  echo "boom: could not open the repository" >&2
  exit 3
fi
if [ "${1:-}" = "git" ] && [ -n "${STUB_FINDING_FILE:-}" ]; then
  printf '{"DetectorName":"Stub","Raw":"%s","SourceMetadata":{"Data":{"Git":{"file":"%s","commit":"0123456789abcdef"}}}}\n' \
    "${STUB_RAW:-not-a-secret}" "$STUB_FINDING_FILE"
fi
if [ "${1:-}" = "filesystem" ] && [ -n "${STUB_FS_FINDING_FILE:-}" ]; then
  printf '{"DetectorName":"Stub","Raw":"%s","SourceMetadata":{"Data":{"Filesystem":{"file":"%s"}}}}\n' \
    "${STUB_RAW:-not-a-secret}" "$STUB_FS_FINDING_FILE"
fi
exit 0
STUB
chmod +x "$SANDBOX/ss/bin/trufflehog"
sandbox_repo() { # sandbox_repo <name> <file...>: a new git repository holding scan_secrets.sh and empty files at these paths
  local repo="$SANDBOX/ss/$1"
  shift
  mkdir -p "$repo/scripts"
  cp scripts/scan_secrets.sh "$repo/scripts/scan_secrets.sh"
  (
    cd "$repo"
    env -u GIT_DIR -u GIT_WORK_TREE git -c init.defaultBranch=main init -q .
    for path in "$@"; do
      mkdir -p "$(dirname "$path")"
      : >"$path"
    done
    # -f: a global gitignore (this Mac's ignores keychains and signing requests) must not drop a file from the sandbox
    env -u GIT_DIR -u GIT_WORK_TREE git add -f -A
    env -u GIT_DIR -u GIT_WORK_TREE git -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false \
      -c core.hooksPath=/dev/null commit -q -m "sandbox"
  )
  echo "$repo"
}
scan_in() { # scan_in <repo> [NAME=value ...]: scan_secrets.sh with the stub trufflehog; prints its exit status, its output is in $SANDBOX/out
  local repo="$1" status=0
  shift
  (cd "$repo" && env -u GIT_DIR -u GIT_WORK_TREE PATH="$SANDBOX/ss/bin:$PATH" ${@+"$@"} scripts/scan_secrets.sh >"$SANDBOX/out" 2>&1) || status=$?
  echo "$status"
}

repo=$(sandbox_repo leaky notes/visit.m4a data/ichirp.sqlite-wal data/ichirp.sqlite-shm keys/Example.keychain-db \
  signing/request.certSigningRequest docs/consult.vtt App/Resources/Samples/synthetic.m4a \
  ChirpKit/Tests/ChirpAudioTests/Fixtures/synthetic.wav upstream/macparakeet/docs/demo.mp4)
status=$(scan_in "$repo")
missed=""
for leaked in notes/visit.m4a data/ichirp.sqlite-wal data/ichirp.sqlite-shm keys/Example.keychain-db \
  signing/request.certSigningRequest docs/consult.vtt; do
  grep -q "$leaked" "$SANDBOX/out" || missed="$missed $leaked"
done
if [ "$status" != "1" ]; then
  fail "scan_secrets.sh exits $status (expected 1) for a repository with a recording, a caption, a keychain and SQLite -wal/-shm files"
elif [ -n "$missed" ]; then
  fail "scan_secrets.sh did not name:$missed"
elif grep -qE "Samples/synthetic.m4a|Fixtures/synthetic.wav|upstream/macparakeet/docs/demo.mp4" "$SANDBOX/out"; then
  fail "scan_secrets.sh flags a synthetic fixture or the upstream mirror"
else
  pass "scan_secrets.sh flags recordings, captions, keychains and SQLite -wal/-shm files outside the fixture folders, and only those"
fi

repo=$(sandbox_repo tidy App/Resources/Samples/synthetic.m4a ChirpKit/Tests/ChirpAudioTests/Fixtures/synthetic.wav \
  README.md)
if [ "$(scan_in "$repo")" = "0" ] && grep -q "SECRET SCAN CLEAN" "$SANDBOX/out"; then
  pass "scan_secrets.sh is clean for synthetic fixtures only"
else
  fail "scan_secrets.sh is not clean for a repository holding only synthetic fixtures: $(tail -3 "$SANDBOX/out" | tr '\n' ' ')"
fi

status=$(scan_in "$repo" STUB_FAIL=1)
if [ "$status" = "2" ] && grep -q "boom: could not open the repository" "$SANDBOX/out"; then
  pass "scan_secrets.sh reports a failing trufflehog (exit 2, its message shown) instead of exiting silently"
else
  fail "scan_secrets.sh hides a trufflehog failure (exit $status): $(tail -3 "$SANDBOX/out" | tr '\n' ' ')"
fi

status=$(scan_in "$repo" STUB_FINDING_FILE=upstream/macparakeet/Tests/MacParakeetTests/Utilities/MediaPlatformTests.swift)
if [ "$status" = "0" ]; then
  pass "scan_secrets.sh allows MacParakeet's placeholder-URL test at its upstream path"
else
  fail "scan_secrets.sh flags MacParakeet's placeholder-URL test at its upstream path (exit $status)"
fi
status=$(scan_in "$repo" STUB_FINDING_FILE=ChirpKit/Tests/ChirpIngestTests/MediaPlatformTests.swift)
if [ "$status" = "1" ] && grep -q "ChirpKit/Tests/ChirpIngestTests/MediaPlatformTests.swift" "$SANDBOX/out"; then
  pass "scan_secrets.sh does not allow a file merely named MediaPlatformTests.swift elsewhere"
else
  fail "scan_secrets.sh allows a MediaPlatformTests.swift outside MacParakeet's paths (exit $status)"
fi

# Filesystem mode reports ABSOLUTE paths, and the main checkout holds one worktree per lane (.claude/worktrees/<name>/),
# each with its own upstream/macparakeet copy. Run from the repository root, as AGENTS.md says to before every push, the
# scan must allow MacParakeet's test in all of them (it printed about 49 false findings without this) and still flag any
# other file. The finding paths below are built from the logical path the shell reports ($PWD), like trufflehog's.
worktree="$repo/.claude/worktrees/lane-x"
mirror_test="upstream/macparakeet/Tests/MacParakeetTests/Utilities/MediaPlatformTests.swift"
status=$(scan_in "$repo" STUB_FS_FINDING_FILE="$repo/$mirror_test")
if [ "$status" = "0" ]; then
  pass "scan_secrets.sh allows MacParakeet's test at its upstream path when the filesystem scan reports it absolutely"
else
  fail "scan_secrets.sh flags MacParakeet's test at its upstream path in filesystem mode (exit $status)"
fi
status=$(scan_in "$repo" STUB_FS_FINDING_FILE="$worktree/$mirror_test")
if [ "$status" = "0" ]; then
  pass "scan_secrets.sh allows MacParakeet's test inside a lane worktree under .claude/worktrees"
else
  fail "scan_secrets.sh flags MacParakeet's test inside a lane worktree (exit $status): $(grep -m1 MediaPlatformTests "$SANDBOX/out" | cut -c1-160)"
fi
status=$(scan_in "$repo" STUB_FS_FINDING_FILE="$worktree/Tests/MacParakeetTests/Utilities/MediaPlatformTests.swift")
if [ "$status" = "0" ]; then
  pass "scan_secrets.sh allows MacParakeet's test at its pre-mirror path inside a lane worktree"
else
  fail "scan_secrets.sh flags MacParakeet's test at its pre-mirror path inside a lane worktree (exit $status)"
fi
status=$(scan_in "$repo" STUB_FS_FINDING_FILE="$worktree/ChirpKit/Tests/ChirpIngestTests/MediaPlatformTests.swift")
if [ "$status" = "1" ] && grep -q ".claude/worktrees/lane-x/ChirpKit/Tests/ChirpIngestTests/MediaPlatformTests.swift" "$SANDBOX/out"; then
  pass "scan_secrets.sh still flags any other file inside a lane worktree"
else
  fail "scan_secrets.sh allows another MediaPlatformTests.swift inside a lane worktree (exit $status)"
fi
status=$(scan_in "$repo" STUB_FS_FINDING_FILE="$repo/notes/.claude/worktrees/lane-x/$mirror_test")
if [ "$status" = "1" ]; then
  pass "scan_secrets.sh strips .claude/worktrees/<name>/ only at the start of the path"
else
  fail "scan_secrets.sh allows a MediaPlatformTests.swift under notes/.claude/worktrees (exit $status)"
fi

# Two placeholder links with a user name and the password "secret", in ChirpIngest's link classifier and its tests (they
# prove such a link is refused). The history keeps the commits that added them and cannot be rewritten, so they are
# allowed by their exact value wherever they appear; any other link with credentials is still a finding. The URLs are
# assembled from parts so that this file holds no link with credentials of its own (the scanner reads it too).
slashes="//"
placeholder_short="https:${slashes}name:secret@host"
placeholder_long="https:${slashes}jane:secret@cdn.example.com"
other_credentials="https:${slashes}alice:hunter2@host"
status=$(scan_in "$repo" STUB_FINDING_FILE=ChirpKit/Sources/ChirpIngest/Links/Example.swift STUB_RAW="$placeholder_short")
if [ "$status" = "0" ]; then
  pass "scan_secrets.sh allows the placeholder link with credentials in the link classifier's comment (git history)"
else
  fail "scan_secrets.sh flags the placeholder link in the link classifier's comment (exit $status)"
fi
status=$(scan_in "$repo" STUB_FS_FINDING_FILE="$worktree/ChirpKit/Tests/ChirpIngestTests/Example.swift" STUB_RAW="$placeholder_long")
if [ "$status" = "0" ]; then
  pass "scan_secrets.sh allows the placeholder link in the link classifier's tests (a lane worktree)"
else
  fail "scan_secrets.sh flags the placeholder link in the link classifier's tests (exit $status)"
fi
status=$(scan_in "$repo" STUB_FINDING_FILE=ChirpKit/Sources/ChirpIngest/Links/Example.swift STUB_RAW="$other_credentials")
if [ "$status" = "1" ] && grep -q "Possible secrets" "$SANDBOX/out"; then
  pass "scan_secrets.sh still flags any other link with credentials"
else
  fail "scan_secrets.sh lets another link with credentials through (exit $status)"
fi
status=$(scan_in "$repo" STUB_FINDING_FILE=ChirpKit/Sources/ChirpIngest/Links/Example.swift STUB_RAW="${placeholder_short}x")
if [ "$status" = "1" ]; then
  pass "scan_secrets.sh allows the placeholder links by exact value only, not by shape or prefix"
else
  fail "scan_secrets.sh allows a link that merely starts like a placeholder (exit $status)"
fi

# 6. stamp_build_identity.sh (R8-24): the app and its widget extension get the same build date and CFBundleVersion even
#    when the build crosses a minute boundary between their two script phases. The clock is a stub `date`; the targets'
#    Info.plists are sandbox files edited with the real PlistBuddy.
mkdir -p "$SANDBOX/st/bin" "$SANDBOX/st/src" "$SANDBOX/st/obj" "$SANDBOX/st/widget" "$SANDBOX/st/app"
cp scripts/stamp_build_identity.sh "$SANDBOX/st/stamp.sh"
chmod +x "$SANDBOX/st/stamp.sh"
cat >"$SANDBOX/st/bin/date" <<'STUB'
#!/usr/bin/env bash
# The clock is the first line of $CLOCK_FILE (an ISO UTC time); the two formats the stamp script asks for.
now=$(head -1 "$CLOCK_FILE")
case "$*" in
  "-u +%Y-%m-%dT%H:%M:%SZ") echo "$now" ;;
  "-u +%Y%m%d%H%M") echo "$now" | tr -d ':TZ-' | cut -c1-12 ;;
  *) echo "unexpected date call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$SANDBOX/st/bin/date"
for target in widget app; do
  cat >"$SANDBOX/st/$target/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ChirpGitCommit</key><string>unknown</string><key>ChirpGitBranch</key><string>unknown</string>
<key>ChirpGitDirty</key><string>0</string><key>ChirpBuildDateUTC</key><string>unknown</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
done
stamp() { # stamp <widget|app> <ISO time> [args]: runs the stamp script for that target at that time
  local target="$1" time="$2"
  shift 2
  echo "$time" >"$SANDBOX/st/clock"
  env -u GIT_DIR -u GIT_WORK_TREE PATH="$SANDBOX/st/bin:$PATH" CLOCK_FILE="$SANDBOX/st/clock" \
    TARGET_BUILD_DIR="$SANDBOX/st/$target" INFOPLIST_PATH=Info.plist SRCROOT="$SANDBOX/st/src" OBJROOT="$SANDBOX/st/obj" \
    "$SANDBOX/st/stamp.sh" ${@+"$@"} >/dev/null
}
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$SANDBOX/st/$1/Info.plist"; }

# The extension is stamped at 17:30:59, the app (after its long Swift compile) at 17:31:05, a minute later.
stamp widget 2026-10-01T17:30:59Z --new-build
stamp app 2026-10-01T17:31:05Z
if [ "$(plist_value widget CFBundleVersion)" = "$(plist_value app CFBundleVersion)" ] \
  && [ "$(plist_value app CFBundleVersion)" = "20261001173059" ] \
  && [ "$(plist_value widget ChirpBuildDateUTC)" = "$(plist_value app ChirpBuildDateUTC)" ]; then
  pass "the app and its widget extension get one CFBundleVersion and one build date per build"
else
  fail "the widget stamped $(plist_value widget CFBundleVersion) and the app $(plist_value app CFBundleVersion) (expected both 20261001173059)"
fi
# The next build starts with the extension again and gets a new, larger number everywhere.
stamp widget 2026-10-01T17:45:10Z --new-build
stamp app 2026-10-01T17:45:40Z
if [ "$(plist_value app CFBundleVersion)" = "20261001174510" ] && [ "$(plist_value widget CFBundleVersion)" = "20261001174510" ]; then
  pass "the next build gets a new number (seconds resolution, later is larger)"
else
  fail "the next build did not get a new shared number: widget $(plist_value widget CFBundleVersion), app $(plist_value app CFBundleVersion)"
fi
# A date file left by an old build (more than two hours) is never reused by an app-only run.
touch -t 202610011000 "$SANDBOX/st/obj/ChirpBuildDate.txt"
stamp app 2026-10-01T19:00:00Z
if [ "$(plist_value app CFBundleVersion)" = "20261001190000" ]; then
  pass "an app-only run does not reuse a stale build date"
else
  fail "an app-only run reused a stale build date: $(plist_value app CFBundleVersion)"
fi

# 7. The privacy manifest (R8-22) declares the "required reason" API categories the app really uses. A category that is
#    used but not declared is flagged at upload (ITMS-91053), so scripts/check_privacy_manifest.sh compares the manifest
#    with the first-party sources, with the imports (`nm -u`) of the vendored runtimes when they are built, and, in CI,
#    with every binary of the built app. The first version read Swift sources only and missed that the Rust standard
#    library inside needle-c imports stat, fstat and lstat (fix round 1 of plan 024). A declared category the scan
#    does not see is a note, not a failure: only a missing declaration blocks an upload. Every rule below is proven on a
#    compiled test program (a few lines of C, built with cc), so a pattern that stopped matching fails here.
if ! plutil -lint App/PrivacyInfo.xcprivacy >"$SANDBOX/out" 2>&1; then
  fail "App/PrivacyInfo.xcprivacy is not a valid property list: $(head -1 "$SANDBOX/out")"
else
  pass "App/PrivacyInfo.xcprivacy is a valid property list"
fi
PRIVACY_CHECK=scripts/check_privacy_manifest.sh
privacy_case() { # privacy_case <what it proves> <expected exit code> <expected output: extended regex, "" for any> <args...>
  local what="$1" want_code="$2" want_text="$3" code=0
  shift 3
  "$PRIVACY_CHECK" "$@" >"$SANDBOX/pm/out" 2>&1 || code=$?
  if [ "$code" -ne "$want_code" ]; then
    fail "$what: exit $code, expected $want_code: $(tail -2 "$SANDBOX/pm/out" | tr '\n' ' ')"
  elif [ -n "$want_text" ] && ! grep -qE -- "$want_text" "$SANDBOX/pm/out"; then
    fail "$what: the output lacks /$want_text/: $(tail -2 "$SANDBOX/pm/out" | tr '\n' ' ')"
  else
    pass "$what"
  fi
}
manifest_without() { # manifest_without <category> <file>: a copy of the real manifest that does not declare one category
  python3 - "$1" "$2" <<'PY'
import plistlib
import sys

with open("App/PrivacyInfo.xcprivacy", "rb") as handle:
    manifest = plistlib.load(handle)
manifest["NSPrivacyAccessedAPITypes"] = [
    item
    for item in manifest["NSPrivacyAccessedAPITypes"]
    if item["NSPrivacyAccessedAPIType"] != "NSPrivacyAccessedAPICategory" + sys.argv[1]
]
with open(sys.argv[2], "wb") as handle:
    plistlib.dump(manifest, handle)
PY
}
mkdir -p "$SANDBOX/pm/src" "$SANDBOX/pm/bin" "$SANDBOX/pm/empty" "$SANDBOX/pm/Sources"
manifest_without FileTimestamp "$SANDBOX/pm/no-file-timestamp.xcprivacy"
manifest_without DiskSpace "$SANDBOX/pm/no-disk-space.xcprivacy"
printf 'import Foundation\nlet uptime = ProcessInfo.processInfo.systemUptime\n' >"$SANDBOX/pm/Sources/Boot.swift"
NO_SOURCES="$SANDBOX/pm/empty"

# Test programs: what a binary imports is read from a real binary, not assumed.
cat >"$SANDBOX/pm/src/clean.c" <<'C'
int main(void) { return 0; }
C
cat >"$SANDBOX/pm/src/stat.c" <<'C'
#include <sys/stat.h>
int main(void) { struct stat info; return stat("/", &info); }
C
cat >"$SANDBOX/pm/src/statfs.c" <<'C'
#include <sys/mount.h>
int main(void) { struct statfs info; return statfs("/", &info); }
C
cat >"$SANDBOX/pm/src/boot.c" <<'C'
#include <mach/mach_time.h>
int main(void) { return (int)mach_absolute_time(); }
C
cat >"$SANDBOX/pm/src/selector.c" <<'C'
const char *selector = "systemUptime";
int main(void) { return selector[0]; }
C
cat >"$SANDBOX/pm/src/inode64.c" <<'C'
extern int stat_inode64(const char *path, void *info) __asm__("_stat$INODE64");
int probe(void) { char info[512]; return stat_inode64("/", info); }
C
if ! command -v cc >/dev/null 2>&1; then
  fail "cc (Xcode's command line tools) is needed to build the privacy checker's test programs"
fi
for name in clean stat statfs boot selector; do
  if ! cc -w -o "$SANDBOX/pm/bin/$name" "$SANDBOX/pm/src/$name.c" 2>"$SANDBOX/pm/cc.err"; then
    fail "cc could not build the $name test program: $(head -1 "$SANDBOX/pm/cc.err")"
  fi
done
if cc -w -c -o "$SANDBOX/pm/bin/stat.o" "$SANDBOX/pm/src/stat.c" 2>"$SANDBOX/pm/cc.err" \
  && cc -w -c -o "$SANDBOX/pm/bin/inode64.o" "$SANDBOX/pm/src/inode64.c" 2>>"$SANDBOX/pm/cc.err" \
  && ar rcs "$SANDBOX/pm/bin/libstat.a" "$SANDBOX/pm/bin/stat.o" 2>>"$SANDBOX/pm/cc.err" \
  && ar rcs "$SANDBOX/pm/bin/libinode64.a" "$SANDBOX/pm/bin/inode64.o" 2>>"$SANDBOX/pm/cc.err"; then
  :
else
  fail "cc or ar could not build the static test libraries: $(head -1 "$SANDBOX/pm/cc.err")"
fi
# A universal library whose arm64 slice is clean and whose x86_64 slice imports mach_absolute_time: `nm` alone reads only
# one slice of a universal file, and the CI app build (the generic simulator destination) makes arm64 + x86_64 files.
if cc -w -arch arm64 -c -o "$SANDBOX/pm/bin/clean-arm64.o" "$SANDBOX/pm/src/clean.c" 2>"$SANDBOX/pm/cc.err" \
  && cc -w -arch x86_64 -c -o "$SANDBOX/pm/bin/boot-x86_64.o" "$SANDBOX/pm/src/boot.c" 2>>"$SANDBOX/pm/cc.err" \
  && ar rcs "$SANDBOX/pm/bin/libclean-arm64.a" "$SANDBOX/pm/bin/clean-arm64.o" 2>>"$SANDBOX/pm/cc.err" \
  && ar rcs "$SANDBOX/pm/bin/libboot-x86_64.a" "$SANDBOX/pm/bin/boot-x86_64.o" 2>>"$SANDBOX/pm/cc.err" \
  && lipo -create "$SANDBOX/pm/bin/libclean-arm64.a" "$SANDBOX/pm/bin/libboot-x86_64.a" \
    -output "$SANDBOX/pm/bin/libfat.a" 2>>"$SANDBOX/pm/cc.err"; then
  :
else
  fail "cc, ar or lipo could not build the universal test library: $(head -1 "$SANDBOX/pm/cc.err")"
fi

# The real manifest against the real sources and, when they are built, the real vendored runtimes (a fresh checkout
# has none, and CI builds them after this script runs, so there it reads the sources only).
privacy_case "the manifest covers what the sources use and what the vendored runtimes import (when they are built)" \
  0 "covers every required-reason API"
privacy_case "the check notices a used category the manifest lacks (sources)" \
  1 'DiskSpace is used \(.+\) but the manifest does not declare it' \
  --manifest "$SANDBOX/pm/no-disk-space.xcprivacy" --binary "$SANDBOX/pm/bin/clean"
privacy_case "the check notices a new first-party use of a required-reason API" \
  1 'SystemBootTime is used \(.*Boot\.swift:2\) but the manifest does not declare it' \
  --sources "$SANDBOX/pm/Sources" --binary "$SANDBOX/pm/bin/clean"

# The imports of a binary, which the first version could not see.
privacy_case "stat imported by a program is File Timestamp, and a manifest without it is a mismatch" \
  1 'FileTimestamp is used \(.*/bin/stat imports _stat\) but the manifest does not declare it' \
  --manifest "$SANDBOX/pm/no-file-timestamp.xcprivacy" --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/stat"
privacy_case "the same import inside a static library, the shape of the vendored needle-c archive" \
  1 'FileTimestamp is used \(.*/libstat\.a imports _stat\) but the manifest does not declare it' \
  --manifest "$SANDBOX/pm/no-file-timestamp.xcprivacy" --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/libstat.a"
privacy_case "the x86_64 spelling stat\$INODE64 counts as stat" \
  1 'FileTimestamp is used \(.*/libinode64\.a imports _stat\$INODE64\) but the manifest does not declare it' \
  --manifest "$SANDBOX/pm/no-file-timestamp.xcprivacy" --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/libinode64.a"
privacy_case "every slice of a universal library is read (the import is only in its x86_64 slice)" \
  1 'SystemBootTime is used \(.*/libfat\.a imports _mach_absolute_time\) but the manifest does not declare it' \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/libfat.a"
privacy_case "statfs imported by a program is Disk Space" \
  1 'DiskSpace is used \(.*/bin/statfs imports _statfs\) but the manifest does not declare it' \
  --manifest "$SANDBOX/pm/no-disk-space.xcprivacy" --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/statfs"
privacy_case "mach_absolute_time imported by a program is System Boot Time (the manifest declares none)" \
  1 'SystemBootTime is used \(.*/bin/boot imports _mach_absolute_time\) but the manifest does not declare it' \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/boot"
privacy_case "the Objective-C selector systemUptime inside a program is System Boot Time" \
  1 'SystemBootTime is used \(.*/bin/selector contains the selector systemUptime\) but the manifest does not declare it' \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/selector"
privacy_case "the manifest as it stands accepts the stat and statfs imports (File Timestamp, Disk Space)" \
  0 "covers every required-reason API" \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/stat" --binary "$SANDBOX/pm/bin/statfs"
privacy_case "a declared category the scan does not see is a note, not a failure" \
  0 'note: not seen by this scan.*FileTimestamp' \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/clean"

# A built app: every Mach-O file counts, the XCTest frameworks of a test build do not.
mkdir -p "$SANDBOX/pm/Fake.app/Frameworks/XCTest.framework" "$SANDBOX/pm/Shipped.app/Frameworks/Other.framework" \
  "$SANDBOX/pm/Empty.app"
if [ -x "$SANDBOX/pm/bin/stat" ] && [ -x "$SANDBOX/pm/bin/boot" ]; then
  cp "$SANDBOX/pm/bin/stat" "$SANDBOX/pm/Fake.app/Fake"
  cp "$SANDBOX/pm/bin/boot" "$SANDBOX/pm/Fake.app/Frameworks/XCTest.framework/XCTest"
  cp "$SANDBOX/pm/bin/stat" "$SANDBOX/pm/Shipped.app/Shipped"
  cp "$SANDBOX/pm/bin/boot" "$SANDBOX/pm/Shipped.app/Frameworks/Other.framework/Other"
fi
printf 'not a binary\n' >"$SANDBOX/pm/Empty.app/README.txt"
privacy_case "--app reads the app's own binary (stat is File Timestamp)" \
  1 'FileTimestamp is used \(Fake\.app/Fake imports _stat\) but the manifest does not declare it' \
  --manifest "$SANDBOX/pm/no-file-timestamp.xcprivacy" --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/clean" \
  --app "$SANDBOX/pm/Fake.app"
privacy_case "--app skips the XCTest framework of a test build (its mach_absolute_time is not shipped)" \
  0 "covers every required-reason API" \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/clean" --app "$SANDBOX/pm/Fake.app"
privacy_case "--app reads a shipped framework (the same import in Frameworks/Other.framework is a mismatch)" \
  1 'SystemBootTime is used \(Shipped\.app/Frameworks/Other\.framework/Other imports _mach_absolute_time\)' \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/clean" --app "$SANDBOX/pm/Shipped.app"
privacy_case "--app with no Mach-O file in it fails, so a wrong path cannot pass" \
  1 "no Mach-O file found" \
  --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/clean" --app "$SANDBOX/pm/Empty.app"

# With no --binary the check reads the vendored runtimes that exist: a copy of the script in a made-up checkout whose
# vendor/ holds a Needle archive that imports stat and a llama framework that imports mach_absolute_time.
mkdir -p "$SANDBOX/pmrepo/scripts" "$SANDBOX/pmrepo/App" "$SANDBOX/pmrepo/ChirpKit/Sources" "$SANDBOX/pmrepo/App/Sources" \
  "$SANDBOX/pmrepo/App/Shared" "$SANDBOX/pmrepo/Widgets" "$SANDBOX/pmrepo/vendor/NeedleC.xcframework/ios-arm64" \
  "$SANDBOX/pmrepo/vendor/llama.xcframework/ios-arm64/llama.framework"
cp scripts/check_privacy_manifest.sh "$SANDBOX/pmrepo/scripts/check_privacy_manifest.sh"
chmod +x "$SANDBOX/pmrepo/scripts/check_privacy_manifest.sh"
cp "$SANDBOX/pm/no-file-timestamp.xcprivacy" "$SANDBOX/pmrepo/App/PrivacyInfo.xcprivacy"
if [ -f "$SANDBOX/pm/bin/libstat.a" ] && [ -x "$SANDBOX/pm/bin/boot" ]; then
  cp "$SANDBOX/pm/bin/libstat.a" "$SANDBOX/pmrepo/vendor/NeedleC.xcframework/ios-arm64/libneedle_c.a"
  cp "$SANDBOX/pm/bin/boot" "$SANDBOX/pmrepo/vendor/llama.xcframework/ios-arm64/llama.framework/llama"
fi
PRIVACY_CHECK="$SANDBOX/pmrepo/scripts/check_privacy_manifest.sh"
privacy_case "with no arguments the check reads the vendored Needle archive (stat is File Timestamp)" \
  1 'FileTimestamp is used \(vendor/NeedleC\.xcframework/ios-arm64/libneedle_c\.a imports _stat\)'
privacy_case "with no arguments the check reads the vendored llama framework too" \
  1 'SystemBootTime is used \(vendor/llama\.xcframework/ios-arm64/llama\.framework/llama imports _mach_absolute_time\)'
cp App/PrivacyInfo.xcprivacy "$SANDBOX/pmrepo/App/PrivacyInfo.xcprivacy"
if [ -x "$SANDBOX/pm/bin/clean" ]; then
  cp "$SANDBOX/pm/bin/clean" "$SANDBOX/pmrepo/vendor/llama.xcframework/ios-arm64/llama.framework/llama"
fi
privacy_case "the real manifest covers the vendored Needle archive's stat imports" \
  0 "scanned 0 source files and 2 binaries"
rm -rf "$SANDBOX/pmrepo/vendor"
privacy_case "with no vendored runtimes and no --app the check says no binary was scanned" \
  0 "note: no binary was scanned"
PRIVACY_CHECK=scripts/check_privacy_manifest.sh

# Bad usage and missing files are exit 2, never a quiet pass.
privacy_case "an unknown argument is a usage error" 2 "unknown argument" --nonsense
privacy_case "a missing manifest is exit 2" 2 "is missing or is not a property list" --manifest "$SANDBOX/pm/none.xcprivacy"
privacy_case "a missing source folder is exit 2, so a renamed folder cannot make the scan vacuous" \
  2 "source folder .* not found" --sources "$SANDBOX/pm/nowhere"
privacy_case "a missing --binary file is exit 2" \
  2 "binary .* not found" --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/nowhere"
privacy_case "--app pointing at nothing is exit 2" \
  2 "is not a folder" --sources "$NO_SOURCES" --binary "$SANDBOX/pm/bin/clean" --app "$SANDBOX/pm/Nowhere.app"

# CI cannot run here, so its order is checked: the vendored runtimes and the app are built before the manifest is compared
# with the built app (a step above them would read neither).
ci_line() { # ci_line <awk regex>: the first line of the workflow that matches
  awk -v pattern="$1" '$0 ~ pattern { print NR; exit }' .github/workflows/ci.yml
}
needle_line=$(ci_line '^[[:space:]]+scripts/build_needle[.]sh$')
llama_line=$(ci_line '^[[:space:]]+run: scripts/build_llamacpp[.]sh$')
app_line=$(ci_line '^[[:space:]]+xcodebuild build-for-testing')
privacy_line=$(ci_line '^[[:space:]]+run: scripts/check_privacy_manifest[.]sh --app ')
if [ -n "$needle_line" ] && [ -n "$llama_line" ] && [ -n "$app_line" ] && [ -n "$privacy_line" ] \
  && [ "$needle_line" -lt "$app_line" ] && [ "$llama_line" -lt "$app_line" ] && [ "$app_line" -lt "$privacy_line" ]; then
  pass "CI compares the privacy manifest with the built app, after the Needle and llama.cpp builds and the app build"
else
  fail "ci.yml must run scripts/check_privacy_manifest.sh --app <built app> after the vendored runtimes and the app are built (lines: needle=${needle_line:-none} llama=${llama_line:-none} app=${app_line:-none} privacy=${privacy_line:-none})"
fi

# 8. .gitignore keeps the shared runtimes out of git whether `vendor` is a real folder or the symlink every lane worktree
#    makes (`vendor/` alone matches a folder only, so `git status` showed `?? vendor` and the link could be committed).
mkdir -p "$SANDBOX/gi/real/vendor/models" "$SANDBOX/gi/real/sub/vendor" "$SANDBOX/gi/linked" "$SANDBOX/gi/shared"
cp .gitignore "$SANDBOX/gi/real/.gitignore"
cp .gitignore "$SANDBOX/gi/linked/.gitignore"
: >"$SANDBOX/gi/real/vendor/models/needle3.cact"
ln -s "$SANDBOX/gi/shared" "$SANDBOX/gi/linked/vendor"
env -u GIT_DIR -u GIT_WORK_TREE git -c init.defaultBranch=main -C "$SANDBOX/gi/real" init -q .
env -u GIT_DIR -u GIT_WORK_TREE git -c init.defaultBranch=main -C "$SANDBOX/gi/linked" init -q .
if env -u GIT_DIR -u GIT_WORK_TREE git -C "$SANDBOX/gi/linked" check-ignore -q vendor \
  && env -u GIT_DIR -u GIT_WORK_TREE git -C "$SANDBOX/gi/real" check-ignore -q vendor/models/needle3.cact \
  && env -u GIT_DIR -u GIT_WORK_TREE git -C "$SANDBOX/gi/real" check-ignore -q sub/vendor/x; then
  pass ".gitignore ignores the vendor symlink, a real vendor folder and a nested vendor folder"
else
  fail ".gitignore no longer ignores the vendor symlink, a real vendor folder or a nested vendor folder"
fi

echo ""
if [ "$failures" -gt 0 ]; then
  echo "SCRIPT CHECKS FAILED: $failures of $checks checks." >&2
  exit 1
fi
echo "SCRIPT CHECKS PASSED: $checks checks."
