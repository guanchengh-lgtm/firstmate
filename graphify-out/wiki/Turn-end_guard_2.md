# Turn-end guard 2

> 35 nodes · cohesion 0.12

## Key Concepts

- **fm_pid_alive()** (19 connections) — `bin/fm-wake-lib.sh`
- **fm-claude-stop-autoarm.sh script** (15 connections) — `bin/fm-claude-stop-autoarm.sh`
- **fm-turnend-guard.sh** (13 connections) — `bin/fm-turnend-guard.sh`
- **fm-turnend-guard.sh script** (13 connections) — `bin/fm-turnend-guard.sh`
- **terminal_fail_open()** (13 connections) — `bin/fm-turnend-guard.sh`
- **fm_watcher_healthy()** (11 connections) — `bin/fm-wake-lib.sh`
- **fm_autoarm_release_abandoned()** (10 connections) — `bin/fm-wake-lib.sh`
- **fm-claude-stop-autoarm.sh** (9 connections) — `bin/fm-claude-stop-autoarm.sh`
- **fm-supervision-lib.sh** (9 connections) — `bin/fm-supervision-lib.sh`
- **autoarm_owns_recovery()** (9 connections) — `bin/fm-turnend-guard.sh`
- **fm_autoarm_claim_open()** (8 connections) — `bin/fm-wake-lib.sh`
- **fm_autoarm_claim_abandoned()** (7 connections) — `bin/fm-wake-lib.sh`
- **fm_autoarm_write_owned()** (7 connections) — `bin/fm-wake-lib.sh`
- **fm_supervision_status()** (6 connections) — `bin/fm-supervision-lib.sh`
- **fm_autoarm_ledger_read()** (6 connections) — `bin/fm-wake-lib.sh`
- **fm-hook-host-lib.sh** (5 connections) — `bin/fm-hook-host-lib.sh`
- **budget_account_current_epoch()** (5 connections) — `bin/fm-turnend-guard.sh`
- **_fm_autoarm_epoch_field()** (5 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_role()** (5 connections) — `bin/fm-wake-lib.sh`
- **fm_watcher_lock_matches_pid()** (5 connections) — `bin/fm-wake-lib.sh`
- **fm_hook_payload_is_foreign_host()** (4 connections) — `bin/fm-hook-host-lib.sh`
- **fm_supervision_needed()** (4 connections) — `bin/fm-supervision-lib.sh`
- **budget_reset()** (4 connections) — `bin/fm-turnend-guard.sh`
- **fm_autoarm_still_owner()** (4 connections) — `bin/fm-wake-lib.sh`
- **autoarm_commit()** (3 connections) — `bin/fm-claude-stop-autoarm.sh`
- *... and 10 more nodes in this community*

## Relationships

- [Crewmate spawn 1](Crewmate_spawn_1.md) (44 shared connections)
- [Turn-end guard 1](Turn-end_guard_1.md) (8 shared connections)
- [Fm Project Write Lib](Fm_Project_Write_Lib.md) (6 shared connections)
- [Watcher loop 2](Watcher_loop_2.md) (5 shared connections)
- [Wake queue 1](Wake_queue_1.md) (4 shared connections)
- [Away mode 1](Away_mode_1.md) (2 shared connections)
- [Fm Branch Outcome](Fm_Branch_Outcome.md) (1 shared connections)
- [Crewmate spawn 2](Crewmate_spawn_2.md) (1 shared connections)

## Source Files

- `bin/fm-claude-stop-autoarm.sh`
- `bin/fm-hook-host-lib.sh`
- `bin/fm-supervision-lib.sh`
- `bin/fm-turnend-guard.sh`
- `bin/fm-wake-lib.sh`

## Audit Trail

- EXTRACTED: 133 (92%)
- INFERRED: 12 (8%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*