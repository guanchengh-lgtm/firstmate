# Project-write guard

This document is the authoritative human-readable contract for the guard that stops a firstmate primary from editing project files with its own file tools.

The shipped mechanism is `bin/fm-project-write-pretool-check.sh`, a PreToolUse guard that denies a file-MODIFYING tool call in a genuine primary home when its target resolves under the home's `projects/` directory or under any live task worktree recorded in `state/*.meta`.
`bin/fm-project-write-grant.sh` carries the one exception: the concrete captain-approved project operation that `AGENTS.md` hard rule 1 defines.

## Why this exists

`AGENTS.md` hard rule 1 is "never write to a project": firstmate reads projects and crewmates change them.
Until this change that rule was entirely self-attested, and so was the `dispatch-not-self` routine written to reinforce it.
Three violations of the class landed in a single session, including one while the reinforcing checklist was itself being written.

The decay modes are structural rather than careless.
A checklist whose read is triggered by remembering it exists cannot catch the moment of not-remembering, which is exactly the moment the primary decides to "just do it".
Long sessions summarize away the pointers that carry the routine.
A small ask ("fix that typo in project X") is the cheapest thing to misclassify as too trivial to dispatch.
Every one of those failures ends at the same mechanical event: a file-modification tool call whose target is inside a project clone.
That event has a signal, so it can be refused rather than remembered.

## Purpose and boundary

The guard addresses one concrete, mechanically identifiable event: the primary session about to modify a file it does not own.

It says nothing about whether the work should have been dispatched, whether the brief is any good, or whether the delivery mode is right.
Those are judgment boundaries with no tool-shape signal.
The scope line is: wrong hands on the file, deny; wrong thinking before reaching for the file, out of scope.

## The predicate

A call is denied when all of these hold.

1. The home is a genuine firstmate primary, by the shared `fm_primary_scope_matches` predicate.
2. The tool name is write-shaped.
3. A path field in the payload resolves under a protected root.
4. No valid grant covers that resolved path.

### Deny, never allow, from durable task state

The deny set is unconditional.
An open task on a project is **not** a reason to let the primary write into that project's clone, and durable task state is used only to widen the protected set.

That inversion is load-bearing, because the obvious-looking rule ("allow if a matching spawned task exists") has no sound meaning here.
`bin/fm-spawn.sh` refuses a worktree that equals a project clone, and treehouse and Orca both hand a crewmate a worktree elsewhere, so a crewmate's writes never happen inside `projects/` at all.
A live task can therefore never make a firstmate write inside the clone correct.
Worse, such a clause would disarm the guard for exactly as long as the fleet is busy, which is the common case.

Recorded `worktree=` paths become protected roots instead.
A primary file-editing a running worker's worktree is the same self-implementation class plus a supervision hazard, and a `kind=secondmate` record protects that secondmate's whole home, whose legitimate inbound paths are all guarded Bash.
A record whose `worktree=` is the active home itself is skipped: honoring it would lock the home out of its own `data/` and `state/`, which is far worse than the case it would catch.
Only the active home's `state/` is read, never a shared namespace.

### Write-shaped tool names

The tool name is normalized to lowercase alphanumerics and matched against these stems:

```text
write  edit  patch  notebook  create  replace  insert
append  delete  remove  rename  move  copy
```

This is shape classification rather than a fixed inventory, for the same reason the delegation guard classifies by shape: a write tool that ships before anyone updates a list must still be caught.
The tracked Claude matcher is `.*` so every tool name reaches the script, which is the single owner of classification.

Two exclusions keep the shape test honest.

- A name beginning `mcp__` is never classified, because an MCP server's payload shape is unknown here.
  This is a real residual gap, not a false-positive avoidance: see "Out of scope".
- `READ_ONLY_TOOLS`: the exact names `notebookread` and `readnotebook` are allowed.
  Firstmate reads project clones constantly and that half of hard rule 1 must stay untouched, so a read tool whose name happens to carry a write stem must pass.
  The exclusion matches the whole normalized name, never a substring, so `NotebookEdit` and `NotebookReadAndPatch` stay denied.

A write-shaped call carrying no path field is allowed: there is nothing to resolve against a protected root.

### Path resolution

Path fields read from the payload are `file_path`, `notebook_path`, `path`, `filePath`, `notebookPath`, `target_file`, `file`, `old_path`, and `new_path`, under `tool_input` or `toolInput`.
Any one of them resolving under a protected root denies the call.

A `Write` target usually does not exist yet, so resolution walks up to the nearest existing directory, resolves that with `cd`/`pwd -P`, and re-appends the remainder.
This settles relative paths, `..` inside the existing prefix, and symlinks: a symlink pointing into a clone resolves into the clone and is denied.
A `..` that appears only in the non-existent tail is left lexically in place, so a path that still reads as being under a protected root is treated as being under it.
That conservative reading costs nothing real, because the primary has no legitimate file-tool write under a protected root at all.

## Hard-rule-1 exception

`AGENTS.md` hard rule 1 says the concrete captain-approved project operation is performed "with its own file tools", so the guard must have a passable path or it breaks a documented contract.

The captain chose a logged one-shot grant over a launch-time environment variable.
`bin/fm-project-write-grant.sh <path> --reason '<captain instruction>'` writes a record under `state/` that the guard consumes on the next matching call.
A grant is path-scoped, single-use, and short-lived (600s by default, 3600s maximum), and every issue, consumption, and revoke appends a line to `state/.project-write-grant.log`.
The grant script refuses a path outside every protected root, a bare protected root, a missing or too-short reason, and a TTL beyond the maximum, and it refuses to write a record at all where the guard is inert.

This is deliberate-and-audited, not unforgeable.
A drifting firstmate can run the grant script without a real approval, exactly as it can run any other script.
The alternative - an environment variable that only a session restart can set - would be unforgeable in-session, but hard-rule-1 approvals are given in the moment, mid-session.
Forcing a restart to honor one destroys conversation context, punishes exactly the sanctioned flow, and creates pressure to route around the guard through Bash.
The threat model of this guard family is agent mistakes, not adversarial agents, and an explicit grant naming the path and quoting the instruction cannot happen absently.

The guarded script paths - project initialization, fleet sync, secondmate sync and inherited-material push, self-update, and the approved `local-only` merge - need no allowlist.
Every clone write on those paths runs through git or other Bash commands, which a file-tool hook never sees.

## Scope

The guard fires only in a genuine firstmate primary home, using `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh` - the same predicate `bin/fm-subagent-pretool-check.sh`, `bin/fm-sessionstart-nudge.sh`, and `bin/fm-turnend-guard.sh` use, so the primary-scoped hooks cannot drift apart.

A marked secondmate home is in scope: it operates its own fleet and must not write its own `projects/` either.
A crewmate's disposable task worktree is a linked worktree, so the guard is inert there even when a leftover `.fm-secondmate-home` marker is present - a crewmate editing project files in its own worktree is the entire point of dispatch.
A non-firstmate repo is out of scope.
Any failure to confirm the home is inert, never a block.

The protected `projects/` directory is the **active** home's, resolved as `${FM_HOME:-<code root>}/projects`, so a secondmate home protects its own clone tree rather than the main home's.

## Out of scope

This guard fences the highest-value slice of hard rule 1, not the whole rule.
Stating the gaps is part of the contract, because a check that overclaims its coverage is the recurring trap in this defect class.

1. **Bash-mediated writes** - `tee`, `sed -i`, heredocs, `cp`, `git -C projects/… commit`.
   Argv path analysis cannot separate read from write per command, and the natural *mistake* path for self-implementation is the harness's file tools.
   Funnelling writes through Bash to evade the guard is evasion rather than drift, which is outside this family's threat model.
   Tripwire: if a real self-implementation instance lands through Bash after this ships, revisit with a narrow classifier on the shared arm-policy lexer.
2. **Self-done deliverables under `data/`** - `data/` is legitimately firstmate-writable, and no mechanical predicate separates a legitimate home record from a deliverable that should have been dispatched.
3. **Firstmate-repo self-implementation** - editing this repo's own tracked surface is legitimate when the fleet is empty (`AGENTS.md` section 1), and a path hook cannot read fleet intent.
4. **MCP write tools** - never classified, because payload shapes are server-defined.
   The residual risk is concrete: an MCP filesystem server could write into a clone and this guard would not see it.
   A Claude primary that runs such a server should deny those tools locally.
5. **Another home's project tree** - the predicate is the active home's `projects/`.
   A main-home primary has no business under another home's tree at all, and `secondmate-provisioning` owns the legitimate push paths, which are Bash.
6. **Dispatch quality** - whether the brief, project, or delivery mode is right is unchanged judgment territory.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[project-write] ..."}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[project-write] ..."}` to stdout for Grok.
- `--claude` suppresses stdout completely, because Claude Code ignores a PreToolUse deny when stdout is nonempty.
  This is the same verified quirk recorded in [`arm-pretool-check.md`](arm-pretool-check.md), and the tracked Claude hook therefore passes `--claude`.
- Malformed or empty stdin, invalid JSON, a payload with no tool name or no path, and missing `jq` for stdin transport all fail open with exit 0 and no output.

The deny message names the resolved target, the protected root it fell under, the blocked tool and the stem that classified it, the real route (`bin/fm-brief.sh` then `bin/fm-spawn.sh` for a clone; `bin/fm-send.sh` to steer the owner of a live worktree), and the grant command for a captain-approved concrete operation.
When a grant existed but did not apply, the message says whether it had expired or covered a different path, so an approved operation is not mistaken for a hard refusal.

## Harness wiring

| Harness | Wiring | Status |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse, matcher `.*`, `--claude` | Wired. Reads `.tool_name` plus `tool_input` path fields. |
| Codex | none | Inspected, not wired. Its file-modification surface is `apply_patch`, and `.codex/hooks.json` forwards `Bash` only. Payload shape unverified, see below. |
| Grok | none | Inspected, not wired. `.grok/hooks/*.json` use a `PreToolUse` matcher, currently `Bash`. Payload shape unverified, see below. |
| OpenCode | none | Inspected, not wired. `.opencode/plugins/fm-primary-pretool-check.js` gates on `input?.tool !== "bash"` and reads `.command` only. |
| Pi / pi-signed | none | Inspected, not wired. `.pi/extensions/fm-primary-turnend-guard.ts` gates on `event.toolName !== "bash"` and reads `.command` only. |

Codex, Grok, and Pi are installed on the host where this work was done, and their write-tool payload shapes were still not established, so none of them is wired.
Codex 0.147.0-alpha.6.5 and grok 1.0.0 were both driven headless in a scratch project carrying a payload-logging `PreToolUse` hook.
Each harness created the requested file, and the hook logged nothing.
The control run is what makes this inconclusive rather than a finding: re-running with the same `Bash` matcher the repo's own tracked entries use, against an ordinary shell command, also logged nothing, so the headless probe never exercised the hook path at all and proves nothing about the harness's real payload.
Pi 0.84.0 was not probed: its integration is an extension rather than a JSON hook, and the same unproven-harness problem applies to a headless run.
OpenCode is not installed here.

This repo's rule is that a harness hook must be validated against the real harness before it is trusted, and [`arm-pretool-check.md`](arm-pretool-check.md) records the concrete cost of guessing: a hook whose command string is even slightly wrong fails to launch at all.
Wiring an unvalidated matcher would trade a known gap for an unknown breakage.

The bounded follow-up is identical for each: in a real interactive session of that harness, confirm a payload-logging pre-tool hook fires at all, then read the tool name and path field it delivers for a file write, then forward both to this script.
`bin/fm-project-write-pretool-check.sh` needs no change for any of them.
It already accepts Grok's stdin shape, already emits the Grok stdout decision object by default, and already accepts the `--tool`/`--path` CLI form that OpenCode's plugin and Pi's extension would use.

Until that lands, those harnesses are covered by the routine and by `AGENTS.md` hard rule 1 alone, exactly as every harness was before this change.

### Known residual gap

Grok loads Claude-compatible settings, so most tracked `.claude/settings.json` entries refuse to run under Grok to avoid a duplicate path with `.grok/hooks/`.
This entry is deliberately unguarded, for the same reason as the delegation guard's: Grok has no counterpart registration for this event, so guarding it would remove the guard from Grok entirely rather than deduplicate it.
The reach it leaves is partial rather than correct - the tracked entry passes `--claude`, which suppresses exactly the stdout decision object Grok consumes - so treat it as incidental reach, not as Grok being wired.
`tests/fm-turnend-guard.test.sh` pins both documented exceptions so neither can be closed silently.

## Optional local hardening

A Claude primary may additionally deny the write tools by path in untracked per-home local settings:

```json
{
  "permissions": {
    "deny": ["Write(projects/**)", "Edit(projects/**)", "NotebookEdit(projects/**)"]
  }
}
```

Removal from the schema beats interception, so this is strictly stronger where it applies.
It is not tracked and not a substitute for the hook: it is Claude-only, it is fail-open by enumeration against future tool names, it cannot express the one-shot grant exception, and a tracked `.claude/settings.json` `permissions` block propagates into linked worktrees where it would disarm legitimate crewmates.

## Automated validation

`tests/fm-project-write-pretool-check.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
It covers the match-all tracked Claude registration; denial of every current and hypothetical write-shaped tool inside a clone; the read-tool and MCP exclusions and the exactness of the read-only exclusion against four near-miss names; allowance of writes under `data/`, `state/`, and the repo's own tracked surface; relative, `..`, symlink, and not-yet-existing target resolution; the `worktree=` deny extension including a secondmate home and the home-self skip; inertness in a linked task worktree and a non-firstmate repo; in-scope enforcement for a marked secondmate home; all three stdin shapes and the CLI form; the empty-stdout requirement; fail-open transport behavior; and the full grant lifecycle (refusals, one-shot consumption, prefix scoping, expiry, show, revoke, and inert-home refusal).

Run:

```sh
bash -n bin/fm-project-write-pretool-check.sh
bin/fm-lint.sh
tests/fm-project-write-pretool-check.test.sh
tests/fm-turnend-guard.test.sh
```
