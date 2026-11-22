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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NineLives"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

RESTIC="vendor/restic-$ARCH/restic"
if [ -x "$RESTIC" ]; then
  cp "$RESTIC" "$APP/Contents/Resources/restic"
  cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
else
  echo "Note: $RESTIC not found. Run scripts/fetch-restic.sh to bundle restic."
  echo "      Without it the app uses a restic installed by Homebrew."
fi

if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  [ -x "$APP/Contents/Resources/restic" ] && codesign --force --options runtime \
    --sign "$IDENTITY" "$APP/Contents/Resources/restic"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD)"
