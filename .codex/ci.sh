#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR
export TMPDIR="$ROOT/build/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/module-cache"

mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
SWIFTPM_OPTIONS=(
  --build-system native
  --build-path "$ROOT/build/swiftpm"
  --cache-path "$ROOT/build/package-cache"
  --config-path "$ROOT/build/package-config"
  --security-path "$ROOT/build/package-security"
  --disable-automatic-resolution
)

swift build "${SWIFTPM_OPTIONS[@]}" --product agentbridge
swift build "${SWIFTPM_OPTIONS[@]}" --product AgentBridgeApp
swift test "${SWIFTPM_OPTIONS[@]}"
