#!/bin/bash
# Builds nl-engine for ARCH (arm64 or x86_64) and prints the path of the binary.
# rustic_core is taken from the Cargo registry, which checks its checksum, and patched (Engine/vendor.sh).
set -euo pipefail
cd "$(dirname "$0")/../Engine"

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64) TRIPLE=aarch64-apple-darwin ;;
  x86_64) TRIPLE=x86_64-apple-darwin ;;
  *) echo "Unknown ARCH $ARCH" >&2; exit 1 ;;
esac
# Keep 15.0 in sync with Package.swift.
export MACOSX_DEPLOYMENT_TARGET=15.0

./vendor.sh >&2
if command -v rustup >/dev/null; then rustup target add "$TRIPLE" >&2; fi
cargo build --release --locked --target "$TRIPLE" >&2
echo "$PWD/target/$TRIPLE/release/nl-engine"
