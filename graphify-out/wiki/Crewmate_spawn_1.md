# Crewmate spawn 1

> 69 nodes · cohesion 0.08

## Key Concepts

- **fm-wake-lib.sh** (139 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_release()** (109 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_acquire_wait()** (65 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_try_acquire()** (49 connections) — `bin/fm-wake-lib.sh`
- **fm_current_pid_into()** (14 connections) — `bin/fm-wake-lib.sh`
- **spawn_remote_secondmate()** (13 connections) — `bin/fm-spawn.sh`
- **fm_lock_acquire_wait_bounded()** (10 connections) — `bin/fm-wake-lib.sh`
- **fm_recovery_transition()** (10 connections) — `bin/fm-wake-lib.sh`
- **fm_wake_append()** (10 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_try_create()** (9 connections) — `bin/fm-wake-lib.sh`
- **clear_stale_recorded_watcher_lock()** (9 connections) — `bin/fm-watch-arm.sh`
- **print_status_presentation()** (8 connections) — `bin/fm-wake-drain.sh`
- **fm_autoarm_claim_next()** (8 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_link_owner()** (8 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_points_to_owner()** (8 connections) — `bin/fm-wake-lib.sh`
- **fm_lock_remove_path()** (8 connections) — `bin/fm-wake-lib.sh`
- **_fm_recovery_marker_publish()** (8 connections) — `bin/fm-wake-lib.sh`
- **fm_recovery_marker_read()** (8 connections) — `bin/fm-wake-lib.sh`
- **fm-wake-grant.sh script** (7 connections) — `bin/fm-wake-grant.sh`
- **_fm_atomic_replace()** (7 connections) — `bin/fm-wake-lib.sh`
- **fm_autoarm_reset_owned()** (7 connections) — `bin/fm-wake-lib.sh`
- **fm_failure_episode_reset()** (7 connections) — `bin/fm-wake-lib.sh`
- **fm_path_age()** (7 connections) — `bin/fm-wake-lib.sh`
- **_fm_recovery_marker_write_locked()** (7 connections) — `bin/fm-wake-lib.sh`
- **fm_watcher_supervision_verdict()** (7 connections) — `bin/fm-wake-lib.sh`
- *... and 44 more nodes in this community*

## Relationships

- [Turn-end guard 2](Turn-end_guard_2.md) (44 shared connections)
- [Teardown cleanup 3](Teardown_cleanup_3.md) (19 shared connections)
- [Teardown cleanup 2](Teardown_cleanup_2.md) (13 shared connections)
- [Watcher loop 2](Watcher_loop_2.md) (13 shared connections)
- [Wake queue 4](Wake_queue_4.md) (12 shared connections)
- [Fm Startup Network](Fm_Startup_Network.md) (12 shared connections)
- [Teardown cleanup 1](Teardown_cleanup_1.md) (10 shared connections)
- [Wake queue 3](Wake_queue_3.md) (10 shared connections)
- [Turn-end guard 1](Turn-end_guard_1.md) (10 shared connections)
- [Crewmate spawn 2](Crewmate_spawn_2.md) (9 shared connections)
- [Pull request landing 1](Pull_request_landing_1.md) (9 shared connections)
- [Remote secondmates 1](Remote_secondmates_1.md) (9 shared connections)

## Source Files

- `bin/fm-spawn.sh`
- `bin/fm-wake-drain.sh`
- `bin/fm-wake-grant.sh`
- `bin/fm-wake-lib.sh`
- `bin/fm-watch-arm.sh`

## Audit Trail

- EXTRACTED: 448 (89%)
- INFERRED: 55 (11%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*