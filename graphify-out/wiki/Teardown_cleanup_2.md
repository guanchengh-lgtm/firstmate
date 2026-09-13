# Teardown cleanup 2

> 59 nodes · cohesion 0.12

## Key Concepts

- **fm-pending-reply-lib.sh** (74 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_get()** (26 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_path()** (26 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_now()** (16 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_tick()** (15 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_set()** (14 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_delivery_confirmation_path()** (13 connections) — `bin/fm-pending-reply-lib.sh`
- **_fm_pending_reply_try_resolve_locked()** (13 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_send_recovery()** (12 connections) — `bin/fm-pending-reply-lib.sh`
- **_fm_pending_reply_maybe_escalate_locked()** (11 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_tick_one()** (11 connections) — `bin/fm-pending-reply-lib.sh`
- **_fm_pending_reply_reconcile_delivery_locked()** (10 connections) — `bin/fm-pending-reply-lib.sh`
- **_fm_pending_reply_close_escalation_locked()** (9 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_reconcile_recovery()** (9 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_create()** (8 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_detect_wrong_home()** (8 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_mark_delivered()** (8 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_prepare_delivery()** (8 connections) — `bin/fm-pending-reply-lib.sh`
- **_fm_pending_reply_confirm_delivery_locked()** (7 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_finish_recovery()** (7 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_reconcile_delivery()** (7 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_try_resolve()** (7 connections) — `bin/fm-pending-reply-lib.sh`
- **fm_pending_reply_observe_busy()** (6 connections) — `bin/fm-pending-reply-lib.sh`
- **_fm_pending_reply_reset_known_undelivered_locked()** (6 connections) — `bin/fm-pending-reply-lib.sh`
- **handoff_wake_retire()** (6 connections) — `bin/fm-teardown.sh`
- *... and 34 more nodes in this community*

## Relationships

- [Crewmate spawn 1](Crewmate_spawn_1.md) (13 shared connections)
- [Fm Send](Fm_Send.md) (11 shared connections)
- [Public follow-up 1](Public_follow-up_1.md) (11 shared connections)
- [Fm Pending Reply Lib](Fm_Pending_Reply_Lib.md) (7 shared connections)
- [Runtime backends 2](Runtime_backends_2.md) (6 shared connections)
- [Teardown cleanup 1](Teardown_cleanup_1.md) (5 shared connections)
- [Teardown cleanup 3](Teardown_cleanup_3.md) (5 shared connections)
- [Fm Procevent Remote Repl](Fm_Procevent_Remote_Repl.md) (4 shared connections)
- [Remote secondmates 7](Remote_secondmates_7.md) (2 shared connections)
- [Watcher loop 1](Watcher_loop_1.md) (2 shared connections)
- [Fm Tmux Lib](Fm_Tmux_Lib.md) (1 shared connections)
- [Fm Classify Lib](Fm_Classify_Lib.md) (1 shared connections)

## Source Files

- `bin/fm-pending-reply-lib.sh`
- `bin/fm-teardown.sh`

## Audit Trail

- EXTRACTED: 254 (95%)
- INFERRED: 12 (5%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*