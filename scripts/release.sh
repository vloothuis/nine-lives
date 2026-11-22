#!/bin/bash
# Signs, notarizes and packages Nine Lives as a DMG.
# Needs: SIGN_IDENTITY (Developer ID Application name) and NOTARY_PROFILE
# (a keychain profile created with `xcrun notarytool store-credentials`).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?set SIGN_IDENTITY}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"
VERSION="${VERSION:-$(date -u +%Y.%m.%d)}"
export VERSION
APP="dist/Nine Lives.app"
DMG="dist/NineLives-$VERSION.dmg"

scripts/bundle.sh
ditto -c -k --keepParent "$APP" dist/NineLives.zip
xcrun notarytool submit dist/NineLives.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f dist/NineLives.zip "$DMG"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nine Lives" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
rm -rf "$STAGE"
echo "Release: $DMG"
shasum -a 256 "$DMG"
