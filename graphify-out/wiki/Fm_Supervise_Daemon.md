# Fm Supervise Daemon

> 19 nodes · cohesion 0.20

## Key Concepts

- **fm_super_main()** (21 connections) — `bin/fm-supervise-daemon.sh`
- **log()** (17 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_run_bounded()** (8 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_emit()** (7 connections) — `bin/fm-supervise-daemon.sh`
- **cleanup()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **inject_wedge_alarm()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_notify()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_os_notifier_override()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_via_herdr()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_via_osascript()** (5 connections) — `bin/fm-supervise-daemon.sh`
- **handle_durable_wakes()** (4 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_via_command()** (4 connections) — `bin/fm-supervise-daemon.sh`
- **record_crash()** (3 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_stop_active_notifier()** (3 connections) — `bin/fm-supervise-daemon.sh`
- **is_wake_reason()** (2 connections) — `bin/fm-supervise-daemon.sh`
- **fm-supervise-daemon.sh script** (2 connections) — `bin/fm-supervise-daemon.sh`
- **start_watcher()** (2 connections) — `bin/fm-supervise-daemon.sh`
- **trim_log()** (2 connections) — `bin/fm-supervise-daemon.sh`
- **wedge_alarm_platform_default()** (2 connections) — `bin/fm-supervise-daemon.sh`

## Relationships

- [Runtime backends 3](Runtime_backends_3.md) (30 shared connections)
- [Crewmate spawn 1](Crewmate_spawn_1.md) (3 shared connections)
- [Away mode 1](Away_mode_1.md) (2 shared connections)
- [Wake queue 1](Wake_queue_1.md) (1 shared connections)
- [Runtime backends 2](Runtime_backends_2.md) (1 shared connections)

## Source Files

- `bin/fm-supervise-daemon.sh`

## Audit Trail

- EXTRACTED: 72 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*