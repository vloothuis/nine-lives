# Skip rebuildable folders that Git ignores

## Problem

Folders such as PHP's `vendor` or Rust's `target` hold downloaded or built files. They are large and
slow to scan. Their names are common words, so a rule that skips every `vendor` folder could skip
real work.

## Design

A new rule kind, `gitignored`, whose value is a folder name. The engine skips a folder when both
hold:

1. Its name is on the list of rule values.
2. The Git repository that holds it ignores it.

The `.gitignore` is the proof that a tool makes the folder. The name list keeps out the other things
a `.gitignore` lists, such as `.env`, keys and local databases, which Git does not hold and which a
backup must keep.

- Swift passes each enabled rule to nl-engine as `--exclude-gitignored NAME`.
- The walker checks the rule in `keep`, so full backups, sweeps and splices agree.
- Only real folders match, never files or symbolic links.
- The repository is the nearest parent folder that holds `.git`. The rules come from every
  `.gitignore` between that folder and the parent folder, from `.git/info/exclude`, and from the
  user's global Git ignore file. The `ignore` crate (from ripgrep) applies Git's own rules.
- Ignore files are read once per folder and kept for the rest of the run.
- A folder the user chose to keep (a negated `--exclude` pattern that matches it) is backed up.
- The restic fallback (`useResticBackup`) has no such option. It backs up these folders.

Built-in names, in the group "Ignored by Git" in Settings:

`vendor`, `target`, `build`, `dist`, `Pods`, `coverage`.

`bin` and `out` are left out: people also ignore their own scripts or exports under those names.

A change to a `.gitignore` takes effect for folders elsewhere in the repository at the next full
backup, at most 7 days later. Quick backups only look at folders that changed.

## Threat model

| Threat | Effect | Mitigation |
|---|---|---|
| A project ignores `vendor` but patches it or uses a private package that is later gone. | That code is missing from the backup. | Accepted. Each name can be turned off in Settings, and a single folder can be kept. |
| A project ignores a listed folder that holds real work, for example `dist` with hand-made files. | That work is missing from the backup. | The list holds only names that tools use for output. Users can turn a name off. |
| A file is tracked by Git although its folder is ignored. | Git still holds it, so nothing is lost. | None needed. |
| Restoring a `vendor` without a lock file gives newer versions. | Different versions after a restore. | Accepted by the product owner: pin versions if they matter. |
| Someone writes a `.gitignore` to hide a folder from the backup. | That folder is skipped. | Writing it needs write access to the parent, which already allows deleting the folder. Not a new risk. |
| A crafted name such as `../x` or `a/b`. | It could match unexpected paths. | The engine rejects names that are empty, hold `/`, or are `.` or `..`. |
| A huge or malformed `.gitignore`. | Slower scans, or bad lines. | Bad lines are skipped, as Git does. Files are read once per run. Reading problems become warnings and skip nothing. |

No data leaves the Mac, and no new permissions are needed.
