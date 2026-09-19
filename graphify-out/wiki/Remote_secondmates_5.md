# Remote secondmates 5

> 33 nodes · cohesion 0.14

## Key Concepts

- **fm_remote_job_prepare_state()** (21 connections) — `bin/fm-remote-job-lib.sh`
- **worker_process_once()** (17 connections) — `bin/fm-remote-job-worker.sh`
- **fm_remote_job_regular_bounded()** (16 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_reap()** (13 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_stage()** (12 connections) — `bin/fm-remote-job-lib.sh`
- **worker_lane_execute()** (12 connections) — `bin/fm-remote-job-worker.sh`
- **fm-remote-transport-lanes.test.sh script** (12 connections) — `tests/fm-remote-transport-lanes.test.sh`
- **fm_remote_job_wait()** (11 connections) — `bin/fm-remote-job-lib.sh`
- **worker_publish_result()** (11 connections) — `bin/fm-remote-job-worker.sh`
- **fm_remote_job_read_state()** (10 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_reap_stale()** (9 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_cancel()** (7 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_job_dir()** (7 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_read_number()** (7 connections) — `bin/fm-remote-job-lib.sh`
- **worker_preempting_waiter_exists()** (7 connections) — `bin/fm-remote-job-worker.sh`
- **fm_remote_job_cancelled()** (6 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_next_seq()** (6 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_safe_id()** (6 connections) — `bin/fm-remote-job-lib.sh`
- **worker_claim_owner_alive()** (6 connections) — `bin/fm-remote-job-worker.sh`
- **worker_reclaim_running_job()** (6 connections) — `bin/fm-remote-job-worker.sh`
- **worker_clear_dead_claim()** (5 connections) — `bin/fm-remote-job-worker.sh`
- **worker_finalize_cancelled()** (5 connections) — `bin/fm-remote-job-worker.sh`
- **worker_read_text()** (5 connections) — `bin/fm-remote-job-worker.sh`
- **fm_remote_job_remove_claim_records()** (4 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_write_state()** (4 connections) — `bin/fm-remote-job-lib.sh`
- *... and 8 more nodes in this community*

## Relationships

- [Remote secondmates 2](Remote_secondmates_2.md) (36 shared connections)
- [Remote secondmates 4](Remote_secondmates_4.md) (36 shared connections)
- [Remote secondmates 6](Remote_secondmates_6.md) (12 shared connections)
- [Fm Remote Transport Lane](Fm_Remote_Transport_Lane.md) (4 shared connections)
- [Remote secondmates 3](Remote_secondmates_3.md) (3 shared connections)
- [Recall ranking 2](Recall_ranking_2.md) (1 shared connections)

## Source Files

- `bin/fm-remote-job-lib.sh`
- `bin/fm-remote-job-worker.sh`
- `tests/fm-remote-transport-lanes.test.sh`

## Audit Trail

- EXTRACTED: 168 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*