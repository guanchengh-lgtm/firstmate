# Scout brief

A scout brief is the investigation contract: the deliverable is `data/<id>/report.md`, the worktree is scratch, and there is no branch, push, or PR.

## Sub-features

- `scout-scaffold` writes a brief that declares `SCOUT task` and points at `report.md`.
- `scout-no-mode` refuses `--mode` on a scout scaffold.
- `scout-sources` records each `--source` URL or path in the named-sources manifest.
- `scout-check-worker` lints a scout brief with `--check-worker scout`.

## How to get to it (user POV)

- Ask the first mate for a separate investigation, diagnosis, plan, or audit when intake classifies a scout.
- Run `bin/fm-brief.sh <task-id> <repo-name> --scout` and pass every named URL or path as `--source`.

## Driving it with fm-test-run

Preconditions:

- Isolated `VERIFY_HOME` from launch, doctor driveable.
- No `data/verify-scout/brief.md` yet in that home.

- **Regression suite.** The scout cases live in the same brief suite. Run `bin/fm-test-run.sh tests/fm-brief.test.sh`. Exit code `0` and stdout contain `FM_TEST_SUMMARY` with `failed=0`.
- **Scout user path.** Scaffold an investigation brief. Run `FM_HOME="$VERIFY_HOME" bin/fm-brief.sh verify-scout alpha --scout`. Exit code `0`. Stdout is `scaffolded: $VERIFY_HOME/data/verify-scout/brief.md (scout; replace {TASK})`.
- **Scout body.** Read `$VERIFY_HOME/data/verify-scout/brief.md`. It contains `SCOUT task` and `report.md` and does not contain `Delivery contract: mode=`.
- **Mode refused.** Add `--mode direct-PR` to a scout command. Run `FM_HOME="$VERIFY_HOME" bin/fm-brief.sh verify-scout-b alpha --scout --mode direct-PR`. Exit code is non-zero and output contains `--mode applies only to ship briefs`.
- **Proof.** Copy `verify-scout/brief.md` into `$VERIFY_EVIDENCE/scout-brief/` before cleanup. After cleanup the copy still contains `SCOUT task` and `report.md`.

## Gotchas

- A scout report recommending implementation does not authorize a ship. Promotion is a separate `bin/fm-promote.sh` path.
- `--source` is how named URLs and lock paths enter the brief. A research ask with no manifest fails `--check-worker scout`.
- `--herdr-lab` is still required if the investigation will drive Herdr lifecycle commands.
- Do not look for `data/<id>/mode` on a scout. Mode markers are ship-only.
