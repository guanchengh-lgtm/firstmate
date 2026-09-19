# Runtime backends 2

> 66 nodes · cohesion 0.06

## Key Concepts

- **fm-backend.sh** (80 connections) — `bin/fm-backend.sh`
- **fm_backend_source()** (40 connections) — `bin/fm-backend.sh`
- **fm_meta_get()** (28 connections) — `bin/fm-backend.sh`
- **tmux.sh** (18 connections) — `bin/backends/tmux.sh`
- **fm_backend_of_meta()** (17 connections) — `bin/fm-backend.sh`
- **fm_backend_target_of_meta()** (17 connections) — `bin/fm-backend.sh`
- **fm_backend_capture()** (16 connections) — `bin/fm-backend.sh`
- **fm_backend_send_text_submit()** (12 connections) — `bin/fm-backend.sh`
- **fm_send_resolve_target()** (12 connections) — `bin/fm-send.sh`
- **secondmate_liveness_one()** (11 connections) — `bin/fm-bootstrap.sh`
- **fm_backend_send_key()** (10 connections) — `bin/fm-backend.sh`
- **fm_backend_composer_state()** (8 connections) — `bin/fm-backend.sh`
- **fm_backend_busy_state()** (7 connections) — `bin/fm-backend.sh`
- **fm_backend_resolve_selector()** (7 connections) — `bin/fm-backend.sh`
- **fm-peek.sh script** (7 connections) — `bin/fm-peek.sh`
- **fm_backend_list_contains()** (6 connections) — `bin/fm-backend.sh`
- **fm_backend_meta_for_selector()** (6 connections) — `bin/fm-backend.sh`
- **fm_backend_remove_worktree()** (6 connections) — `bin/fm-backend.sh`
- **fm_backend_required_tool_available()** (6 connections) — `bin/fm-backend.sh`
- **fm_backend_validate()** (6 connections) — `bin/fm-backend.sh`
- **fm_backend_tmux_agent_state()** (5 connections) — `bin/backends/tmux.sh`
- **fm_backend_clear_transition()** (5 connections) — `bin/fm-backend.sh`
- **fm_backend_commit_transition()** (5 connections) — `bin/fm-backend.sh`
- **fm_backend_has_push()** (5 connections) — `bin/fm-backend.sh`
- **fm_backend_meta_for_window()** (5 connections) — `bin/fm-backend.sh`
- *... and 41 more nodes in this community*

## Relationships

- [Crewmate spawn 2](Crewmate_spawn_2.md) (25 shared connections)
- [Fm Send](Fm_Send.md) (13 shared connections)
- [Runtime backends 3](Runtime_backends_3.md) (12 shared connections)
- [Fm Backend Autodetect Sm](Fm_Backend_Autodetect_Sm.md) (12 shared connections)
- [Runtime backends 1](Runtime_backends_1.md) (11 shared connections)
- [Fm Bootstrap](Fm_Bootstrap.md) (10 shared connections)
- [Teardown cleanup 1](Teardown_cleanup_1.md) (10 shared connections)
- [Orca](Orca.md) (7 shared connections)
- [Agent control 1](Agent_control_1.md) (7 shared connections)
- [Herdr 1](Herdr_1.md) (6 shared connections)
- [Teardown cleanup 2](Teardown_cleanup_2.md) (6 shared connections)
- [Fm Crew State](Fm_Crew_State.md) (5 shared connections)

## Source Files

- `bin/backends/tmux.sh`
- `bin/fm-backend.sh`
- `bin/fm-bootstrap.sh`
- `bin/fm-peek.sh`
- `bin/fm-send.sh`
- `tests/fm-cmux-claude-composer-live-e2e.test.sh`

## Audit Trail

- EXTRACTED: 277 (88%)
- INFERRED: 39 (12%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*