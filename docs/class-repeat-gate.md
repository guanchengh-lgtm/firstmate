# Class-repeat cleanup gate

This note records what the class-repeat refuse-hook at cleanup can see, and what it cannot.
`bin/fm-teardown.sh`'s header owns the predicate, the registry row shape, the scout exemption, and the refusal text.
Do not copy that contract here.

## What it catches

At cleanup of a ship whose measure has a `miss:`, teardown looks for a prior `data/*/measure.md` in this home that matches the same class through `$FM_HOME/data/defect-classes.tsv`.
If one exists, cleanup refuses unless this branch touched an enforcing file under `bin/`, `tests/`, `.github/workflows/`, or a registered hook file (`.claude/settings.json`, `.codex/hooks.json`, `.grok/hooks/`, `.pi/extensions/`).
`--force` does not bypass the gate.
A queued `map_next` successor does not discharge it.
The five-line measure grammar is unchanged.

## What it does not catch

- Over-broad class matching: two different misses that share a captain-owned regex are treated as one class.
- The enforcing-file test proves a mechanism-shaped path changed, never that the change covers the class.
- Measures are per-home: the same class in a secondmate home is a first occurrence there.
- A legal `none:` measure has no `miss:`, so a repeat can hide behind `none:`.
- An unregistered phrasing is invisible, because the captain owns the name list.
- Scout tasks are exempt by design.
- The check does not claim complete coverage of the instance-patch class.

See [`defect-classes.example.tsv`](defect-classes.example.tsv) for the non-live row shape.
The live name list stays in the home's `data/defect-classes.tsv` and is not firstmate git.
Regression coverage lives in `tests/fm-teardown.test.sh`.
The claims file is [`verification/class-repeat-gate-claims.json`](verification/class-repeat-gate-claims.json).
