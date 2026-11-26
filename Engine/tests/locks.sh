#!/bin/bash
# The engine's lock must stop `restic prune`, and `restic unlock` must remove the lock of an engine
# that was killed. Needs restic on PATH.
set -euo pipefail

bin=${NL_ENGINE:-"$(cd "$(dirname "$0")/.." && pwd)/target/release/nl-engine"}
work=$(mktemp -d /tmp/nl-engine-locks.XXXXXX)
work=$(cd "$work" && pwd -P)
src=$work/src repo=$work/repo
export NL_ENGINE_PASSWORD=test RESTIC_PASSWORD=test
fail=0
sftp=()
if [ "${NL_ENGINE_SFTP:-}" = 1 ]; then sftp=(--ssh-json '["/usr/libexec/sftp-server"]'); fi

mkdir -p "$src"
head -c 400000000 /dev/urandom > "$src/big"
restic -r "$repo" init -q

wait_for_lock() {
  for _ in $(seq 100); do [ -n "$(ls "$repo/locks")" ] && return 0; sleep 0.05; done
  return 1
}

"$bin" backup ${sftp[@]+"${sftp[@]}"} --repo "$repo" --host h --force "$src" > /dev/null &
pid=$!
wait_for_lock || { echo "FAIL  engine wrote no lock"; fail=1; }
if restic -r "$repo" prune > "$work/prune.txt" 2>&1; then
  echo "FAIL  prune ran while the engine worked"; fail=1
else
  grep -q locked "$work/prune.txt" && echo "ok    prune refused while the engine works" || { echo "FAIL  prune failed otherwise"; cat "$work/prune.txt"; fail=1; }
fi
wait "$pid" && echo "ok    engine finished" || { echo "FAIL  engine failed"; fail=1; }
[ -z "$(ls "$repo/locks")" ] && echo "ok    lock removed at exit" || { echo "FAIL  lock left"; fail=1; }

"$bin" backup ${sftp[@]+"${sftp[@]}"} --repo "$repo" --host h --force "$src" > /dev/null &
pid=$!
wait_for_lock
kill -9 "$pid"; wait "$pid" 2>/dev/null || true
restic -r "$repo" unlock -q
[ -z "$(ls "$repo/locks")" ] && echo "ok    restic unlock removes a killed engine's lock" || { echo "FAIL  unlock left the lock"; fail=1; }

"$bin" backup ${sftp[@]+"${sftp[@]}"} --repo "$repo" --host h --force "$src" > /dev/null &
pid=$!
wait_for_lock
kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
[ "$rc" = 130 ] && echo "ok    SIGTERM gives exit code 130" || { echo "FAIL  SIGTERM exit code $rc"; fail=1; }
[ -z "$(ls "$repo/locks")" ] && echo "ok    lock removed on SIGTERM" || { echo "FAIL  lock left after SIGTERM"; fail=1; }

restic -r "$repo" check -q && echo "ok    restic check"
[ "$fail" = 0 ] && rm -rf "$work"
exit "$fail"
