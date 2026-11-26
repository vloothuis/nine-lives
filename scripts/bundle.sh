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

# macOS uses the SDK version recorded in the binary to pick the current or the older
# window design. SwiftPM's default build system records the deployment target instead,
# so set the real SDK version explicitly. Keep 15.0 in sync with Package.swift.
SDK_VERSION="$(xcrun --show-sdk-version)"
FLAGS=(-c release --arch "$ARCH" -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$SDK_VERSION")
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/NineLives"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NineLives"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

RESTIC="vendor/restic-$ARCH/restic"
if [ -x "$RESTIC" ]; then
  cp "$RESTIC" "$APP/Contents/Resources/restic"
  cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
elif [ -n "${REQUIRE_RESTIC:-}" ]; then
  echo "Error: $RESTIC not found." >&2
  exit 1
else
  echo "Note: $RESTIC not found. Run scripts/fetch-restic.sh to bundle restic."
  echo "      Without it the app uses a restic installed by Homebrew."
fi

# nl-engine makes the snapshots; restic is still used for everything else.
if command -v cargo >/dev/null; then
  ENGINE="$(scripts/build-engine.sh)"
  cp "$ENGINE" "$APP/Contents/Resources/nl-engine"
elif [ -n "${REQUIRE_ENGINE:-}" ]; then
  echo "Error: cargo not found, so nl-engine cannot be built." >&2
  exit 1
else
  echo "Note: cargo not found, so nl-engine is not bundled. Backups use restic backup."
fi

if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  for tool in restic nl-engine; do
    if [ -x "$APP/Contents/Resources/$tool" ]; then
      codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/$tool"
    fi
  done
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD)"
