# Bearings

Bearings is the local-only "pick up where I left off" fleet digest: compact TOON by default, no GitHub calls unless `--include-prs`.

## Sub-features

- `bearings-empty` prints `schema: fm-bearings.v1` with empty in-flight, secondmates, and landed lists on a fresh home.
- `bearings-local` keeps the default path off the network (`prs: "not_requested ..."`).
- `bearings-json` prints the same projection as JSON with `--json`.
- `bearings-omit` lists omitted surfaces under `omitted[`.

## How to get to it (user POV)

- Ask the first mate `/bearings` (chat-only) or `/bearings file` (also writes today's `data/status-report-<YYYY-MM-DD>.md`).
- Run `bin/fm-bearings-snapshot.sh` from the toolbelt. Firstmate's `/bearings` skill consumes this snapshot.

## Driving it with fm-test-run

Preconditions:

- Isolated `VERIFY_HOME` from launch, doctor driveable.
- `jq` is on `PATH` (the bearings test file skips with `skip: jq not found` when it is not; this checkout has `/usr/bin/jq`).

- **Regression suite.** Run the existing bearings tests. Run `bin/fm-test-run.sh tests/fm-bearings-snapshot.test.sh`. Exit code `0` and stdout contain `FM_TEST_SUMMARY` with `failed=0`.
- **Empty-home user path.** Project the isolated home. Run `FM_HOME="$VERIFY_HOME" bin/fm-bearings-snapshot.sh`. Exit code `0`. Stdout starts with `schema: fm-bearings.v1` and contains `in_flight: []`, `secondmates: []`, `landed: []`.
- **Local-only.** The same stdout contains `prs: "not_requested (run: /bearings include PRs)"` and an `omitted[` row for `live PR discovery + checks`.
- **JSON parity.** Run `FM_HOME="$VERIFY_HOME" bin/fm-bearings-snapshot.sh --json`. Exit code `0`. The JSON object has `"schema": "fm-bearings.v1"` (or the equivalent projected field the suite already asserts).
- **Proof.** Save both TOON and JSON stdout under `$VERIFY_EVIDENCE/bearings/` before cleanup.

## Gotchas

- Default bearings is local-only. `--include-prs` is the only network path. Do not pass it unless the feature under test is live PR enrichment and `gh-axi` is present.
- `ideas_unscheduled: 0` on a home whose ledgers were unreadable is only valid when `ideas_warnings` is empty. This isolated home has no ledgers, so zero is a real empty count.
- `prior_session` may contain `INCOMPLETE: startup-memory budget is unavailable: file is absent` on a fresh home. That is expected, not a bearings failure.
- `/bearings file` writes under `data/` of the active home. On verification, that is `$VERIFY_HOME/data/`, not the live checkout.
