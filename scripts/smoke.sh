#!/usr/bin/env bash
# Offline end-to-end smoke test: run the Debug app against scripts/mock-openai.py on a copy of
# demo-project and assert the scripted agent actually fixed the cart and the tests pass.
#
#   scripts/smoke.sh                      # Responses API flavour (--api-key)
#   scripts/smoke.sh --openrouter         # Chat Completions flavour (--openrouter-key)
#   SMOKE_SKIP_BUILD=1 scripts/smoke.sh   # reuse the existing Debug build
#
# The app is launched through LaunchServices (`open -n`): a Debug binary started directly from a
# non-interactive shell may never get a window. It quits itself after writing the screenshot,
# which lands at DerivedData/smoke-<flavour>.png (+ .log with the app's snapshot trace).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOUR="responses"; AUTH=(--api-key test)
if [ "${1:-}" = "--openrouter" ]; then FLAVOUR="openrouter"; AUTH=(--openrouter-key test); fi

PORT="${SMOKE_PORT:-8765}"
DELAY="${SMOKE_DELAY:-14}"
APP="$ROOT/DerivedData/Build/Products/Debug/RokubiHarness.app"
WORK="$(mktemp -d -t rokubi-smoke)"
SNAP="$ROOT/DerivedData/smoke-$FLAVOUR.png"
MOCK_PID=""

cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if pgrep -xq RokubiHarness; then
  echo "smoke: RokubiHarness is already running — quit it first (the smoke run needs its own instance)" >&2; exit 1
fi
if [ "${SMOKE_SKIP_BUILD:-0}" != "1" ]; then "$ROOT/scripts/build.sh" Debug; fi
[ -d "$APP" ] || { echo "smoke: app not built at $APP" >&2; exit 1; }

cp -R "$ROOT/demo-project" "$WORK/demo"
rm -f "$WORK/demo/.DS_Store"
if (cd "$WORK/demo" && npm test >/dev/null 2>&1); then
  echo "smoke: demo-project tests already pass — the deliberate bug in src/cart.js is missing" >&2; exit 1
fi

python3 "$ROOT/scripts/mock-openai.py" "$PORT" >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 20); do curl -fs "http://127.0.0.1:$PORT/models" >/dev/null 2>&1 && break; sleep 0.25; done
curl -fs "http://127.0.0.1:$PORT/models" >/dev/null || { echo "smoke: mock did not start"; cat "$WORK/mock.log"; exit 1; }

rm -f "$SNAP" "$SNAP.log"
launch() {
  open -n "$APP" --args --project "$WORK/demo" --base-url "http://127.0.0.1:$PORT" "${AUTH[@]}" --model gpt-5.4 \
    --prompt "Fix the failing cart test" --snapshot "$SNAP" --snapshot-delay="$DELAY" --quit-after-snapshot
}
launch
# Right after a rebuild LaunchServices occasionally drops the first launch; retry once if no process shows up.
for _ in $(seq 1 40); do pgrep -xq RokubiHarness && break; sleep 0.25; done
if ! pgrep -xq RokubiHarness; then echo "smoke: app did not start, retrying launch"; launch; fi

for _ in $(seq 1 $((DELAY * 4 + 60))); do [ -f "$SNAP" ] && break; sleep 0.5; done
# Give the app a moment to quit on its own; then make sure it's gone.
# Only ever stop the instance this script launched (matched by its temp project path).
for _ in $(seq 1 20); do pgrep -fq -- "--project $WORK/demo" || break; sleep 0.25; done
pkill -f -- "--project $WORK/demo" 2>/dev/null || true
[ -f "$SNAP" ] || { echo "smoke: no snapshot written"; cat "$SNAP.log" 2>/dev/null; cat "$WORK/mock.log"; exit 1; }

status=0
if grep -q "turn 3" "$WORK/mock.log"; then echo "✓ agent reached the completion turn"; else echo "✗ agent never reached turn 3"; status=1; fi
if ! diff -q "$ROOT/demo-project/src/cart.js" "$WORK/demo/src/cart.js" >/dev/null; then echo "✓ src/cart.js was patched"; else echo "✗ src/cart.js unchanged"; status=1; fi
if (cd "$WORK/demo" && npm test >/dev/null 2>&1); then echo "✓ demo tests pass after the fix"; else echo "✗ demo tests still fail"; status=1; fi
echo "→ $SNAP"
if [ "$status" != 0 ]; then echo "--- mock.log"; cat "$WORK/mock.log"; echo "--- snapshot log"; cat "$SNAP.log" 2>/dev/null; fi
exit "$status"
