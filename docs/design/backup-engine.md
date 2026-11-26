# Backup engine: rustic for backups, with incremental snapshots

## Goal

Backups should take seconds when little changed, instead of a full walk of the home folder.

- Most backups are *incremental*. Nine Lives reads only the folders that FSEvents reports as changed and
  splices them into the last snapshot. This is the technique from `rustic-spike.md`.
- A periodic *full sweep* walks everything, as backups do today. It catches anything FSEvents missed.
- Both are done by one program, `nl-engine`, built on rustic_core. Both produce the same snapshot for the
  same files, so a sweep after an incremental backup changes only what really changed.
- restic stays for everything else: `init`, `snapshots`, `ls`, `restore`, `forget --prune`, `check`,
  `unlock`, `cat config` and `stats`. Repositories stay plain restic repositories, readable with restic alone.

## Why one program for both kinds of backup

- **Same metadata.** restic and rustic write different folder metadata for the same files, for example
  atime. If restic made the sweeps, every sweep after an incremental backup would rewrite every tree.
- **Same exclude rules.** The splice must leave out exactly what the sweep leaves out. One filter module
  in one program guarantees that.
- **No extra binaries.** One Rust binary next to restic, instead of rustic, nl-splice and an SFTP helper.

## nl-engine

A Rust command-line program in `Engine/`. It uses rustic_core 0.14.0 with a small patch (see below).
Arguments and JSON output are a private protocol between Nine Lives and the engine. Swift and Rust both
test against it.

```
nl-engine backup  --repo R [--ssh-json A] --tag T --host H [--parent ID] [--force] [filters] SOURCE...
nl-engine splice  --repo R [--ssh-json A] --tag T --host H --parent ID --changed FILE [filters] SOURCE...
```

- `--ssh-json` is the ssh command as a JSON array of arguments. The engine runs it directly, never
  through a shell.
- `--parent` is required to be used. The engine looks it up by ID, not by host and paths, and fails when it
  does not exist. rustic's own parent lookup by host, label and paths is switched off, because it silently
  drops a parent whose paths differ (for example after a source was added).
- Sources are made absolute, sorted and de-nested (a source inside another source is dropped) before use.
  Both commands get the same sources, so the snapshot's `paths` are the same.

Filters, the same for both commands:

- `--exclude P`: a restic exclude pattern, `!P` takes back an earlier match, as in restic.
- `--exclude-if-present SPEC`, `--exclude-caches` and `--one-file-system`, as in restic.

The password comes from the environment (`NL_ENGINE_PASSWORD`), never from an argument. The cache folder
comes from `--cache-dir`, so it stays inside the app's own cache folder. Exit codes follow restic, so
`ResticExit` keeps working:

| Exit code | Meaning |
|---|---|
| 0 | done |
| 3 | done, but some files could not be read |
| 1 | failed, and no snapshot was written |
| 11 | the repository is locked by another process |
| 130 | stopped by a signal |

### Filter (`filter.rs`)

This is a port of restic 0.18's `internal/filter`, so the patterns Nine Lives writes keep their meaning.
It is used exactly as restic's backup uses it:

- Each item is checked with `filter.List` on its absolute path. An excluded folder is never entered. A
  later `!P` only takes back a match of that same item; it cannot reach inside an excluded folder.
- Malformed patterns stop the run before it starts, as in restic.
- A marker (`--exclude-if-present name[:header]`) excludes every item in the folder that holds it, except
  the marker itself. The folder and the marker stay in the snapshot, as in restic. With a header, the
  marker must start with exactly those bytes. `--exclude-caches` is the marker
  `CACHEDIR.TAG:Signature: 8a477f597d28d172789f06886806bc55`.
- `--one-file-system` keeps a mount point as a folder, but nothing inside it, as in restic.

The tests run 12,000 cases whose answers restic itself computed (`Engine/tests/filtergen`), plus restic's
own test cases.

Nine Lives passes paths from `pathChoices` as patterns. Today these are not escaped, so a folder named
`Photos [2020]` is never matched. Swift escapes `\`, `[`, `]`, `*` and `?` in them. This also fixes it for
restic.

### Walker (`walk.rs`)

The walker reads folders itself with `std::fs::read_dir`, sorts the names by bytes, and makes each node with
rustic's public `LocalSourceSaveOptions::map_entry`. It does not follow symbolic links. It can list one
folder (for a splice) or a whole tree (for a sweep).

A sweep wraps the walker in a `ReadSource` and passes it to rustic's public `Repository::archive`, the same
archiver `rustic backup` uses. That archiver needs a strict order, which the walker guarantees and checks:

- items in depth-first order, names in byte order, each folder's node directly followed by its contents;
- the source roots themselves are not emitted, as in rustic's `LocalSource`, so their nodes are
  placeholders in both sweep and splice;
- sources sorted and not nested.

A folder is opened before its node is emitted. If it cannot be read, the folder is left out and an error is
reported. restic does the same, and an empty folder in a snapshot would look like lost data at restore.

### Splice (`splice.rs`)

As in the spike, with these changes:

- **Recursive entries.** A line `R <path>` in the change file means "this folder and everything below it".
  Every subfolder is then listed as well, but unchanged files still keep their content. This is how
  FSEvents' `MustScanSubDirs` is handled.
- **No temporary snapshot.** The patch adds a narrow call that chunks and packs one file's content and
  returns its node. There is no second open of the repository and no snapshot to delete, which also makes
  append-only servers work. One indexer is shared, and the order is: data packs, index, trees, snapshot.
- **Same filter and walker.** The splice lists folders with the sweep's walker and filter, so it cannot
  disagree with a sweep about what is in a folder.
- **Hard links.** When a changed file has more than one link, the splice reports it. Swift then makes the
  next backup a sweep, because the other links may be in folders FSEvents did not report.
- **Summary.** The snapshot gets a restic-style summary: the parent's totals plus the changes. So Nine
  Lives can show the number of files and their size after a splice, as after a sweep.

### Output

There is one JSON object per line on standard output:

- `{"type":"progress","files":N,"bytes":N,"path":"..."}`, at most four times a second.
- `{"type":"folder","path":"/a/b/","items":N}`, for each folder the walker lists. It feeds the folder index.
- `{"type":"error","path":"...","message":"..."}`, for unreadable files and folders.
- `{"type":"summary","snapshot_id":"...","kind":"backup|splice","files":N,"bytes":N,"files_new":N,`
  `"files_changed":N,"data_added":N,"data_added_packed":N,"duration":S,"hard_links_changed":bool,`
  `"sample":[{"path":"...","size":N}]}`.

The sample is up to 50 random regular files (1 byte to 20 MB) from the finished snapshot, picked by a random
walk down its trees. Verification restores files from it, and it stays correct after a splice. The per-file
`-vv` parsing in Swift goes away.

### SFTP (`sftp.rs`)

The engine runs the ssh command from `--ssh-json` (Nine Lives' `SSHOptions`, unchanged) and speaks SFTP over
its standard input and output. It has its own small synchronous SFTP version 3 client (about 700 lines)
instead of an async crate, because rustic calls the backend from plain threads. It implements rustic's
public `ReadBackend` and `WriteBackend` traits with restic's file layout.

- **Atomic writes.** Files are written to a temporary name in the same folder, as restic's SFTP backend
  does, synced with `fsync@openssh.com` when offered, and then renamed. The engine uses
  `posix-rename@openssh.com` when the server offers it. Listings ignore temporary names and remove those
  older than a day.
- **Threads.** Every request has an ID. One thread reads all answers and hands each to the thread that
  waits for it. Reads and writes of one file keep 32 requests in flight, with the sizes the server
  announces in `limits@openssh.com`, so speed is not limited by round trips.
- **Timeouts.** Each request has a timeout of 120 seconds, both for sending (the pipe is non-blocking) and
  for the answer. A hung server ends the run with an error instead of waiting forever.
- **Tests** run the client against OpenSSH's `sftp-server` directly, without sshd, and through a proxy
  that drops the connection or stops answering halfway through an upload.
- It uses the same known-hosts file and key as today, and never prompts.

### Locks

restic tells other processes "I am using this repository" with a file in `locks/`. rustic does not. The
engine writes restic-format lock files through the raw backend, so no new rustic file type is needed:

- The lock holds the real host name and the engine's process ID, so `restic unlock` can tell when it is
  stale.
- It is not exclusive, like the lock of `restic backup`. Acquiring follows restic: check for an exclusive
  lock, write ours, wait, check again. A fresh exclusive lock means exit code 11.
- Every five minutes a new lock file is written and the old one deleted, because lock files are named after
  their content.
- Before the snapshot is saved, the engine checks that its last successful refresh is younger than restic's
  stale timeout (30 minutes). If not, for example after the Mac slept, another client may have pruned, so
  the engine stops without saving.
- On exit, and on SIGINT or SIGTERM, the engine removes its lock. Swift sends the signal to the engine only,
  and stops ssh after the engine has exited or the grace period has passed.

### rustic_core patch

The patch is kept small and could be proposed upstream:

1. `Repository::save_trees` and `Repository::save_snapshot` (from the spike).
2. `Repository::file_saver()`: a handle that chunks and packs a reader's content for a given node and
   returns the node with its content, plus `finalize()`. It shares one indexer with `save_trees`.

## Nine Lives

### Choosing incremental or full

After each successful backup, Nine Lives stores an *incremental state* per disk and server:

- the snapshot ID;
- the FSEvents ID taken just before that backup began;
- the UUID of each source volume (`FSEventsCopyUUIDForDevice`);
- a hash of the sources and the filter arguments;
- when the last sweep was, and when the last sweep with `--force` was;
- the permissions state (Full Disk Access).

The state lives in the app's state file next to `KnownDisk`. Before a backup, Nine Lives replays FSEvents
since the stored ID for the source paths, with `kFSEventStreamCreateFlagWatchRoot`, until `HistoryDone`.
Event paths are made canonical with `realpath`. Paths that the filter excludes are dropped before
counting. Then:

| Situation | Backup |
|---|---|
| No state, or the newest snapshot in the repository is not the stored one | full |
| Sources or filters changed (different hash) | full |
| A source volume has a different UUID, or the event ID went back | full |
| A source is not on the internal startup volume | full |
| An event has `RootChanged`, `Mount`, `Unmount`, `EventIdsWrapped`, `UserDropped` or `KernelDropped` | full |
| More than 50,000 changed folders remain after filtering | full |
| The last sweep is older than 7 days | full |
| The previous splice changed a hard-linked file | full |
| The permissions state changed since the last sweep | full |
| Otherwise | incremental, with `MustScanSubDirs` paths as recursive entries |

A full sweep is run with `--force` (all file content read again) when the last forced sweep is more than
30 days old and the Mac is on mains power.

If a splice fails for a reason other than cancellation or a connection problem, the same run retries at once
as a full sweep, and the failure is logged in the backup notes.

### Swift changes

- `ResticKit/Engine.swift`: runs nl-engine with the same `ProcessRunner`, environment, priority handling and
  error mapping as restic, and parses the JSON lines above.
- `NineLivesCore/ChangeTracker.swift`: FSEvents collection, and the decision table above as a pure
  function so it can be tested.
- `BackupEngine.runBackup`: calls the engine instead of `restic backup`. The folder index and the sample
  come from the engine's output.
- **Folder index after a splice:** the folder index needs every folder, and a splice lists only a few. After
  a splice, Nine Lives keeps the index of the last sweep and accepts it for snapshots that were spliced from it.
- **Notes after a splice:** a splice reports only problems in the folders it read. Folders that could not be
  read at the last sweep are still missing from the snapshot. So the notes of a splice also repeat the
  unreadable items from the last sweep that are not inside a folder this splice read.
- **Activity:** the history shows "Quick backup" for incremental runs and "Full backup" for sweeps.
- **Logging:** the reason for each full sweep is logged. When a sweep follows a splice and still finds new
  or changed files, that is logged too, because it means FSEvents missed something.
- **Fallback:** a hidden setting `useResticBackup` runs `restic backup` as before, for one release.
- **Bundling:** `scripts/bundle.sh` builds nl-engine for the target architecture and signs it like restic.
  CI runs `cargo test`, the comparison tests and `swift test`. The release workflow builds it for both
  architectures.

### Upgrade

The first engine sweep of a repository made by restic reads no file data, because rustic matches files
with restic's parent. Only symbolic links count as changed once, and they have no content. It does write every tree again, because the folder metadata differs. These trees
are kept until the old restic snapshots expire. This is a one-off cost, measured before release.

## Threat model

What must be protected:

- Every file that should be in a backup is in it, with the right content. A missing or stale file is
  found only at restore time.
- The repository stays consistent and readable with plain restic.
- The repository password and the SSH key stay secret.
- The server learns nothing beyond what restic already shows it (sizes and timing of encrypted files).

| Threat | Mitigation |
|---|---|
| FSEvents misses a change, so a snapshot keeps an old file | Full sweep on every condition in the table above, and at least every 7 days. A sweep compares every file's metadata with the parent, so it repairs any missed change. Misses are logged |
| A splice bug keeps a wrong node, and every later sweep trusts it | The parent is never changed. CI compares splices with sweeps by root tree ID over many cases. Monthly verification restores random files and runs `check --read-data-subset`. A monthly `--force` sweep reads all file data again, so wrong content cannot survive for long |
| The engine's filter and restic's disagree, so files are silently left out | The filter is a port of restic's, tested against 12,000 answers computed by restic. A test backs up one tree with both programs and compares `restic ls` |
| The archiver gets items out of order and silently misses the parent or duplicates names | The walker sorts and checks the order, and sources are de-nested. Tests with names such as `a`, `a-b`, `a.txt`, `a/b` and non-ASCII names |
| The parent is silently dropped, so a sweep re-reads everything | The parent is looked up by ID, and the engine fails if it is not used |
| An unreadable folder is stored as an empty folder | The folder is opened before its node is written. If that fails it is left out and reported |
| A hard-linked file changes through a folder that was not reported | The splice reports changed files with several links, and the next backup is a sweep |
| Another process prunes while the engine writes | Restic-format lock with the real host and process ID, refreshed. The engine refuses to start with a fresh exclusive lock, and refuses to save after its lock went stale |
| Crash or kill halfway | Data packs, then index and trees, are written before the snapshot, which is one file. Nothing refers to unfinished packs. The next prune removes them. `restic unlock` sees the dead process and removes the lock |
| SFTP connection drops while writing | Temporary name, then rename. A file is only listed under its final name once complete |
| SFTP server hangs | A timeout on every request |
| Man in the middle on SFTP | The same ssh command as today: own known-hosts file, `StrictHostKeyChecking=accept-new`, key only, no agent, no prompts |
| Shell injection through the ssh command | The command is passed as a JSON array and run without a shell |
| Password exposure | From the environment only, never in arguments, logs or JSON output. The environment of the child is built from scratch, as for restic |
| Change list or arguments point outside the sources | Paths must be absolute, without `.` or `..`, and inside a source. Links are stored, never followed |
| A malicious file name breaks the JSON or the notes | Paths are JSON-escaped by `serde_json`. Swift treats every path as data |
| Tampered repository on a server | As with restic: everything is encrypted and authenticated, and rustic checks each blob it reads. The repository ID check before each backup stays |
| Tampered dependency or build | Cargo.lock with checksums, `cargo build --locked` in CI and release, and the patch in this repository. Release builds are signed with the hardened runtime |
| Resource exhaustion on a huge change list | The change list is deduplicated. Above 50,000 folders, Nine Lives does a sweep instead |
| The engine has a serious bug in the field | A hidden setting falls back to `restic backup` for one release |

## Tests

- **Rust unit tests:** filter (12,000 restic answers, restic's cases, Nine Lives' default rules), walker
  order, change-list normalisation, lock file format, JSON output.
- **Comparison tests** (`Engine/tests/compare.sh`): every scenario from the spike plus recursive entries,
  negated patterns, markers, `CACHEDIR.TAG`, unreadable folders, hard links, and names that sort
  differently as strings and as paths. Each splice must have the same root tree ID as a sweep of the same
  tree. A control case must fail. `restic check` runs at the end.
- **Cross-check with restic:** the same tree backed up by restic and by the engine with the default rules,
  markers, a folder with mode 000 and a path choice. `restic ls` must list the same paths.
- **Locks:** `restic prune` during an engine run must fail; `restic unlock` after `kill -9` of the engine
  must remove its lock.
- **Upgrade:** the engine's first sweep of a restic-made repository has no new files and adds only trees.
- **SFTP:** the comparison tests also run against a local SFTP server (`sshd` on localhost with a throwaway
  key) when available, and in CI.
- **Swift unit tests:** the incremental-or-full decision table, JSON parsing, notes carry-over, escaping of
  path choices.
- **End to end:** the app bundle backs up to a disk image, incrementally and in full, and restores with restic.
