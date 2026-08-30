# Proof run 2026-08-30

Launch, doctor, one mapped feature (`crewmate-brief`), then cleanup.

Isolated home `/tmp/fm-verify-proof-20260830` is gone.
These files remained.

- Launch: `helpers/launch.sh` with `VERIFY_RUN_ID=proof-20260830`
- Doctor: `doctor: driveable isolated-bin-scripts (missing_tools=7)`
- Drive (user path): `FM_HOME=$VERIFY_HOME bin/fm-brief.sh verify-brief demo-proj --mode direct-PR` exit 0; `mode` is `direct-PR`; `role` is `builder`
- Drive (harness): `bin/fm-test-run.sh tests/fm-brief.test.sh` exit 0; `FM_TEST_SUMMARY total=1 failed=0`
- Cleanup: `cleanup: removed /tmp/fm-verify-proof-20260830` and `evidence_kept:` this directory
