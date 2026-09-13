# Runtime backends 1

> 105 nodes · cohesion 0.05

## Key Concepts

- **cmux.sh** (37 connections) — `bin/backends/cmux.sh`
- **fm-composer-lib.sh** (36 connections) — `bin/fm-composer-lib.sh`
- **zellij.sh** (35 connections) — `bin/backends/zellij.sh`
- **fm_backend_cmux_cli()** (17 connections) — `bin/backends/cmux.sh`
- **fm_backend_zellij_cli()** (14 connections) — `bin/backends/zellij.sh`
- **fm_composer_classify_screen()** (14 connections) — `bin/fm-composer-lib.sh`
- **fm_composer_extract_selected_content()** (14 connections) — `bin/fm-composer-lib.sh`
- **fm_backend_cmux_target_ready()** (13 connections) — `bin/backends/cmux.sh`
- **fm_composer_normalize_trim_var()** (13 connections) — `bin/fm-composer-lib.sh`
- **fm_backend_zellij_target_ready()** (12 connections) — `bin/backends/zellij.sh`
- **_fm_composer_row_content()** (10 connections) — `bin/fm-composer-lib.sh`
- **_fm_composer_scan_screen()** (10 connections) — `bin/fm-composer-lib.sh`
- **_fm_composer_screen_row()** (9 connections) — `bin/fm-composer-lib.sh`
- **fm_backend_cmux_kill()** (7 connections) — `bin/backends/cmux.sh`
- **fm_backend_zellij_kill()** (7 connections) — `bin/backends/zellij.sh`
- **fm_composer_classify_content()** (7 connections) — `bin/fm-composer-lib.sh`
- **_fm_composer_select_cursorless()** (7 connections) — `bin/fm-composer-lib.sh`
- **fm_backend_cmux_capture()** (6 connections) — `bin/backends/cmux.sh`
- **fm_backend_cmux_create_task()** (6 connections) — `bin/backends/cmux.sh`
- **fm_backend_cmux_send_key()** (6 connections) — `bin/backends/cmux.sh`
- **fm_backend_zellij_capture()** (6 connections) — `bin/backends/zellij.sh`
- **fm_backend_zellij_composer_capture()** (6 connections) — `bin/backends/zellij.sh`
- **fm_backend_zellij_create_task()** (6 connections) — `bin/backends/zellij.sh`
- **fm_backend_zellij_send_key()** (6 connections) — `bin/backends/zellij.sh`
- **fm_backend_zellij_send_text_submit()** (6 connections) — `bin/backends/zellij.sh`
- *... and 80 more nodes in this community*

## Relationships

- [Runtime backends 2](Runtime_backends_2.md) (11 shared connections)
- [Herdr 3](Herdr_3.md) (3 shared connections)
- [Crewmate spawn 2](Crewmate_spawn_2.md) (2 shared connections)
- [Runtime backends 3](Runtime_backends_3.md) (2 shared connections)
- [Herdr 1](Herdr_1.md) (1 shared connections)

## Source Files

- `bin/backends/cmux.sh`
- `bin/backends/zellij.sh`
- `bin/fm-backend-hometag-lib.sh`
- `bin/fm-composer-lib.sh`

## Audit Trail

- EXTRACTED: 303 (98%)
- INFERRED: 7 (2%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*