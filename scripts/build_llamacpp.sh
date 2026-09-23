#!/usr/bin/env bash
# Builds the on-device small-language-model runtime from source: llama.cpp (MIT) at a pinned release, compiled with
# llama.cpp's own build-xcframework.sh for the iPhone, the iOS Simulator and this Mac (Metal on, the Metal library
# embedded in the binary), and copied to vendor/llama.xcframework. ChirpKit links ChirpEngineLlamaCpp's runtime only
# when that folder exists (ADR-015); without it Settings says "not in this build". Nothing here is committed: vendor/
# is gitignored. No prebuilt binary is downloaded, ever.
#
# Usage: scripts/build_llamacpp.sh                      (needs Xcode and CMake 3.28+, or uv to fetch CMake)
#        LLAMA_CPP_DIR=/path/to/clone scripts/build_llamacpp.sh   (reuse a clone; it is checked out at the pin)
set -euo pipefail
cd "$(dirname "$0")/.."

# The pin. Bump it only together with the opt-in real-model test (CHIRP_ONDEVICE_LLM_TESTS=1) and ADR-015; the Swift
# side records the same values in LlamaCppRuntimeInfo (a test keeps them equal).
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp"
LLAMA_CPP_TAG="b11118"
LLAMA_CPP_COMMIT="e6ab7c1a41054a888ada952eab4c886444c2f5ad"
# iPhone, Simulator, Mac (the Mac slice runs the package tests). No visionOS or tvOS.
BUILDS=(ios-device ios-sim macos)

VENDOR="vendor"
SRC="${LLAMA_CPP_DIR:-$VENDOR/llama.cpp}"
OUT="$VENDOR/llama.xcframework"

if ! command -v xcrun >/dev/null; then
  echo "error: Xcode is not installed (xcrun missing)." >&2
  exit 1
fi

# CMake 3.28 or later. When it is not installed, uv runs a pinned-range CMake from PyPI without installing anything
# system-wide (llama.cpp's script only needs `cmake` on PATH).
cmake_ok() {
  command -v cmake >/dev/null || return 1
  local version major minor
  version="$(cmake --version | head -1 | awk '{print $3}')"
  major="${version%%.*}"
  minor="$(echo "$version" | cut -d. -f2)"
  [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 28 ]; }
}
if ! cmake_ok; then
  if command -v uvx >/dev/null; then
    shim="$(pwd)/$VENDOR/.tools/bin"
    mkdir -p "$shim"
    cat >"$shim/cmake" <<'SHIM'
#!/usr/bin/env bash
exec uvx --quiet --from 'cmake>=3.28,<5' cmake "$@"
SHIM
    chmod +x "$shim/cmake"
    export PATH="$shim:$PATH"
    echo "==> CMake via uv ($(cmake --version | head -1))"
  else
    echo "error: CMake 3.28+ is needed. Install it with 'brew install cmake' (or install uv), then run this again." >&2
    exit 1
  fi
fi

echo "==> llama.cpp $LLAMA_CPP_TAG (${LLAMA_CPP_COMMIT:0:8})"
mkdir -p "$VENDOR"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --depth 1 --branch "$LLAMA_CPP_TAG" "$LLAMA_CPP_REPO" "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$LLAMA_CPP_COMMIT^{commit}" 2>/dev/null; then
  git -C "$SRC" fetch --quiet --depth 1 origin "refs/tags/$LLAMA_CPP_TAG:refs/tags/$LLAMA_CPP_TAG"
fi
git -C "$SRC" checkout --quiet --detach "$LLAMA_CPP_COMMIT"
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$LLAMA_CPP_COMMIT" ]; then
  echo "error: $SRC is not at the pinned commit $LLAMA_CPP_COMMIT" >&2
  exit 1
fi
# Patches to the vendored source, if one is ever needed, live in scripts/llamacpp/*.patch (none today).
shopt -s nullglob
for patch in scripts/llamacpp/*.patch; do
  git -C "$SRC" apply --check "$(pwd)/$patch" && git -C "$SRC" apply "$(pwd)/$patch"
done
shopt -u nullglob

echo "==> build-xcframework.sh ${BUILDS[*]} (several minutes; logs in $SRC/build_*.log)"
(cd "$SRC" && ./build-xcframework.sh "${BUILDS[@]}" >/dev/null)
test -d "$SRC/build-apple/llama.xcframework"

rm -rf "$OUT"
cp -R "$SRC/build-apple/llama.xcframework" "$OUT"
echo "$LLAMA_CPP_COMMIT" >"$VENDOR/llama.commit"

# Check that ChirpKit's Package.swift now links the runtime (an uncached evaluation).
description="$(swift package --package-path ChirpKit --manifest-cache none describe)"
if ! grep -qx "  *Name: llama" <<<"$description"; then
  echo "error: ChirpKit/Package.swift does not see $OUT" >&2
  exit 1
fi
echo "Built $OUT (llama.cpp $LLAMA_CPP_TAG; slices: ${BUILDS[*]})."
echo "Next: scripts/gen.sh, then build the app. If Settings still says \"not in this build\", open a new terminal"
echo "(SwiftPM re-reads Package.swift in a new environment) or use Xcode's File > Packages > Reset Package Caches."
