# Fm Daemon.Test 3

> 18 nodes · cohesion 0.11

## Key Concepts

- **make_wedge_case()** (20 connections) — `tests/fm-daemon.test.sh`
- **test_inject_wedge_alarm_fires_active_alert_on_non_tmux_backend()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_inject_wedge_alarm_throttles_when_marker_cannot_be_written()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wake_helpers_replace_inherited_notifier_override()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_auto_darwin_selects_osascript()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_auto_non_darwin_has_no_os_channel()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_command_channel_receives_summary()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_command_failure_hides_configured_command()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_config_file_multi_channel()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_direct_notifiers_honor_discard_seam()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_discard_seam_fires_nothing()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_failing_channel_degrades_gracefully()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_herdr_channel_selected()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_hung_channel_times_out_and_falls_through()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_hung_override_times_out_and_falls_through()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_off_disables_active_alert_regardless_of_position()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_osascript_channel_selected()** (3 connections) — `tests/fm-daemon.test.sh`
- **test_wedge_alarm_unknown_channel_hides_configured_directive()** (3 connections) — `tests/fm-daemon.test.sh`

## Relationships

- [Fm Daemon.Test 1](Fm_Daemon.Test_1.md) (35 shared connections)
- [Fm Daemon.Test 5](Fm_Daemon.Test_5.md) (2 shared connections)

## Source Files

- `tests/fm-daemon.test.sh`

## Audit Trail

- EXTRACTED: 54 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*