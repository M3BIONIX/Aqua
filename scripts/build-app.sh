#!/bin/zsh
# Builds Aqua.app (release, arm64) into ./build and signs it ad hoc.
# Usage: scripts/build-app.sh [--debug]
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

cd "$ROOT"
swift build -c "$CONFIG" --arch arm64 --product Aqua
BIN=$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)

APP="$ROOT/build/Aqua.app"
VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo "0.1.0")
BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Aqua" "$APP/Contents/MacOS/Aqua"
# SwiftPM resource bundles (recipes.json); Bundle.module finds them in Contents/Resources.
for bundle in "$BIN"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
[[ -f "$ROOT/Resources/Aqua.icns" ]] && cp "$ROOT/Resources/Aqua.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Aqua</string>
  <key>CFBundleDisplayName</key><string>Aqua</string>
  <key>CFBundleIdentifier</key><string>app.aqua.launcher</string>
  <key>CFBundleExecutable</key><string>Aqua</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>Aqua</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Wine is LGPL; legendary is GPLv3; D3DMetal is Apple's and downloaded separately.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
du -sh "$APP"
echo "Built $APP"
