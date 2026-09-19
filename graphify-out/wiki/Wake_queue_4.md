# Wake queue 4

> 19 nodes · cohesion 0.20

## Key Concepts

- **fm-wake-drain.sh** (30 connections) — `bin/fm-wake-drain.sh`
- **fm-wake-drain.sh script** (18 connections) — `bin/fm-wake-drain.sh`
- **_drain_rebuild_outcome_indexes()** (7 connections) — `bin/fm-wake-drain.sh`
- **reclaim_stale_branch_grant_locked()** (4 connections) — `bin/fm-wake-drain.sh`
- **rows_file_valid()** (4 connections) — `bin/fm-wake-drain.sh`
- **write_rows_file_locked()** (4 connections) — `bin/fm-wake-drain.sh`
- **branch_grant_live_locked()** (3 connections) — `bin/fm-wake-drain.sh`
- **claim_main_rows_locked()** (3 connections) — `bin/fm-wake-drain.sh`
- **consume_actor_rows_locked()** (3 connections) — `bin/fm-wake-drain.sh`
- **require_branch_eligible_rows()** (3 connections) — `bin/fm-wake-drain.sh`
- **acknowledge_inactive_outcomes()** (2 connections) — `bin/fm-wake-drain.sh`
- **assert_watcher_liveness()** (2 connections) — `bin/fm-wake-drain.sh`
- **cleanup()** (2 connections) — `bin/fm-wake-drain.sh`
- **_drain_outcome_store_last_seq()** (2 connections) — `bin/fm-wake-drain.sh`
- **_drain_publish_outcome_index_ready()** (2 connections) — `bin/fm-wake-drain.sh`
- **_drain_write_outcome_index()** (2 connections) — `bin/fm-wake-drain.sh`
- **inactive_outcome_fingerprints()** (2 connections) — `bin/fm-wake-drain.sh`
- **outcome_index_ready_ok()** (2 connections) — `bin/fm-wake-drain.sh`
- **fm_wake_print_deduped()** (2 connections) — `bin/fm-wake-lib.sh`

## Relationships

- [Wake queue 2](Wake_queue_2.md) (12 shared connections)
- [Crewmate spawn 1](Crewmate_spawn_1.md) (12 shared connections)
- [Teardown cleanup 5](Teardown_cleanup_5.md) (2 shared connections)
- [Fm Classify Lib](Fm_Classify_Lib.md) (1 shared connections)
- [Recall ranking 2](Recall_ranking_2.md) (1 shared connections)
- [Wake queue 1](Wake_queue_1.md) (1 shared connections)

## Source Files

- `bin/fm-wake-drain.sh`
- `bin/fm-wake-lib.sh`

## Audit Trail

- EXTRACTED: 58 (92%)
- INFERRED: 5 (8%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*