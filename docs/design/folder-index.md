# Folder index and pattern suggestions for backup notes

## Goal

When files cannot be read, the backup notes group the failing folders and offer one skip pattern.
The pattern should be as broad as possible without skipping much that did not fail.
To judge that in milliseconds, Nine Lives keeps a small index of the folders in the last backup.

## Folder index

- Built while `restic backup -vv --json` runs, from the `verbose_status` lines Nine Lives already reads
  (`FolderCollector`). Folder lines end in `/`. Each file or folder line adds one item to its parent folder.
- Only item counts are kept, not bytes. restic reports size 0 for unchanged files, and an `lstat` per file
  would cost millions of system calls. Item counts are enough to judge a pattern.
- Lines are read as bytes: `memmem` finds `"item":"`. A line whose item has a JSON escape is decoded with
  `JSONDecoder`. The walk down the tree reuses the previous path, because restic reports folder by folder.
- Folders are kept as a trie with interned names: parent, name number and item count per folder, and one
  dictionary from (parent, name) to child. Folders that restic could not read come from error lines and are
  marked unknown. Collecting stops at 2 million folders and then no index is written.
- After the backup, on success or exit code 3 (some files unreadable), the folders are sorted into
  depth-first order and stored as columns: name number, end of subtree, items below, flags.
  A cancelled or failed backup writes nothing, so the previous index stays.
- File format: magic, version, snapshot ID, name table, columns, LZFSE. The reader checks magic, version,
  every length, every name number and every subtree end, and rejects the file on any mismatch.
- One file, `Folder Index/latest.nlfi` in Application Support, folder 0700, file 0600, written to a
  temporary file in the same folder and swapped in with `replaceItemAt`. Always excluded from backups.
- The index is not kept in memory. Notes of a backup are grouped with it once, in the background,
  and only when the notes contain unreadable or blocked items and the index is of the same snapshot.

Measured on a real home folder (786,204 folders, 70,016 distinct names, 4.7 million lines, release build):

| Step | Result |
| --- | --- |
| Collecting during the backup | 0.57 µs per line, 2.7 s in total, 56 MB while the backup runs |
| Building the depth-first columns | 0.17 s |
| Writing | 0.12 s, 2.5 MB on disk |
| Loading | 0.06 s |
| Query `~/*/*/node_modules` | 0.9 ms |
| Query `~/Library/Containers/*/Data/Library/Caches` | 0.3 ms |

## Pattern suggestions

1. Group unreadable and blocked items by folder, as before.
2. Two groups can merge when their folders have the same depth and the same last name. Where names differ,
   their shared start and end are kept and the middle becomes `*` (`ansible-local-*`). Each component is a
   restic pattern component: `*` does not cross `/`, and the pattern is absolute.
3. With an index of the same backup, a merge is accepted when the pattern matches at most 10 items besides
   the failing folders, and no matched folder holds an unreadable folder. Merging repeats until no pair passes.
4. Without an index, a merge is accepted only when the folders differ in one name.
5. The part before the first `*` must not be the home folder or one of its parents.
6. The note says what the pattern skipped in the last backup. It says "in the last backup", because a
   wildcard also matches folders made later.
7. A group counts as skipped when enabled rules already cover each of its folders, not only when a rule
   has the same text.

## Threat model

Assets: the list of folder names in the user's home (project, client and personal names) and the
user's backup coverage.

| Threat | Mitigation |
| --- | --- |
| Another local user or process reads the index and learns folder names. | Stored in the user's Application Support, file 0600, folder 0700. Same trust level as the catalogs and `state.json`, which already hold full file lists. No file names, sizes, contents or dates are stored. |
| The index ends up in a backup or on the backup disk. | The folder is in the rules that are always applied, as an absolute home path. It is never written to the backup disk. |
| A crafted folder name breaks the line scanner or the file (quotes, escapes, newlines, very long names). | Escaped items go through `JSONDecoder`. Lines without an item are ignored. The reader validates every count and offset and rejects the file on any mismatch. Names cannot hold NUL, which separates them in the file. |
| A tampered index makes a broad pattern look narrow, so the user skips data they need. | A local attacker who can write the index can also change settings directly, so this adds no new access. The pattern stays visible in the note and in settings, and the home-folder check does not depend on the index. |
| A planted symlink redirects the write. | The temporary file is created in the index folder and swapped in with `replaceItemAt`, which replaces a symlink at the destination instead of following it. |
| Over-broad patterns skip data created later. | The budget limits extras in the last backup. The last name is never a wildcard. The note says "in the last backup". The rule is shown in settings and can be removed. |
| Resource use. | Folders only. Collecting stops at 2 million folders. Measured 56 MB for 786,204 folders during a backup and nothing between backups. |
