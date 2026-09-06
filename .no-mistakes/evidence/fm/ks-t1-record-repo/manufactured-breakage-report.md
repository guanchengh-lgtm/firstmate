# Manufactured defect evidence

Every changed test file detected a one-line defect in executable code.
The original source was restored after each failure.
Git porcelain was empty before each green rerun and before the next defect.

The runner used Bash DEBUG selection to execute existing test functions without changing their assertions.
The lint test only exercised file discovery with `--list-files`; no linter ran.

Reproduction: `python3 manufactured-breakage.py`, with the worktree as the current directory.

## tests/fm-record.test.sh

Subject: `bin/fm-record.sh:785`.
Selector: `test_index_recovery_accepts_a_status_refresh`.

[Failure log](breakage-fm-record-red.log) and [restored test log](breakage-fm-record-green.log).

```text
Test: tests/fm-record.test.sh
Selector: test_index_recovery_accepts_a_status_refresh
Subject: bin/fm-record.sh:785
-     if ! git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" diff --cached --quiet --ita-visible-in-index "$tree" --; then
+     if ! cmp -s "$GIT_DIR_ABS/index" "$journal/index"; then

not ok - recovery after status at rm: expected exit 0, got 8

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-record-scan.test.sh

Subject: `bin/fm-record-scan.sh:42`.
Selector: `test_eight_classes_refuse_without_echoing_values`.

[Failure log](breakage-fm-record-scan-red.log) and [restored test log](breakage-fm-record-scan-green.log).

```text
Test: tests/fm-record-scan.test.sh
Selector: test_eight_classes_refuse_without_echoing_values
Subject: bin/fm-record-scan.sh:42
- SECRET_COMBINED="$PRIVATE_KEY_HEADER|gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{20,255}|(AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,255}|[sr]k_live_[A-Za-z0-9]{16,255}|AIza[A-Za-z0-9_-]{35}|$OPENAI_SECRET"
+ SECRET_COMBINED="$PRIVATE_KEY_HEADER|fmphase_never_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{20,255}|(AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,255}|[sr]k_live_[A-Za-z0-9]{16,255}|AIza[A-Za-z0-9_-]{35}|$OPENAI_SECRET"

not ok - class github-classic-token: expected exit 2, got 0

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-captain-hold-lifecycle.test.sh

Subject: `bin/fm-captain-hold.sh:1138`.
Selector: `test_complete_scan_block_cannot_print_success`.

[Failure log](breakage-fm-captain-hold-lifecycle-red.log) and [restored test log](breakage-fm-captain-hold-lifecycle-green.log).

```text
Test: tests/fm-captain-hold-lifecycle.test.sh
Selector: test_complete_scan_block_cannot_print_success
Subject: bin/fm-captain-hold.sh:1138
-   record_out=$("$SCRIPT_DIR/fm-record.sh" checkpoint --reason complete 2>&1) \
+   record_out=$(true) \

warning: templates not found in /opt/homebrew/opt/git/share/git-core/templates
not ok - scan-blocked completion printed success

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-feeder-export.test.sh

Subject: `bin/fm-feeder-export.sh:1362`.
Selector: `test_nested_git_report_is_not_exported`.

[Failure log](breakage-fm-feeder-export-red.log) and [restored test log](breakage-fm-feeder-export-green.log).

```text
Test: tests/fm-feeder-export.test.sh
Selector: test_nested_git_report_is_not_exported
Subject: bin/fm-feeder-export.sh:1362
-   LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -name report.md -print0 > "$report_sources" 2>/dev/null \
+   LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 4 -name report.md -print0 > "$report_sources" 2>/dev/null \

not ok - nested Git report: exporter failed with 1
fm-feeder-export: source data/aa/report.md changed path, type, containment, or identity before its snapshot

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-fleet-snapshot-view.test.sh

Subject: `bin/fm-fleet-snapshot.sh:1712`.
Selector: `test_nested_git_report_is_not_discovered`.

[Failure log](breakage-fm-fleet-snapshot-view-red.log) and [restored test log](breakage-fm-fleet-snapshot-view-green.log).

```text
Test: tests/fm-fleet-snapshot-view.test.sh
Selector: test_nested_git_report_is_not_discovered
Subject: bin/fm-fleet-snapshot.sh:1712
-   LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
+   LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 4 -type f -name report.md -print \

not ok - snapshot walked a nested Git report: {
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-09-06T21:45:47Z",
  "fm_home": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report",
  "roots": {
    "fm_root": "/Users/AI/.no-mistakes/worktrees/edb446952c22/01M1VRWMEZJGZ0328RGDY94JYC",
    "state": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/state",
    "data": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/data",
    "config": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/config",
    "projects": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/projects"
  },
  "backlog": {
    "path": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/data/backlog.md",
    "present": false,
    "records": []
  },
  "tasks": [],
  "main_inventory": {
    "valid": true,
    "reason": null,
    "orphan_in_flight": [],
    "unstructured_current_count": 0
  },
  "scout_reports": [
    {
      "id": "aa",
      "path": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/data/.git/objects/aa/report.md",
      "kind": "scout"
    },
    {
      "id": "real-scout",
      "path": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/data/real-scout/report.md",
      "kind": "scout"
    }
  ],
  "decision_locks_open": [],
  "secondmate_current": {
    "registry": {
      "present": false,
      "available": true,
      "complete": true,
      "reason": null,
      "provenance": "registered-table",
      "path": "/private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-fleet-snapshot.QayDy2/nested-git-report/data/secondmates.md",
      "freshness": {
        "status": "fresh",
        "observed_at": "2026-09-06T21:45:47Z"
      },
      "records": [],
      "input_truncated": false,
      "records_truncated": false,
      "reasons": [],
      "lines_in_window": 0,
      "records_in_window": 0
    },
    "records": [],
    "total_registered": 0,
    "total": 0,
    "shown": 0,
    "truncated": 0
  },
  "secondmate_landed": {
    "records": [],
    "truncated": [],
    "unreadable": [],
    "partial": []
  },
  "secondmate_guidance": {
    "note": "For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority."
  }
}

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-gotmp.test.sh

Subject: `bin/fm-teardown.sh:3100`.
Selector: `test_teardown_removes_tasktmp_dir`.

[Failure log](breakage-fm-gotmp-red.log) and [restored test log](breakage-fm-gotmp-green.log).

```text
Test: tests/fm-gotmp.test.sh
Selector: test_teardown_removes_tasktmp_dir
Subject: bin/fm-teardown.sh:3100
-   rm -rf "$TASK_TMP"
+   : "$TASK_TMP"

not ok - teardown did not remove the tasktmp dir (/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T//fm-gotmp-tests.UViaNU/fm-td-rm-z2 still exists)

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-lint.test.sh

Subject: `bin/fm-lint.sh:931`.
Selector: `test_list_files_reports_the_shell_inventory`.

[Failure log](breakage-fm-lint-red.log) and [restored test log](breakage-fm-lint-green.log).

```text
Test: tests/fm-lint.test.sh
Selector: test_list_files_reports_the_shell_inventory
Subject: bin/fm-lint.sh:931
-     ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
+     ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh data/.git/bin/*.sh)

not ok - fm-lint.sh --list-files did not return the complete shell inventory

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-map-fog-check.test.sh

Subject: `bin/fm-map-fog-check.sh:176`.
Selector: `test_nested_git_map_is_not_discovered`.

[Failure log](breakage-fm-map-fog-check-red.log) and [restored test log](breakage-fm-map-fog-check-green.log).

```text
Test: tests/fm-map-fog-check.test.sh
Selector: test_nested_git_map_is_not_discovered
Subject: bin/fm-map-fog-check.sh:176
-     done < <(find "$DATA" -name .git -prune -o -name map.md -type f -print 2>/dev/null || true)
+     done < <(find "$DATA" -name map.md -type f -print 2>/dev/null || true)

not ok - nested Git map.md was discovered as fog: MAP_FOG: data/.git/objects/aa/map.md	live unspecified item: - Whether a nested Git map is treated as live fog.

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-session-start.test.sh

Subject: `bin/fm-session-start.sh:995`.
Selector: `test_record_checkpoint_only_on_locked_startup`.

[Failure log](breakage-fm-session-start-red.log) and [restored test log](breakage-fm-session-start-green.log).

```text
Test: tests/fm-session-start.test.sh
Selector: test_record_checkpoint_only_on_locked_startup
Subject: bin/fm-session-start.sh:995
-   record_out=$("$SCRIPT_DIR/fm-record.sh" checkpoint --reason session-start 2>&1) || true
+   record_out=$("$SCRIPT_DIR/fm-record.sh" health 2>&1) || true

warning: templates not found in /opt/homebrew/opt/git/share/git-core/templates
not ok - locked session start did not checkpoint the Record (missing: 'RECORD
fm-record: state=committed-local')
--- output ---

================================================================================
SESSION START - /private/var/folders/p3/95t2_00n2jl3r2cn79bfn18h0000gp/T/fm-session-start-tests.isSoJs/record-checkpoint/home
================================================================================

LOCK
--------------------------------------------------------------------------------
lock acquired: harness pid 96514

BOOTSTRAP
--------------------------------------------------------------------------------
MISSING: tasks-axi (install: npm install -g tasks-axi)
MISSING: quota-axi (install: npm install -g quota-axi)

WAKE QUEUE
--------------------------------------------------------------------------------
(no queued wakes)
================================================================================
SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude
================================================================================
Current state:
- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.
- Away mode: inactive.
- X mode: inactive; use the default watcher cadence.
- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.

Mode: Claude Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   Handle every item required by the harness-neutral drain contract in [`AGENTS.md`](../../AGENTS.md#8-supervision-protocol), then run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Routine watcher arm and re-arm are owned by the Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`), never by you.
   Every turn end while supervision is needed launches or attaches one home-scoped watcher cycle with no model command and no model tokens.
   An actionable close wakes you through the hook's exit-2 rewake, delivered as a `Stop hook feedback` message.
3. On a `Stop hook feedback` wake (`signal:`, `stale:`, `check:`, or `heartbeat`), run `bin/fm-wake-drain.sh` first and handle the wake.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; act only on items allowed by the harness-neutral drain contract or a real watcher reason line.
4. On the one `Stop hook feedback` automatic-mechanism failure notice (`firstmate watcher auto-arm FAILED ...`), drain, inspect the automatic mechanism failure, and do not turn the notice into a repeating manual-arm loop.
5. If the Stop hook does not claim the home or reports an exhausted failure, inspect its registration and watcher startup path before ending blind.
   Keep the Stop-owned automatic mechanism as the only Claude arm owner.
6. Treat `watcher: started ...` and `watcher: attached ...` inside automatic arm output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a rewake and the next Stop-launched arm, while the bounded turn-end guard prevents a blind Stop when recovery did not start.
   No PreToolUse hook denies fleet commands based on watcher status.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. The turn-end guard (`bin/fm-turnend-guard.sh --claude`) remains the final backstop.
   It requires the PID-strict live-watcher and fresh-beacon predicate at the Stop boundary, while the mid-turn pull guard accepts a fresh beacon without a live process under Claude's between-turns auto-arm model.
   It allows the stop when a watcher is healthy or an open auto-arm generation claim owns recovery, while fresh failure epochs advance the bounded one-time attended fail-open progression described in [`turnend-guard.md`](../turnend-guard.md).
9. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the Stop hook foregrounds.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract and the Claude ownership model.


================================================================================
READ-ONCE CONTRACT
================================================================================
Everything below provides a required PRIOR SESSION retrieve, every state/*.meta, a
compact data/backlog.md listing, a bounded tail of every state/*.status,
data/projects.md, data/secondmates.md, data/captain.md, data/captain-shared.md,
and data/learnings.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (each task's full log path is
    printed with its tail),
  - a full task body is needed (tasks-axi show <id> --full, or data/backlog.md),
  - the backlog listing disclosed omitted queued items and this turn needs them,
  - the PRIOR SESSION fold reported missing, unreadable, parse-failed, or
    truncated input and this turn needs one of its three targeted categories,
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled.

================================================================================
PRIOR SESSION
================================================================================
scope: targeted prior-talk fold only; not 100% of chat; no GBrain, Graphify, or Obsidian ingestion.
INCOMPLETE: prior session parser produced no result.

================================================================================
FLEET STATE
================================================================================

data/backlog.md
--------------------------------------------------------------------------------
ABSENT

Work under way (state/*.meta)
--------------------------------------------------------------------------------
(none)

Orphan status logs (state/*.status without matching .meta)
--------------------------------------------------------------------------------
(none)

AFK
--------------------------------------------------------------------------------
absent

================================================================================
NETWORK CHECKS
================================================================================
not started - no deferred network checks have run for this home yet.

================================================================================
CONTEXT
================================================================================

data/projects.md
--------------------------------------------------------------------------------
ABSENT

data/secondmates.md
--------------------------------------------------------------------------------
ABSENT

data/captain.md
--------------------------------------------------------------------------------
session note

data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)
--------------------------------------------------------------------------------
ABSENT

data/learnings.md
--------------------------------------------------------------------------------
ABSENT

================================================================================
NEXT STEP
================================================================================
Follow the supervision operating instructions block above for harness 'claude'.
This script never starts supervision itself.

The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.

RECORD
fm-record: state=unchanged
state=unchanged
pending=0
pending_since=0
pending_age_seconds=0

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-stow-cascade.test.sh

Subject: `bin/fm-record.sh:1278`.
Selector: `test_cascade_does_not_checkpoint_a_configured_record`.

[Failure log](breakage-fm-stow-cascade-red.log) and [restored test log](breakage-fm-stow-cascade-green.log).

```text
Test: tests/fm-stow-cascade.test.sh
Selector: test_cascade_does_not_checkpoint_a_configured_record
Subject: bin/fm-record.sh:1278
-   run_transaction checkpoint "$reason" "$lock_mode"
+   return 0

warning: templates not found in /opt/homebrew/opt/git/share/git-core/templates
fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree.
Use '--' to separate paths from revisions, like this:
'git <command> [<revision>...] -- [<file>...]'
fatal: invalid object name 'HEAD'.
not ok - cascade enumeration replaced the completed-home snapshot

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-teardown.test.sh

Subject: `bin/fm-teardown.sh:2924`.
Selector: `test_force_preserves_record_checkpoint_when_scan_blocks`.

[Failure log](breakage-fm-teardown-red.log) and [restored test log](breakage-fm-teardown-green.log).

```text
Test: tests/fm-teardown.test.sh
Selector: test_force_preserves_record_checkpoint_when_scan_blocks
Subject: bin/fm-teardown.sh:2924
-   if ! "$SCRIPT_DIR/fm-record.sh" checkpoint --reason teardown --required >&2; then
+   if ! true; then

warning: templates not found in /opt/homebrew/opt/git/share/git-core/templates
not ok - forced teardown must refuse a blocked Record checkpoint: expected exit 1, got 0

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.

## tests/fm-test-run.test.sh

Subject: `bin/fm-test-run.sh:1028`.
Selector: `test_list_all_exact_suite_coverage`.

[Failure log](breakage-fm-test-run-red.log) and [restored test log](breakage-fm-test-run-green.log).

```text
Test: tests/fm-test-run.test.sh
Selector: test_list_all_exact_suite_coverage
Subject: bin/fm-test-run.sh:1028
-   for f in tests/*.test.sh; do
+   for f in tests/*.test.sh data/.git/tests/*.test.sh; do

not ok - --list --all discovered a nested Git test file

exit=1

After source restoration: git status --porcelain is empty.
```

The restored test passed with exit zero, and Git porcelain remained empty.
