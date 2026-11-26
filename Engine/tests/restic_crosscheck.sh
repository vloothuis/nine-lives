#!/bin/bash
# Backs up one tree with restic and with nl-engine, with the same filters, and compares the paths
# `restic ls` lists for both snapshots. Then checks that the engine's first backup after a restic
# backup reads no file data. Needs restic on PATH.
set -euo pipefail

bin=${NL_ENGINE:-"$(cd "$(dirname "$0")/.." && pwd)/target/release/nl-engine"}
work=$(mktemp -d /tmp/nl-engine-cross.XXXXXX)
work=$(cd "$work" && pwd -P)
src=$work/src repo=$work/repo
export NL_ENGINE_PASSWORD=test RESTIC_PASSWORD=test
home=$src/Users/u
filters=(
  --exclude "$home/Library/Caches" --exclude node_modules --exclude '!'"$home/p/node_modules"
  --exclude '*.pyc' --exclude '.nx/cache' --exclude "$home/Pro\\*jects" --exclude "$home/Photos \\[2020\\]"
  --exclude-if-present .nobackup --exclude-caches
)
fail=0
sftp=()
if [ "${NL_ENGINE_SFTP:-}" = 1 ]; then sftp=(--ssh-json '["/usr/libexec/sftp-server"]'); fi

mkdir -p "$home"/{Library/Caches/x,Library/Mail,p/node_modules/m,q/node_modules/m,a/.nx/cache,a/.nx/other,'Pro*jects',Projects,'Photos [2020]',tagged/sub,cache/sub,locked,'sp ace'}
for d in Library/Caches/x Library/Mail p/node_modules/m q/node_modules/m a/.nx/cache a/.nx/other 'Pro*jects' Projects 'Photos [2020]' tagged tagged/sub cache cache/sub locked 'sp ace'; do
  echo "$d" > "$home/$d/f"; echo x > "$home/$d/m.pyc"
done
touch "$home/tagged/.nobackup"
printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "$home/cache/CACHEDIR.TAG"
printf 'Signature: wrong' > "$home/a/CACHEDIR.TAG"
ln -s /etc "$home/etc-link"
printf 'x' > "$home/$(printf 'caf\xc3\xa9')"
chmod 000 "$home/locked"

restic -r "$repo" init -q
restic -r "$repo" backup -q --host h "${filters[@]}" "$src" 2>/dev/null || true
rid=$(restic -r "$repo" snapshots --json --latest 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["id"])')
out=$("$bin" backup ${sftp[@]+"${sftp[@]}"} --repo "$repo" --host h --parent "$rid" "${filters[@]}" "$src" | grep '"type":"summary"') || true
eid=$(echo "$out" | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["snapshot_id"])')

restic -r "$repo" ls --json "$rid" | python3 -c 'import json,sys; [print(json.loads(l)["path"]) for l in sys.stdin if "\"path\"" in l]' | sort > "$work/restic.txt"
restic -r "$repo" ls --json "$eid" | python3 -c 'import json,sys; [print(json.loads(l)["path"]) for l in sys.stdin if "\"path\"" in l]' | sort > "$work/engine.txt"
if diff "$work/restic.txt" "$work/engine.txt"; then echo "ok    same paths as restic ($(wc -l < "$work/engine.txt") items)"; else echo "FAIL  paths differ"; fail=1; fi

new=$(echo "$out" | python3 -c 'import json,sys; o=json.loads(sys.stdin.readline()); print(o["files_new"], o["files_changed"])')
# rustic stores link targets differently, so links count as changed once. They have no content.
if [ "$new" = "0 1" ]; then echo "ok    first engine backup after restic reads no files (1 link changed)"; else echo "FAIL  first engine backup: new/changed $new"; fail=1; fi

chmod 755 "$home/locked"
restic -r "$repo" check -q && echo "ok    restic check"
[ "$fail" = 0 ] && rm -rf "$work"
exit "$fail"
