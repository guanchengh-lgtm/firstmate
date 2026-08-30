# Crewmate ship brief

A ship brief is the written contract firstmate gives a crewmate before spawn: task placeholder, isolation assertion, status protocol, and an explicit delivery mode with builder role markers.

## Sub-features

- `brief-ship-direct-pr` scaffolds a `direct-PR` ship brief and writes `mode`/`role` markers.
- `brief-ship-no-mistakes` scaffolds a `no-mistakes` brief whose definition of done names the separate verifier handoff.
- `brief-ship-local-only` scaffolds a `local-only` brief that stops on a ready branch.
- `brief-mode-required` refuses a ship scaffold with no `--mode` or an unknown mode.
- `brief-no-overwrite` refuses to replace an existing `brief.md`.

## How to get to it (user POV)

- Ask the first mate to ship a change; firstmate runs `bin/fm-brief.sh` at intake before `bin/fm-spawn.sh`.
- Run `bin/fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only>` by hand from the toolbelt.

## Driving it with fm-test-run

Preconditions:

- Isolated `VERIFY_HOME` from launch, doctor driveable.
- No `data/verify-brief/brief.md` yet in that home.
- `bin/fm-brief.sh` is executable.

- **Regression suite.** Run the existing brief tests. Run `bin/fm-test-run.sh tests/fm-brief.test.sh`. Exit code `0` and stdout contain `FM_TEST_SUMMARY` with `failed=0`.
- **Direct-PR user path.** Scaffold the brief firstmate writes before spawn. Run `FM_HOME="$VERIFY_HOME" bin/fm-brief.sh verify-brief demo-proj --mode direct-PR`. Exit code `0`. Stdout is `scaffolded: $VERIFY_HOME/data/verify-brief/brief.md (ship, mode=direct-PR; replace {TASK})`.
- **Marker files.** Read the unforgeable siblings. `cat "$VERIFY_HOME/data/verify-brief/mode"` is exactly `direct-PR`. `cat "$VERIFY_HOME/data/verify-brief/role"` is exactly `builder`.
- **Brief body.** Read `$VERIFY_HOME/data/verify-brief/brief.md`. It contains `# Task` then `{TASK}`, the isolation STOP line about `primary checkout`, `Delivery contract: mode=direct-PR`, `Role: builder`, and `done: PR {url}`.
- **Mode required.** Omit `--mode`. Run `FM_HOME="$VERIFY_HOME" bin/fm-brief.sh verify-brief-b demo-proj`. Exit code is non-zero and stderr or stdout contains `ship briefs require --mode`. No `data/verify-brief-b/brief.md` exists.
- **No overwrite.** Repeat the successful direct-PR command against `verify-brief`. Exit code is non-zero and the first `brief.md` bytes are unchanged.
- **Proof.** Copy `brief.md`, `mode`, and `role` into `$VERIFY_EVIDENCE/crewmate-brief/` before cleanup. After cleanup those copies still exist and still contain `direct-PR` and `builder`.

## Gotchas

- `--mode` is required on ship briefs and is a closed set: `no-mistakes`, `direct-PR`, `local-only`. `no-mistakes-prod-only` is a registry policy, not a task mode; the refusal says to classify the task's surface.
- `fm-brief.sh` does not read `data/projects.md`. An explicit `--mode` always wins; an unregistered repo name still scaffolds.
- There is no `--yolo` flag. Passing `--yolo` is refused (`--yolo is not a brief input`).
- The worker never owns merge authority. A passing brief scaffold is not a ship.
- Relative `FM_HOME` is resolved against the caller's working directory before the brief is written. Use an absolute `VERIFY_HOME`.
