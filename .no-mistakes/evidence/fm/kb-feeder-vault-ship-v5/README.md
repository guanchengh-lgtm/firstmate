# Feeder vault exporter - test evidence

- `e2e-transcript.txt` - end-to-end CLI transcript: first export publishes and pushes into a local bare origin, a no-change rerun skips the commit but still pushes HEAD, a credential-bearing source refuses without printing the secret, a changed record produces a new commit and push, and `data/` is never written back to.
- `full-suite-green.txt` - full run of `tests/fm-feeder-export.test.sh` (50 cases, all ok).
- `breakage-*.red.txt` - manufactured-breakage red observations; each was produced by breaking one line of `bin/fm-feeder-export.sh`, then restored.
- `test-runner-mapping.txt` - `bin/fm-test-run.sh --list --family pr-forge` shows the new test file is mapped.
- `e2e-scenario.sh` - the scenario body appended to the suite's fixture helpers to produce `e2e-transcript.txt`.
