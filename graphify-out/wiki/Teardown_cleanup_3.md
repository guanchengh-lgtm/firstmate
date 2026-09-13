# Teardown cleanup 3

> 53 nodes · cohesion 0.10

## Key Concepts

- **fm-teardown.sh script** (71 connections) — `bin/fm-teardown.sh`
- **fm-backlog-transition-lib.sh** (38 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_atomic_transition()** (23 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_record_present()** (17 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm-promote.sh script** (17 connections) — `bin/fm-promote.sh`
- **fm-promote.sh** (15 connections) — `bin/fm-promote.sh`
- **fm_meta_lock_path()** (12 connections) — `bin/fm-wake-lib.sh`
- **fm_backlog_data_absolute()** (11 connections) — `bin/fm-backlog-transition-lib.sh`
- **backlog_record_reconcile()** (11 connections) — `bin/fm-bootstrap.sh`
- **fm_backlog_close_marker_replay()** (10 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_row_probe()** (9 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_transition_applies()** (8 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_close_marker_validate()** (7 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_directory_present()** (7 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_mutate()** (7 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_record_parent_authorized()** (7 connections) — `bin/fm-backlog-transition-lib.sh`
- **handoff_wake_retire_stage_restore()** (7 connections) — `bin/fm-teardown.sh`
- **fm_backlog_close_marker_stage()** (6 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_close_marker_write()** (6 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_dispatch_transition()** (6 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_file()** (6 connections) — `bin/fm-backlog-transition-lib.sh`
- **fm_backlog_record_remove()** (6 connections) — `bin/fm-backlog-transition-lib.sh`
- **spawn_record_traceparent()** (6 connections) — `bin/fm-spawn.sh`
- **handoff_wake_retire_stage()** (6 connections) — `bin/fm-teardown.sh`
- **fm_backlog_root()** (5 connections) — `bin/fm-backlog-transition-lib.sh`
- *... and 28 more nodes in this community*

## Relationships

- [Teardown cleanup 1](Teardown_cleanup_1.md) (46 shared connections)
- [Crewmate spawn 2](Crewmate_spawn_2.md) (20 shared connections)
- [Crewmate spawn 1](Crewmate_spawn_1.md) (19 shared connections)
- [Fm Bootstrap](Fm_Bootstrap.md) (6 shared connections)
- [Fm X Lib](Fm_X_Lib.md) (5 shared connections)
- [Teardown cleanup 2](Teardown_cleanup_2.md) (5 shared connections)
- [Pull request landing 1](Pull_request_landing_1.md) (4 shared connections)
- [Secondmate seed](Secondmate_seed.md) (4 shared connections)
- [Runtime backends 2](Runtime_backends_2.md) (4 shared connections)
- [Worker briefs](Worker_briefs.md) (2 shared connections)
- [Public follow-up 1](Public_follow-up_1.md) (2 shared connections)
- [Public follow-up 2](Public_follow-up_2.md) (2 shared connections)

## Source Files

- `bin/fm-backlog-transition-lib.sh`
- `bin/fm-bootstrap.sh`
- `bin/fm-promote.sh`
- `bin/fm-spawn.sh`
- `bin/fm-teardown.sh`
- `bin/fm-wake-lib.sh`
- `bin/fm-x-lib.sh`

## Audit Trail

- EXTRACTED: 263 (95%)
- INFERRED: 13 (5%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*