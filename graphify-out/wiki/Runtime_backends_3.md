# Runtime backends 3

> 47 nodes · cohesion 0.11

## Key Concepts

- **fm-supervise-daemon.sh** (68 connections) — `bin/fm-supervise-daemon.sh`
- **handle_wake()** (28 connections) — `bin/fm-supervise-daemon.sh`
- **housekeeping()** (25 connections) — `bin/fm-supervise-daemon.sh`
- **window_to_task()** (16 connections) — `bin/fm-classify-lib.sh`
- **fm_backend_target_exists()** (13 connections) — `bin/fm-backend.sh`
- **inject_msg()** (11 connections) — `bin/fm-supervise-daemon.sh`
- **reconcile_pause_tracking()** (11 connections) — `bin/fm-supervise-daemon.sh`
- **status_is_paused_or_captain_held()** (9 connections) — `bin/fm-classify-lib.sh`
- **classify_stale()** (9 connections) — `bin/fm-supervise-daemon.sh`
- **migrate_watcher_pause_markers()** (8 connections) — `bin/fm-supervise-daemon.sh`
- **_now()** (8 connections) — `bin/fm-supervise-daemon.sh`
- **_stale_key()** (8 connections) — `bin/fm-supervise-daemon.sh`
- **stale_window_is_busy()** (7 connections) — `bin/fm-supervise-daemon.sh`
- **status_is_paused()** (6 connections) — `bin/fm-classify-lib.sh`
- **pause_marker_record()** (6 connections) — `bin/fm-supervise-daemon.sh`
- **stale_marker_remove()** (6 connections) — `bin/fm-supervise-daemon.sh`
- **status_seen_offset()** (6 connections) — `bin/fm-supervise-daemon.sh`
- **window_for_task()** (6 connections) — `bin/fm-supervise-daemon.sh`
- **afk_active()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **escalate_flush()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **pane_is_busy()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **stale_marker_record()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **sync_pause_markers_from_signal()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **status_is_captain_held()** (4 connections) — `bin/fm-classify-lib.sh`
- **status_is_terminal_verb()** (4 connections) — `bin/fm-classify-lib.sh`
- *... and 22 more nodes in this community*

## Relationships

- [Fm Supervise Daemon](Fm_Supervise_Daemon.md) (30 shared connections)
- [Fm Classify Lib](Fm_Classify_Lib.md) (26 shared connections)
- [Runtime backends 2](Runtime_backends_2.md) (12 shared connections)
- [Wake queue 3](Wake_queue_3.md) (10 shared connections)
- [Fm Operational Input](Fm_Operational_Input.md) (3 shared connections)
- [Runtime backends 1](Runtime_backends_1.md) (2 shared connections)
- [Watcher loop 1](Watcher_loop_1.md) (2 shared connections)
- [Agent control 2](Agent_control_2.md) (2 shared connections)
- [Herdr 2](Herdr_2.md) (1 shared connections)
- [Orca](Orca.md) (1 shared connections)
- [Agent control 1](Agent_control_1.md) (1 shared connections)
- [Fm Fleet Snapshot](Fm_Fleet_Snapshot.md) (1 shared connections)

## Source Files

- `bin/fm-backend.sh`
- `bin/fm-classify-lib.sh`
- `bin/fm-supervise-daemon.sh`

## Audit Trail

- EXTRACTED: 209 (97%)
- INFERRED: 7 (3%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*