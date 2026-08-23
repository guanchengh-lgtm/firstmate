# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start adapters in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), [`subagent-guard.md`](subagent-guard.md), and [`project-write-guard.md`](project-write-guard.md).
Claude also registers `AskUserQuestion` PreToolUse hooks for the same `bin/fm-sot-speech-check.sh` helper as this guard's speech predicate and for `bin/fm-owner-invoke-wait-check.sh`; each helper's header owns its PreToolUse path.
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those other guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work, a process-event source, or Relay polling needs supervision at that boundary and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
Separately, the same script refuses ending a turn as prose-only waiting when a ready queued ticket has no worker owner; `bin/fm-turnend-guard.sh`'s header owns that ready-action contract.
The same family refuses a held locked next act with no worker, a tight `OWNER_INVOKE_WAIT` marker on an owner-invoke skill, an owner-invoke node still open after the captain's next message with no matching artifact, and session-scoped durable ship records whose OV review worker is gone without a report or whose report-gated Claude `skills` record never listed plan-eng-review; `bin/fm-owner-invoke-wait-check.sh` owns those rules.
It does not hunt free English. Split transcript windows and live fog gather stay as gather holes.
It also refuses ending a turn on an unchecked yen126/TradingView login or session-death block from a `tradingview-tools` task; that same header owns the session-diagnosis contract.
Before primary scope, it also refuses a Stop that wrote Map 2 spec, tickets, or keep-list files this turn while `bin/fm-spec-compile-check.sh` is red; `bin/fm-spec-compile-stop-check.sh`'s header owns that adapter.
The mid-turn pull warning uses the model-aware supervision verdict described below, while the turn-end guard keeps the PID-strict watcher predicate.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Guard predicates

Before primary scope and before the Codex/Grok `stop_hook_active` allow, the guard runs `bin/fm-spec-compile-stop-check.sh` so a child firstmate worktree that wrote Map 2 spec, tickets, or keep-list files cannot end while the matcher is red.
That adapter's header owns the write window and home derivation from the written path; it never uses `FM_HOME` as an implicit compile or reduce home.

The guard then calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes a plain checkout.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes, and the root's git dir must equal its git common dir.
A leftover marker on a linked worktree does not force-include it.
An unmarked checkout, invalid marker, or linked worktree falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert for supervision because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, before the supervision check, the guard runs `bin/fm-sot-speech-check.sh` against registered file-backed SoT identifiers, then `bin/fm-answer-lock-check.sh` against `data/wf-map2-v2/tickets/*.md`, then refuses an unchecked yen126/TradingView login or session-death block from a `tradingview-tools` task, then refuses a ready queued ticket that still lacks matching `state/<id>.meta` worker ownership, then runs `bin/fm-owner-invoke-wait-check.sh`.
The speech helper's header owns the registry, read window, declared-unread escape, fail-open cases, and residual coverage.
The answer-lock helper's header owns gather, rules, the `## Answer` lock-token seat, the two escapes, and residual coverage.
The owner-invoke helper's header owns held locked-next, the `OWNER_INVOKE_WAIT` marker, owner-node-open one-message-late completion, fog gather, session-scoped ship gather (`session=` matching `state/.lock`), the Stop ladder on `data/<ov>/report.md` then live OV *agent* (not bare pane husk) then refuse, report-gated `data/<ov>/skills` for plan-eng-review only when durable `ov_harness` is claude/claude* (non-Claude or missing harness is a disclosed gap), fail-closed CLI input, and residual coverage. Claude crewmate `settings.local.json` wires absolute-path PostToolUse Skill recording via `bin/fm-skill-load-record.sh`.
`bin/fm-turnend-guard.sh`'s header owns the yen126 session-diagnosis contract and still blocks under Claude `--claude` when `stop_hook_active` is true.
A spawn or steer leaves that metadata; recording a concrete backlog blocker removes the ticket from `tasks-axi ready`.
The ready-action check and the owner-invoke held-locked-next gather fail open when the tasks-axi backend cannot be read, honor `config/backlog-backend=manual`, have no skip flag, and still block under Claude `--claude` when `stop_hook_active` is true.

After those pre-checks, the guard counts in-flight work from `state/*.meta`.
Registered `state/procevent/*.source` records also require supervision even though they have no task metadata.
The default cross-harness mode exits silently with no supervision need.
Every mode treats `state/x-watch.check.sh` as supervision need, so Relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same PID-strict identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`: a stale beacon blocks even when a watcher pid is live, and a fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.
The turn-end guard needs that strict check because it fires at the turn boundary, where the auto-arm is bringing a fresh watcher up for the upcoming idle period, and it cooperates with that arm rather than trusting a beacon left by the cycle that just ended.
`bin/fm-guard.sh`, the pull warning, instead uses the model-aware `fm_watcher_supervision_verdict` from the same library, because it fires mid-turn when the auto-arm model runs no watcher at all.
Under the Claude Stop auto-arm model a beacon fresh within grace is healthy even with no live watcher process, and only a beacon stale beyond grace (or absent) alarms.
Under every persistent-watcher harness a live identity-matched watcher with a fresh beacon is still required, so the pull guard keeps the same strict semantics there.
Its banner names the true failing condition, either a missing live watcher process or a genuinely stale beacon with its real age, and keys the once-per-episode dedup on that condition rather than the beacon mtime.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If hook stdin is empty, the guard exits 0 before any predicate.
If `jq` is missing after the spec compile adapter, the remaining predicates exit 0 because they cannot safely read loop-guard fields.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` or `GROK_HOOK_EVENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.
  Both markers are required because Grok does not inject the same variables into every process kind: grok 0.2.73 set `GROK_AGENT` for child and tool processes, while grok 1.0.0 hook processes carry `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` but no `GROK_AGENT`.
  A guard keyed on `GROK_AGENT` alone therefore stopped firing on grok 1.0.0, and the resulting Claude-only auto-arm ran synchronously under Grok - Grok has no `asyncRewake`, so it waited on the foregrounded watcher for the declared 28800-second timeout and the Grok turn never ended.
  Do NOT widen this guard to `GROK_SESSION_ID`: Grok injects that into every child process, so it can survive into a Claude session that Grok launched and would silently disable Claude's own continuity.
  The same marker guard carries every tracked `.claude/settings.json` entry whose event Grok already covers through its own `.grok/hooks/` registration, which is both `Stop` entries, the `SessionStart` entry, both `AskUserQuestion` PreToolUse entries (SoT-speech and owner-invoke-wait), the `PostToolUse` Skill load recorder, and the two `PreToolUse` Bash entries; the two match-all `PreToolUse` entries are the deliberate unguarded exceptions, because no Grok registration covers the subagent-spawn or project-write events, recorded in [`subagent-guard.md`](subagent-guard.md) and [`project-write-guard.md`](project-write-guard.md) "Known residual gap".
  `tests/fm-turnend-guard.test.sh` pins that inventory (8 grok-guarded entries, 2 unguarded exceptions) so neither the guarded set nor the exception can change silently.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation for every predicate that runs after that allow, including SoT speech, answer-time lock, ready-action, owner-invoke wait, session-diagnosis, and supervision.
The spec compile-check adapter is seated before that allow; see Known residual gap.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live `autoarm` role owner whose eventual failure must exit 2, or `state/.claude-autoarm-epoch` contains a fresh actionable rewake owned by this event epoch.
Fresh `failed` and `failed-suppressed` outcomes enter or advance the failure progression instead of acting as unconditional recovery proof.
The auto-arm itself rechecks the healthy watcher predicate and retries a bounded number of times before reporting a genuine failure.
The first fresh exhausted-failure epoch preserves its handoff without consuming a blocked-stop count, while later fresh failed epochs advance the same monotonic progression instead of resetting it.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override).
In Claude mode, positive watcher recovery clears the block budget, failure notice, and attended alarm together under the existing budget lock before either hook reports ordinary recovery.
The one loud attended fail-open is available only when the auto-arm has recorded an exhausted failure, its one notice is already consumed, the block budget is exhausted, and a final check finds neither a healthy watcher nor an automatic continuation.
Each epoch identity is accounted at most once under the budget lock.
Whenever both coordination locks are needed, positive auto-arm recovery and the terminal check acquire the auto-arm owner lock before the budget lock.
After that alarm, the Stop auto-arm suppresses further exit-2 continuations until positive watcher recovery, so the final fail-open remains reachable.
The alarm cannot repeat during that failure episode, and a later unhealthy stop blocks again.
A positively verified healthy watcher clears the failure notice, alarm, and block budget for a future independent episode.
A Claude failure notice describes the automatic mechanism as broken and does not direct a routine manual background arm.

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

Grok makes exactly one typed capability decision from each running Stop payload.
A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
The camel-case field has precedence when both spellings appear; when it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`; genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child crewmate and scout worktrees are outside supervision scope. The spec compile-check adapter is the exception; its header owns that seat.
- A valid secondmate home is in scope; an idle secondmate endpoint with no Relay poll remains healthy because it has no supervision need.
- The direct-blocking and bounded passive-follow-up split is limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Known residual gap

The spec compile-check Stop adapter is inert on Pi, OpenCode, and pi-signed primaries because those adapters feed the guard `{"stop_hook_active":false}` with no transcript path.
It also cannot see writes that are not a Stop (an editor save or `git checkout`) or Bash writes through variables or `cd` that leave no literal `data/wf-map2-loops/`, `data/decisions/`, or cited `data/<id>/report.md` suffix in the command string.
On Codex and Grok default mode it also runs before the `stop_hook_active` / `stopHookActive` allow, so a still-red this-turn write can exit 2 again on the bounded continuation and break that harness's never-block-twice loop contract until the matcher is green or the write leaves the this-turn window.
`bin/fm-spec-compile-stop-check.sh`'s header owns the write-window residual; `bin/fm-turnend-guard.sh`'s header owns the pre-loop-guard seat.

The same adapter refuses a declared wide-work count miss when a this-turn write to the spec, a Map 2 ticket, or `data/decisions/<name>.md` carries an `expected-reports:` line and `bin/fm-reduce-check.sh` is red.
N is the id list firstmate wrote at dispatch; the matcher never waits for reports and never reads `FM_HOME`.
It cannot catch a wrong or absent declaration, a cited-but-unread report, harness-internal fan-outs that drop a failed child with no file, non-Map-2 synthesis that never writes those paths, or Pi / OpenCode / pi-signed primaries with no transcript.
A scout declared `id(failed: reason)` is an explicit escape, not a finding.
`bin/fm-spec-compile-stop-check.sh`'s header owns that write window and the child-path home derivation.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, leftover-marker inertness on a linked worktree, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the ready-action refusal for ownerless queued tickets, every-ready-id checking, matching-worker acceptance, Claude `stop_hook_active` non-bypass of ready-action, answer-time lock refuse after primary scope, its Codex loop-guard allow, Claude non-bypass, crewmate inertness, held locked-next and owner-invoke yes-ask refusals, the TradingView session-diagnosis refusal for missing evidence and failing checker findings, passing-checker acceptance, unrelated-blocker negative controls, Claude `stop_hook_active` non-bypass of that session gate, the live-lock and fresh-beacon guard predicate, the cooperative `--claude` claim wait, monotonic failed-epoch progression, bounded attended fail-open, post-alarm continuation suppression, positive recovery reset, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
`tests/fm-answer-lock-check.test.sh` covers the Map 2 answer-time lock matcher rules, `## Answer` lock-token seat, undated close, pick-still-open, and absent-gather inertness.
`tests/fm-spec-compile-stop-check.test.sh` covers the Stop adapter's this-turn write window, path-derived home, child-worktree seat before primary-scope, no-write and no-transcript inertness, red compile refuse, and reduce `expected-reports` refuse.
`tests/fm-owner-invoke-wait-check.test.sh` covers the helper's fail-closed input, exact-count fixtures, held locked-next, owner-invoke yes-ask, owner-node-open one-message-late refusal, same-turn owner-node acceptance, fog-pin wait, session-scoped ship gather, live-agent-no-report pass, husk-pane-without-report refuse, torn-down worker with report, report-gated Claude skills refusal, finished non-Claude review without skills pass, skill-load recorder normalization, crewmate Skill PostToolUse wiring, current-turn skill-load scoping, and invoked-skill acceptance.
`tests/fm-reduce-check.test.sh` covers the reduce matcher directly.
`tests/fm-guard-stale-banner.test.sh` covers the pull-guard predicate, including the persistent-model fresh-leftover-beacon negative control, the auto-arm model's healthy fresh-beacon-without-a-watcher case and its stale-beacon alarm, the true-reason banner wording, and the reason-keyed episode dedup surviving a beacon mtime change.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
