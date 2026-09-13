# Fm Send

> 15 nodes · cohesion 0.23

## Key Concepts

- **fm-send.sh script** (35 connections) — `bin/fm-send.sh`
- **fm-send.sh** (25 connections) — `bin/fm-send.sh`
- **fm_pending_reply_reset_known_undelivered()** (6 connections) — `bin/fm-pending-reply-lib.sh`
- **fm-marker-lib.sh** (5 connections) — `bin/fm-marker-lib.sh`
- **fm_send_id_from_meta()** (5 connections) — `bin/fm-send.sh`
- **fm_send_refuse_recorded_lifecycle()** (5 connections) — `bin/fm-send.sh`
- **fm_send_close_resolved_keys()** (4 connections) — `bin/fm-send.sh`
- **fm_send_known_undelivered_cleanup()** (4 connections) — `bin/fm-send.sh`
- **fm_send_record_interrupt()** (3 connections) — `bin/fm-send.sh`
- **fm_pending_reply_extract_corr()** (2 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_send_add_resolve_key()** (2 connections) — `bin/fm-send.sh`
- **fm_send_feed_resolved_holds()** (2 connections) — `bin/fm-send.sh`
- **fm_send_hold_resolved_id()** (2 connections) — `bin/fm-send.sh`
- **fm-marker-lib.sh script** (1 connections) — `bin/fm-marker-lib.sh`
- **fm_send_normalize_key()** (1 connections) — `bin/fm-send.sh`

## Relationships

- [Runtime backends 2](Runtime_backends_2.md) (13 shared connections)
- [Teardown cleanup 2](Teardown_cleanup_2.md) (11 shared connections)
- [Agent control 1](Agent_control_1.md) (6 shared connections)
- [Watcher loop 1](Watcher_loop_1.md) (5 shared connections)
- [Crewmate spawn 1](Crewmate_spawn_1.md) (4 shared connections)
- [Fm Classify Lib](Fm_Classify_Lib.md) (2 shared connections)
- [Wake queue 2](Wake_queue_2.md) (2 shared connections)
- [Recall ranking 2](Recall_ranking_2.md) (2 shared connections)
- [Teardown cleanup 5](Teardown_cleanup_5.md) (2 shared connections)
- [Public follow-up 1](Public_follow-up_1.md) (2 shared connections)
- [Worker briefs](Worker_briefs.md) (1 shared connections)
- [Fm Operational Input](Fm_Operational_Input.md) (1 shared connections)

## Source Files

- `bin/fm-marker-lib.sh`
- `bin/fm-pending-reply-lib.sh`
- `bin/fm-send.sh`

## Audit Trail

- EXTRACTED: 64 (82%)
- INFERRED: 14 (18%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*