# Wake queue 3

> 19 nodes · cohesion 0.18

## Key Concepts

- **fm_wake_status_append_self_announced()** (11 connections) — `bin/fm-wake-lib.sh`
- **status_observed_signature()** (10 connections) — `bin/fm-classify-lib.sh`
- **status_presentation_marker_report()** (7 connections) — `bin/fm-classify-lib.sh`
- **status_presentation_marker_reported_matches()** (7 connections) — `bin/fm-classify-lib.sh`
- **_fm_wake_require_classify()** (7 connections) — `bin/fm-wake-lib.sh`
- **fm_wake_signal_seen_current()** (7 connections) — `bin/fm-wake-lib.sh`
- **status_presentation_marker_commit()** (6 connections) — `bin/fm-classify-lib.sh`
- **status_presentation_marker_offset()** (6 connections) — `bin/fm-classify-lib.sh`
- **status_presentation_marker_parse()** (6 connections) — `bin/fm-classify-lib.sh`
- **fm_wake_signal_seen_size()** (5 connections) — `bin/fm-wake-lib.sh`
- **fm_wake_status_mark_current()** (5 connections) — `bin/fm-wake-lib.sh`
- **mark_escalated_seen()** (4 connections) — `bin/fm-supervise-daemon.sh`
- **mark_status_seen()** (4 connections) — `bin/fm-supervise-daemon.sh`
- **fm_wake_signal_seen_path()** (4 connections) — `bin/fm-wake-lib.sh`
- **fm_wake_status_seen_commit()** (4 connections) — `bin/fm-wake-lib.sh`
- **_status_presentation_signature_valid()** (3 connections) — `bin/fm-classify-lib.sh`
- **fm_wake_signal_sig()** (3 connections) — `bin/fm-wake-lib.sh`
- **fm_wake_status_reported_commit()** (3 connections) — `bin/fm-wake-lib.sh`
- **_status_observed_path_state()** (2 connections) — `bin/fm-classify-lib.sh`

## Relationships

- [Fm Classify Lib](Fm_Classify_Lib.md) (10 shared connections)
- [Runtime backends 3](Runtime_backends_3.md) (10 shared connections)
- [Crewmate spawn 1](Crewmate_spawn_1.md) (10 shared connections)
- [Wake queue 2](Wake_queue_2.md) (8 shared connections)
- [Watcher loop 1](Watcher_loop_1.md) (3 shared connections)
- [Fm Captain Hold](Fm_Captain_Hold.md) (1 shared connections)
- [Teardown cleanup 2](Teardown_cleanup_2.md) (1 shared connections)
- [Fm Send](Fm_Send.md) (1 shared connections)

## Source Files

- `bin/fm-classify-lib.sh`
- `bin/fm-supervise-daemon.sh`
- `bin/fm-wake-lib.sh`

## Audit Trail

- EXTRACTED: 74 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*