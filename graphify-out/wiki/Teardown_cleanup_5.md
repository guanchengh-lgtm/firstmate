# Teardown cleanup 5

> 17 nodes · cohesion 0.25

## Key Concepts

- **fm-lease-lib.sh** (20 connections) — `bin/fm-lease-lib.sh`
- **fm_lease_guard()** (11 connections) — `bin/fm-lease-lib.sh`
- **fm-lease.sh script** (9 connections) — `bin/fm-lease.sh`
- **fm_lease_actor()** (5 connections) — `bin/fm-lease-lib.sh`
- **fm_lease_clear_stale()** (5 connections) — `bin/fm-lease-lib.sh`
- **fm_lease_forbid_branch()** (5 connections) — `bin/fm-lease-lib.sh`
- **fm_lease_guard_release()** (5 connections) — `bin/fm-lease-lib.sh`
- **fm_lease_live()** (5 connections) — `bin/fm-lease-lib.sh`
- **fm-lease.sh** (4 connections) — `bin/fm-lease.sh`
- **fm_lease_path()** (4 connections) — `bin/fm-lease-lib.sh`
- **fm_lease_read()** (4 connections) — `bin/fm-lease-lib.sh`
- **teardown_release_locks()** (4 connections) — `bin/fm-teardown.sh`
- **fm_lease_valid_id()** (3 connections) — `bin/fm-lease-lib.sh`
- **teardown_release_herdr_locks()** (3 connections) — `bin/fm-teardown.sh`
- **fm_lease_lock_helpers()** (2 connections) — `bin/fm-lease-lib.sh`
- **usage()** (2 connections) — `bin/fm-lease.sh`
- **fm-lease-lib.sh script** (1 connections) — `bin/fm-lease-lib.sh`

## Relationships

- [Crewmate spawn 1](Crewmate_spawn_1.md) (7 shared connections)
- [Agent control 1](Agent_control_1.md) (3 shared connections)
- [Teardown cleanup 1](Teardown_cleanup_1.md) (3 shared connections)
- [Fm Merge Local](Fm_Merge_Local.md) (2 shared connections)
- [Pull request landing 2](Pull_request_landing_2.md) (2 shared connections)
- [Fm Send](Fm_Send.md) (2 shared connections)
- [Crewmate spawn 2](Crewmate_spawn_2.md) (2 shared connections)
- [Wake queue 4](Wake_queue_4.md) (2 shared connections)
- [Teardown cleanup 3](Teardown_cleanup_3.md) (1 shared connections)

## Source Files

- `bin/fm-lease-lib.sh`
- `bin/fm-lease.sh`
- `bin/fm-teardown.sh`

## Audit Trail

- EXTRACTED: 48 (83%)
- INFERRED: 10 (17%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*