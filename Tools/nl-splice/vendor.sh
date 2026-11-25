#!/bin/sh
# Copies rustic_core 0.14.0 from the Cargo registry (Cargo has checked its checksum) and applies rustic_core.patch.
set -eu
cd "$(dirname "$0")"
cargo fetch --manifest-path fetch/Cargo.toml -q
src=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/rustic_core-0.14.0 | head -n 1)
rm -rf vendor/rustic_core
mkdir -p vendor
cp -R "$src" vendor/rustic_core
patch -s -d vendor -p0 < rustic_core.patch
