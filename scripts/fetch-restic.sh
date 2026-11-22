#!/bin/bash
# Downloads the official restic binary for macOS into vendor/restic-<arch>/restic.
# The SHA-256 values come from the SHA256SUMS file of the 0.20.0 release.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
VERSION="0.20.0"
case "$ARCH" in
  arm64)  ASSET="restic_${VERSION}_darwin_arm64.bz2"; SHA="0962c515acd9fb6937a658e9d8505200f72a6a0c6a2d334c0290b8002377dfb7" ;;
  x86_64) ASSET="restic_${VERSION}_darwin_amd64.bz2"; SHA="21f0070ef2bc6f3da2e33c070628e3e026e5237ba5fcddb1f9e0e8cabdd809d5" ;;
  *) echo "Unsupported ARCH: $ARCH" >&2; exit 1 ;;
esac

DEST="vendor/restic-$ARCH"
mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $ASSET…"
curl -fL --proto '=https' -o "$TMP/restic.bz2" \
  "https://github.com/restic/restic/releases/download/v$VERSION/$ASSET"

ACTUAL="$(shasum -a 256 "$TMP/restic.bz2" | cut -d' ' -f1)"
if [ "$ACTUAL" != "$SHA" ]; then
  echo "Checksum mismatch: expected $SHA, got $ACTUAL" >&2
  exit 1
fi

bunzip2 "$TMP/restic.bz2"
install -m 755 "$TMP/restic" "$DEST/restic"
echo "Installed $DEST/restic"
