# AGENTS.md A1 line-removal evidence

Validated target commit `59b4fe9309e87bf2d3f7643b842bec71ef9bbeb2` against base `4771877e3ca95de1044ea3359585c11a2819b0a0`.

## Changed paths and counts

Command:

```text
git diff --numstat 4771877e3ca95de1044ea3359585c11a2819b0a0..59b4fe9309e87bf2d3f7643b842bec71ef9bbeb2
```

Output:

```text
0	1	AGENTS.md
```

No paths were returned by the corresponding changed-test-path query. A focused diff query for `.agents/skills/diagnostic-reasoning/SKILL.md` was also empty.

## Reviewer-visible instruction diff

Command:

```text
git diff --no-ext-diff --unified=3 4771877e3ca95de1044ea3359585c11a2819b0a0..59b4fe9309e87bf2d3f7643b842bec71ef9bbeb2 -- AGENTS.md
```

Output:

```diff
diff --git a/AGENTS.md b/AGENTS.md
index 613bd79..5690d06 100644
--- a/AGENTS.md
+++ b/AGENTS.md
@@ -120,7 +120,6 @@ Classify the deliverable:
 - **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.
 
 If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
-A report, recommendation, or finding alone is not a go to change code; a lock that already names the change is.
 Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.
 
 Resolve every ship task's concrete delivery mode and yolo posture at intake, and pass both explicitly to the brief, the spawn, and any scout promotion, which all refuse to guess.
```

## Current instruction surface

Command:

```text
nl -ba AGENTS.md | sed -n '118,127p'
```

Output:

```text
   118
   119	- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
   120	- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.
   121
   122	If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
   123	Load `diagnostic-reasoning` before scoping a reported bug and before acting on a diagnostic report.
   124
   125	Resolve every ship task's concrete delivery mode and yolo posture at intake, and pass both explicitly to the brief, the spawn, and any scout promotion, which all refuse to guess.
   126	A ship spawn also requires explicit `--role` (`builder` at first dispatch; `verifier` only for the no-mistakes second context) and refuses an omitted role rather than defaulting it; script headers own the role/mode marker gate.
   127	A current explicit captain instruction wins; otherwise the project's registry entry is the captain's standing posture, and dropping below its rigor needs a reason you can state.
```

This shows the requested sentence removed with no replacement, while the existing line 122 remains intact.

## Manufactured-breakage applicability and clean state

The branch changes no test files, so the required per-test-file mutation loop has no members.

Final command:

```text
git status --porcelain=v1
```

Output was empty.
