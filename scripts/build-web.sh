#!/usr/bin/env bash
# Builds the Monaco bundle and copies it to App/Resources/Monaco (bundled as a folder reference).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/App/Resources/Monaco"

(cd "$ROOT/Web/monaco" && npm run --silent build)
if [ -d "$OUT" ]; then rm -r "$OUT"; fi
cp -R "$ROOT/Web/monaco/dist" "$OUT"
echo "Monaco bundle → App/Resources/Monaco"
