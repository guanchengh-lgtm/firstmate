# Record maintain 6

> 14 nodes · cohesion 0.15

## Key Concepts

- **StagedViews** (7 connections) — `bin/fm-maintain.py`
- **input_manifest()** (6 connections) — `bin/fm-maintain.py`
- **.land()** (6 connections) — `bin/fm-maintain.py`
- **refuse_symlinked()** (5 connections) — `bin/fm-maintain.py`
- **canonical_view()** (4 connections) — `bin/fm-maintain.py`
- **atomic_write()** (3 connections) — `bin/fm-maintain.py`
- **scrub_generated()** (2 connections) — `bin/fm-maintain.py`
- **.add()** (2 connections) — `bin/fm-maintain.py`
- **.bind_inputs()** (2 connections) — `bin/fm-maintain.py`
- **Reject a Record-relative write path when any component is a symlink.** (1 connections) — `bin/fm-maintain.py`
- **Drop generated timestamps so an unchanged view is left untouched.** (1 connections) — `bin/fm-maintain.py`
- **sha256 of every file the views read, keyed by Record-relative path.** (1 connections) — `bin/fm-maintain.py`
- **Stage generated files outside the Record, then land them atomically.** (1 connections) — `bin/fm-maintain.py`
- **.__init__()** (1 connections) — `bin/fm-maintain.py`

## Relationships

- [Record maintain 2](Record_maintain_2.md) (6 shared connections)
- [Record maintain 1](Record_maintain_1.md) (4 shared connections)
- [Record maintain 5](Record_maintain_5.md) (2 shared connections)
- [Record maintain 7](Record_maintain_7.md) (1 shared connections)
- [Record maintain 9](Record_maintain_9.md) (1 shared connections)

## Source Files

- `bin/fm-maintain.py`

## Audit Trail

- EXTRACTED: 28 (100%)
- INFERRED: 0 (0%)
- AMBIGUOUS: 0 (0%)

---

*Part of the graphify knowledge wiki. See [index](index.md) to navigate.*