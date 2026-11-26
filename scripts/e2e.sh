#!/bin/bash
# End-to-end test: builds the app, mounts an APFS disk image as the backup disk, and runs
# EndToEndTests with the restic and nl-engine inside the app.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -n "${SKIP_BUNDLE:-}" ] || scripts/bundle.sh
app="$PWD/dist/Nine Lives.app"
work=$(mktemp -d /tmp/nl-e2e.XXXXXX)
mnt="$work/mnt"
mkdir "$mnt"
hdiutil create -quiet -size 2g -fs APFS -volname "NL E2E" "$work/disk.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$mnt" "$work/disk.dmg"
cleanup() { hdiutil detach -quiet -force "$mnt" || true; rm -rf "$work"; }
trap cleanup EXIT

NL_E2E_VOLUME="$mnt" NL_E2E_APP="$app" swift test --filter EndToEndTests
