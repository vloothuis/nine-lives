# Retrying busy reads and skipping any note

## Problem

A backup can report folders it could not read because the Mac was busy:

- `interrupted system call` (EINTR): a system call was cut short. It is safe to try again.
- `too many open files in system` (ENFILE) or `too many open files` (EMFILE): no file
  handles were free. Another program, such as a large Xcode build, may hold them.

The engine does not retry these reads, so a folder is left out of that snapshot. The app also
only offers Skip for "permission denied" and "operation not permitted". Every other error loses
its path, so the user cannot skip it.

Xcode build caches outside `DerivedData` (a custom `-derivedDataPath` such as
`build/dd-strip`) are also backed up, though Xcode rebuilds them.

## Change

1. **Engine retry.** Folder listings and item metadata reads in `walk.rs` retry:
   - EINTR: up to 5 times, at once.
   - ENFILE and EMFILE (matched on the raw OS error): up to 5 times, waiting 50, 100, 200 and
     400 ms. One run waits at most 30 s in all; after that busy reads fail at once.
   A listing that fails partway is read again from the start. After the retries the error is
   reported as before. File contents are read by rustic and are not retried. The engine also
   raises its open-file limit from macOS's default of 256 to the hard limit (at most 10240).
2. **Quick backups keep the old copy.** When a splice cannot list a folder because the Mac is
   busy, it keeps that folder's tree from the parent snapshot instead of dropping it, and
   reports the error. `excluded()` no longer treats an lstat error as "excluded"; the listing
   that follows reports it.
3. **New cause `.busy`.** The app groups these errors as "the Mac was busy". The note says a
   later backup tries again, and offers Skip. Busy groups are not merged into patterns.
4. **Skip for item errors of any cause.** `.other` errors keep their path only when the message
   has an item error's form (`read /`, `open /` or `lstat /` at the start). Free text, such as
   maintenance warnings, never becomes a folder to skip. `.other` groups are not merged.
5. **Built-in rule for Xcode caches.** The names Xcode uses: `ModuleCache.noindex`,
   `CompilationCache.noindex`, `SDKStatCaches.noindex`, `Intermediates.noindex` and
   `Index.noindex`, anywhere. Not `*.noindex`: Signal Desktop keeps attachments and drafts in
   `attachments.noindex` and `drafts.noindex`.

## Threat model

Assets: the user's files and the completeness of their backup. Nine Lives runs as the user and
has no network-facing surface in this change.

| Threat | Effect | Mitigation |
| --- | --- | --- |
| A Skip pattern covers more than the user meant | Real files are silently missing from backups | Skip keeps the existing limits: `canSkip` refuses home and its parents, merged patterns must match at most `extraBudget` other items, and the button names the folders it skips. |
| A path in an error message is crafted by a file name (for example a name containing `: `) | Skip adds a pattern for a different folder | Paths are escaped with `escapedPattern`, so no name becomes a wildcard. The pattern only covers the folder that held the item. |
| A built-in rule skips user data | Data is never backed up | The rule lists Xcode's exact folder names, not a wildcard suffix. |
| Retrying hides a lasting fault | A folder quietly goes missing | After the retries the error is reported as before. |
| Retry waits slow a backup a lot | A backup on a starved Mac takes longer | At most 0.75 s per item and 30 s per run, and only while the system is out of file handles. |
| Free-text notes are read as paths | Skip offers a wrong folder, such as `/Volumes` | Only messages in an item error's form give a path. |
| A busy error drops a folder from a quick backup | The folder is missing until the next full backup | The splice keeps the parent's copy of the folder. |
| A busy or unknown error is merged into a wide pattern | Skip covers readable siblings | Only `.unreadable` and `.protected` groups are merged. |
| A busy Mac makes the user skip a folder they need | Data is missing from backups | The `.busy` note says the next backup tries again, so Skip is not the obvious fix. |
