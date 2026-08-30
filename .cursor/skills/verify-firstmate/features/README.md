# firstmate verification map

This directory is the maintained source for verifying firstmate's user-facing distro behavior.
Read this index before driving, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch an isolated home with `.cursor/skills/verify-firstmate/helpers/launch.sh` and source its `VERIFY_ENV`.
- Run `.cursor/skills/verify-firstmate/helpers/doctor.sh` and require `doctor: driveable isolated-bin-scripts`.
- Keep `FM_HOME` pointed at that isolated home for every direct `bin/fm-*.sh` call.
- Never set `FM_HOME` to the live checkout.
- Prefer `bin/fm-test-run.sh tests/<subject>.test.sh` for regression; use the direct `FM_HOME=... bin/fm-*.sh` command when proving the path firstmate itself runs.

## Driving conventions

- Start every recipe from a fresh isolated home unless the feature file says otherwise.
- Treat every command as literal.
- Keep quoted names and flags unchanged.
- Capture stdout, stderr, and exit code for every drive.
- Restore nothing into the live checkout.
- Remove the isolated home after the run; keep proof artifacts.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the last line of stdout.
- Mutation proof includes a second read of the file firstmate wrote (`brief.md`, `mode`, `role`, digest sections).
- Record the feature ID and entry point with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition (for example `MISSING: treehouse` when a recipe needs spawn).
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior.
It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with fm-test-run` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

## Features

- [Session start](./session-start.md) covers the ordered digest a harness-open runs.
- [Crewmate ship brief](./crewmate-brief.md) covers scaffolding a ship brief with an explicit delivery mode.
- [Scout brief](./scout-brief.md) covers the investigation brief whose deliverable is a report.
- [Bootstrap doctor](./bootstrap.md) covers toolchain detection without mutating sweeps.
- [Bearings](./bearings.md) covers the local-only fleet digest.
