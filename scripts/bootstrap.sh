#!/usr/bin/env bash
# One-time setup: web deps + XcodeGen (brew copy preferred, vendored fallback into .tools/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1 && [ ! -x "$ROOT/.tools/xcodegen/bin/xcodegen" ]; then
  echo "Fetching XcodeGen into .tools/ (alternative: brew install xcodegen)"
  mkdir -p "$ROOT/.tools"
  TAG=$(curl -fsL https://api.github.com/repos/yonaskolb/XcodeGen/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
  if [ -z "$TAG" ]; then
    echo "Could not resolve the latest XcodeGen release (GitHub API rate limit?). Run: brew install xcodegen" >&2
    exit 1
  fi
  curl -fsL "https://github.com/yonaskolb/XcodeGen/releases/download/$TAG/xcodegen.zip" -o "$ROOT/.tools/xcodegen.zip" \
    || { echo "Download of XcodeGen $TAG failed" >&2; exit 1; }
  (cd "$ROOT/.tools" && unzip -qo xcodegen.zip && rm xcodegen.zip)
fi

(cd "$ROOT/Web/monaco" && npm ci --no-audit --no-fund)
echo "bootstrap done"
