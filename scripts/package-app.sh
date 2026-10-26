#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export DEVELOPER_DIR
export TMPDIR="$ROOT/build/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/module-cache"

mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"
SWIFTPM_OPTIONS=(
  --configuration release
  --build-system native
  --build-path "$ROOT/build/swiftpm"
  --cache-path "$ROOT/build/package-cache"
  --config-path "$ROOT/build/package-config"
  --security-path "$ROOT/build/package-security"
  --disable-automatic-resolution
)
swift build "${SWIFTPM_OPTIONS[@]}" --product agentbridge
swift build "${SWIFTPM_OPTIONS[@]}" --product AgentBridgeApp

APP="$ROOT/build/AgentBridge.app"
if [[ -L "$APP" ]]; then
  rm "$APP"
elif [[ -e "$APP" ]]; then
  rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/build/swiftpm/release/AgentBridgeApp" "$APP/Contents/MacOS/AgentBridgeApp"
cp "$ROOT/build/swiftpm/release/agentbridge" "$APP/Contents/Helpers/agentbridge"
RESOURCE_BUNDLE="$(find "$ROOT/build/swiftpm" -type d -path '*/release/SwiftTerm_SwiftTerm.bundle' -print | LC_ALL=C sort | sed -n '1p')"
if [[ -z "$RESOURCE_BUNDLE" ]]; then
  printf 'Missing SwiftTerm_SwiftTerm.bundle in the SwiftPM build output.\n' >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp "$ROOT/LICENSES/SwiftTerm-LICENSE.txt" "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AgentBridgeApp</string>
  <key>CFBundleIdentifier</key><string>org.agentbridge.app</string>
  <key>CFBundleName</key><string>AgentBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST
chmod 755 "$APP/Contents/MacOS/AgentBridgeApp" "$APP/Contents/Helpers/agentbridge"
plutil -lint "$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/AgentBridgeApp"
test -x "$APP/Contents/Helpers/agentbridge"
printf 'Created %s\n' "$APP"
