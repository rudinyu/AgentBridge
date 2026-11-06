#!/usr/bin/env bash
set -euo pipefail

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
  swift build "${options[@]}" --product agentbridge
  swift build "${options[@]}" --product AgentBridgeApp
  swift test "${options[@]}"
}

check_build_system native "$ROOT/build/swiftpm"
check_build_system swiftbuild "$ROOT/build/swiftpm-swiftbuild"
