#!/usr/bin/env bash
# Full build: web bundle → xcodeproj → xcodebuild.
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Debug}"

"$ROOT/scripts/build-web.sh"
(cd "$ROOT" && "$ROOT/scripts/xcodegen.sh" generate --quiet)
mkdir -p "$ROOT/DerivedData"   # the log is tee'd here before xcodebuild creates the directory
ARCH="${ARCH:-$(uname -m)}"    # arm64 on Apple Silicon, x86_64 on Intel

set +e
xcodebuild -project "$ROOT/RokubiHarness.xcodeproj" -scheme RokubiHarness -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/DerivedData" -destination "platform=macOS,arch=$ARCH" build \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES 2>&1 | tee "$ROOT/DerivedData/last-build.log" | grep -E "error:|warning:|BUILD "
status=${PIPESTATUS[0]}
set -e

APP="$ROOT/DerivedData/Build/Products/$CONFIG/RokubiHarness.app"
[ -d "$APP" ] && echo "→ $APP"
exit "$status"
