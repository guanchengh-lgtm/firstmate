# Agent control 1

> 47 nodes · cohesion 0.10

## Key Concepts

- **fm-control.sh** (30 connections) — `bin/fm-control.sh`
- **fm-control-lib.sh** (25 connections) — `bin/fm-control-lib.sh`
- **fm-control.sh script** (18 connections) — `bin/fm-control.sh`
- **do_relaunch()** (13 connections) — `bin/fm-control.sh`
- **do_exit()** (11 connections) — `bin/fm-control.sh`
- **die()** (10 connections) — `bin/fm-control.sh`
- **fm-gate-refuse-lib.sh** (9 connections) — `bin/fm-gate-refuse-lib.sh`
- **agent_state()** (8 connections) — `bin/fm-control.sh`
- **send_interrupt_keys()** (8 connections) — `bin/fm-control.sh`
- **deliver_interrupt()** (6 connections) — `bin/fm-control.sh`
- **resolve_relaunch_profile()** (6 connections) — `bin/fm-control.sh`
- **verify_interrupt_running()** (6 connections) — `bin/fm-control.sh`
- **fm_refuse_if_gate_agent()** (6 connections) — `bin/fm-gate-refuse-lib.sh`
- **fm_control_backend_state_verified()** (5 connections) — `bin/fm-control-lib.sh`
- **fm_control_harness_supported()** (5 connections) — `bin/fm-control-lib.sh`
- **fm_control_key_verb()** (5 connections) — `bin/fm-control-lib.sh`
- **prepare_interrupt_ack()** (5 connections) — `bin/fm-control.sh`
- **require_state_verified_backend()** (5 connections) — `bin/fm-control.sh`
- **control_cleanup()** (4 connections) — `bin/fm-control.sh`
- **do_interrupt()** (4 connections) — `bin/fm-control.sh`
- **fm_control_harness_family()** (4 connections) — `bin/fm-control-lib.sh`
- **fm_control_interrupt_clear_key()** (4 connections) — `bin/fm-control-lib.sh`
- **record_note()** (4 connections) — `bin/fm-control.sh`
- **relaunch_rollback()** (4 connections) — `bin/fm-control.sh`
- **wait_agent_state()** (4 connections) — `bin/fm-control.sh`
- *... and 22 more nodes in this community*

## Relationships

- [Crewmate spawn 2](Crewmate_spawn_2.md) (9 shared connections)
- [Runtime backends 2](Runtime_backends_2.md) (7 shared connections)
- [Fm Send](Fm_Send.md) (6 shared connections)
- [Agent control 2](Agent_control_2.md) (5 shared connections)
- [Teardown cleanup 1](Teardown_cleanup_1.md) (4 shared connections)
- [Crewmate spawn 1](Crewmate_spawn_1.md) (3 shared connections)
- [Teardown cleanup 5](Teardown_cleanup_5.md) (3 shared connections)
- [Pull request landing 1](Pull_request_landing_1.md) (2 shared connections)
- [Fm Quota Choose](Fm_Quota_Choose.md) (2 shared connections)
- [Fm Operational Input](Fm_Operational_Input.md) (2 shared connections)
- [Turn-end guard 1](Turn-end_guard_1.md) (2 shared connections)
- [Runtime backends 3](Runtime_backends_3.md) (1 shared connections)

## Source Files

- `bin/fm-control-lib.sh`
- `bin/fm-control.sh`
- `bin/fm-gate-refuse-lib.sh`
- `bin/fm-send.sh`

## Audit Trail

- EXTRACTED: 138 (90%)
- INFERRED: 16 (10%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*