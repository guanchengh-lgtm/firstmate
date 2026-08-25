---
name: firstmate-no-mistakes
description: >-
  Agent-only Firstmate procedure for no-mistakes ship validation.
  Load after a builder stops, on any verifier decision or outcome, or before superseding active validation.
user-invocable: false
metadata:
  internal: true
---

# Firstmate no-mistakes validation

After the builder's implementation commit and stop, render a missing verifier brief with `bin/fm-brief.sh <id> --verifier` and spawn a fresh context on the same task with `--role verifier` using the invocation form owned by `harness-adapters`.
The builder never drives no-mistakes, builder and verifier never share a context, and Firstmate never calls `no-mistakes axi respond` for a worker-owned run.
The verifier owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next decision or outcome.

Once validation starts, route new requirements to follow-up work unless they completely invalidate the work under validation.
Corrections required by accepted intent, the smallest downstream compatibility changes, behavioral tests for an executable contract, and documentation accuracy remain within the task.

Only a current, explicit captain instruction that completely invalidates the work keeps supersession on the same task.
The active verifier must abort through the supported AXI command and confirm the run stopped before replacement begins.
Follow the public `no-mistakes` skill for all `branch_sync.next_action` and synchronization mechanics; use guarded recovery only when the code is `recover_custody`.
Recovery settles custody, not content, so rebuild from the correct pre-invalidation base and exclude obsolete pipeline-fix commits.
Do not hand-edit, commit, restart, or start another validation run while the obsolete run owns the branch.
When the final head is ready, use a fresh verifier context and validate that head exactly once.

Load `ask-user-authority` before deciding an ask-user finding.
If a decision goes to the verifier, send one exact answer naming the decision key, step, action, finding IDs, instructions when needed, and response command; pass `--resolve-key`, require the matching resolved event, forbid `--yes`, and have the verifier process every synchronous return through completion or a new escalation.
Resume fleet supervision after the answer lands.

Judge validation by the current-code-matched run step from `bin/fm-crew-state.sh`, not shell liveness or the last status event.
Running, fixing, and CI remain working; parked approval or fix-review requires the verifier to follow current gate help; passed or checks-passed is complete; failed or cancelled is failure.
If a verifier edits, commits, aborts, or restarts during an active run outside the supersession sequence, steer it back to the gate-response flow.
The verifier reports the PR when CI first becomes green rather than waiting for merge monitoring.
