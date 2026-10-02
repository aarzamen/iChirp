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

# 2. run_device.sh tells a locked phone, a signing problem and any other failure apart (R8-2). xcodebuild's log always
#    carries signing words (the environment dump of the Stamp Build Identity phases, CodeSign lines), so a Swift compile
#    error must not be called a signing failure. Fixture logs are named <kind>--<expected>--<what>.log.
for log in scripts/fixtures/device-logs/*.log; do
  name=$(basename "$log" .log)
  kind=${name%%--*}
  rest=${name#*--}
  expected=${rest%%--*}
  actual=$(scripts/run_device.sh --classify-log "$kind" "$log")
  if [ "$actual" = "$expected" ]; then
    pass "run_device.sh classifies $name as $expected"
  else
    fail "run_device.sh classifies $name as $actual, expected $expected"
  fi
done

# 3. run_device.sh device selection never reads or writes the real Config/Device.local: the script runs from a copy.
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

echo ""
if [ "$failures" -gt 0 ]; then
  echo "SCRIPT CHECKS FAILED: $failures of $checks checks." >&2
  exit 1
fi
echo "SCRIPT CHECKS PASSED: $checks checks."
