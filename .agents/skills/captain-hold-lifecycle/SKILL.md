---
name: captain-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain calls, and for closing what the captain owns with his actual words.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, and on any RECORD DIVERGENCE line the wake drain prints.
user-invocable: false
metadata:
  internal: true
---

# Captain-hold lifecycle

A decision is not a separate thing: it is simply a task waiting on the captain.
The one primitive is an ordinary backlog task held for the captain (`tasks-axi hold <id> --kind captain`), its identity is the task id, and `bin/fm-captain-hold.sh` owns the deterministic mechanics this policy relies on.
The same completion gate inventories unscheduled product ideas in the originating home's `data/product-ideas.md`.
The agent performs both semantic inventories because scripts must not infer captain calls or ideas from report prose, visual-review artifacts, terminal output, or chat.

## Policy

Every unresolved question that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must be carried by a captain-held task in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
Put the question and its options in the hold reason, and keep one held task per genuine gate: a multi-question review is one held task pointing at its report, not a row per question. Represent that task with exactly one board card that consolidates its questions and options; never fan one task id into duplicate same-key cards.
Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
Every product idea, feature proposal, or strategic suggestion not yet scheduled as work must become a well-formed home-local `PI-NNN` row whose Source names its report section, never a line number.
After inventorying the whole report and review surface, run `bin/fm-captain-hold.sh complete` with every captain-held task id, or with `--none` only when the reviewed surface leaves nothing waiting on the captain, plus exactly one idea attestation: `--ideas <PI-id>...` or `--no-ideas`.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; secondmate-owned work registers in that secondmate home's backlog, and a question already held anywhere is never re-registered as a second row.
Do not close a captain-held task merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.

Never close anything the captain owns without recording what he actually said: `bin/fm-captain-hold.sh answer` writes his exact words into the task and closes it in the same act, with `--release` when the answer frees a captain-gated work item to proceed instead of completing a question.
A later durable decision record and already-Done ship may instead supersede an older still-open captain call, but only through `bin/fm-captain-hold.sh supersede` with that exact held task id, one ordinary decision record under `data/decisions/`, and the exact shipped task.
Session recovery and deterministic checks read `bin/fm-captain-hold.sh state`; unkeyed chat is never authoritative captain-call state.
When the captain says "later", that is an answer too: re-hold with `tasks-axi hold <id> ... --until <date>` so the item leaves the live Captain's Call and resurfaces on its date, instead of leaving a live-looking card or fabricating a closure.
"A keyed answer closes its matching captain-held task" is one capability with one owner, `bin/fm-captain-hold.sh answers`, and every channel that carries a captain answer feeds it the same task id and answer; a channel never maps keys to tasks, records a decision, or closes anything itself.
Chat already feeds it through `bin/fm-send.sh --resolve-key`, and a captured-answer source feeds it once bound with `bin/fm-captain-hold.sh bind <source-id>`; bind before arming the source, and key each structured question by the held task's id.
An unbound source and a key that names no captain-held task both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the direct command above.
A captain-held task closed outside this owner leaves no durable answer, so the completion gate keeps failing until `answer` records the decision the captain actually gave.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

A captain call can be written down twice - as the keyed status decision the fold reads, and as the backlog task held for the captain - and those two records can disagree without either surface saying so.
`bin/fm-captain-hold.sh diverged` reports that contradiction and the wake drain prints it as `RECORD DIVERGENCE`; it closes nothing, because a captain call closed wrongly leaves review entirely, which is worse than the noise.
Read such a line as "these two records disagree", never as "the captain ruled and someone forgot to file it": a call can dissolve because its premise was false, or turn out to have been a question of fact rather than the captain's to answer.
Reconcile it with what actually happened - `answer` when the captain's own words exist to record, and a fresh `needs-decision` line re-opening the status decision when that resolution was not the captain's word.
The absence of a routed work item is not a divergence and the guard never requires one: when the decision IS the deliverable there is nothing to route.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain, find the task each one gates, and inventory unscheduled product ideas that need durable discovery.
3. Hold that task - or create one captain-held task for the review's open questions - with a concise reason carrying the question and options.
4. Append each idea to `data/product-ideas.md` with a `data/<origin-id>/report.md#<section-heading>` Source.
5. Run `complete` with the full captain-held inventory and exactly one idea attestation for that review pass.
6. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
7. Close each call only through `answer` (or a channel that feeds `answers`), through `--until` when the captain defers it, or through `supersede` when later shipped authority already replaced it.
8. Confirm Bearings reflects the outcome: answered and superseded calls leave Captain's Call, released work resumes, and deferred calls sit in Charted Next with their date.

`bin/fm-captain-hold.sh --help` owns command syntax, close modes, legacy-identity compatibility, decision and idea completion attestation, retry behavior, supersession binding, state resolution, and close ordering.
`docs/captain-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
