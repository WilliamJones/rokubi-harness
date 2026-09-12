#!/usr/bin/env bash
# Runs unit tests for every local package that has a Tests/ directory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0
for pkg in "$ROOT"/Packages/*/; do
  name="$(basename "$pkg")"
  [ -d "$pkg/Tests" ] || continue
  echo "── swift test: $name"
  if ! (cd "$pkg" && swift test 2>&1 | tail -20); then status=1; fi
done
exit $status
