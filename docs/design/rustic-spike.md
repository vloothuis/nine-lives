# Spike: incremental snapshots with rustic

## Question

Can Nine Lives back up only the folders that changed, and still produce a complete snapshot?
restic walks every folder and checks every file on each run, even when nothing changed.

## Setup

- restic 0.20.0, rustic 0.12.0 (Homebrew), rustic_core 0.14.0, Apple silicon, local repository on APFS.
- Test tree A: 200 folders with 500 files each (100,000 files).
- Test tree B: 20,000 folders with 10 files each (200,000 files).
- Commands are run from a shell. Times are wall clock and include opening the repository.

## Findings

1. **rustic reads and writes restic repositories.** rustic backed up into a repository made by restic.
   `restic check` passed afterwards, and restic can list, diff and restore rustic snapshots.
2. **rustic's full walk is not faster.** An unchanged backup of tree A took about 4.6 s with restic and
   4.4 to 5.9 s with rustic. Tree B took 10.4 s and 9.9 s. Switching tools alone gains nothing.
3. **`rustic merge` alone is not enough.** It joins two snapshot trees. Changed and new files come through,
   but a file deleted since the full snapshot stays in the result.
4. **Rewrite, then merge, gives a correct snapshot.** The steps are:
   1. `rustic backup <changed folders>` makes a partial snapshot of only those folders.
   2. `rustic rewrite <full> --glob '!<changed folder>' ...` makes a new snapshot of the last full
      one without those folders. No file data is copied. Unchanged folder trees keep their IDs and are
      reused; only the trees on the path to an excluded folder are written again.
   3. `rustic merge <rewritten> <partial>` joins them.

   On tree A, with one changed, one deleted and one new file in three folders, the result had the same
   files and file contents as a fresh full backup (`restic diff`: 0 new, 0 removed, 0 changed).
5. **Steps 2 and 3 still visit every folder in the snapshot.** They read the stored trees, not the disk.
   On tree B, after changing one file:

   | Step                              | Time   |
   |-----------------------------------|--------|
   | restic backup, full walk          | 10.4 s |
   | rustic backup of 1 changed folder | 0.7 s  |
   | rustic rewrite                    | 1.9 s  |
   | rustic merge                      | 2.3 s  |
   | rustic, open repository only      | 0.6 s  |
   | rustic ls, visit all stored trees | 2.1 s  |

   The command-line steps take about 4.8 s in all, which is roughly half of a full walk. A splice that
   rewrites only the folders on the path from the root to each change would cost about the time to open
   the repository plus a few tree writes. rustic_core has the code for this (`TreeModifier`), but it is
   private to the crate, so this needs a fork or about 100 lines of copied code.

## Side effects found

- The merged snapshot lists every input path (`/src`, `/src/d007`, ...) instead of only `/src`.
  restic chooses the parent snapshot by host and paths, so its next full sweep would not pick the merged
  snapshot as parent. It would pick an older full snapshot. Passing `--parent` explicitly avoids this.
- rustic writes no user name on snapshots, and it encodes folder entries a little differently from restic.
  All 405 tree blobs differed between a rustic and a restic snapshot of the same files. Data blobs are
  shared, so the extra cost is only tree metadata.
- A partial backup of a folder includes everything below it. FSEvents reports the folders whose entries
  changed, so the partial backup should be per folder, not recursive. rustic has no option for that.
  Without one, a change near the root makes the partial backup almost as slow as a full one.

## What a real version needs

- Change tracking with FSEvents, keeping the last event ID per backup disk. A full sweep is needed when
  events were dropped (`MustScanSubDirs`, `UserDropped`, `KernelDropped`), when the event ID went back
  (volume replaced), and on a fixed schedule as a safety net.
- A splice that rewrites only the path from the root to each changed folder, written against rustic_core.
- A way to call it from Swift: either a second bundled binary next to restic, or a Rust static library
  with a C interface. rustic and rustic_core are dual licensed MIT and Apache 2.0.
- Snapshot metadata (paths, host, user, tags) set to match what restic writes, so `forget`, parent selection
  and the Restore view keep working unchanged.

## Recommendation

The approach works and keeps the backups readable with plain restic. The command-line version halves
the time on 20,000 folders. The targeted splice below removes most of what remains.

## Splice tool

`nl-splice`, in `Tools/nl-splice`, is a Rust tool on rustic_core 0.14.0. It makes one new snapshot from a
parent snapshot and a list of changed folders, and never changes the parent. Build it with
`./vendor.sh && cargo build --release`. Test it with `tests/compare.sh`.

### Results

Test tree: 292,556 folders and 1,042,815 small files, up to 8 levels deep, on a local repository.
An unchanged full walk of it takes 124 to 136 s with rustic and 146 to 153 s with restic.
Each splice changed one file in each of N random folders, starting from the previous snapshot.

| Changed folders | Splice | Files read | Trees written | Same tree as a full backup |
|---:|---:|---:|---:|---|
| 1 | 1.1 s | 1 | 12 | yes |
| 10 | 2.3 s | 10 | 67 | yes |
| 100 | 2.1 s | 100 | 598 | yes |
| 1,000 | 3.9 s | 1,000 | 5,025 | yes |
| 5,000 | 8.9 s | 5,000 | 18,445 | yes |

"Same tree" means the root tree ID of the spliced snapshot equals that of `rustic backup` of the same tree.
The two snapshots are then identical, metadata included. `restic check` passed afterwards.
About 0.5 to 0.9 s of each run is opening the repository and loading the index.

`tests/compare.sh` runs 17 cases on a small tree and compares root tree IDs in the same way. The cases
include new nested folders where only the deepest one is reported, renames, deleted folders, a folder
replaced by a file, exclude markers added and removed, a new folder matching a glob, metadata-only changes,
and a changed folder below another changed folder. A control case leaves out a change and must fail.

### Input

- `--repo PATH`: the repository (local only in the spike).
- The password: from `RUSTIC_PASSWORD` or `--password-file`, never as an argument.
- `--parent ID`: the snapshot to start from. It must be the snapshot that the change list starts from.
- `--changed FILE`: one absolute folder path per line, from FSEvents.
- `--glob GLOB` and `--exclude-if-present NAME`, repeated, with the meaning they have in `rustic backup`.

The tool prints one JSON object with the new snapshot ID, counts, read errors and timings.

### Steps

1. Open the repository and load the index. Delete temporary snapshots left by a crashed run of this host.
2. For each changed folder, go up to the nearest folder that is a folder both on disk and in the parent.
   This handles new folders where only a nested one is reported, renames, deletions and a folder replaced
   by a file. A changed folder that is now excluded, by a glob or a marker file, is removed from the
   folder above it, and nothing below it is rebuilt.
3. List each changed folder one level deep. The listing uses the same walker settings as rustic's
   `LocalSource`, and makes nodes with rustic's public `map_entry`, so the metadata is what
   `rustic backup` writes. Entries are handled as follows:
   - A file whose type, size, mtime, ctime and inode match the parent gets the parent's content, as in rustic.
   - Other files are read.
   - A subfolder that is not changed keeps the parent's subtree, under a fresh node.
   - New subfolders are listed in the same way, all the way down.
4. Read all files to be read with one `Repository::backup` into a temporary snapshot. Open the repository
   again so the new index files are loaded, and take the file nodes from the temporary tree.
5. Build the trees in one pass, deepest folder first:
   - Rebuilt folders get their tree from the listing.
   - Each folder above a change gets the parent's tree with changed entries replaced or removed.
   - Rebuilt folders get their fresh node. Snapshot paths keep the parent's node, because rustic gives
     those a placeholder node.
   - Stored trees are read through a cache, so each one is read once.
6. Write all new trees in one call, which finishes the packs and the index. Only then write the
   snapshot, with the parent's paths, host, user name and tags. Delete the temporary snapshot.

### rustic_core patch

`rustic_core.patch` (53 lines) adds `Repository::save_trees`, which uses the same packer and indexer as
`merge_trees`, and `Repository::save_snapshot`, which returns the ID. `vendor.sh` copies rustic_core 0.14.0
from the Cargo registry, where Cargo has checked its checksum, and applies the patch. Both methods could be
proposed upstream.

### Threat model

What must be protected:
- Every file that should be in a backup is in it. A missing file is found only at restore time.
- The repository stays consistent.
- The password stays secret.

| Threat | Mitigation |
|---|---|
| FSEvents misses a change, so the snapshot keeps an old file | Nine Lives runs a full sweep on dropped events, an event ID that goes back, changed rules, and on a schedule |
| A splice bug keeps a wrong file node, which every later sweep trusts | The parent is never changed. Tests compare root tree IDs with full backups. Nine Lives should run an occasional sweep that rereads all files (`--force`) and `check --read-data-subset` |
| A hard-linked file is changed through another folder, and FSEvents reports only that folder | Not handled in the spike. The fix is an index of files with more than one link, whose folders are added to the change list |
| `prune` deletes blobs the splice is about to use | rustic writes no lock files. Nine Lives runs one operation at a time per repository. A real version must write a restic lock |
| Crash halfway | Trees and index are written before the snapshot, which is one file. A leftover temporary snapshot is deleted on the next run of the same host. Unused packs go at the next prune |
| Append-only repository | Deleting the temporary snapshot fails there. The real version should not need one (see below) |
| Password in `ps` or logs | Only from the environment or a file, never printed |
| Change list points outside the backup | Paths must be absolute, without `.` or `..`, and inside a snapshot path. Symbolic links are stored as links and never followed |
| Files change during the run | As with restic, there is no point-in-time copy. Nine Lives stores the FSEvents ID from before the run, so the changes are picked up next time |
| Tampered repository on a server | As with restic: blobs are encrypted and authenticated, and rustic checks each blob it reads |
| Tampered dependency | Dependencies are pinned in `Cargo.lock` with checksums. The patch is in this repository |

### Limits and next steps

- **Excludes:** Nine Lives uses restic `--exclude` patterns, `--exclude-caches` and `--one-file-system`.
  The splice uses rustic globs and marker files. Either Nine Lives moves to rustic for full sweeps too,
  or the patterns are translated, with tests that compare both.
- **Mixed tools:** restic and rustic write different tree metadata for the same files, for example atime.
  A restic sweep after a splice rewrites every tree, though not the file data. Using rustic for sweeps
  avoids this.
- **Temporary snapshot:** it costs a second repository open (about 0.5 s) and needs a delete. Exposing
  rustic_core's file archiver in the patch would remove both.
- **Not built yet:** SFTP repositories, restic locks, hard-link tracking, case-insensitive name matching,
  and the output Nine Lives reads from restic (per-file lines, summary, unreadable folders).
- **Still to measure:** a real home folder with large files and a cold cache, over SFTP.
