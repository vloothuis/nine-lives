#!/bin/bash
# Runs change scenarios on a test tree. After each one, the spliced snapshot must have the same root
# tree ID and the same totals as a full backup (`nl-engine backup --force`) of the same tree.
# Needs restic on PATH. With NL_ENGINE_SFTP=1 the engine reaches the repository over SFTP, through
# OpenSSH's sftp-server on this machine; restic still opens it as a local folder.
set -euo pipefail

bin=${NL_ENGINE:-"$(cd "$(dirname "$0")/.." && pwd)/target/release/nl-engine"}
work=$(mktemp -d /tmp/nl-engine-test.XXXXXX)
work=$(cd "$work" && pwd -P)   # /tmp is a link to /private/tmp
src=$work/src src2=$work/src-2 repo=$work/repo
export NL_ENGINE_PASSWORD=test RESTIC_PASSWORD=test
filters=(--exclude cache --exclude '*.log' --exclude '!keep.log' --exclude-if-present .nobackup --exclude-caches)
common=(--repo "$repo" --host testhost --tag ninelives)
if [ "${NL_ENGINE_SFTP:-}" = 1 ]; then common+=(--ssh-json '["/usr/libexec/sftp-server"]'); fi
fail=0

# Runs the engine, prints its summary line. Exit code 3 (some files unreadable) is accepted.
engine() {
  local rc=0 out
  out=$("$bin" "$@") || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then echo "engine failed ($rc): $*" >&2; return 1; fi
  echo "$out" | grep '"type":"summary"'
}
field() { python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['$1'])"; }
tree_of() { restic -r "$repo" cat snapshot "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['tree'])"; }
full() { engine backup "${common[@]}" --force "${filters[@]}" "$src" "$src2"; }

mkdir -p "$src"/{a/b/c,d,e/f,g,h/i/j} "$src2"/x
for d in a a/b a/b/c d e e/f g h h/i h/i/j; do for i in 1 2 3; do echo "$d $i" > "$src/$d/file$i"; done; done
echo other > "$src2/x/file"
: > "$src/a/empty"
ln -s ../d/file1 "$src/a/link"
mkdir -p "$src/a/cache" && echo skip > "$src/a/cache/x"
echo log > "$src/d/x.log"; echo keep > "$src/d/keep.log"
# Names whose order differs between strings and paths, and a non-ASCII name.
mkdir -p "$src/n/a/b" "$src/n/a-b" && echo 1 > "$src/n/a.txt" && echo 2 > "$src/n/a/b/f" && echo 3 > "$src/n/a-b/f"
echo 4 > "$src/n/$(printf 'caf\xc3\xa9')"
restic -r "$repo" init >/dev/null 2>&1
parent=$(full | field snapshot_id)

# scenario <name> <changed folders, relative to src; prefix R for recursive>...   (after the change)
scenario() {
  local name=$1; shift
  : > "$work/changed"
  for c in "$@"; do
    case $c in R\ *) echo "R $src/${c#R }" ;; /*) echo "$c" ;; *) echo "$src/$c" ;; esac >> "$work/changed"
  done
  local s f
  s=$(engine splice "${common[@]}" --parent "$parent" --changed "$work/changed" "${filters[@]}" "$src" "$src2")
  f=$(full)
  local sid fid; sid=$(echo "$s" | field snapshot_id); fid=$(echo "$f" | field snapshot_id)
  local st ft; st=$(tree_of "$sid"); ft=$(tree_of "$fid")
  local stot ftot; stot="$(echo "$s" | field files)/$(echo "$s" | field bytes)"; ftot="$(echo "$f" | field files)/$(echo "$f" | field bytes)"
  if [ "$st" = "$ft" ] && [ "$stot" = "$ftot" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name (trees $st $ft, totals $stot $ftot)"
    restic -r "$repo" diff --metadata "$sid" "$fid" | head -20
    fail=1
  fi
  last_summary=$s
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
touch "$src/h/.nobackup";                              scenario "exclude marker added above a change" h h/i/j
rm "$src/h/.nobackup";                                 scenario "exclude marker removed above" h
mkdir -p "$src/g/cache" && echo x > "$src/g/cache/y";  scenario "new folder matching a pattern" g/cache
echo l > "$src/g/y.log"; echo k > "$src/g/keep.log";  scenario "negated pattern" g
mkdir -p "$src/g/cc" && printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "$src/g/cc/CACHEDIR.TAG" && echo z > "$src/g/cc/z"
                                                       scenario "CACHEDIR.TAG" g/cc
rm -r "$src/g/n" && echo file > "$src/g/n";            scenario "folder replaced by a file" g/n
ln -s /etc/hosts "$src/g/hostlink";                    scenario "add a symbolic link" g
chmod 600 "$src/a/file2";                              scenario "metadata-only change" a
echo two > "$src/a/file3"; echo two > "$src/e/f2/file1"; scenario "two folders at once" a e/f2
echo 3 > "$src/h/file1"; echo 3 > "$src/h/i/j/file1"; scenario "changed folder below a changed folder" h h/i/j
touch "$src/a/b";                                      scenario "folder mtime only" a/b
echo deep2 > "$src/h/i/j/file2"; echo deep3 > "$src/h/i/file3"
                                                       scenario "recursive entry" "R h"
echo 5 > "$src/n/a/b/f"; echo 6 > "$src/n/a-b/f";      scenario "names that sort differently" n/a/b n/a-b
echo 7 > "$src/n/$(printf 'caf\xc3\xa9')";             scenario "non-ASCII name" n
mkdir -p "$src/g/locked" && echo secret > "$src/g/locked/s" && chmod 000 "$src/g/locked"
                                                       scenario "unreadable new folder" g
chmod 755 "$src/g/locked";                             scenario "folder readable again" g/locked
# A hard-linked file changed through a folder that was reported, while its other link's folder was
# not. The splice cannot see the other link, so it must say so; Nine Lives then runs a sweep.
ln "$src/d/file1" "$src/e/hard"; echo via-link > "$src/e/hard"
echo "$src/e" > "$work/changed"
s=$(engine splice "${common[@]}" --parent "$parent" --changed "$work/changed" "${filters[@]}" "$src" "$src2")
if [ "$(echo "$s" | field hard_links_changed)" = True ]; then echo "ok    hard link reported"; else echo "FAIL  hard link not reported"; fail=1; fi
parent=$(full | field snapshot_id)
echo s2 > "$src2/x/file2";                             scenario "second source" "$src2/x"
scenario "nothing changed" a

# Control: a change that is not reported must make the comparison fail.
echo unreported > "$src/g/file1"
if (scenario "control" a | grep -q '^FAIL'); then echo "ok    control (unreported change detected)"; else echo "FAIL  control"; fail=1; fi

restic -r "$repo" check -q && echo "ok    restic check"
[ -z "$(ls "$repo/locks")" ] && echo "ok    no locks left" || { echo "FAIL  locks left"; fail=1; }
[ "$fail" = 0 ] && rm -rf "$work"
exit "$fail"
