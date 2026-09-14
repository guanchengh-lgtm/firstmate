# Nightly maintenance verification

Audience: maintainer verification.

This record keeps the evidence behind the nightly maintenance task and the transcript archive.
[`bin/fm-nightly.sh`](../../bin/fm-nightly.sh), [`bin/fm-maintain.py`](../../bin/fm-maintain.py), and [`bin/fm-record.sh`](../../bin/fm-record.sh) own the behavior; [`docs/configuration.md`](../configuration.md) owns activation and limits; [`docs/architecture.md`](../architecture.md) owns the ownership boundaries.
Each claim below names the executable check that proves it, so a maintainer re-runs the check rather than trusting this page.

## Fixture checks (run on every change)

These suites run under `bin/fm-test-run.sh` and build every Record, bare origin, transcript home, and tool double inside a temporary root; nothing touches a live home, Drive, Keychain, or LaunchAgent.

- `tests/fm-record.test.sh` proves the nightly transaction seams: `reconcile` fast-forwards a clean equal Record, refuses local changes without moving a ref, reports a racing push as `diverged` while keeping the local commit and file bytes, reports a vanished origin as `remote-unknown`, and reports an origin that has no bound branch yet as `reconciled detail=remote-branch-missing`; `checkpoint --reason maintain --summary` produces the dated maintain subject and refuses a multi-line summary or a summary on another reason; `verify` proves working tree, `HEAD`, and origin equality from a fresh fetch and reports a bound branch that origin no longer holds as not equal instead of trusting the cached ref.
- `tests/fm-maintain.test.sh` proves rules R1 to R5 on fixture Records, including the `lint` refusal of a Record without `backlog.md`, the acknowledged historical brief-only sidecar bound to the brief's content hash, the seven-date report-to-enforce latch with gap, duplicate-date, fingerprint-change, and cloud-run resets, the stow-gate exit matrix, fold receipt consumption without implementing folds, idempotent staged views that leave hand-owned files untouched, the T2 measure counters, receipt merging by host key, and every digest state within its line budget.
- `tests/fm-nightly.test.sh` proves the schedule and runner: a parsable LaunchAgent rendered only from the stable code checkout, the dry run listing every stage with each skipped stage and its reason, including `graphify` as not-configured without the T10 ledger and as cloud-scope under `--record-only`, the busy lock that leaves the live run files untouched, the run bound that stops the in-flight stage and keeps the prior success, the `archive` subcommand that never writes `last-attempt` or `last-complete`, an external SIGTERM recorded as `signal-term`, the default scheduled date taken from the local calendar date east and west of UTC, a full run on a fixture Record home that writes the stage table, the receipt, and one maintain commit, a lint finding that does not stop the archive, a missing restic that leaves the archive `not-configured` while the Record stages still run, a `status` that survives a corrupt `archive.json`, a Record-only run that commits views and skips the cloud-scope stages, a diverged Record-only run that keeps its local commit, skips rollout, receipt, and checkpoint, and pushes nothing, a detached Record-only clone that pushes nothing, and a Record-only verify that records a failed fetch instead of a stale equality.
- `tests/fm-graphify.test.sh` proves the T10 helper: inventory dedupes same-origin clones and keeps an absent vault explicit, eval collapses many nodes from one document and refuses a bare archive citation, an unscoped README is an ambiguous miss, pine and csv stay unsupported, an unchanged ready set does not invoke graphify, a code edit and a rename run update plus wiki, a document edit is docs-stale without a shell update, docs-stale survives a shell code update until the host wiki rebuild replaces the graph, an unknown built_at_commit forces a rebuild, a single ready graph waits for a second input instead of calling merge-graphs, a merge path with a space stays one argument, a git-tracked graph is never rewritten and leaves the clone clean, a missing ready graph refuses merge and keeps the prior merged file, pending selected rows skip merge, and a pending row whose graph already exists still reports pending-inputs.
- `tests/fm-nightly-archive.test.sh` proves the archive with tool doubles: the five families are passed as existing directories rather than globs, a missing family is recorded as `missing`, a previously present family that disappears is `finding coverage-regressed`, restic exit 3 is `finding incomplete` and never becomes the last complete snapshot, restic exit 0 without a summary id is `finding no-snapshot-id` and keeps the previous id, a locked repository by exit 11 or by the older stderr marker is `failed locked` with no stderr text in the Record, every family absent skips both backup and check, a corrupt weekly state is recorded as `state-unreadable` before the rotation restarts, the weekly check advances only after success, symlinked roots are skipped, and restore refuses a non-empty target and an implicit `latest`.

## Local transport check (real restic, local rclone backend)

`tests/fm-nightly-archive.test.sh` also runs the real `restic` and `rclone` binaries when both are on `PATH`, against an rclone remote of `type = local` inside the temporary root, and restores the snapshot into an empty directory.
The check passed on 2026-09-07 with restic 0.19.1 and rclone v1.75.1 on darwin/arm64: the restored transcript bytes were identical to the archived source and the archive state recorded a last complete snapshot id parsed from restic's JSON summary.
This proves the restic invocation, the summary parsing, and the restore recipe against a real repository; it does not prove Drive.

## Live checks (recorded at activation, not by tests)

The following are proven only on the activated home and must be recorded here with the date when they run:

- the `drive.file` scoped remote can see the repository root it created and `restic snapshots` lists the seed snapshot from a second machine using only the restored rclone configuration and Keychain password;
- the first seed archive finishes within the reviewed bound and the digest line names the snapshot as the last complete recovery point;
- `launchctl print gui/$UID/com.firstmate.nightly` shows the 03:00 calendar interval with no `KeepAlive` and no `RunAtLoad`, and the next morning's session start prints the digest line for that date;
- the cloud Record-only routine's Git credential pushes one receipt under its own host key without overwriting the Mac's receipt, and its skipped stages appear in that receipt;
- Drive capacity, token renewal, and upload throughput for one week of nightly runs.

No live check has run yet; landing the code activates nothing.
