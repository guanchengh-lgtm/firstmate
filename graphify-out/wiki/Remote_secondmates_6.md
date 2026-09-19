# Remote secondmates 6

> 18 nodes · cohesion 0.17

## Key Concepts

- **worker_run_job()** (16 connections) — `bin/fm-remote-job-worker.sh`
- **fm-remote-entrypoint.sh script** (15 connections) — `bin/fm-remote-entrypoint.sh`
- **fm-remote-entrypoint.sh** (9 connections) — `bin/fm-remote-entrypoint.sh`
- **fm_remote_job_canonical_home()** (6 connections) — `bin/fm-remote-job-lib.sh`
- **decode_text()** (5 connections) — `bin/fm-remote-entrypoint.sh`
- **fm_remote_job_normalize_absolute_path()** (4 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_operator_tool()** (4 connections) — `bin/fm-remote-job-lib.sh`
- **base64_decode_to()** (3 connections) — `bin/fm-remote-entrypoint.sh`
- **die()** (3 connections) — `bin/fm-remote-entrypoint.sh`
- **fm_remote_job_build_child_path()** (3 connections) — `bin/fm-remote-job-lib.sh`
- **fm_remote_job_read_deadline()** (3 connections) — `bin/fm-remote-job-lib.sh`
- **entrypoint_cleanup()** (2 connections) — `bin/fm-remote-entrypoint.sh`
- **path_is_ancestor()** (2 connections) — `bin/fm-remote-entrypoint.sh`
- **sha256_file()** (2 connections) — `bin/fm-remote-entrypoint.sh`
- **fm_remote_job_has_forbidden_text_bytes()** (2 connections) — `bin/fm-remote-job-lib.sh`
- **worker_capture_output()** (2 connections) — `bin/fm-remote-job-worker.sh`
- **worker_cleanup_output_capture()** (2 connections) — `bin/fm-remote-job-worker.sh`
- **entrypoint_caller_connected()** (1 connections) — `bin/fm-remote-entrypoint.sh`

## Relationships

- [Remote secondmates 5](Remote_secondmates_5.md) (12 shared connections)
- [Remote secondmates 2](Remote_secondmates_2.md) (10 shared connections)
- [Remote secondmates 4](Remote_secondmates_4.md) (10 shared connections)

## Source Files

- `bin/fm-remote-entrypoint.sh`
- `bin/fm-remote-job-lib.sh`
- `bin/fm-remote-job-worker.sh`

## Audit Trail

- EXTRACTED: 57 (98%)
- INFERRED: 1 (2%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*