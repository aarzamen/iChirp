#!/usr/bin/env bash
# Checks the scripts themselves: that every script parses under macOS's bash 3.2, and the logic that nothing else runs
# automatically because it needs a phone, signing or a scanner. Nothing here builds the app, signs, installs, reaches the
# network or touches Config/Device.local, Config/Signing.local.xcconfig or a phone: each check runs a copy of the script
# in a temporary folder, with stubs where the real tool would be.
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
# Stub: `git` mode reports what $STUB_FINDING_FILE names (a path inside the repository), `filesystem` mode reports
# nothing; STUB_FAIL=1 stands for a trufflehog that errors.
if [ "${STUB_FAIL:-0}" = "1" ]; then
  echo "boom: could not open the repository" >&2
  exit 3
fi
if [ "${1:-}" = "git" ] && [ -n "${STUB_FINDING_FILE:-}" ]; then
  printf '{"DetectorName":"Stub","Raw":"not-a-secret","SourceMetadata":{"Data":{"Git":{"file":"%s","commit":"0123456789abcdef"}}}}\n' "$STUB_FINDING_FILE"
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

# 7. The privacy manifest (R8-22) declares exactly the "required reason" API categories the app's own sources use: a
#    category the code uses but the manifest lacks would be flagged at upload (ITMS-91053), and one declared but no
#    longer used is a false statement. Comment lines are ignored; third-party packages ship their own manifests.
privacy_problems() { # privacy_problems <manifest> <source folder...>: one line per problem, nothing when consistent
  local manifest="$1"
  shift
  python3 - "$manifest" "$@" <<'PY'
import json, re, subprocess, sys
from pathlib import Path

manifest = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", sys.argv[1]]))
declared = {item["NSPrivacyAccessedAPIType"] for item in manifest.get("NSPrivacyAccessedAPITypes", [])}
patterns = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|\bNSUserDefaults\b|\bAppStorage\b",
    "NSPrivacyAccessedAPICategoryDiskSpace": r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|\.systemSize\b"
    r"|NSFileSystemFreeSize|NSFileSystemSize|\bstatfs\b|\bstatvfs\b",
    "NSPrivacyAccessedAPICategoryFileTimestamp": r"\.creationDate\b|\.modificationDate\b|contentModificationDate"
    r"|creationDateKey|NSFileCreationDate|NSFileModificationDate|\bstat\(|\blstat\(|\bfstat\(|getattrlist"
    r"|contentAccessDate|attributeModificationDate",
    "NSPrivacyAccessedAPICategorySystemBootTime": r"systemUptime|mach_absolute_time|mach_continuous_time|\bclock_gettime",
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"activeInputModes",
}
used = {}
for root in sys.argv[2:]:
    for path in sorted(Path(root).rglob("*.swift")):
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for category, pattern in patterns.items():
                if category not in used and re.search(pattern, line):
                    used[category] = f"{path}:{number}"
for category, where in sorted(used.items()):
    if category not in declared:
        print(f"{category} is used ({where}) but the manifest does not declare it")
for category in sorted(declared):
    if category not in used:
        print(f"{category} is declared but no source uses it")
PY
}
if ! plutil -lint App/PrivacyInfo.xcprivacy >"$SANDBOX/out" 2>&1; then
  fail "App/PrivacyInfo.xcprivacy is not a valid property list: $(head -1 "$SANDBOX/out")"
else
  problems=$(privacy_problems App/PrivacyInfo.xcprivacy ChirpKit/Sources App/Sources App/Shared Widgets)
  if [ -z "$problems" ]; then
    pass "App/PrivacyInfo.xcprivacy declares exactly the required-reason APIs the sources use"
  else
    fail "App/PrivacyInfo.xcprivacy disagrees with the sources: $(echo "$problems" | tr '\n' ';')"
  fi
fi
# The check itself is not vacuous: a manifest without a category the sources use, and a source that uses one it lacks.
mkdir -p "$SANDBOX/pm/Sources"
cp App/PrivacyInfo.xcprivacy "$SANDBOX/pm/without-disk-space.xcprivacy"
plutil -remove NSPrivacyAccessedAPITypes.1 "$SANDBOX/pm/without-disk-space.xcprivacy"
if privacy_problems "$SANDBOX/pm/without-disk-space.xcprivacy" ChirpKit/Sources App/Sources App/Shared Widgets \
  | grep -q "DiskSpace is used .* but the manifest does not declare it"; then
  pass "the manifest check notices a used category the manifest lacks"
else
  fail "the manifest check missed a used category the manifest lacks"
fi
printf 'import Foundation\nlet uptime = ProcessInfo.processInfo.systemUptime\n' >"$SANDBOX/pm/Sources/Boot.swift"
if privacy_problems App/PrivacyInfo.xcprivacy "$SANDBOX/pm/Sources" \
  | grep -q "SystemBootTime is used .* but the manifest does not declare it"; then
  pass "the manifest check notices a new use of a required-reason API"
else
  fail "the manifest check missed a new use of a required-reason API"
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
