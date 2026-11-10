#!/bin/bash
# Usage: ./build.sh            -> builds Rihtim.app and packs it into Rihtim.dmg
#        ./build.sh install    -> also installs it to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP="Rihtim"
BUNDLE_ID="dev.minik.rihtim"
# .noindex keeps Spotlight/Launchpad from listing the build copy as a second "Rihtim.app".
OUT="build/app.noindex/$APP.app"
DMG="build/$APP.dmg"

echo "▸ Building (release, arm64)…"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Assembling the .app bundle…"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -d "build/$APP.app" ] && [ -x "$LSREG" ] && "$LSREG" -u "$PWD/build/$APP.app" 2>/dev/null || true
rm -rf "$OUT" "build/$APP.app"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$APP" "$OUT/Contents/MacOS/$APP"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
cp -R Resources/Localization "$OUT/Contents/Resources/Localization"
cp -R Resources/*.lproj "$OUT/Contents/Resources/"
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# Signing with a stable certificate matters: with ad-hoc signing macOS forgets the
# Accessibility / Screen Recording permissions after every build.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 -E '"(Apple Development|Developer ID Application|Rihtim Dev)' \
  | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "⚠︎ No signing certificate found, signing ad-hoc. You may need to reset permissions after each build:"
  echo "    tccutil reset Accessibility $BUNDLE_ID && tccutil reset ScreenCapture $BUNDLE_ID"
else
  echo "▸ Signing with: $IDENTITY"
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$OUT"

echo "▸ Creating the DMG…"
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$OUT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # for drag-and-drop install
hdiutil create -volname "Rıhtım" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -d "$HOME/Desktop" ] && [ -z "${CI:-}" ]; then
  cp -f "$DMG" "$HOME/Desktop/$APP.dmg"
  echo "✓ Done: ~/Desktop/$APP.dmg"
else
  echo "✓ Done: $DMG"
fi

if [ "${1:-}" = "install" ]; then
  pkill -x "$APP" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP.app"
  cp -R "$OUT" "/Applications/$APP.app"
  open "/Applications/$APP.app"
  echo "✓ Installed to /Applications/$APP.app and launched"
fi
