# Fm Daemon.Test 2

> 18 nodes · cohesion 0.12

## Key Concepts

- **handle_wake()** (16 connections) — `tests/fm-daemon.test.sh`
- **test_status_read_failure_surfaces_without_advancing_seen()** (5 connections) — `tests/fm-daemon.test.sh`
- **test_stale_read_failure_surfaces_without_advancing_seen()** (4 connections) — `tests/fm-daemon.test.sh`
- **_fm_status_read_span()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_durable_wake_failure_retains_entire_batch()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_enriched_wedge_under_declared_wait_uses_pause_cadence()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_handle_wake_paused_records_pause_marker()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_handle_wake_paused_signal_records_pause_marker()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_handle_wake_routes_self_and_escalate()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_handle_wake_terminal_signal_clears_pause_tracking()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_inject_skip_forces_self()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_signal_escalate_marks_seen_no_catchall_refire()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_stale_actionable_wait_escalates_and_keeps_pause_cadence()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_stale_masked_event_escalates_at_captured_endpoint()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_terminal_stale_escalate_leaves_no_marker()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_transient_unreadable_signal_recovers_without_advancing()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_unverifiable_identity_surfaces_without_marker()** (3 connections) — `tests/fm-daemon.test.sh`
- **last_status_line()** (1 connections) — `tests/fm-daemon.test.sh`

## Relationships

- [Fm Daemon.Test 1](Fm_Daemon.Test_1.md) (30 shared connections)
- [Fm Daemon.Test 5](Fm_Daemon.Test_5.md) (2 shared connections)

## Source Files

- `tests/fm-daemon.test.sh`

## Audit Trail

- EXTRACTED: 50 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*