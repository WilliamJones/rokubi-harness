#!/usr/bin/env bash
# Runs XcodeGen from PATH, falling back to the vendored copy in .tools/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if command -v xcodegen >/dev/null 2>&1; then
  exec xcodegen "$@"
fi
exec "$ROOT/.tools/xcodegen/bin/xcodegen" "$@"
