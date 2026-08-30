---
name: verify-firstmate
description: >-
  Verify firstmate, the agent-distro crew orchestrator, on its real surface:
  an isolated FM_HOME plus the bin/ toolbelt and tests/*.test.sh runner.
  Use when proving a firstmate change the way a first mate drives the distro
  (session start, crewmate briefs, bootstrap, bearings) without touching the
  live captain home.
---

# Verify firstmate

Firstmate is an agent distro, not a web app, CLI product, or long-running server.

A user clones this repo and launches a verified harness inside it (`claude`, `grok --trust`, `pi` / `pi-signed`, or Cursor Agent CLI with `--trust`).
`AGENTS.md` takes over.
The programmatic surface an agent can drive without opening a second primary session is the `bin/` toolbelt under an isolated `FM_HOME`, plus the existing behavior suite `bin/fm-test-run.sh tests/<subject>.test.sh`.

This skill is for the next agent mid-task.
Drive an isolated home this run created.
Never set `FM_HOME` to the live checkout and never spawn, steer, or arm supervision against the captain's home.

Secondary surfaces that exist and are out of scope unless a mapped feature names them: public `skills/stow`, optional Relay (`FMX_PAIRING_TOKEN` in `.env`), and session backends (tmux is the documented default; herdr, zellij, orca, and cmux are experimental).

## Launch

There is no server, port, or seed database.

```sh
.cursor/skills/verify-firstmate/helpers/launch.sh
# prints VERIFY_HOME, VERIFY_EVIDENCE, VERIFY_ENV
. "$VERIFY_ENV"
```

Ready when those three lines print and `$VERIFY_HOME` contains `state/`, `data/`, `config/`, `projects/`, and `.fm-verify-home`.

The helper refuses to place `VERIFY_HOME` under the live checkout.
Default location is `${TMPDIR:-/tmp}/fm-verify-<utc>-<pid>`.
Override with `VERIFY_HOME`, `VERIFY_ROOT`, `VERIFY_EVIDENCE`, or `VERIFY_RUN_ID` before launch.

Captain-facing launch (do not use this for verification of the live home) is documented in `README.md`: `git clone` then `claude`, `grok --trust`, `pi`, or Cursor with `--trust`.
A second primary in the same `FM_HOME` cannot share the session lock.

Teardown of what launch created is `helpers/cleanup.sh` (see Cleanup).
It does not stop a harness.

## Doctor

Run this first whenever anything looks off.

```sh
.cursor/skills/verify-firstmate/helpers/doctor.sh
# or: .cursor/skills/verify-firstmate/helpers/doctor.sh "$VERIFY_ENV"
```

Worth driving when the last line is `doctor: driveable isolated-bin-scripts (missing_tools=N)`.

Doctor checks, all read-only:

- `.fm-verify-home` marker and `state/`, `data/`, `config/`, `projects/`
- `bash -n` on `bin/fm-session-start.sh`, `bin/fm-bootstrap.sh`, `bin/fm-brief.sh`, `bin/fm-bearings-snapshot.sh`, `bin/fm-lock.sh`, `bin/fm-test-run.sh`
- `FM_HOME="$VERIFY_HOME" bin/fm-lock.sh status` (a fresh launch home prints `lock: free`)
- `FM_HOME="$VERIFY_HOME" FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh` (silent means every detected tool is present; this checkout printed `MISSING:` lines for treehouse, no-mistakes, gh-axi, chrome-devtools-axi, lavish-axi, tasks-axi, and quota-axi)
- `bin/fm-test-run.sh --list tests/fm-brief.test.sh` exits 0

`MISSING:` lines do not fail doctor.
They block spawn/worktrees (`treehouse`), no-mistakes delivery (`no-mistakes` 1.31.2+), and axi-backed GitHub/browser/quota/backlog verbs.
They do not block brief scaffold, bearings, session-start, or `bin/fm-test-run.sh`.

Do not treat `bin/fm-guard.sh` as this doctor.
It always exits 0 and warns about primary-checkout tangles and watcher health on whatever `FM_HOME`/`FM_ROOT` it sees.

## Drive

Existing harness first: `bin/fm-test-run.sh`.
Direct user-path second: the same `bin/fm-*.sh` firstmate itself runs, with `FM_HOME` set to the isolated home.

```sh
. "$VERIFY_ENV"
bin/fm-test-run.sh tests/fm-brief.test.sh
FM_HOME="$VERIFY_HOME" bin/fm-brief.sh verify-brief demo-proj --mode direct-PR
```

Read the matching file under `features/` before driving.
The map is the source; do not substitute a convenient neighboring script.

Stable handles (no CSS, no coordinates):

- Session-start digest section titles: `SESSION START - <FM_HOME>`, `LOCK`, `BOOTSTRAP`, `READ-ONCE CONTRACT`, `CONTEXT`, `NEXT STEP`
- Brief stdout: `scaffolded: <home>/data/<id>/brief.md (ship, mode=<mode>; replace {TASK})`
- Brief files: `data/<id>/brief.md`, sibling `data/<id>/mode` (exact token `no-mistakes|direct-PR|local-only`), sibling `data/<id>/role` (exactly `builder`)
- Brief headings: `# Task`, `# Setup`, `# Rules`, `# Definition of done`
- Ship contract lines inside the brief: `Delivery contract: mode=<mode>` and `Role: builder`
- Scout stdout: `scaffolded: <home>/data/<id>/brief.md (scout; replace {TASK})`
- Scout brief text: `SCOUT task` and `report.md`
- Bearings header: `schema: fm-bearings.v1` and `home: <label>`
- Test runner markers: `FM_TEST_BEGIN`, `FM_TEST_END`, `FM_TEST_SUMMARY total=<n> failed=<n> ...`
- Test assertions: `ok - ...` on stdout; `not ok - ...` on stderr

Isolation rules:

- Two isolated `FM_HOME` values can run side by side.
- One `FM_HOME` has one session lock.
- `FM_HOME="$VERIFY_HOME" bin/fm-session-start.sh` will acquire that home's lock when a Cursor or Claude harness is in the process ancestry (observed: `lock acquired: harness pid <n>`).
- Do not run session-start, spawn, send, or merge against the live checkout home.
- Zellij and cmux do not split containers per home; do not start those backends for ordinary verification.
- Cursor PreToolUse policy in this repo refuses some operator shells that name watcher scripts.
  Drive watcher behavior only through `bin/fm-test-run.sh tests/fm-watch-arm.test.sh` (and siblings), never by hand-arming a cycle.

## Evidence

Proof lives under `.cursor/skills/verify-firstmate/evidence/<run-id>/` (the `VERIFY_EVIDENCE` path launch printed).
Cleanup must not delete that directory.

Standards:

- Exercise the real path firstmate uses (`bin/fm-brief.sh`, `bin/fm-session-start.sh`, `bin/fm-bootstrap.sh`, `bin/fm-bearings-snapshot.sh`) or the existing `tests/<subject>.test.sh` that drives those same scripts.
- Do not treat an internal setter, a hand-written `data/<id>/brief.md`, or a mocked stdout string as proof.
- Capture the command, stdout, stderr, and exit code, then a second read of the resulting files.
- For a ship brief, the action is the `fm-brief.sh` invocation; the resulting state is `brief.md` plus the `mode` and `role` marker files.
- Mocks belong only where a test already isolates an external tool (the behavior suite's fakebin).
- `FM_BOOTSTRAP_DETECT_ONLY=1` skips bootstrap's mutating sweeps.
  Confirm that by observing no `projects/` clone refresh and no secondmate send; do not trust the flag name alone.

Minimum artifact set for a brief drive:

- `drive-cmd.txt` (exact command)
- `drive.stdout` / `drive.stderr` / `drive.exit`
- copies of `data/<id>/brief.md`, `data/<id>/mode`, `data/<id>/role` taken before cleanup

## Cleanup

```sh
.cursor/skills/verify-firstmate/helpers/cleanup.sh
# or: .cursor/skills/verify-firstmate/helpers/cleanup.sh "$VERIFY_ENV"
```

Removes only `$VERIFY_HOME` when it carries the `.fm-verify-home` marker this skill wrote.
Refuses the live checkout and any unmarked directory.
Prints `evidence_kept: <VERIFY_EVIDENCE>`.

After cleanup, confirm `$VERIFY_EVIDENCE` still exists.
The behavior suite cleans its own `fm_test_tmproot` dirs on EXIT; do not delete those yourself.

Do not `pkill` by process name.
If this run acquired an isolated-home session lock, deleting that home is enough; the lock file lives under `$VERIFY_HOME/state/`.

## Helpers

All three are executable.
Invoke them from the repo root as shown.

| Helper | Invocation | Ready / success line |
| --- | --- | --- |
| Launch | `.cursor/skills/verify-firstmate/helpers/launch.sh` | `VERIFY_HOME=...` |
| Doctor | `.cursor/skills/verify-firstmate/helpers/doctor.sh` | `doctor: driveable isolated-bin-scripts (missing_tools=N)` |
| Cleanup | `.cursor/skills/verify-firstmate/helpers/cleanup.sh` | `cleanup: removed ...` and `evidence_kept: ...` |

Keep the feature map honest with `/maintain-verification-skill` as the app changes.
