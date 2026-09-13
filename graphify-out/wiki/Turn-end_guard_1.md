# Turn-end guard 1

> 36 nodes · cohesion 0.14

## Key Concepts

- **fm-session-lock-lib.sh** (18 connections) — `bin/fm-session-lock-lib.sh`
- **fm-turnend-guard-cursor.sh** (16 connections) — `bin/fm-turnend-guard-cursor.sh`
- **fm_session_lock_owned_by_self()** (12 connections) — `bin/fm-session-lock-lib.sh`
- **fm-turnend-guard-cursor.sh script** (12 connections) — `bin/fm-turnend-guard-cursor.sh`
- **fm-lock.sh script** (10 connections) — `bin/fm-lock.sh`
- **fm-sessionstart-run.sh script** (10 connections) — `bin/fm-sessionstart-run.sh`
- **fm-sessionstart-run.sh** (9 connections) — `bin/fm-sessionstart-run.sh`
- **emit_repair_followup()** (9 connections) — `bin/fm-turnend-guard-cursor.sh`
- **fm-lock.sh** (8 connections) — `bin/fm-lock.sh`
- **emit_followup()** (8 connections) — `bin/fm-turnend-guard-cursor.sh`
- **fm_harness_pid_alive()** (7 connections) — `bin/fm-session-lock-lib.sh`
- **fm_session_lock_identity()** (7 connections) — `bin/fm-session-lock-lib.sh`
- **budget_reset_if_ours()** (7 connections) — `bin/fm-turnend-guard-cursor.sh`
- **current_session_still_ours()** (6 connections) — `bin/fm-turnend-guard-cursor.sh`
- **lock_acquire_bounded()** (6 connections) — `bin/fm-turnend-guard-cursor.sh`
- **lock_refuses_current_session()** (5 connections) — `bin/fm-lock.sh`
- **fm_harness_process_matches()** (5 connections) — `bin/fm-session-lock-lib.sh`
- **fm_session_lock_read_session_id()** (5 connections) — `bin/fm-session-lock-lib.sh`
- **park_still_ours()** (5 connections) — `bin/fm-turnend-guard-cursor.sh`
- **fm_harness_ancestry_pid()** (4 connections) — `bin/fm-session-lock-lib.sh`
- **fm_harness_ancestry_pids()** (4 connections) — `bin/fm-session-lock-lib.sh`
- **fm_session_id_valid()** (4 connections) — `bin/fm-session-lock-lib.sh`
- **claim_park()** (4 connections) — `bin/fm-turnend-guard-cursor.sh`
- **release_claim_lock()** (3 connections) — `bin/fm-lock.sh`
- **session_start_completed()** (3 connections) — `bin/fm-sessionstart-run.sh`
- *... and 11 more nodes in this community*

## Relationships

- [Crewmate spawn 1](Crewmate_spawn_1.md) (10 shared connections)
- [Turn-end guard 2](Turn-end_guard_2.md) (8 shared connections)
- [Fm Project Write Lib](Fm_Project_Write_Lib.md) (6 shared connections)
- [Session start 1](Session_start_1.md) (3 shared connections)
- [Fm Startup Network](Fm_Startup_Network.md) (3 shared connections)
- [Fm Operational Input](Fm_Operational_Input.md) (3 shared connections)
- [Fm Bootstrap](Fm_Bootstrap.md) (2 shared connections)
- [Agent control 1](Agent_control_1.md) (2 shared connections)

## Source Files

- `bin/fm-lock.sh`
- `bin/fm-session-lock-lib.sh`
- `bin/fm-sessionstart-run.sh`
- `bin/fm-turnend-guard-cursor.sh`

## Audit Trail

- EXTRACTED: 107 (87%)
- INFERRED: 16 (13%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*