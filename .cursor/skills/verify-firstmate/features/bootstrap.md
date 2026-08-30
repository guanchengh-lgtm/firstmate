# Bootstrap doctor

Bootstrap is the toolchain and fleet-health detect firstmate runs at session start: one line per actionable problem, silent when every detected tool is present, always exit 0 on the detect path.

## Sub-features

- `bootstrap-detect` prints `MISSING: <tool> (install: <command>)` for absent required tools.
- `bootstrap-silent` prints nothing when the toolchain is complete.
- `bootstrap-detect-only` skips the six mutating sweeps when `FM_BOOTSTRAP_DETECT_ONLY=1`.
- `bootstrap-tangle` reports `TANGLE:` when `FM_ROOT` is on a named non-default branch.

## How to get to it (user POV)

- Open a firstmate session; session start prints the `BOOTSTRAP` section.
- Run `bin/fm-bootstrap.sh` from the toolbelt (detect is the no-argument path).
- Firstmate may later run `bin/fm-bootstrap.sh install <tool>` only after current captain consent.

## Driving it with fm-test-run

Preconditions:

- Isolated `VERIFY_HOME` from launch, doctor driveable.
- Do not pass `install` unless the captain has just approved that exact install.

- **Regression suite.** Run the existing bootstrap tests. Run `bin/fm-test-run.sh tests/fm-bootstrap.test.sh`. Exit code `0` and stdout contain `FM_TEST_SUMMARY` with `failed=0`.
- **Detect-only user path.** Run detection without mutating sweeps. Run `FM_HOME="$VERIFY_HOME" FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh`. Exit code `0`.
- **Observe skip.** After that command, `$VERIFY_HOME/projects` is still empty and no `state/.secondmate-nudge-pending` directory was created. That is the proof detect-only skipped the mutating sweeps.
- **Missing tools.** On a machine without the full toolchain, stdout contains lines matching `MISSING: treehouse`, `MISSING: no-mistakes`, and `MISSING: *-axi`. Those lines are facts, not a failed verify of brief or bearings.
- **Silent machine.** When every detected tool is present, stdout is empty. Treat silence as the all-good detect result, not a hung command.
- **Proof.** Save stdout to `$VERIFY_EVIDENCE/bootstrap.stdout` and a `ls` of `$VERIFY_HOME/projects` to `$VERIFY_EVIDENCE/bootstrap-projects.ls` before cleanup.

## Gotchas

- Detect always exits 0, including when it prints `MISSING:` lines. Assert the lines, not a non-zero exit.
- Without `FM_BOOTSTRAP_DETECT_ONLY=1`, a locked session-start path can run fleet sync, secondmate sweeps, and Relay artifact writes. Do not run that against the live home for verification.
- `install` is a different verb and needs captain consent. Doctor and this feature stay on detect.
- `TANGLE:` names the primary checkout (`FM_ROOT`), not `FM_HOME`. A verification home on `/tmp` does not hide a feature-branch tangle on the clone you are editing.
- `NEEDS_GH_AUTH` is a detect line. This skill does not call `gh` from operator shells; firstmate-owned scripts may call it internally.
