#!/bin/bash
# Downloads the official BorgBackup single-file binary for macOS into vendor/borg-<arch>/borg.
# The SHA-256 values are the digests GitHub reports for the 1.4.5 release assets.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
VERSION="1.4.5"
case "$ARCH" in
  arm64)  ASSET="borg-macos-15-arm64-gh";  SHA="a47c308090ce4ada8b734a7fb7ae04269e85621961c61d40833e2ad3997b6c0f" ;;
  x86_64) ASSET="borg-macos-15-x86_64-gh"; SHA="9690873e91beabd50c8873221e9f8ba7b19becd36eb0eb5d37fc34cbf78d15ef" ;;
  *) echo "Unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac

DEST="vendor/borg-$ARCH"
mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $ASSET ($VERSION)…"
curl -fL --proto '=https' -o "$TMP/borg" \
  "https://github.com/borgbackup/borg/releases/download/$VERSION/$ASSET"

ACTUAL="$(shasum -a 256 "$TMP/borg" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$SHA" ]; then
  echo "Checksum mismatch: expected $SHA, got $ACTUAL" >&2
  exit 1
fi

install -m 755 "$TMP/borg" "$DEST/borg"
echo "Installed $DEST/borg"
