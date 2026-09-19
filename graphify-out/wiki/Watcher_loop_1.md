# Watcher loop 1

> 92 nodes · cohesion 0.05

## Key Concepts

- **fm-watch.sh** (57 connections) — `bin/fm-watch.sh`
- **fm-watch.sh script** (45 connections) — `bin/fm-watch.sh`
- **fm-task-inbox-lib.sh** (25 connections) — `bin/fm-task-inbox-lib.sh`
- **fm-push-transition-lib.sh** (17 connections) — `bin/fm-push-transition-lib.sh`
- **handle_push_transition()** (14 connections) — `bin/fm-push-transition-lib.sh`
- **wake()** (12 connections) — `bin/fm-push-transition-lib.sh`
- **fm-transition-lib.sh** (12 connections) — `bin/fm-transition-lib.sh`
- **inbox_steer_check()** (11 connections) — `bin/fm-watch.sh`
- **triage_log()** (10 connections) — `bin/fm-push-transition-lib.sh`
- **window_key()** (9 connections) — `bin/fm-watch.sh`
- **fm_task_inbox_write_idempotent()** (8 connections) — `bin/fm-task-inbox-lib.sh`
- **busy_turn_bound_check()** (8 connections) — `bin/fm-watch.sh`
- **handle_paused_stale()** (8 connections) — `bin/fm-watch.sh`
- **fm_task_inbox_dir()** (7 connections) — `bin/fm-task-inbox-lib.sh`
- **fm_task_inbox_ring()** (7 connections) — `bin/fm-task-inbox-lib.sh`
- **clear_write_tracking()** (7 connections) — `bin/fm-watch.sh`
- **wedge_timer_check()** (7 connections) — `bin/fm-watch.sh`
- **window_is_busy()** (7 connections) — `bin/fm-watch.sh`
- **fm_backend_herdr_apply_transition()** (6 connections) — `bin/backends/herdr.sh`
- **fm_task_inbox_due_action()** (6 connections) — `bin/fm-task-inbox-lib.sh`
- **fm_task_inbox_lock_acquire()** (6 connections) — `bin/fm-task-inbox-lib.sh`
- **fm_task_inbox_write()** (6 connections) — `bin/fm-task-inbox-lib.sh`
- **fm_transition_field()** (6 connections) — `bin/fm-transition-lib.sh`
- **wedge_defer_writing()** (6 connections) — `bin/fm-watch.sh`
- **window_backend()** (6 connections) — `bin/fm-watch.sh`
- *... and 67 more nodes in this community*

## Relationships

- [Crewmate spawn 1](Crewmate_spawn_1.md) (9 shared connections)
- [Pull request landing 1](Pull_request_landing_1.md) (7 shared connections)
- [Herdr 1](Herdr_1.md) (6 shared connections)
- [Runtime backends 2](Runtime_backends_2.md) (5 shared connections)
- [Fm Send](Fm_Send.md) (5 shared connections)
- [Fm Check Lib](Fm_Check_Lib.md) (4 shared connections)
- [Fm Classify Lib](Fm_Classify_Lib.md) (3 shared connections)
- [Wake queue 3](Wake_queue_3.md) (3 shared connections)
- [Agent control 2](Agent_control_2.md) (3 shared connections)
- [Fm Backend Autodetect Sm](Fm_Backend_Autodetect_Sm.md) (2 shared connections)
- [Runtime backends 3](Runtime_backends_3.md) (2 shared connections)
- [Fm Send Inbox Doorbell L](Fm_Send_Inbox_Doorbell_L.md) (2 shared connections)

## Source Files

- `bin/backends/herdr.sh`
- `bin/fm-push-transition-lib.sh`
- `bin/fm-task-inbox-lib.sh`
- `bin/fm-transition-lib.sh`
- `bin/fm-watch.sh`

## Audit Trail

- EXTRACTED: 263 (93%)
- INFERRED: 21 (7%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*