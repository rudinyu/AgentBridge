#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

print_usage() {
  cat <<'USAGE'
Usage: ./scripts/verify-app-launch.sh /path/to/AgentBridge.app

Starts the packaged app with this repository's build output moved aside, so an
app that only runs because this Mac has the build folder fails here. The app
window opens for a few seconds with your saved settings.
USAGE
}

if (($# != 1)) || [[ "$1" == "--help" || "$1" == "-h" ]]; then
  print_usage >&2
  exit 2
fi

APP="$1"
EXECUTABLE="$APP/Contents/MacOS/AgentBridgeApp"
if [[ ! -x "$EXECUTABLE" ]]; then
  printf 'Error: no app executable at %s.\n' "$EXECUTABLE" >&2
  exit 1
fi

# A missing bundle only falls back to untranslated text, so launching cannot catch it.
RESOURCE_BUNDLE="$APP/Contents/Resources/AgentBridge_AgentBridgeApp.bundle"
for localization in en zh-hant; do
  if [[ -z "$(find "$RESOURCE_BUNDLE" -maxdepth 2 -ipath "*/$localization.lproj/Localizable.strings" -print -quit 2>/dev/null)" ]]; then
    printf 'Error: %s has no %s string table.\n' "$RESOURCE_BUNDLE" "$localization" >&2
    exit 1
  fi
done

MOVED_SUFFIX=".launch-check"
BUILD_OUTPUTS=("$ROOT/build/swiftpm" "$ROOT/build/swiftpm-swiftbuild")
for output in "${BUILD_OUTPUTS[@]}"; do
  if [[ -e "$output$MOVED_SUFFIX" ]]; then
    printf 'Error: %s is left over from an interrupted check. Move it back to %s first.\n' "$output$MOVED_SUFFIX" "$output" >&2
    exit 1
  fi
done

APP_PID=""
LOG="$(mktemp)"
restore() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    { wait "$APP_PID" || true; } 2>/dev/null
  fi
  for output in "${BUILD_OUTPUTS[@]}"; do
    if [[ -e "$output$MOVED_SUFFIX" ]]; then
      mv "$output$MOVED_SUFFIX" "$output"
    fi
  done
  rm -f "$LOG"
}
trap restore EXIT
trap 'exit 130' INT TERM

for output in "${BUILD_OUTPUTS[@]}"; do
  if [[ -e "$output" ]]; then
    mv "$output" "$output$MOVED_SUFFIX"
  fi
done

# SwiftPM compiles the absolute build path into the app. If the app was built
# somewhere else, that path is still there and this check would prove nothing.
BUILD_PATH_BUNDLE="$(strings -a "$EXECUTABLE" | grep '^/.*/AgentBridge_AgentBridgeApp\.bundle$' | sed -n '1p' || true)"
if [[ -n "$BUILD_PATH_BUNDLE" && -e "$BUILD_PATH_BUNDLE" ]]; then
  printf 'Error: the build output this app was built from still exists at %s.\n' "$BUILD_PATH_BUNDLE" >&2
  exit 1
fi

"$EXECUTABLE" >"$LOG" 2>&1 &
APP_PID=$!
for ((tick = 0; tick < 40; tick++)); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    status=0
    wait "$APP_PID" || status=$?
    APP_PID=""
    printf 'Error: the app exited with status %d during the launch check.\n' "$status" >&2
    tail -n 5 "$LOG" >&2
    exit 1
  fi
  sleep 0.2
done

printf 'Launch check passed: %s stayed running without the build output.\n' "$APP"
