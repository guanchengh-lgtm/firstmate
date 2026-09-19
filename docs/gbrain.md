# Derived gbrain brain

This page is the operator document for the local derived brain.
[`bin/fm-gbrain-maintain.py`](../bin/fm-gbrain-maintain.py) owns projection, exclusive maintenance, primary-only ingest, footer edges, publication, versioned archive install, and the loopback LaunchAgent plist.
[`bin/fm-gbrain-eval.py`](../bin/fm-gbrain-eval.py) owns the 13-probe comparison and the dated verdict file.
[`bin/fm-nightly.sh`](../bin/fm-nightly.sh) is the only scheduler and the only Record publisher for generated gbrain pages.
The Record remains the system of record.
Do not point a gbrain home, brain directory, working directory, or source at the live Record.

## What this ship does

The maintenance executable copies committed Record text into a disposable local Git tree, calls pinned gbrain commands, and publishes only scanned pages under `wiki/gbrain/` and `wiki/views/gbrain/`.
Brief and session-start recall use `--ranker auto`.
`GBRAIN_RECALL` defaults to off when absent, so those calls stay on term overlap until I4 flips the switch after install smoke.
Ambient writeback stays off.
Dream is not used.
T12 is the nightly owner.

## Home layout

Private roots live under `$FM_HOME/state/gbrain/` and are never a Record path.

- `home` is `GBRAIN_HOME` and holds the PGLite database under `.gbrain/`.
- `brain` is the disposable projection Git repository, with no remote.
- `candidate` and `previous` are the in-flight and last accepted generations.
- `eval/<run-id>/` holds measurement rows before T12 publishes a scanned copy.

Configuration is `$FM_HOME/config/gbrain.env` as `KEY=VALUE` lines.
Required key for the nightly phase is `GBRAIN_BIN`, which must be an executable versioned binary.
Optional keys are `GBRAIN_HOME`, `GBRAIN_BRAIN`, `GBRAIN_LABEL`, `GBRAIN_PORT`, `GBRAIN_TRANSCRIPT_MANIFEST`, `GBRAIN_LAUNCHCTL`, `GBRAIN_SCAN`, `GBRAIN_RECALL`, `GBRAIN_RECALL_TOKEN_FILE`, and `GBRAIN_RECALL_URL`.
`GBRAIN_RECALL` is off when absent.
`bin/fm-recall.sh` owns those recall keys and the loopback search call.
`GBRAIN_RECALL_URL` must name host `127.0.0.1`, `::1`, or `localhost`; any other host counts as serve down and the token is not sent.
The nightly views stage runs the maintenance command only on a local home when `GBRAIN_BIN` is executable.
Cloud record-only nights never start this Mac's database or ingest its local transcripts.

## Pins

Install into a new versioned directory.
Do not mutate an older global package in place.

- gbrain `v0.48.2.0` darwin-arm64 SHA-256 `bbe2572e47af88183f76e24b85fb1f311743fd2910d7969f90d0f4716f375395`
- Ollama `v0.33.3` `ollama-darwin.tgz` SHA-256 `342db03df80bb9db84ff64246031bd5f70c09b59ff52fa5cc9aaae3476cc4a9d`
- embedding model `ollama:nomic-embed-text`, 768 dimensions, manifest SHA-256 `0a109f422b47e3a30ba2b10eca18548e944e8a23073ee3f3e947efcf3c45e59f`
- local chat model `ollama:qwen2.5-coder:14b` Q4_K_M, manifest SHA-256 `9ec8897f747e246e970bc5cfdda85d22f1123dc2e3d34978a010a75968716849`

Release pages are [gbrain v0.48.2.0](https://github.com/garrytan/gbrain/releases/tag/v0.48.2.0) and [Ollama v0.33.3](https://github.com/ollama/ollama/releases/tag/v0.33.3).
`fm-gbrain-maintain.py install-archive --archive FILE --sha256 HEX --dest DIR` verifies the digest and refuses a different existing dest.
A matching prior install is a no-op.

## Services

Captain consent already covers one gbrain HTTP serve and one Ollama serve.
Do not add Postgres, hosted embeddings, Funnel, all-harness MCP, or a second scheduler.

gbrain LaunchAgent label is `com.firstmate.ks-t17-gbrain`.
Program arguments are the versioned binary plus `serve --http --bind 127.0.0.1 --port 3131 --suppress-bootstrap-token`.
Working directory is the disposable brain.
`GBRAIN_HOME` is the parent of `.gbrain`.
`fm-gbrain-maintain.py write-plist` renders that plist with no secrets.
Install it at `~/Library/LaunchAgents/com.firstmate.ks-t17-gbrain.plist`, because the maintenance restart bootstraps that path and reports a missing plist as a failed run.
Ollama listens on `127.0.0.1:11434`.
A port conflict is a reported configuration choice, never a reason to kill another process.

Required local configuration, set by hand in the dedicated home and never inherited from hosted providers:

- `memory.auto_writeback=off` in both configuration planes
- `self_upgrade.mode=notify`
- `sync.write_through=false`
- `search.mode=conservative`, `search.expansion=false`, `search.reranker.enabled=false`, `search.autocut=false`
- brief comparison calls use `recency: off` and `salience: off`
- `OLLAMA_BASE_URL=http://127.0.0.1:11434/v1`
- embedder is the pinned 768-dimension model on a fresh PGLite database
- `OLLAMA_CONTEXT_LENGTH=8192` and `OLLAMA_NUM_PARALLEL=1`

Do not run `gbrain bootstrap`.
Do not enable autopilot, per-turn hooks, dream, automatic capture, or hosted reranking.
Do not set `GBRAIN_ALLOW_MASS_RECONCILE=1`.
Maintenance commands set `GBRAIN_SKIP_STARTUP_HOOKS=1`.

## Nightly transaction

T12 already owns the 03:00 local calendar hour unless that job was installed at another hour.
The maintenance lock is `$FM_HOME/state/gbrain/maintain.lock`.
A second invocation exits 3 and does not stop services.

The run projects Record `HEAD`, stops only the named gbrain LaunchAgent, replaces the brain with the candidate, runs `gbrain sync --no-pull`, ingests only primary rows from the transcript manifest, replaces `record-footer` typed edges, exports generated prefixes, scans the staged wiki payload, publishes the allowlisted trees, and restarts that agent on the cleanup path.
A failed batch restores the previous accepted generation and leaves the Record wiki unchanged.
Publication never rewrites `playbook/`, `captain.md`, `captain-shared.md`, or `learnings.md`.

Transcript ingest uses exact filenames and a role of `primary`, `worker`, or `unclassified`.
Only `primary` rows are passed to `gbrain transcripts ingest`.
Unclassified rows are counted and never ingested.
Cursor, Grok, and Pi adapters are out of scope.

## Measurement

`fm-gbrain-eval.py run` calls `bin/fm-recall.sh` for overlap and the same command with `--ranker hybrid`, using [`tests/fixtures/recall/probe-expected.tsv`](../tests/fixtures/recall/probe-expected.tsv) unchanged.
Modes A, B, and C match the locked probe contract.
A keyword-only, hybrid-unverified, or unavailable hybrid arm is not a completed hybrid trial.
Hybrid wins only when both arms complete every row.
A timeout on either arm keeps overlap.
The two-week eval still compares `--ranker hybrid` against `--ranker overlap` regardless of the brief switch.
Serve-up for brief ranking means a successful search POST, not `GET /health`.

## Verification

```sh
bin/fm-test-run.sh tests/fm-gbrain-maintain.test.sh tests/fm-gbrain-eval.test.sh tests/fm-recall.test.sh
```

Those suites prove projection isolation, collisions, lock busy, primary-only ingest, footer publication, restore on failure, digest-checked archive install, scoring rules, and the recall hybrid client through the public executables.
A real gbrain and Ollama smoke is a home operation after I4.
`GET http://127.0.0.1:3131/health` is liveness only.
A successful authenticated search POST is the retrieval health check.

## Removal

Set `GBRAIN_RECALL=off` or delete the recall token file to return brief and session-start ranking to term overlap with no code change.
If the two-week comparison does not beat overlap, leave that switch off.
If the derived layer is later disabled, unload only `com.firstmate.ks-t17-gbrain`, keep the Record and generated pages, and do not delete original transcripts.
Stop Ollama only when this installation is its sole consumer.

## Out of scope

Postgres, hosted embeddings, Voyage, Funnel, tailnet exposure, all-harness MCP, Cursor/Grok/Pi transcript adapters, a second scheduler, a parallel recall engine, and edits to `AGENTS.md` are not part of this ship.
See [`verification/nightly-maintenance.md`](verification/nightly-maintenance.md) for the T12 runner evidence.
