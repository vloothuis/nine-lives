#!/bin/bash
# Runs change scenarios on a test tree. After each one, the spliced snapshot must have the same
# root tree ID as a full `rustic backup` of the same tree. Needs rustic and restic on PATH.
set -euo pipefail

bin=${NL_SPLICE:-"$(dirname "$0")/../target/release/nl-splice"}
work=$(mktemp -d /tmp/nl-splice-test.XXXXXX)
work=$(cd "$work" && pwd -P)   # /tmp is a link to /private/tmp
src=$work/src repo=$work/repo
export RUSTIC_PASSWORD=test RESTIC_PASSWORD=test
filters=(--glob '!cache' --exclude-if-present .nobackup)
fail=0

full() { rustic -r "$repo" backup "$src" "${filters[@]}" --json --no-progress 2>/dev/null; }
field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }

mkdir -p "$src"/{a/b/c,d,e/f,g,h/i/j}
for d in a a/b a/b/c d e e/f g h h/i h/i/j; do for i in 1 2 3; do echo "$d $i" > "$src/$d/file$i"; done; done
: > "$src/a/empty"
ln -s ../d/file1 "$src/a/link"
mkdir -p "$src/a/cache" && echo skip > "$src/a/cache/x"
rustic -r "$repo" init >/dev/null 2>&1
parent=$(full | field id)

# scenario <name> <changed folders, relative to src>...   (run after making the change)
scenario() {
  local name=$1; shift
  printf '%s\n' "${@/#/$src/}" > "$work/changed"
  local out; out=$("$bin" --repo "$repo" --parent "$parent" --changed "$work/changed" "${filters[@]}")
  local sid; sid=$(echo "$out" | field snapshot_id)
  local stree; stree=$(restic -r "$repo" cat snapshot "$sid" | field tree)
  local ftree; ftree=$(full | field tree)
  if [ "$stree" = "$ftree" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name"; echo "$out"
    restic -r "$repo" diff --metadata "$sid" "$(restic -r "$repo" snapshots --json --latest 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["id"])')" | head -20
    fail=1
  fi
  parent=$sid
}

echo changed > "$src/a/b/file1";                       scenario "change a file" a/b
echo new > "$src/d/new";                               scenario "add a file" d
rm "$src/e/file2";                                     scenario "delete a file" e
mkdir -p "$src/g/n/x" && echo deep > "$src/g/n/x/f";   scenario "new nested folders, only deepest reported" g/n/x
mv "$src/e/f" "$src/e/f2";                             scenario "rename a folder" e/f e/f2
rm -r "$src/a/b/c";                                    scenario "delete a folder" a/b/c
touch "$src/d/.nobackup";                              scenario "exclude marker added" d
rm "$src/d/.nobackup";                                 scenario "exclude marker removed" d
mkdir -p "$src/g/cache" && echo x > "$src/g/cache/y";  scenario "new folder matching a glob" g/cache
rm -r "$src/g/n" && echo file > "$src/g/n";            scenario "folder replaced by a file" g/n
ln -s /etc/hosts "$src/g/hostlink";                    scenario "add a symbolic link" g
chmod 600 "$src/a/file2";                              scenario "metadata-only change" a
echo two > "$src/a/file3"; echo two > "$src/e/f2/file1"; scenario "two folders at once" a e/f2
echo 3 > "$src/h/file1"; echo 3 > "$src/h/i/j/file1"; scenario "changed folder below a changed folder" h h/i/j
touch "$src/a/b";                                      scenario "folder mtime only" a/b
scenario "nothing changed" a

# Control: a change that is not reported must make the comparison fail.
echo unreported > "$src/g/file1"
if (scenario "control" a | grep -q '^FAIL'); then echo "ok    control (unreported change detected)"; else echo "FAIL  control"; fail=1; fi

restic -r "$repo" check -q && echo "ok    restic check"
[ "$fail" = 0 ] && rm -rf "$work"
exit "$fail"
