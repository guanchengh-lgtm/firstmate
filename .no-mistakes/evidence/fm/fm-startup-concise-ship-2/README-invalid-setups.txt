INVALID-SETUP-* files are setup attempts, not pass evidence:
- codex exec with -s read-only fired only 4 SessionStart hook lines (7 with the guard flags); the three tracked hooks did not appear to load; no cause asserted.
- claude -p --max-turns 1 ended at the turn limit before answering.
