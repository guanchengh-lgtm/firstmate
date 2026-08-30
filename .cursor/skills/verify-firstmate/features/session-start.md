# Session start

Session start is the one digest a supported harness runs when a firstmate home opens: lock, bootstrap, wake queue, supervision instructions, then the read-once fleet and context sections.

## Sub-features

- `session-lock` acquires or refuses the per-home session lock and prints `LOCK`.
- `session-bootstrap` prints bootstrap detect lines under `BOOTSTRAP`.
- `session-read-once` prints `READ-ONCE CONTRACT` before the bulky sources.
- `session-context` prints `CONTEXT` with `ABSENT` or file bodies for `data/projects.md` and siblings.
- `session-next` prints `NEXT STEP` for the detected primary harness.

## How to get to it (user POV)

- Launch `claude`, `grok --trust`, `pi`, or Cursor Agent CLI with `--trust` inside a firstmate clone.
- Cursor's tracked `.cursor/hooks.json` `sessionStart` hook runs `bin/fm-sessionstart-cursor.sh --source startup`, which calls `bin/fm-sessionstart-run.sh`.
- Run `bin/fm-session-start.sh` directly (the script those adapters compose).

## Driving it with fm-test-run

Preconditions:

- Isolated `VERIFY_HOME` from launch, doctor driveable.
- Do not point `FM_HOME` at the live checkout.
- `bin/fm-session-start.sh` is executable in this repo.

- **Regression suite.** Run the existing session-start tests. Run `bin/fm-test-run.sh tests/fm-session-start.test.sh`. Exit code `0` and stdout contain `FM_TEST_SUMMARY` with `failed=0`.
- **Isolated digest.** Compose the digest against the verification home. Run `FM_HOME="$VERIFY_HOME" bin/fm-session-start.sh`. Exit code `0`. Stdout starts with `SESSION START - ` followed by the isolated home path.
- **Lock section.** Read the `LOCK` section. On a Cursor or Claude ancestry this home prints `lock acquired: harness pid <n>`; otherwise it stays read-only and `NEXT STEP` says the session did not acquire the fleet lock.
- **Context absent.** Read `CONTEXT`. On a fresh isolated home each of `data/projects.md`, `data/secondmates.md`, `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` prints `ABSENT`.
- **Proof.** Save the full stdout to `$VERIFY_EVIDENCE/session-start.stdout` before cleanup. Confirm the file still contains `READ-ONCE CONTRACT` and `NEXT STEP` after the home is removed.

## Gotchas

- Default `FM_HOME` is the repo root. Omitting `FM_HOME` drives the live captain home and can take its session lock.
- This script's default budget is `FM_SESSION_START_TIMEOUT` (120s). A truncated digest names the stage that did not run; do not treat a truncated tail as a complete context read.
- `NETWORK CHECKS` may print `IN PROGRESS` on a fast run. That is not failure; those checks are deferred and unconfirmed until `bin/fm-startup-network.sh report`.
- Isolated session-start that acquires a lock writes under `$VERIFY_HOME/state/`. Delete that home in cleanup; do not kill harness pid.
- The behavior suite builds throwaway git roots and fake toolchains. Its passing is not proof you drove this checkout's live `AGENTS.md` digest.
