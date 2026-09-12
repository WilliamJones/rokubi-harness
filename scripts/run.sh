#!/usr/bin/env bash
# Builds (Debug) and launches the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" Debug
open "$ROOT/DerivedData/Build/Products/Debug/RokubiHarness.app"
