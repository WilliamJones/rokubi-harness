#!/usr/bin/env bash
# Builds a self-contained Release app and copies it to the project root as RokubiHarness.app,
# so you don't have to dig through DerivedData. Optionally drop it in /Applications.
#
#   scripts/package.sh              → ./RokubiHarness.app
#   scripts/package.sh --install    → also copy to /Applications
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/build.sh" Release

SRC="$ROOT/DerivedData/Build/Products/Release/RokubiHarness.app"
DEST="$ROOT/RokubiHarness.app"
[ -d "$SRC" ] || { echo "Release build not found at $SRC" >&2; exit 1; }

# Replace any previous copy in the project root.
if [ -d "$DEST" ]; then rm -r "$DEST"; fi
cp -R "$SRC" "$DEST"
# Re-sign the copy (ad-hoc) so macOS is happy running it from its new location.
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true
echo "→ $DEST"

if [ "${1:-}" = "--install" ]; then
  APP="/Applications/RokubiHarness.app"
  if [ -d "$APP" ]; then rm -r "$APP"; fi
  cp -R "$DEST" "$APP"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "→ $APP"
fi

echo "Done. Double-click RokubiHarness.app, or run: open \"$DEST\""
