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
APP_RESOURCE_BUNDLE="$(find "$ROOT/build/swiftpm" -type d -path '*/release/AgentBridge_AgentBridgeApp.bundle' -print | LC_ALL=C sort | sed -n '1p')"
if [[ -z "$APP_RESOURCE_BUNDLE" ]]; then
  printf 'Missing AgentBridgeApp resource bundle in the SwiftPM build output.\n' >&2
  exit 1
fi
cp -R "$APP_RESOURCE_BUNDLE" "$APP/Contents/Resources/AgentBridge_AgentBridgeApp.bundle"
for localization in en zh-Hant; do
  LOCALIZATION_SOURCE="$ROOT/Sources/AgentBridgeApp/Resources/$localization.lproj"
  if [[ ! -d "$LOCALIZATION_SOURCE" ]]; then
    printf 'Missing app localization resources: %s\n' "$LOCALIZATION_SOURCE" >&2
    exit 1
  fi
  cp -R "$LOCALIZATION_SOURCE" "$APP/Contents/Resources/$localization.lproj"
done
ICON_SOURCE="$ROOT/Assets/AppIcon-1024.png"
ICONSET="$ROOT/build/tmp/AgentBridge-$$.iconset"
if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'Missing app icon source: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi
mkdir "$ICONSET"
trap 'rm -rf "$ICONSET"' EXIT
make_icon() {
  local pixels="$1"
  local filename="$2"
  sips -z "$pixels" "$pixels" "$ICON_SOURCE" --out "$ICONSET/$filename" >/dev/null
}
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AgentBridge.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AgentBridgeApp</string>
  <key>CFBundleIconFile</key><string>AgentBridge.icns</string>
  <key>CFBundleIdentifier</key><string>org.agentbridge.app</string>
  <key>CFBundleName</key><string>AgentBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.6.1</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string></array>
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
