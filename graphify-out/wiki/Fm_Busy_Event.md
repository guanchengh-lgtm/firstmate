# Fm Busy Event

> 12 nodes · cohesion 0.30

## Key Concepts

- **fm-busy-event.sh script** (9 connections) — `bin/fm-busy-event.sh`
- **fm-busy-event.sh** (7 connections) — `bin/fm-busy-event.sh`
- **fm_busy_current_gen()** (5 connections) — `bin/fm-busy-lib.sh`
- **fm_busy_record_read()** (5 connections) — `bin/fm-busy-lib.sh`
- **fm_busy_token_valid()** (4 connections) — `bin/fm-busy-lib.sh`
- **lock_acquire()** (3 connections) — `bin/fm-busy-event.sh`
- **fm_busy_gen_path()** (3 connections) — `bin/fm-busy-lib.sh`
- **fm_busy_record_path()** (3 connections) — `bin/fm-busy-lib.sh`
- **lock_mtime()** (2 connections) — `bin/fm-busy-event.sh`
- **lock_release()** (2 connections) — `bin/fm-busy-event.sh`
- **usage()** (2 connections) — `bin/fm-busy-event.sh`
- **write_record()** (2 connections) — `bin/fm-busy-event.sh`

## Relationships

- [Agent control 2](Agent_control_2.md) (7 shared connections)

## Source Files

- `bin/fm-busy-event.sh`
- `bin/fm-busy-lib.sh`

## Audit Trail

- EXTRACTED: 26 (96%)
- INFERRED: 1 (4%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*