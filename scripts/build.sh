#!/bin/bash
# Builds build/ClaudeDict.app with swiftc (no Xcode or SwiftPM needed).
#   scripts/build.sh            build only
#   scripts/build.sh --install  also copy to ~/Applications and (re)start it
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos14.0"
APP="build/ClaudeDict.app"
mkdir -p build

echo "▸ compiling"
swiftc -swift-version 5 -O -target "$TARGET" -module-name ClaudeDict \
  Sources/Core/*.swift Sources/App/*.swift -o build/ClaudeDict

if [ ! -f build/AppIcon.icns ]; then
  echo "▸ drawing the icon"
  swiftc -O -target "$TARGET" scripts/make-icon.swift -o build/make-icon
  ./build/make-icon build/icon_1024.png >/dev/null
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/ClaudeDict "$APP/Contents/MacOS/ClaudeDict"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: Accessibility permission is tied to it, so re-grant after each rebuild.
codesign --force --sign - "$APP"
echo "✓ built $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="$HOME/Applications/ClaudeDict.app"
  pkill -x ClaudeDict 2>/dev/null || true
  sleep 0.5
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # The new ad-hoc signature no longer matches the old Accessibility grant; clear the stale entry
  # so the app can ask again instead of looking enabled but not working.
  tccutil reset Accessibility local.claudedict.app >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  open "$DEST"
  echo "✓ installed $DEST and started it"
fi
