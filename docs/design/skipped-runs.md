# Skipped runs when a server goes away

## Problem

A server on the home network is often out of reach: the laptop moves, sleeps or changes Wi-Fi.
Scheduled runs already wait until a probe gets an answer from the server. But when the connection
drops after the probe, the run is saved as failed:

- The overall status turns red with "Could not reach the server.", or the raw ssh and restic
  output when that classification misses.
- A check that loses its connection is saved as "Problem found", although it learned nothing
  about the backups.
- A manual run fails on the first short network blip.

Being away from the server is normal. The user should only hear about two things: a long time
without a backup, and a server that keeps dropping the connection while it answers the probe.

## Change

1. **Classify a lost connection.** `ResticError.isConnectionLost` is true for network errors
   (refused, timed out, unreachable, broken pipe, connection lost, reset or closed, `client_loop`,
   "not responding", "unexpected EOF", and nl-engine's "the SFTP connection ended" and timeouts).
   It is false when the server rejected the key, the host key changed, SFTP is missing, or the
   server closed the connection before the handshake (`kex_exchange_identification`, usually a
   limit or a ban): those need the user. `restic check` and the quick-backup fallback use the same
   test. The ssh probe before a backup keeps the text ssh printed. It throws
   `EngineError.serverUnreachable` with that text only for a lost connection, and a plain failure
   otherwise.
2. **New outcome `.skipped`.** On disk it is stored as `cancelled` with `"skipped": true`, so
   older versions can still read the state file. A scheduled run that loses its connection is saved as skipped,
   with one plain sentence ("pi stopped answering, so this backup was skipped. Nine Lives tries
   again when pi is reachable.") and the raw output in `details`. It sets `lastFailure` as
   before, so the next attempt waits 15 minutes and does not loop against a flaky server. No
   notification is posted. A skip directly after a skip of the same server, with no other run in between, merges into that record. The record keeps a count and the time of the
   first skip. Other scheduled server failures now post a notification, because
   they need the user.
3. **Status ignores skipped runs.** The overall status and the "What went wrong" card use the
   newest run that was not skipped. When the last three runs to a server were all skipped, the
   status shows a warning: "Backups to pi keep getting interrupted". The next good backup
   clears it. Servers reached through a proxy or jump host get no warning: their probe always
   succeeds, so skips are expected while away. Until the first probe after launch the kind of
   connection is unknown, so there is no warning yet. The reminder after `remindAfterDays` without a backup stays as it is.
4. **Manual runs say what happened.** A manual run that loses its connection is saved as failed
   with a plain message: "The connection to pi dropped. Check that pi is on and awake, then try
   again." There is no automatic retry: ssh takes up to 3 minutes to notice a drop, so a retry
   would not help with a short blip.
5. **An interrupted check keeps the last result.** A check that loses its connection leaves
   `lastVerification` unchanged, so it stays due. A scheduled check sets `lastFailure`, so it
   waits until the next good backup, which starts the check when it is due. A check that someone
   started, directly or by a manual backup, posts a notification that it did not finish.
6. **Activity.** Skipped runs show a grey icon and "Backup to pi skipped". The details show the
   sentence; the raw output sits under a closed "Technical details" disclosure.
7. **Only real attempts are logged.** A tick where the probe gets no answer adds no record. The
   menu already shows the server as unreachable.

## Threat model

Assets: the completeness of the user's backups, and the user's trust that a quiet app means
backups are happening. No new network surface, input or permission is added.

| Threat | Effect | Mitigation |
| --- | --- | --- |
| A real fault is classified as a lost connection | A lasting problem stays quiet | Key rejection, host key change and missing SFTP are excluded and still fail. Three skipped runs in a row show a warning. The stale reminder still fires after `remindAfterDays`. |
| A changed host key (possible attacker in the middle) is hidden as "skipped" | The user does not notice a possible attack | `host key verification failed` and `remote host identification has changed` are never a lost connection. |
| A flaky server makes the scheduler retry in a loop | Battery drain, many log entries | A skipped run sets `lastFailure`, so attempts are 15 minutes apart. The history keeps at most 300 records. |
| An interrupted check is read as "backups are fine" | The user trusts backups that were not checked | The previous check result stays, with its date. The check stays due. |
| An interrupted check is read as "backups are broken" | The user deletes or redoes good backups | An interrupted check no longer writes "Problem found". |
| Raw output in `details` holds host names, paths or user names | Information shown on screen | The data is the same as in today's failure details. It stays local, and it is only shown when the user opens the disclosure. |
| An older version reads a history with `.skipped` | An unknown outcome fails the whole `state.json` decode, so the older version starts over without disks or settings | A skipped record is stored as outcome `cancelled` with `"skipped": true`. Older versions read it as a stopped backup. If an older version saves the file, the flag is lost and the record stays "stopped". |
| A server whose ssh service is down never answers the probe | No record is written, so the app looks quiet | The menu shows the server as unreachable, and the stale reminder fires after `remindAfterDays`. |
| A proxy server is skipped every 15 minutes while away | The history fills up and real backups drop out | Skips in a row merge into one record. Proxy servers get no "keep getting interrupted" warning. |
| A skipped run blocks scheduled checks | Checks wait longer | Checks start after the next good backup when they are due. |
| A real ssh failure is reported as "unreachable" | The user misses a fix, such as file permissions on the ssh config | The probe's ssh text is classified; only network failures become skipped runs, with the text in `details`. |
