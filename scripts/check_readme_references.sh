#!/usr/bin/env bash
# Fails when a module README names a .swift file that no longer exists.
#
# Usage: scripts/check_readme_references.sh
#
# Scans every ChirpKit/Sources/<Module>/README.md for backticked names ending in ".swift" and resolves each one:
#   - a repo-root path (`ChirpKit/...`, `App/...`, `AppTests/...`, `upstream/...`) must exist from the repo root;
#   - a bare file name (`ParakeetEngine.swift`) must exist somewhere inside that module;
#   - a relative path (`Engines/SpeechEngine.swift`) must exist inside that module, or, when the README is citing
#     MacParakeet (`Services/ExportService.swift`), under upstream/macparakeet/Sources/<target>/.
# Exits 1 and lists every reference that resolves nowhere.
set -euo pipefail
cd "$(dirname "$0")/.."

missing=0
checked=0

for readme in ChirpKit/Sources/*/README.md; do
  module_dir=$(dirname "$readme")
  refs=$(grep -oE '`[^`[:space:]]+\.swift`' "$readme" | tr -d '`' | sort -u || true)
  [ -n "$refs" ] || continue
  while IFS= read -r ref; do
    checked=$((checked + 1))
    case "$ref" in
      ChirpKit/* | App/* | AppTests/* | upstream/*)
        [ -e "$ref" ] && continue
        ;;
      */*)
        [ -e "$module_dir/$ref" ] && continue
        if compgen -G "upstream/macparakeet/Sources/*/$ref" >/dev/null; then
          continue
        fi
        ;;
      *)
        if [ -n "$(find "$module_dir" -type f -name "$ref" -print -quit)" ]; then
          continue
        fi
        ;;
    esac
    echo "missing: $readme references \`$ref\`" >&2
    missing=$((missing + 1))
  done <<<"$refs"
done

if [ "$missing" -gt 0 ]; then
  echo "error: $missing README reference(s) point at .swift files that do not exist (checked $checked)." >&2
  exit 1
fi
echo "README references OK ($checked .swift references checked)."
