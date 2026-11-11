#!/usr/bin/env bash
set -euo pipefail

# A Git hook exports repository-scoped variables such as a relative GIT_INDEX_FILE.
# Tests would pass them on to Git commands aimed at fixture repositories, so clear them.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR
export TMPDIR="$ROOT/build/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/module-cache"

mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

# Packaging uses the native build system, and SwiftPM now defaults to swiftbuild.
# They lay out resources differently, so a change can pass on one and break on the other.
check_build_system() {
  local options=(
    --build-system "$1"
    --build-path "$2"
    --cache-path "$ROOT/build/package-cache"
    --config-path "$ROOT/build/package-config"
    --security-path "$ROOT/build/package-security"
    --disable-automatic-resolution
  )
  # macOS refuses a nested sandbox, so SwiftPM cannot start its own under AgentBridge's.
  if [[ -n "${AGENTBRIDGE_VERIFICATION_SANDBOX:-}" ]]; then
    options+=(--disable-sandbox)
  fi
  swift build "${options[@]}" --product agentbridge
  swift build "${options[@]}" --product AgentBridgeApp
  swift test "${options[@]}"
}

check_build_system native "$ROOT/build/swiftpm"
check_build_system swiftbuild "$ROOT/build/swiftpm-swiftbuild"
