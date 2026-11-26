#!/bin/bash
# The engine over SFTP when the connection drops during an upload, and when the server stops
# answering. Either way the run must fail, save no snapshot and leave no file under a final name that
# is incomplete. Needs restic on PATH.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
bin=${NL_ENGINE:-"$here/../target/release/nl-engine"}
work=$(mktemp -d /tmp/nl-engine-sftp.XXXXXX)
work=$(cd "$work" && pwd -P)
src=$work/src repo=$work/repo
export NL_ENGINE_PASSWORD=test RESTIC_PASSWORD=test NL_ENGINE_SFTP_TIMEOUT=5
fail=0

mkdir -p "$src"
head -c 50000000 /dev/urandom > "$src/big"
restic -r "$repo" init -q

for mode in drop hang; do
  ssh=$(printf '["python3","%s","%s","20000000"]' "$here/sftp_proxy.py" "$mode")
  start=$(date +%s)
  rc=0; "$bin" backup --ssh-json "$ssh" --repo "$repo" --host h --force "$src" > "$work/out-$mode" 2> "$work/err-$mode" || rc=$?
  took=$(( $(date +%s) - start ))
  if [ "$rc" = 1 ] && ! grep -q '"type":"summary"' "$work/out-$mode"; then
    echo "ok    $mode: run fails without a snapshot (${took}s)"
  else
    echo "FAIL  $mode: exit code $rc"; cat "$work/err-$mode"; fail=1
  fi
  [ "$took" -lt 60 ] || { echo "FAIL  $mode took ${took}s"; fail=1; }
done

[ -z "$(restic -r "$repo" snapshots --json | python3 -c 'import json,sys; print(json.load(sys.stdin) or "")')" ] \
  && echo "ok    no snapshots saved" || { echo "FAIL  a snapshot was saved"; fail=1; }
restic -r "$repo" unlock -q
restic -r "$repo" check -q --read-data && echo "ok    restic check --read-data" || fail=1
"$bin" backup --ssh-json '["/usr/libexec/sftp-server"]' --repo "$repo" --host h --force "$src" | grep -q '"type":"summary"' \
  && echo "ok    a later run succeeds" || { echo "FAIL  later run"; fail=1; }
restic -r "$repo" check -q --read-data && echo "ok    restic check --read-data after the later run" || fail=1
[ "$fail" = 0 ] && rm -rf "$work"
exit "$fail"
