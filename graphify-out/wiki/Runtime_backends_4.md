# Runtime backends 4

> 15 nodes · cohesion 0.24

## Key Concepts

- **fm-owner-invoke-wait-check.sh** (15 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **fm-owner-invoke-wait-check.sh script** (12 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **ov_endpoint_alive()** (6 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **fm_backend_agent_alive()** (4 connections) — `bin/fm-backend.sh`
- **hook_refuse()** (3 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **evaluate_turn()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **gather_held()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **gather_meta()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **is_known_rule()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **json_escape()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **read_skill_lines()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **report_findings()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **structural()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **usage()** (2 connections) — `bin/fm-owner-invoke-wait-check.sh`
- **cleanup()** (1 connections) — `bin/fm-owner-invoke-wait-check.sh`

## Relationships

- [Runtime backends 2](Runtime_backends_2.md) (4 shared connections)
- [Fm Project Write Lib](Fm_Project_Write_Lib.md) (2 shared connections)
- [Fm Fleet Snapshot](Fm_Fleet_Snapshot.md) (1 shared connections)
- [Crewmate spawn 2](Crewmate_spawn_2.md) (1 shared connections)
- [Runtime backends 3](Runtime_backends_3.md) (1 shared connections)

## Source Files

- `bin/fm-backend.sh`
- `bin/fm-owner-invoke-wait-check.sh`

## Audit Trail

- EXTRACTED: 32 (94%)
- INFERRED: 2 (6%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*