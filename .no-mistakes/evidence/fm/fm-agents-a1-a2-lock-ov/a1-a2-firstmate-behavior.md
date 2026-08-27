# A1/A2 Firstmate behavior evidence

Target: `59b9b223c6d40080f5586a27627d5a6066f86676`

## Real-agent interpretation check

Claude Fable ran at medium effort with session persistence disabled and the current worktree's `CLAUDE.md` / `AGENTS.md` loaded.
The evaluation was read-only and presented the two collision scenarios through the agent's normal instruction-consumer surface.

```text
A1: Proceed from the lock, captain - AGENTS.md section 7 states that a lock which already names the change is a go, and the report only adds evidence.
A2: Run the review - the selected path owns its own rigor, so a workflow-native default-on review is not an added manual gate or a redundant design exercise.
```

## Focused contract test

Command: `bin/fm-test-run.sh tests/fm-ov-backpass-apply.test.sh`

```text
ok - supervisor skills: internal frontmatter + agent-only descriptions + required body contracts
ok - worker brief: refuses /worker-control and /firstmate-no-mistakes; permits plain names
ok - AGENTS.md contract: locked always-on facts and restorations present
ok - companion skills: cross-references resolve to live AGENTS.md text
ok - style: plain dash and one-sentence-per-line on applied contract surfaces
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```

## Acceptance checks

```text
HEAD=59b9b223c6d40080f5586a27627d5a6066f86676
BASE_AGENTS_LINES=303
TARGET_AGENTS_LINES=302
CHANGED_TEST_FILES=0
ADDED_EM_DASH_LINES=0
COAUTHOR_TRAILERS=0
STATUS_PORCELAIN_BEGIN
STATUS_PORCELAIN_END
```

No changed test file exists on this branch, so the required per-changed-test manufactured-breakage loop had no subject.
