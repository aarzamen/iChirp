#!/usr/bin/env bash
# Builds Needle 3's runtime from source: needle-rs's C FFI crate (`needle-c`, MIT) at a pinned commit, compiled as a
# static library for the iPhone, the iOS Simulator and this Mac, packaged as vendor/NeedleC.xcframework (headers +
# module map). ChirpKit links it only when that folder exists (ADR-012). Nothing here is committed: vendor/ is
# gitignored. No Cactus binary (libneedle.a) is used, ever.
#
# Usage: scripts/build_needle.sh            (needs Rust 1.87+ via rustup: https://rustup.rs)
#        NEEDLE_RS_DIR=/path/to/clone scripts/build_needle.sh   (reuse an existing clone; it is checked out at the pin)
set -euo pipefail
cd "$(dirname "$0")/.."

# The pin. Bump it only together with a re-run of the Eval view (Settings → Structure models → Eval) and ADR-012.
NEEDLE_RS_REPO="https://github.com/Geekgineer/needle-rs"
NEEDLE_RS_COMMIT="4de50494fd60f417b24c37e4d972f95d128f8a0f" # v0.3.1 + docs/CI commits, 2026-09
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)

VENDOR="vendor"
SRC="${NEEDLE_RS_DIR:-$VENDOR/needle-rs}"
HEADERS="$VENDOR/NeedleC-headers"
OUT="$VENDOR/NeedleC.xcframework"

export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v cargo >/dev/null || ! command -v rustup >/dev/null; then
  echo "error: Rust is not installed. Install it with https://rustup.rs, then run this script again." >&2
  exit 1
fi

echo "==> Rust targets"
rustup target add "${TARGETS[@]}" >/dev/null 2>&1

echo "==> needle-rs at ${NEEDLE_RS_COMMIT:0:8}"
mkdir -p "$VENDOR"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet "$NEEDLE_RS_REPO" "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$NEEDLE_RS_COMMIT^{commit}" 2>/dev/null; then
  git -C "$SRC" fetch --quiet origin
fi
git -C "$SRC" checkout --quiet --detach "$NEEDLE_RS_COMMIT"
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$NEEDLE_RS_COMMIT" ]; then
  echo "error: $SRC is not at the pinned commit $NEEDLE_RS_COMMIT" >&2
  exit 1
fi
# Patches to the vendored source, if one is ever needed, live in scripts/needle/*.patch (none today).
shopt -s nullglob
for patch in scripts/needle/*.patch; do
  git -C "$SRC" apply --check "$(pwd)/$patch" && git -C "$SRC" apply "$(pwd)/$patch"
done
shopt -u nullglob

# Objects built for an older OS than the app's minimum link without warnings.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0

# Rust static libraries each carry their own copy of Rust's standard library. FluidAudio already links one
# (libtext_processing_rs.a), so two plain Rust archives collide at link time (duplicate `_rust_eh_personality`).
# Pre-link needle-c into one relocatable object that exports only the `needle_*` C API and keeps every Rust symbol
# local (`ld -r` turns the hidden ones into static symbols), then archive that single object.
PRELINK="$VENDOR/NeedleC-prelink"
rm -rf "$PRELINK"
echo '_needle_*' >"$VENDOR/NeedleC-exports.txt"
platform_of() {
  case "$1" in
    aarch64-apple-ios) echo "ios $IPHONEOS_DEPLOYMENT_TARGET" ;;
    aarch64-apple-ios-sim) echo "ios-simulator $IPHONEOS_DEPLOYMENT_TARGET" ;;
    aarch64-apple-darwin) echo "macos $MACOSX_DEPLOYMENT_TARGET" ;;
  esac
}

for target in "${TARGETS[@]}"; do
  echo "==> cargo build needle-c --target $target"
  cargo build --quiet --release --locked -p needle-c --target "$target" --manifest-path "$SRC/Cargo.toml"
  archive="$(pwd)/$SRC/target/$target/release/libneedle_c.a"
  test -f "$archive"
  work="$PRELINK/$target"
  mkdir -p "$work/objects"
  (cd "$work/objects" && ar x "$archive")
  read -r platform minimum <<<"$(platform_of "$target")"
  xcrun ld -r -arch arm64 -platform_version "$platform" "$minimum" "$minimum" \
    -exported_symbols_list "$VENDOR/NeedleC-exports.txt" "$work"/objects/*.o -o "$work/needle_c.o"
  if nm -g "$work/needle_c.o" | grep -v " U " | grep -qv " _needle_"; then
    echo "error: the pre-linked needle-c for $target exports more than the needle_* C API" >&2
    exit 1
  fi
  xcrun libtool -static -o "$work/libneedle_c.a" "$work/needle_c.o"
  rm -rf "$work/objects"
done

echo "==> $OUT"
rm -rf "$HEADERS" "$OUT"
mkdir -p "$HEADERS"
cp "$SRC/crates/needle-c/include/needle.h" "$HEADERS/needle.h"
cat >"$HEADERS/module.modulemap" <<'MODULEMAP'
module NeedleC {
    header "needle.h"
    export *
}
MODULEMAP
args=()
for target in "${TARGETS[@]}"; do
  args+=(-library "$PRELINK/$target/libneedle_c.a" -headers "$HEADERS")
done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT" >/dev/null
echo "$NEEDLE_RS_COMMIT" >"$VENDOR/NeedleC.commit"

# Check that ChirpKit's Package.swift now links the runtime (an uncached evaluation).
description="$(swift package --package-path ChirpKit --manifest-cache none describe)"
if ! grep -q "Name: NeedleC" <<<"$description"; then
  echo "error: ChirpKit/Package.swift does not see $OUT" >&2
  exit 1
fi
echo "Built $OUT (needle-rs ${NEEDLE_RS_COMMIT:0:8}; slices: ${TARGETS[*]})."
echo "Next: scripts/gen.sh, then build the app. If Settings still says \"Needle is not in this build\", open a new"
echo "terminal (SwiftPM re-reads Package.swift in a new environment) or use Xcode's File > Packages > Reset Package Caches."
