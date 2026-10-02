#!/usr/bin/env bash
# Checks that the privacy manifest (App/PrivacyInfo.xcprivacy) declares every "required reason" API the app uses, so App
# Store processing does not reject the upload for a missing declaration (ITMS-91053).
#
# Evidence it reads:
#   - the first-party Swift sources (ChirpKit/Sources, App/Sources, App/Shared, Widgets), comment lines ignored;
#   - the vendored runtimes built by scripts/build_needle.sh and scripts/build_llamacpp.sh, when they exist: their
#     undefined symbols (`nm -u`, every slice of a universal file), because the Rust standard library inside needle-c
#     imports stat, fstat and lstat;
#   - a built app (--app): every Mach-O file in it except the test frameworks, by imported symbols and Objective-C
#     selector names. A static library can hide imports from `nm` (FluidAudio's NeMo library keeps its Rust standard
#     library as bitcode, which is where `fstatat` comes from), so only the linked binary shows everything it pulled in.
#
# What it proves: nothing this scan sees is undeclared. What it does not prove or see:
#   - that a declaration is still needed. A category the manifest declares but this scan did not see is printed as a
#     note, never a failure: a scan without the vendored runtimes (a fresh checkout) or without a built app cannot see
#     what those import, and an extra declaration with a valid reason is harmless, while a missing one blocks the upload;
#   - the contents of dynamically loaded system frameworks (they are Apple's own);
#   - the privacy manifests that other Swift packages ship in their resource bundles (GRDB does; Xcode merges them at
#     build time), so a category a package declares for itself is not required here.
#
# CI runs it after the app build, so the vendored runtimes and the built app are both present:
#   scripts/check_privacy_manifest.sh --app .build/xcode/Build/Products/Debug-iphonesimulator/iChirp.app
# On a Mac, with no argument, it reads the sources and whichever vendored runtimes have been built.
#
# Usage: scripts/check_privacy_manifest.sh [--app <built .app>] [--manifest <file>] [--sources <folder>]... [--binary <file>]...
#        --binary replaces the vendored runtimes as the binaries to read (the self-checks use it); --sources replaces the
#        default source folders.
# Exit:  0 nothing undeclared was found · 1 a mismatch (each one printed) · 2 bad usage, a missing file, a missing tool
#        or a file whose imports cannot be read (nm or lipo fails on it): unknown imports are not "no imports", so an
#        unreadable binary stops the scan instead of counting as scanned.
set -euo pipefail
cd "$(dirname "$0")/.."

MANIFEST="App/PrivacyInfo.xcprivacy"
SOURCES=()
BINARIES=()
APPS=()
usage() {
  cat >&2 <<'EOF'
usage: scripts/check_privacy_manifest.sh [--app <built .app>] [--manifest <file>] [--sources <folder>]... [--binary <file>]...
  no arguments: the first-party sources and the vendored runtimes that exist (vendor/NeedleC.xcframework, vendor/llama.xcframework)
  --app:        also every Mach-O file of a built app, except the test frameworks (what CI does after the app build)
  --binary:     read these files instead of the vendored runtimes
  --sources:    read these folders instead of ChirpKit/Sources, App/Sources, App/Shared and Widgets
exit: 0 nothing undeclared found, 1 a mismatch (printed), 2 bad usage, a missing file or tool, or a file nm cannot read
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest) [ "$#" -ge 2 ] || { usage; exit 2; }; MANIFEST="$2"; shift 2 ;;
    --sources) [ "$#" -ge 2 ] || { usage; exit 2; }; SOURCES+=("$2"); shift 2 ;;
    --binary) [ "$#" -ge 2 ] || { usage; exit 2; }; BINARIES+=("$2"); shift 2 ;;
    --app) [ "$#" -ge 2 ] || { usage; exit 2; }; APPS+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
for tool in plutil nm lipo strings python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is needed and was not found" >&2; exit 2; }
done
if [ "${#SOURCES[@]}" -eq 0 ]; then
  SOURCES=(ChirpKit/Sources App/Sources App/Shared Widgets)
fi
if [ "${#BINARIES[@]}" -eq 0 ]; then
  # The vendored runtimes, when they have been built (gitignored; absent in a fresh clone).
  shopt -s nullglob
  BINARIES=(vendor/NeedleC.xcframework/*/*.a vendor/llama.xcframework/*/llama.framework/llama)
  shopt -u nullglob
fi

python3 - "$MANIFEST" --sources ${SOURCES[@]+"${SOURCES[@]}"} --binaries ${BINARIES[@]+"${BINARIES[@]}"} \
  --apps ${APPS[@]+"${APPS[@]}"} <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path

manifest_path = sys.argv[1]
groups = {"--sources": [], "--binaries": [], "--apps": []}
current = None
for argument in sys.argv[2:]:
    if argument in groups:
        current = argument
    else:
        groups[current].append(argument)
sources, binaries, apps = groups["--sources"], groups["--binaries"], groups["--apps"]


def stop(message):
    # Exit 2: bad usage, a missing file, or a file whose imports cannot be read. Never a pass.
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def first_line(text, marker):
    # The tools start their errors with their own long path; keep what follows the marker on the first line. nm adds
    # "no symbols" lines for the members it cannot read at all, so prefer the line that says why.
    lines = [line for line in text.strip().splitlines() if line.strip()] or ["no message"]
    line = ([line for line in lines if not line.rstrip().endswith("no symbols")] or lines)[0]
    return line.split(marker, 1)[-1]


PREFIX = "NSPrivacyAccessedAPICategory"
try:
    manifest = json.loads(
        subprocess.check_output(["plutil", "-convert", "json", "-o", "-", manifest_path], stderr=subprocess.DEVNULL)
    )
except (subprocess.CalledProcessError, ValueError):
    stop(f"{manifest_path} is missing or is not a property list")
declared = {item["NSPrivacyAccessedAPIType"].replace(PREFIX, "") for item in manifest.get("NSPrivacyAccessedAPITypes", [])}

# Swift/ObjC source patterns, per category (comment lines are skipped). The names are the ones on Apple's documented list
# (the "Describing use of required reason API" page) and nothing else: clock_gettime, mach_continuous_time and the
# access and attribute-change dates look related but are not on it, so using them is no reason to declare anything.
SOURCE_PATTERNS = {
    "UserDefaults": r"\bUserDefaults\b|\bNSUserDefaults\b|\bAppStorage\b",
    "DiskSpace": r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|\.systemSize\b"
    r"|NSFileSystemFreeSize|NSFileSystemSize|\bstatfs\b|\bstatvfs\b",
    "FileTimestamp": r"\.creationDate\b|\.modificationDate\b|\bfileModificationDate\b|\bfileCreationDate\b"
    r"|contentModificationDate|creationDateKey|NSFileCreationDate|NSFileModificationDate|\bstat\(|\blstat\(|\bfstat\("
    r"|getattrlist",
    "SystemBootTime": r"systemUptime|mach_absolute_time",
    "ActiveKeyboards": r"activeInputModes",
}
# Imported symbols (`nm -u`), per category. Apple's list: stat, fstat, lstat, fstatat, getattrlist* and the date keys
# are file timestamps; statfs, statvfs, fstatfs, fstatvfs and the volume-capacity keys are disk space; mach_absolute_time
# is system boot time. On x86_64 the stat family carries a $INODE64 suffix. clock_gettime and mach_continuous_time are
# not on Apple's list.
SYMBOL_PATTERNS = [
    ("FileTimestamp", r"^_(stat|fstat|lstat|fstatat|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat)(\$INODE64)?$"),
    ("FileTimestamp", r"^_(NSURLContentModificationDateKey|NSURLCreationDateKey|NSFileCreationDate|NSFileModificationDate)$"),
    ("DiskSpace", r"^_(statfs|statvfs|fstatfs|fstatvfs)(\$INODE64)?$"),
    (
        "DiskSpace",
        r"^_(NSURLVolumeAvailableCapacityKey|NSURLVolumeAvailableCapacityForImportantUsageKey"
        r"|NSURLVolumeAvailableCapacityForOpportunisticUsageKey|NSURLVolumeTotalCapacityKey|NSFileSystemFreeSize|NSFileSystemSize)$",
    ),
    ("SystemBootTime", r"^_mach_absolute_time$"),
    ("UserDefaults", r"^_OBJC_CLASS_\$_NSUserDefaults$"),
]
# Objective-C selectors do not appear as imported symbols; they are plain strings in the binary.
SELECTORS = {
    "systemUptime": "SystemBootTime",
    "activeInputModes": "ActiveKeyboards",
    "fileModificationDate": "FileTimestamp",
    "fileCreationDate": "FileTimestamp",
}
# Files in a built app that never ship: the XCTest host injection of a test build.
TEST_ONLY = re.compile(r"(^|/)(XC[A-Za-z]*\.framework|Testing\.framework|libXCTest[^/]*|[^/]*\.xctest|__preview\.dylib)(/|$)")
MACHO_HEADS = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"!<ar"}

used = {}  # category -> first piece of evidence
scanned_sources = 0
scanned_binaries = []
notes = []


def note_use(category, where):
    used.setdefault(category, where)


for root in sources:
    if not os.path.isdir(root):
        stop(f"source folder {root} not found")
    for path in sorted(Path(root).rglob("*.swift")):
        scanned_sources += 1
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for category, pattern in SOURCE_PATTERNS.items():
                if re.search(pattern, line):
                    note_use(category, f"{path}:{number}")


def is_binary(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4) in MACHO_HEADS
    except OSError:
        return False


def slices(path, label):
    # `nm` alone reads one slice of a universal file; the CI app build (generic simulator destination) is arm64 + x86_64.
    # A file whose architectures lipo cannot tell has imports nobody has read: unknown is not "none".
    result = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    archs = result.stdout.split() if result.returncode == 0 else []
    if not archs:
        stop(
            f"cannot tell which architectures {label} has ({first_line(result.stderr, 'lipo: ')}); its imports are "
            "unknown, so this scan cannot vouch for the manifest"
        )
    return archs


def scan_binary(path, label):
    symbols = set()
    for arch in slices(path, label):
        result = subprocess.run(["nm", "-u", "-arch", arch, path], capture_output=True, text=True)
        if result.returncode != 0:
            # Xcode's nm already fails on the Rust standard library inside FluidAudio's NeMo library (bitcode it cannot
            # read) while still listing the other members: a rebuilt libneedle_c.a that fails the same way would lose its
            # stat imports, so a failure here is never a note and a pass.
            stop(
                f"nm could not read {label} ({first_line(result.stderr, 'error: ')}); its imports are unknown, so "
                "this scan cannot vouch for the manifest"
            )
        symbols |= {line.split()[-1] for line in result.stdout.splitlines() if line.split() and line.split()[-1].startswith("_")}
    for symbol in sorted(symbols):
        for category, pattern in SYMBOL_PATTERNS:
            if re.match(pattern, symbol):
                note_use(category, f"{label} imports {symbol}")
    if not path.endswith(".a"):
        listing = subprocess.run(["strings", "-a", path], capture_output=True, text=True)
        if listing.returncode != 0:
            stop(f"strings could not read {label} ({first_line(listing.stderr, ': ')}); its selector names are unknown")
        for selector, category in SELECTORS.items():
            if re.search(rf"^{selector}$", listing.stdout, re.MULTILINE):
                note_use(category, f"{label} contains the selector {selector}")
    scanned_binaries.append(label)


for path in binaries:
    if not os.path.isfile(path):
        stop(f"binary {path} not found")
    scan_binary(path, path)
for app in apps:
    if not os.path.isdir(app):
        stop(f"{app} is not a folder (pass the built .app)")
    found = 0
    for folder, _dirs, files in os.walk(app):
        for name in sorted(files):
            full = os.path.join(folder, name)
            relative = os.path.relpath(full, app)
            if TEST_ONLY.search(relative) or os.path.islink(full) or not is_binary(full):
                continue
            scan_binary(full, f"{os.path.basename(app)}/{relative}")
            found += 1
    if found == 0:
        print(f"error: no Mach-O file found in {app}; is that the built .app?")
        sys.exit(1)

problems = []
for category in sorted(used):
    if category not in declared:
        problems.append(f"{category} is used ({used[category]}) but the manifest does not declare it")
unseen = sorted(declared - set(used))
if unseen:
    notes.append(
        "not seen by this scan, so neither proven used nor unused: " + ", ".join(unseen)
        + ". A declaration is removed only after a scan with every runtime (sources, vendor/ and a built app) finds no use"
    )
if not scanned_binaries:
    notes.append(
        "no binary was scanned (vendor/NeedleC.xcframework and vendor/llama.xcframework are not built, and no --app "
        "was given): the Rust libraries' stat imports are not checked here"
    )

print(f"scanned {scanned_sources} source files and {len(scanned_binaries)} binaries; manifest declares: "
      + (", ".join(sorted(declared)) or "nothing"))
for note in notes:
    print(f"note: {note}")
for problem in problems:
    print(f"MISMATCH: {problem}")
if problems:
    sys.exit(1)
print("privacy manifest covers every required-reason API this scan found")
PY
