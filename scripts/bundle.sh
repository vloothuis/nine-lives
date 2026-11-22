#!/bin/bash
# Builds dist/Nine Lives.app. Set SIGN_IDENTITY to a Developer ID name to sign for distribution.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
# Calendar version (YYYY.MM.DD, plus .N for more releases on the same day) and the commit it was built from.
VERSION="${VERSION:-$(date -u +%Y.%m.%d)}"
BUILD="${BUILD:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
IDENTITY="${SIGN_IDENTITY:--}"
APP="dist/Nine Lives.app"

swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/NineLives"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/borg"
cp "$BIN" "$APP/Contents/MacOS/NineLives"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

BORG="vendor/borg-$ARCH/borg"
if [ -x "$BORG" ]; then
  cp "$BORG" "$APP/Contents/Resources/borg/borg"
  cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
else
  rmdir "$APP/Contents/Resources/borg"
  echo "Note: $BORG not found. Run scripts/fetch-borg.sh to bundle borg."
  echo "      Without it the app uses a borg installed by Homebrew."
fi

if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  [ -x "$APP/Contents/Resources/borg/borg" ] && codesign --force --options runtime \
    --entitlements Resources/borg.entitlements --sign "$IDENTITY" "$APP/Contents/Resources/borg/borg"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD)"
