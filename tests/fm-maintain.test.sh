#!/usr/bin/env bash
# Behavior tests for bin/fm-maintain.py through the public executable.
# Fixture Records are scratch directories under the test tmp root; the ones
# that need an age source are git repositories with pinned commit dates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAINTAIN="$ROOT/bin/fm-maintain.py"
TMP_ROOT=$(fm_test_tmproot fm-maintain)
OUTER_STATUS_BEFORE=$(git -C "$ROOT" status --short --untracked-files=all)
fm_git_identity fmtest fmtest@example.invalid

NOW=2026-09-15T03:00:00Z
NOW_LATER=2026-09-15T05:00:00Z
MIDNIGHT=2026-09-15T00:00:00Z

run_maint() {
  set +e
  OUT=$(python3 "$MAINTAIN" "$@" 2>&1)
  RC=$?
  set -e
}

capture_lint() { # <out-file> <args...>
  local out=$1
  shift
  set +e
  python3 "$MAINTAIN" lint --format json "$@" > "$out" 2>/dev/null
  LINT_RC=$?
  set -e
}

new_record() { # <name> -> echoes the Record root
  local name=$1 rec
  rec="$TMP_ROOT/$name"
  mkdir -p "$rec"
  printf '%s\n' '# backlog' > "$rec/backlog.md"
  printf '%s\n' '# captain' > "$rec/captain.md"
  printf '%s\n' '# learnings' > "$rec/learnings.md"
  printf '%s\n' "$rec"
}

clean_record() { # <name> -> echoes a Record whose lint is clean
  local rec
  rec=$(new_record "$1")
  printf '%s\n' '- [ ] t-clean - ship the queued change' >> "$rec/backlog.md"
  printf '%s\n' '- Captain merges only green PRs (dated 2026-01-01)' >> "$rec/captain.md"
  printf '%s\n' '- The fleet reads AGENTS.md first [timeless]' >> "$rec/learnings.md"
  git -C "$rec" init -q --initial-branch=main
  printf '%s\n' "$rec"
}

commit_at() { # <repo> <git-date> <message>
  git -C "$1" add -A
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git -C "$1" commit -q -m "$3"
}

sha256_of() { # <file>
  python3 -c 'import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

json_at() { # <file> <dotted-path>
  python3 - "$1" "$2" <<'PY'
import json
import sys

node = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    node = node[int(key)] if isinstance(node, list) else node[key]
print(json.dumps(node, sort_keys=True))
PY
}

test_inputs_are_strict_about_now_and_record() {
  local rec
  rec=$(clean_record strict-inputs)
  run_maint lint --record "$rec" --now 2026-09-15
  expect_code 2 "$RC" 'bare day --now'
  assert_contains "$OUT" 'RFC3339 UTC' 'bare day --now message'
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail '--now error is one line'
  run_maint lint --record "$rec" --now '2026-09-15T03:00:00+00:00'
  expect_code 2 "$RC" 'offset --now'
  run_maint lint --record "$rec" --now "$NOW" --format json --rules R9
  expect_code 2 "$RC" 'unknown rule id'
  assert_contains "$OUT" 'unknown rule id: R9' 'unknown rule message'
  run_maint lint --record relative/path --now "$NOW"
  expect_code 2 "$RC" 'relative --record'
  run_maint lint --record "$rec/absent" --now "$NOW"
  expect_code 2 "$RC" 'missing Record'
  mkdir -p "$rec/not-a-record"
  run_maint lint --record "$rec/not-a-record" --now "$NOW"
  expect_code 2 "$RC" 'directory without backlog.md'
  assert_contains "$OUT" 'no backlog.md' 'missing backlog message'
  chmod 000 "$rec/captain.md"
  run_maint lint --record "$rec" --now "$NOW"
  chmod 644 "$rec/captain.md"
  expect_code 2 "$RC" 'unreadable owner file'
  assert_contains "$OUT" 'cannot read' 'unreadable owner file message'
  run_maint lint --record "$rec"
  expect_code 2 "$RC" 'missing --now'
  run_maint lint --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'clean Record lint'
  assert_contains "$OUT" 'summary: finding=0 unknown=0' 'clean Record summary'
  pass 'fm-maintain: --now and --record are validated before any rule runs'
}

test_r1_binds_a_deferral_to_a_hold_and_evaluator() {
  local rec
  rec=$(new_record r1)
  cat >> "$rec/backlog.md" <<'EOF'
- [ ] t-bound - ship it (hold: the audit lands) (evaluator crew)
- [ ] t-colon - later, once ready (hold: the audit lands) evaluator: crew
- [ ] t-nohold - pending a decision
- [ ] t-noeval - later, once ready (hold: the audit lands)
- [ ] t-quoted - the row says `later` and "pending" only in quotes
- [x] t-done - shipped, pending nothing
- [ ] t-cont - ship it later
  hold: the audit lands (evaluator crew)
- [ ] t-apos - we can't ship this later, it's blocked
EOF
  run_maint lint --record "$rec" --now "$NOW" --rules R1
  expect_code 1 "$RC" 'R1 lint'
  assert_contains "$OUT" 'R1 finding backlog.md:4 deferral-without-hold' 'R1 no hold'
  assert_contains "$OUT" 'R1 finding backlog.md:10 deferral-without-hold' 'R1 apostrophes are not quotes'
  assert_contains "$OUT" 'R1 finding backlog.md:5 hold-without-evaluator' 'R1 no evaluator'
  assert_contains "$OUT" 'R1 unknown backlog.md:6 deferral-word-in-quote' 'R1 quoted'
  assert_not_contains "$OUT" 'backlog.md:2' 'R1 bound row passes'
  assert_not_contains "$OUT" 'backlog.md:3' 'R1 evaluator colon form passes'
  assert_not_contains "$OUT" 'backlog.md:7' 'R1 done row passes'
  assert_not_contains "$OUT" 'backlog.md:8' 'R1 continuation line binds the row'
  assert_contains "$OUT" 'summary: finding=3 unknown=1 acknowledged=0 pass=4' 'R1 summary'
  pass 'fm-maintain: R1 separates bound deferrals, missing evaluators, and quotes'
}

test_r2_age_threshold_is_exact_at_fourteen_days() {
  local rec
  rec=$(new_record r2-age)
  git -C "$rec" init -q --initial-branch=main
  mkdir -p "$rec/over" "$rec/exact" "$rec/reported"
  printf 'brief\n' > "$rec/over/brief.md"
  commit_at "$rec" 2026-08-31T23:59:59Z 'add over'
  printf 'brief\n' > "$rec/exact/brief.md"
  commit_at "$rec" 2026-09-01T00:00:00Z 'add exact'
  printf 'brief\n' > "$rec/reported/brief.md"
  printf 'outcome\n' > "$rec/reported/report.md"
  commit_at "$rec" 2026-08-01T00:00:00Z 'add reported'
  run_maint lint --record "$rec" --now "$MIDNIGHT" --rules R2
  expect_code 1 "$RC" 'R2 lint'
  assert_contains "$OUT" 'R2 finding over/brief.md brief-without-report' 'R2 over 14 days'
  assert_not_contains "$OUT" 'exact/brief.md' 'R2 exactly 14 days passes'
  assert_not_contains "$OUT" 'reported/brief.md' 'R2 reported task passes'
  assert_contains "$OUT" 'summary: finding=1 unknown=0 acknowledged=0 pass=2' 'R2 summary'
  pass 'fm-maintain: R2 flags a brief only once dispatch is strictly over 14 days'
}

test_r2_reports_unknown_age_without_a_durable_source() {
  local rec
  rec=$(new_record r2-unknown)
  mkdir -p "$rec/nogit" "$rec/launched" "$rec/mirrored" "$rec/.record-state"
  printf 'brief\n' > "$rec/nogit/brief.md"
  printf 'brief\n' > "$rec/launched/brief.md"
  printf '{"launched_at": "2026-01-02T00:00:00Z"}\n' > "$rec/launched/launch.json"
  printf 'brief\n' > "$rec/mirrored/brief.md"
  printf 'launched_at=2026-09-14T00:00:00Z\n' > "$rec/.record-state/mirrored.meta"
  mkdir -p "$rec/millis" "$rec/boolean"
  printf 'brief\n' > "$rec/millis/brief.md"
  printf '{"launched_at": 1000000000000000}\n' > "$rec/millis/launch.json"
  printf 'brief\n' > "$rec/boolean/brief.md"
  printf '{"launched_at": true}\n' > "$rec/boolean/launch.json"
  run_maint lint --record "$rec" --now "$NOW" --rules R2
  expect_code 1 "$RC" 'R2 unknown lint'
  assert_contains "$OUT" 'R2 unknown nogit/brief.md age-unknown' 'R2 unknown age'
  assert_contains "$OUT" 'R2 unknown boolean/brief.md age-unknown' 'R2 boolean launched_at is unknown'
  assert_contains "$OUT" 'R2 unknown millis/brief.md age-unknown' 'R2 out-of-range epoch is unknown'
  assert_contains "$OUT" 'R2 finding launched/brief.md brief-without-report' 'R2 launch.json age'
  assert_not_contains "$OUT" 'mirrored/brief.md' 'R2 mirrored meta age is fresh'
  pass 'fm-maintain: R2 reads durable dispatch times and reports unknown age'
}

test_r2_sidecar_binds_the_acknowledgement_to_the_brief_bytes() {
  local rec
  rec=$(new_record r2-sidecar)
  mkdir -p "$rec/ack" "$rec/unbound"
  printf 'brief\n' > "$rec/ack/brief.md"
  printf 'brief\n' > "$rec/unbound/brief.md"
  printf '{"launched_at": "2026-01-02T00:00:00Z"}\n' > "$rec/ack/launch.json"
  printf '{"launched_at": "2026-01-02T00:00:00Z"}\n' > "$rec/unbound/launch.json"
  printf 'dispatched, never reported\nbrief-sha256: %s\n' \
    "$(sha256_of "$rec/ack/brief.md")" > "$rec/ack/status"
  printf 'dispatched, never reported\n' > "$rec/unbound/status"
  run_maint lint --record "$rec" --now "$NOW" --rules R2
  expect_code 1 "$RC" 'R2 sidecar lint'
  assert_contains "$OUT" 'R2 acknowledged ack/status sidecar-acknowledged' 'R2 bound sidecar'
  assert_contains "$OUT" 'R2 finding unbound/status sidecar-unbound' 'R2 sidecar without hash'
  printf 'brief changed\n' >> "$rec/ack/brief.md"
  run_maint lint --record "$rec" --now "$NOW" --rules R2
  expect_code 1 "$RC" 'R2 changed brief lint'
  assert_contains "$OUT" 'R2 finding ack/status sidecar-brief-changed' 'R2 brief changed'
  pass 'fm-maintain: R2 acknowledges a sidecar only while its brief hash holds'
}

test_r2_brief_mtime_does_not_change_a_verdict() {
  local rec before after
  rec=$(new_record r2-mtime)
  git -C "$rec" init -q --initial-branch=main
  mkdir -p "$rec/old" "$rec/fresh"
  printf 'brief\n' > "$rec/old/brief.md"
  commit_at "$rec" 2026-08-01T00:00:00Z 'add old'
  printf 'brief\n' > "$rec/fresh/brief.md"
  commit_at "$rec" 2026-09-14T00:00:00Z 'add fresh'
  capture_lint "$rec/before.json" --record "$rec" --now "$NOW" --rules R2
  expect_code 1 "$LINT_RC" 'R2 mtime baseline lint'
  touch -t 203001010000 "$rec/old/brief.md" "$rec/fresh/brief.md"
  capture_lint "$rec/after.json" --record "$rec" --now "$NOW" --rules R2
  expect_code 1 "$LINT_RC" 'R2 mtime rerun lint'
  before=$(json_at "$rec/before.json" results)
  after=$(json_at "$rec/after.json" results)
  [ "$before" = "$after" ] || fail 'touching a brief changed the R2 verdict'
  assert_grep 'brief-without-report' "$rec/after.json" 'R2 still flags the old brief'
  pass 'fm-maintain: touching a brief mtime leaves every R2 verdict identical'
}

test_r3_classifies_every_twin_pointer_state() {
  local rec
  rec=$(new_record r3)
  mkdir -p "$rec/alpha" "$rec/alpha-nm" "$rec/beta" "$rec/beta-verify" \
    "$rec/gamma" "$rec/gamma-fable" "$rec/delta" "$rec/delta-nm" \
    "$rec/eps" "$rec/eps-nm" "$rec/zeta" "$rec/zeta-nm" "$rec/eta" "$rec/eta-nm" \
    "$rec/theta" "$rec/theta-nm"
  printf 'outside\n' > "$TMP_ROOT/outside.md"
  printf 'review\n' > "$rec/alpha/report.md"
  printf '[review](../alpha/report.md)\n' > "$rec/alpha-nm/POINTER.md"
  printf 'review\n' > "$rec/beta/report.md"
  printf '[review](../beta/missing.md)\n' > "$rec/beta-verify/POINTER.md"
  printf 'review\n' > "$rec/gamma/report.md"
  printf '[review](../../outside.md)\n' > "$rec/gamma-fable/POINTER.md"
  printf '[onward](../delta-nm/POINTER.md)\n' > "$rec/delta/POINTER.md"
  printf '[onward](../delta/POINTER.md)\n' > "$rec/delta-nm/POINTER.md"
  printf 'review\n' > "$rec/eps/report.md"
  printf 'review\n' > "$rec/eps/other.md"
  printf '[a](../eps/report.md) and [b](../eps/other.md)\n' > "$rec/eps-nm/POINTER.md"
  printf 'review\n' > "$rec/zeta/report.md"
  printf 'review\n' > "$rec/theta/report.md"
  printf 'Review lives in the base dir, e.g. ../theta/report.md after v1.10 shipped; see https://github.com/x/y\n' \
    > "$rec/theta-nm/POINTER.md"
  run_maint lint --record "$rec" --now "$NOW" --rules R3
  expect_code 1 "$RC" 'R3 lint'
  assert_not_contains "$OUT" 'alpha-nm' 'R3 resolving pointer passes'
  assert_contains "$OUT" 'R3 finding beta-verify/POINTER.md pointer-broken' 'R3 missing target'
  assert_contains "$OUT" 'R3 finding gamma-fable/POINTER.md pointer-broken' 'R3 outside root'
  assert_contains "$OUT" 'R3 finding delta-nm/POINTER.md pointer-cycle' 'R3 cycle'
  assert_contains "$OUT" 'R3 finding eps-nm/POINTER.md pointer-ambiguous' 'R3 ambiguous'
  assert_contains "$OUT" 'R3 finding zeta-nm/POINTER.md pointer-missing' 'R3 missing pointer'
  assert_contains "$OUT" 'R3 unknown eta-nm/POINTER.md review-owner-unclear' 'R3 unclear owner'
  assert_not_contains "$OUT" 'theta-nm' 'R3 prose abbreviations, version strings, and URLs are not paths'
  pass 'fm-maintain: R3 separates resolving, broken, cyclic, and unclear twins'
}

test_r4_flags_only_resolving_directory_tables() {
  local rec
  rec=$(new_record r4)
  mkdir -p "$rec/decisions" "$rec/wiki/views"
  printf '# one\n' > "$rec/decisions/one.md"
  printf '# two\n' > "$rec/decisions/two.md"
  printf '# three\n' > "$rec/decisions/three.md"
  cat > "$rec/dir-table.md" <<'EOF'
# directory

| decision | status |
| --- | --- |
| [one](decisions/one.md) | locked |
| [two](decisions/two.md) | locked |
| [three](decisions/three.md) | locked |
EOF
  cat > "$rec/mixed.md" <<'EOF'
| decision | note |
| --- | --- |
| [one](decisions/one.md) | first |
| [two](decisions/two.md) | second |
| nothing-here | third |
EOF
  cat > "$rec/option-comparison.md" <<'EOF'
| option | tradeoff |
| --- | --- |
| Option A | cheap |
| Option B | fast |
| Option C | safe |
EOF
  mkdir -p "$rec/t2"
  printf 'brief\n' > "$rec/t2/brief.md"
  printf 'outcome\n' > "$rec/t2/report.md"
  printf 'notes\n' > "$rec/wiki/notes.md"
  [ -f "$rec/backlog.md" ] || printf '# backlog\n' > "$rec/backlog.md"
  cat > "$rec/data-model.md" <<'EOF'
| file | purpose |
| --- | --- |
| backlog.md | open work |
| wiki/notes.md | notes |
| t2/report.md | outcome |
EOF
  printf '# ledger\n' > "$rec/decision-ledger.md"
  {
    printf '%s\n' '<!-- generated by fm-maintain.py views; source: x; generated: y -->'
    cat "$rec/dir-table.md"
  } > "$rec/generated.md"
  cp "$rec/dir-table.md" "$rec/wiki/views/decisions.md"
  run_maint lint --record "$rec" --now "$NOW" --rules R4
  expect_code 1 "$RC" 'R4 lint'
  assert_contains "$OUT" 'R4 finding dir-table.md:3 handwritten-directory-table' 'R4 directory table'
  assert_contains "$OUT" 'R4 finding decision-ledger.md:1 handwritten-directory-table' 'R4 ledger'
  assert_contains "$OUT" 'R4 unknown mixed.md:1 mixed-table' 'R4 mixed table'
  assert_not_contains "$OUT" 'option-comparison.md' 'R4 option table passes'
  assert_not_contains "$OUT" 'data-model.md' 'R4 data-model table of ordinary files passes'
  assert_not_contains "$OUT" 'generated.md' 'R4 skips a generated file'
  assert_not_contains "$OUT" 'wiki/views' 'R4 skips wiki/views'
  pass 'fm-maintain: R4 flags resolving directory tables and spares option tables'
}

test_r5_qualifies_facts_without_touching_the_file() {
  local rec
  rec=$(new_record r5)
  mkdir -p "$rec/decisions"
  printf '# one\n' > "$rec/decisions/one.md"
  cat >> "$rec/captain.md" <<'EOF'
- Captain prefers short briefs (dated 2026-01-02)
- Captain reads `decisions/one.md` before merging
- Captain never merges red [timeless]
- Captain wants the queue drained
  - nested detail stays out of the fact set
EOF
  printf '%s\n' '- The fleet keeps one owner per PR, tier: timeless' >> "$rec/learnings.md"
  cp "$rec/captain.md" "$rec/captain.expected"
  run_maint lint --record "$rec" --now "$NOW" --rules R5
  expect_code 1 "$RC" 'R5 lint'
  assert_contains "$OUT" 'R5 unknown captain.md:5 unclassified-fact' 'R5 unqualified fact'
  assert_contains "$OUT" 'summary: finding=0 unknown=1 acknowledged=0 pass=4' 'R5 summary'
  cmp -s "$rec/captain.md" "$rec/captain.expected" || fail 'R5 rewrote captain.md'
  pass 'fm-maintain: R5 marks unqualified facts unknown and rewrites nothing'
}

test_rule_selection_changes_the_rule_fingerprint() {
  local rec full subset
  rec=$(clean_record fingerprint)
  capture_lint "$rec/full.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'full lint'
  capture_lint "$rec/subset.json" --record "$rec" --now "$NOW" --rules R1,R2
  expect_code 0 "$LINT_RC" 'subset lint'
  full=$(json_at "$rec/full.json" rule_fingerprint)
  subset=$(json_at "$rec/subset.json" rule_fingerprint)
  [ "$full" != "$subset" ] || fail 'a rule subset kept the same fingerprint'
  capture_lint "$rec/reversed.json" --record "$rec" --now "$NOW" --rules R2,R1
  [ "$subset" = "$(json_at "$rec/reversed.json" rule_fingerprint)" ] \
    || fail 'the rule order given to --rules changed the fingerprint'
  capture_lint "$rec/full-again.json" --record "$rec" --now "$NOW_LATER"
  [ "$full" = "$(json_at "$rec/full-again.json" rule_fingerprint)" ] \
    || fail 'the rule fingerprint moved with --now'
  pass 'fm-maintain: the rule fingerprint tracks the selected rules, not the clock'
}

test_rollout_latches_enforce_on_the_seventh_clean_day() {
  local rec day
  rec=$(clean_record rollout-latch)
  run_maint rollout status --record "$rec"
  expect_code 0 "$RC" 'rollout status before init'
  assert_contains "$OUT" 'mode=not-configured' 'rollout not configured'
  run_maint rollout init --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'rollout init'
  assert_contains "$OUT" 'mode=report' 'rollout init mode'
  assert_present "$rec/.git/maintain-rollout.json" 'rollout local record'
  assert_present "$rec/wiki/views/maintain-rollout.json" 'rollout durable record'
  run_maint rollout init --record "$rec" --now "$NOW"
  expect_code 2 "$RC" 'second rollout init'
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'clean lint for rollout'
  for day in 01 02 03 04 05 06; do
    run_maint rollout advance --record "$rec" --now "$NOW" \
      --lint-json "$rec/lint.json" --scheduled-date "2026-09-$day"
    expect_code 0 "$RC" "advance day $day"
    assert_contains "$OUT" 'mode=report' "day $day stays in report"
  done
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-07
  expect_code 0 "$RC" 'advance day 07'
  assert_contains "$OUT" 'mode=enforce' 'seventh clean day latches enforce'
  assert_contains "$OUT" 'transition=latched-enforce' 'latch transition'
  run_maint rollout status --record "$rec" --format json
  expect_code 0 "$RC" 'rollout status after latch'
  assert_contains "$OUT" '"date": "2026-09-07"' 'transition evidence date'
  pass 'fm-maintain: seven consecutive clean days latch the rollout into enforce'
}

test_rollout_resets_on_a_gap_and_ignores_a_repeated_date() {
  local rec
  rec=$(clean_record rollout-gap)
  run_maint rollout init --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'rollout init'
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'clean lint'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-01
  assert_contains "$OUT" 'clean_days=1' 'first clean day'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-02
  assert_contains "$OUT" 'clean_days=2' 'second clean day'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-02
  expect_code 0 "$RC" 'repeat date advance'
  assert_contains "$OUT" 'transition=duplicate-date' 'repeat date transition'
  assert_contains "$OUT" 'clean_days=2' 'a repeat date cannot compress a week'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-04
  assert_contains "$OUT" 'transition=gap-reset' 'gap transition'
  assert_contains "$OUT" 'clean_dates=2026-09-04' 'a gap restarts the streak'
  pass 'fm-maintain: a gap resets the streak and a repeated date never advances it'
}

test_rollout_resets_when_the_fingerprint_or_lint_changes() {
  local rec
  rec=$(clean_record rollout-reset)
  run_maint rollout init --record "$rec" --now "$NOW"
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'clean lint'
  capture_lint "$rec/subset.json" --record "$rec" --now "$NOW" --rules R1
  expect_code 0 "$LINT_RC" 'clean subset lint'
  sed 's/"rule_fingerprint": "/"rule_fingerprint": "0/' "$rec/lint.json" > "$rec/moved.json"
  sed 's/"rule_fingerprint": "[0-9a-f]*"/"rule_fingerprint": ""/' "$rec/lint.json" > "$rec/blank.json"
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-01
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-02
  assert_contains "$OUT" 'clean_days=2' 'two clean days'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/subset.json" --scheduled-date 2026-09-03
  expect_code 2 "$RC" 'advance with a rule subset'
  assert_contains "$OUT" 'does not cover every rule' 'a rule subset is refused'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/blank.json" --scheduled-date 2026-09-03
  expect_code 2 "$RC" 'advance with an empty fingerprint'
  run_maint rollout status --record "$rec"
  assert_contains "$OUT" 'clean_days=2' 'refused payloads left the streak alone'
  printf '%s\n' '- [ ] t-late - pending a decision' >> "$rec/backlog.md"
  capture_lint "$rec/dirty.json" --record "$rec" --now "$NOW"
  expect_code 1 "$LINT_RC" 'dirty lint'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/dirty.json" --scheduled-date 2026-09-03
  assert_contains "$OUT" 'transition=finding-reset' 'finding transition'
  assert_contains "$OUT" 'clean_days=0' 'a finding clears the streak'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/moved.json" --scheduled-date 2026-09-04
  assert_contains "$OUT" 'transition=fingerprint-reset' 'fingerprint transition'
  assert_contains "$OUT" 'clean_dates=2026-09-04' 'a changed fingerprint restarts the streak'
  pass 'fm-maintain: a finding or a changed rule fingerprint clears the streak'
}

test_rollout_cloud_coverage_never_advances_the_streak() {
  local rec
  rec=$(clean_record rollout-cloud)
  run_maint rollout init --record "$rec" --now "$NOW"
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'clean lint'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-01
  assert_contains "$OUT" 'clean_days=1' 'local day counted'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-02 --coverage cloud
  expect_code 0 "$RC" 'cloud advance'
  assert_contains "$OUT" 'transition=cloud-recorded' 'cloud transition'
  assert_contains "$OUT" 'clean_days=1' 'cloud coverage did not advance the streak'
  run_maint rollout status --record "$rec" --format json
  assert_contains "$OUT" '"coverage": "cloud"' 'cloud result recorded'
  pass 'fm-maintain: cloud coverage is recorded without moving the streak'
}

test_rollout_enforce_never_reverts_and_reports_a_missing_record() {
  local rec day
  rec=$(clean_record rollout-sticky)
  run_maint rollout init --record "$rec" --now "$NOW"
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'clean lint'
  for day in 01 02 03 04 05 06 07; do
    run_maint rollout advance --record "$rec" --now "$NOW" \
      --lint-json "$rec/lint.json" --scheduled-date "2026-09-$day"
    expect_code 0 "$RC" "advance day $day"
  done
  assert_contains "$OUT" 'mode=enforce' 'streak latched'
  printf '%s\n' '- [ ] t-late - pending a decision' >> "$rec/backlog.md"
  capture_lint "$rec/dirty.json" --record "$rec" --now "$NOW"
  expect_code 1 "$LINT_RC" 'dirty lint'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/dirty.json" --scheduled-date 2026-09-08
  expect_code 0 "$RC" 'advance after a finding'
  assert_contains "$OUT" 'mode=enforce' 'enforce never reverts to report'
  assert_contains "$OUT" 'clean_days=0' 'the streak still resets under enforce'
  rm -f "$rec/.git/maintain-rollout.json"
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-09
  expect_code 2 "$RC" 'advance without a local record'
  assert_contains "$OUT" 'rollout-record-missing-after-activation' 'missing local record'
  run_maint rollout init --record "$rec" --now "$NOW"
  expect_code 2 "$RC" 'init over a durable record'
  assert_contains "$OUT" 'rollout-record-missing-after-activation' 'init refuses a new grace week'
  assert_grep '"mode": "enforce"' "$rec/wiki/views/maintain-rollout.json" 'durable record kept enforce'
  printf '{"mode": "Enforce"}\n' > "$rec/.git/maintain-rollout.json"
  run_maint stow-gate --record "$rec" --now "$NOW"
  expect_code 2 "$RC" 'stow-gate with a corrupt mode'
  assert_contains "$OUT" 'rollout-record-unreadable' 'corrupt mode is unreadable'
  printf '[]\n' > "$rec/.git/maintain-rollout.json"
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-09
  expect_code 2 "$RC" 'advance with a non-object record'
  assert_contains "$OUT" 'rollout-record-unreadable' 'non-object record is unreadable'
  pass 'fm-maintain: enforce is sticky and a lost or corrupt record is an error'
}

test_rollout_advance_is_a_noop_when_unconfigured() {
  local rec
  rec=$(clean_record rollout-unconfigured)
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'clean lint'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/lint.json" --scheduled-date 2026-09-01
  expect_code 0 "$RC" 'unconfigured advance'
  assert_contains "$OUT" 'mode=not-configured' 'unconfigured advance mode'
  assert_absent "$rec/.git/maintain-rollout.json" 'unconfigured advance wrote a record'
  assert_absent "$rec/wiki/views/maintain-rollout.json" 'unconfigured advance wrote a copy'
  run_maint rollout advance --record "$rec" --now "$NOW" \
    --lint-json "$rec/absent.json" --scheduled-date 2026-09-01
  expect_code 2 "$RC" 'advance with an unreadable lint file'
  pass 'fm-maintain: an unconfigured rollout advance writes nothing and exits 0'
}

test_stow_gate_blocks_only_under_enforce() {
  local rec day
  rec=$(clean_record stow-gate)
  run_maint stow-gate --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'stow-gate unconfigured'
  assert_contains "$OUT" 'mode=not-configured' 'stow-gate unconfigured mode'
  printf '%s\n' '- [ ] t-late - pending a decision' >> "$rec/backlog.md"
  run_maint stow-gate --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'stow-gate unconfigured with findings'
  assert_contains "$OUT" 'R1 finding' 'stow-gate prints the lint text'
  run_maint rollout init --record "$rec" --now "$NOW"
  run_maint stow-gate --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'stow-gate report with findings'
  assert_contains "$OUT" 'mode=report' 'stow-gate report mode'
  git -C "$rec" checkout -q -- backlog.md 2>/dev/null || true
  printf '%s\n' '# backlog' > "$rec/backlog.md"
  printf '%s\n' '- [ ] t-clean - ship the queued change' >> "$rec/backlog.md"
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 0 "$LINT_RC" 'clean lint'
  for day in 01 02 03 04 05 06 07; do
    run_maint rollout advance --record "$rec" --now "$NOW" \
      --lint-json "$rec/lint.json" --scheduled-date "2026-09-$day"
    expect_code 0 "$RC" "advance day $day"
  done
  run_maint stow-gate --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'stow-gate enforce while clean'
  assert_contains "$OUT" 'mode=enforce' 'stow-gate enforce mode'
  printf '%s\n' '- [ ] t-late - pending a decision' >> "$rec/backlog.md"
  run_maint stow-gate --record "$rec" --now "$NOW"
  expect_code 1 "$RC" 'stow-gate enforce with findings'
  run_maint stow-gate --record "$rec" --now "$NOW" --format json
  expect_code 1 "$RC" 'stow-gate enforce json'
  assert_contains "$OUT" '"gate": "blocked"' 'stow-gate blocked gate'
  pass 'fm-maintain: stow-gate reports in every mode and blocks only under enforce'
}

test_fold_reports_the_receipt_and_proposes_duplicates() {
  local rec
  rec=$(new_record fold)
  mkdir -p "$rec/acked"
  printf 'brief\n' > "$rec/acked/brief.md"
  printf 'dispatched, never reported\nbrief-sha256: %s\n' \
    "$(sha256_of "$rec/acked/brief.md")" > "$rec/acked/status"
  printf '[review](../acked/brief.md)\n' > "$rec/acked/POINTER.md"
  printf '%s\n' '- Captain merges only green PRs (dated 2026-01-01)' >> "$rec/captain.md"
  printf '%s\n' '- Captain merges only green PRs (dated 2026-01-01)' >> "$rec/learnings.md"
  cat > "$rec/memory-archive.md" <<'EOF'
# archive
- retired note, duplicate of Captain merges only green PRs (dated 2026-01-01)
- lost note, duplicate of a fact nobody wrote down
- partial note, duplicate of the
EOF
  run_maint fold --record "$rec" --now "$NOW" --format json
  expect_code 0 "$RC" 'fold without a receipt'
  assert_contains "$OUT" '"present": false' 'fold receipt absent'
  assert_contains "$OUT" '"duplicate-fact"' 'fold duplicate fact proposal'
  assert_contains "$OUT" '"captain.md:2"' 'fold duplicate locator one'
  assert_contains "$OUT" '"learnings.md:2"' 'fold duplicate locator two'
  assert_contains "$OUT" '"canonical": "captain.md:2"' 'fold names the canonical copy'
  assert_contains "$OUT" '"marked-duplicate"' 'fold resolvable mark proposal'
  assert_contains "$OUT" '"marked-duplicate-unresolved"' 'fold unresolvable mark question'
  printf '%s\n' "$OUT" > "$rec/fold.json"
  python3 - "$rec/fold.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
marks = [p for p in data["proposals"] if p["kind"] == "marked-duplicate"]
assert [p["locators"] for p in marks] == [["memory-archive.md:2"]], marks
assert marks[0]["canonical"] == "captain.md:2", marks
open_marks = [q["locators"][0] for q in data["questions"]]
assert "memory-archive.md:4" in open_marks, open_marks
PY
  assert_contains "$OUT" '"bound_sidecars": 1' 'fold counts bound sidecars'
  assert_contains "$OUT" '"pointers": 1' 'fold counts pointers'
  printf '# cleanup\n' > "$rec/cleanup-2026-09-01.md"
  printf '# cleanup\n' > "$rec/cleanup-2026-09-05.md"
  run_maint fold --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'fold with a receipt'
  assert_contains "$OUT" 'receipt=present date=2026-09-05' 'fold latest receipt date'
  pass 'fm-maintain: fold reports the latest cleanup receipt and proposes duplicates'
}

test_views_land_once_and_leave_hand_files_alone() {
  local rec
  rec=$(new_record views)
  mkdir -p "$rec/decisions" "$rec/wiki" "$rec/vr-reports" "$rec/alpha" "$rec/vr-lost"
  printf '# one\nDate: 2026-01-01\nStatus: locked\n' > "$rec/decisions/one.md"
  printf '# two\nStatus: locked\nSupersedes: decisions/one.md\n' \
    > "$rec/decisions/two-2026-03-04.md"
  printf '## Archived 2026-03-01\n- [x] alpha - shipped alpha\n' > "$rec/done-archive.md"
  printf 'brief\n' > "$rec/alpha/brief.md"
  printf 'outcome\n' > "$rec/alpha/report.md"
  printf '# index\n- [kept](kept.md)\n- [gone](gone.md)\n' > "$rec/vr-reports/INDEX.md"
  printf 'kept\n' > "$rec/vr-reports/kept.md"
  printf '%s\n' '- Captain wants the queue drained' >> "$rec/captain.md"
  printf 'hand-owned notes\n' > "$rec/wiki/notes.md"
  cp "$rec/wiki/notes.md" "$rec/notes.expected"
  run_maint views --record "$rec" --now "$NOW" --apply
  expect_code 0 "$RC" 'first views apply'
  assert_contains "$OUT" 'written=6 unchanged=0' 'first views summary'
  assert_grep 'generated by fm-maintain.py views' "$rec/wiki/views/decisions.md" \
    'views header marker'
  assert_grep 'decisions/two-2026-03-04.md' "$rec/wiki/views/decisions.md" \
    'views decision row'
  assert_grep 'shipped alpha' "$rec/wiki/views/completed-tasks.md" 'views archive row'
  assert_grep 'alpha' "$rec/wiki/views/brief-only.md" 'views brief inventory'
  assert_grep 'unclassified-fact' "$rec/wiki/views/memory-lint.md" 'views memory lint'
  assert_grep 'broken' "$rec/wiki/views/video-index.md" 'views broken video link'
  assert_grep 'vr-lost' "$rec/wiki/views/video-index.md" 'views unlinked video dir'
  cp -R "$rec/wiki/views" "$rec/views.expected"
  run_maint views --record "$rec" --now "$NOW_LATER" --apply
  expect_code 0 "$RC" 'second views apply'
  assert_contains "$OUT" 'written=0 unchanged=6' 'second views summary'
  diff -r "$rec/views.expected" "$rec/wiki/views" > /dev/null \
    || fail 'a second views run rewrote an unchanged view'
  cmp -s "$rec/wiki/notes.md" "$rec/notes.expected" || fail 'views touched a hand file'
  run_maint views --record "$rec" --now "$NOW" --stage-dir "$rec/stage"
  expect_code 2 "$RC" 'stage dir inside the Record'
  rm -rf "$rec/wiki/views"
  mkdir -p "$rec/playbook"
  ln -s ../playbook "$rec/wiki/views"
  run_maint views --record "$rec" --now "$NOW" --apply
  expect_code 2 "$RC" 'views through a symlinked views dir'
  assert_contains "$OUT" 'refusing to write through symlink' 'views names the symlink'
  [ -z "$(ls -A "$rec/playbook")" ] || fail 'views wrote through the symlink into playbook'
  pass 'fm-maintain: views land once and a timestamp-only change is left alone'
}

test_measure_counts_reuse_once_and_names_missing_evidence() {
  local rec measures
  rec=$(new_record measure)
  git -C "$rec" init -q --initial-branch=main
  mkdir -p "$rec/decisions" "$rec/m1" "$rec/m2" "$rec/m3" "$rec/state"
  printf '# one\n' > "$rec/decisions/one.md"
  printf '# two\n' > "$rec/decisions/two.md"
  printf '# older\nDate: 2026-09-14\n' > "$rec/decisions/older-2026-09-14.md"
  printf '# newer\nSupersedes: decisions/older-2026-09-14.md\n' \
    > "$rec/decisions/newer-2026-09-15.md"
  printf '# self\nSupersedes: decisions/self-2026-09-15.md\n' \
    > "$rec/decisions/self-2026-09-15.md"
  cat > "$rec/m1/brief.md" <<'EOF'
# task m1

Read decisions/one.md before starting, and decisions/two.md after.

# Recalled pointers

- decisions/three.md
EOF
  cat > "$rec/m1/recall.json" <<'EOF'
{
  "type": "recall-receipt",
  "timestamp_utc": "2026-09-15T01:00:00Z",
  "emitted_paths": ["decisions/one.md", "decisions/two.md", "decisions/three.md"],
  "preexisting_cited_paths": ["decisions/two.md"],
  "answer_classification": "answered",
  "answer_location": "decisions/one.md",
  "answer_date": "2026-09-01"
}
EOF
  printf 'brief\n' > "$rec/m3/brief.md"
  cat > "$rec/m3/recall.json" <<'EOF'
{
  "type": "recall-receipt",
  "timestamp_utc": "2026-09-15T02:00:00Z",
  "emitted_paths": ["decisions/one.md"]
}
EOF
  printf '{"digest_bytes": 10, "bytes": 30}\n' \
    > "$rec/state/.session-recall-receipt.a.json"
  commit_at "$rec" 2026-09-15T00:30:00Z 'add measured tasks'
  printf 'brief\n' > "$rec/m2/brief.md"
  run_maint measure --record "$rec" --now "$NOW" --apply --format json
  expect_code 0 "$RC" 'measure run'
  printf '%s\n' "$OUT" > "$rec/measure.json"
  measures=measures.current_week
  [ "$(json_at "$rec/measure.json" "$measures.reuse.tasks")" = 1 ] \
    || fail 'measure did not count the reusing task exactly once'
  assert_contains "$OUT" '"emitted_path": "decisions/one.md"' 'measure reuse evidence'
  [ "$(json_at "$rec/measure.json" "$measures.rediscovery.counts.answered")" = 1 ] \
    || fail 'measure did not count the answered rediscovery'
  [ "$(json_at "$rec/measure.json" "$measures.rediscovery.counts.unknown")" = 1 ] \
    || fail 'measure did not count the unclassified rediscovery'
  [ "$(json_at "$rec/measure.json" "$measures.succession.decisions")" = 1 ] \
    || fail 'measure counted a self-superseding decision'
  assert_contains "$OUT" '"older": "decisions/older-2026-09-14.md"' 'measure succession pair'
  assert_not_contains "$OUT" '"older": "decisions/self-2026-09-15.md"' 'measure self link'
  [ "$(json_at "$rec/measure.json" "$measures.injected")" = '"not measured"' ] \
    || fail 'measure reported a zero instead of not measured'
  assert_contains "$OUT" '"task": "m2"' 'measure unobserved task'
  assert_contains "$OUT" '"reason": "no-git-history"' 'measure unobserved reason'
  assert_grep 'ceil(UTF-8 bytes / 3)' "$rec/wiki/views/recall-compounding.md" \
    'measure token estimator label'
  printf '{"digest_bytes": "lots", "bytes": 30, "timestamp_utc": "2026-09-15T01:00:00Z"}\n' \
    > "$rec/state/.session-recall-receipt.b.json"
  run_maint measure --record "$rec" --now "$NOW" --state "$rec/state" --format json
  expect_code 0 "$RC" 'measure with a state dir holding a corrupt receipt'
  assert_contains "$OUT" '"not measured"' 'undated session receipts stay not measured'
  cp "$rec/m3/recall.json" "$rec/m1/recall.json"
  run_maint measure --record "$rec" --now "$NOW" --format json
  expect_code 0 "$RC" 'measure without classifications'
  printf '%s\n' "$OUT" > "$rec/measure.json"
  [ "$(json_at "$rec/measure.json" "$measures.rediscovery")" = '"not measured"' ] \
    || fail 'rediscovery reported zeros with no receipt carrying answer_classification'
  pass 'fm-maintain: measure counts reuse once and names every missing measure'
}

test_receipt_merges_its_own_host_only() {
  local rec local_before local_after
  rec=$(new_record receipt)
  printf 'lint\tfinding\t1.5\t3 findings\n' > "$rec/stages.tsv"
  printf 'archive\tfinding\t12\tincomplete\n' >> "$rec/stages.tsv"
  printf 'views\tok\t0.4\t\n' >> "$rec/stages.tsv"
  printf '%s\n' '- [ ] t-late - pending a decision' >> "$rec/backlog.md"
  capture_lint "$rec/lint.json" --record "$rec" --now "$NOW"
  expect_code 1 "$LINT_RC" 'lint for the receipt'
  run_maint receipt --record "$rec" --now "$NOW" --host local --stages "$rec/stages.tsv" \
    --input-commit "$(printf 'abc123\nEVIL')" --lint-json "$rec/lint.json" --rollout-json - \
    --tool-fingerprint 'ruff 0.16.6' --apply
  expect_code 0 "$RC" 'local receipt'
  assert_contains "$OUT" 'complete=yes' 'local receipt completeness'
  assert_grep 'input commit: abc123 EVIL' "$rec/wiki/views/maintenance/2026-09-15-local.md" \
    'receipt sanitizes the input commit'
  assert_no_grep '^EVIL' "$rec/wiki/views/maintenance/2026-09-15-local.md" \
    'receipt printed a raw control character'
  assert_grep 'recorded locally in .git/nightly/last-attempt' \
    "$rec/wiki/views/maintenance/2026-09-15-local.md" 'receipt names where checkpoint and verify land'
  assert_grep 'R1:deferral-without-hold' "$rec/wiki/views/maintenance/2026-09-15-local.md" \
    'receipt collapses a rule finding into one line'
  assert_grep 'archive:incomplete' "$rec/wiki/views/maintenance/2026-09-15-local.md" \
    'receipt names the problem stage'
  assert_grep 'lint mode: not-configured' "$rec/wiki/views/maintenance/2026-09-15-local.md" \
    'receipt records the lint mode'
  local_before=$(json_at "$rec/wiki/views/nightly-digest.json" hosts.local)
  printf 'archive\tfailed\t3\trestic missing\n' > "$rec/cloud-stages.tsv"
  run_maint receipt --record "$rec" --now 2026-09-16T03:00:00Z --host cloud \
    --stages "$rec/cloud-stages.tsv" --input-commit def456 \
    --lint-json "$rec/lint.json" --rollout-json - --tool-fingerprint 'ruff 0.16.6' --apply
  expect_code 0 "$RC" 'cloud receipt'
  assert_contains "$OUT" 'complete=no' 'a failed stage marks the run incomplete'
  local_after=$(json_at "$rec/wiki/views/nightly-digest.json" hosts.local)
  [ "$local_before" = "$local_after" ] || fail 'the cloud receipt rewrote the local host'
  assert_grep '"cloud"' "$rec/wiki/views/nightly-digest.json" 'cloud host merged'
  printf 'archive\tbogus\t1\tdetail\n' > "$rec/bad-stages.tsv"
  run_maint receipt --record "$rec" --now "$NOW" --host local --stages "$rec/bad-stages.tsv" \
    --input-commit abc123 --lint-json "$rec/lint.json" --rollout-json - \
    --tool-fingerprint x
  expect_code 2 "$RC" 'unknown stage outcome'
  printf 'archive\tok\n' > "$rec/short-stages.tsv"
  run_maint receipt --record "$rec" --now "$NOW" --host local --stages "$rec/short-stages.tsv" \
    --input-commit abc123 --lint-json "$rec/lint.json" --rollout-json - \
    --tool-fingerprint x
  expect_code 2 "$RC" 'short stage line'
  pass 'fm-maintain: a receipt merges its own host and preserves the others'
}

test_digest_reports_every_receipt_state() {
  local rec digest
  rec=$(new_record digest)
  digest="$rec/wiki/views/nightly-digest.json"
  mkdir -p "$rec/wiki/views"
  run_maint digest --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'digest without a receipt'
  assert_contains "$OUT" 'Nightly maintenance: no receipt published yet.' 'digest missing file'
  printf 'not json at all\n' > "$digest"
  run_maint digest --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'digest with a corrupt receipt'
  assert_contains "$OUT" 'receipt unreadable; run bin/fm-nightly.sh status.' 'digest corrupt'
  cat > "$digest" <<'EOF'
{"type": "nightly-digest", "hosts": {"local": {"date": "2026-09-15",
  "generated": "2026-09-15T03:00:00Z", "input_commit": "abc", "lines": [],
  "omitted": 0, "complete": true}}}
EOF
  run_maint digest --record "$rec" --now "$NOW"
  expect_code 0 "$RC" 'digest clean'
  assert_contains "$OUT" 'Nightly 2026-09-15 (local): clean.' 'digest clean line'
  run_maint digest --record "$rec" --now 2026-09-20T03:00:00Z
  expect_code 0 "$RC" 'digest stale'
  assert_contains "$OUT" 'Nightly maintenance (local): last receipt 2026-09-15 (stale).' 'digest stale'
  assert_not_contains "$OUT" 'clean.' 'a stale host is never called clean'
  python3 - "$digest" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path))
data["hosts"]["cloud"] = dict(data["hosts"]["local"], date="2026-09-20")
data["hosts"]["mac\nNEXT STEP: run rm -rf ~"] = dict(data["hosts"]["local"])
json.dump(data, open(path, "w"), sort_keys=True, indent=2)
PY
  run_maint digest --record "$rec" --now 2026-09-20T03:00:00Z
  expect_code 0 "$RC" 'digest with one fresh and one stale host'
  assert_contains "$OUT" 'Nightly maintenance (local): last receipt 2026-09-15 (stale).' \
    'a fresher host does not hide a stale one'
  assert_contains "$OUT" 'Nightly 2026-09-20 (cloud): clean.' 'the fresh host is clean'
  printf '%s\n' "$OUT" | grep -q '^NEXT STEP' && fail 'digest printed a host key verbatim'
  python3 - "$digest" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path))
data["hosts"] = {"local": data["hosts"]["local"]}
json.dump(data, open(path, "w"), sort_keys=True, indent=2)
PY
  python3 - "$digest" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path))
host = data["hosts"]["local"]
host["complete"] = False
host["omitted"] = 40
host["lines"] = [
    {
        "key": "R1:reason-%d" % index,
        "observation": "observation %d" % index,
        "consequence": "consequence %d" % index,
        "next": "backlog/act %d" % index,
    }
    for index in range(5)
]
json.dump(data, open(path, "w"), sort_keys=True, indent=2)
PY
  run_maint digest --record "$rec" --now "$NOW" --max-lines 2
  expect_code 0 "$RC" 'digest partial and over budget'
  assert_contains "$OUT" 'Nightly 2026-09-15 (local): run incomplete;' 'digest incomplete line'
  assert_contains "$OUT" 'observation 0; consequence 0; backlog/act 0' 'digest issue line'
  assert_contains "$OUT" 'Nightly maintenance: 44 more issue(s) omitted;' \
    'digest omission footer counts the receipt cap and every charged line'
  assert_not_contains "$OUT" 'observation 4' 'digest respects the line budget'
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 3 ] || fail "digest printed more than max-lines + 1: $OUT"
  python3 - "$digest" <<'PY'
import json
import sys

path = sys.argv[1]
data = json.load(open(path))
data["hosts"]["cloud"] = {
    "date": "2026-09-15",
    "generated": "2026-09-15T03:00:00Z",
    "input_commit": "abc",
    "lines": [],
    "omitted": 0,
    "complete": True,
}
for index in range(6):
    data["hosts"]["h%d" % index] = dict(data["hosts"]["cloud"])
json.dump(data, open(path, "w"), sort_keys=True, indent=2)
PY
  run_maint digest --record "$rec" --now "$NOW" --max-lines 2
  expect_code 0 "$RC" 'digest with many hosts'
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 3 ] || fail "per-host lines escaped the budget: $OUT"
  assert_contains "$OUT" 'see wiki/views/maintenance/2026-09-15-local.md' \
    'the omission footer names the host whose lines were capped'
  assert_not_contains "$OUT" 'maintenance/2026-09-15-cloud.md' 'the footer named a host with nothing omitted'
  mkdir -p "$rec/.git/nightly"
  printf 'date=2026-09-15\nresult=ok\nverify=fm-record: state=verified equal=yes head=abc remote=abc staged=0\n' \
    > "$rec/.git/nightly/last-attempt"
  run_maint digest --record "$rec" --now "$NOW" --max-lines 8
  expect_code 0 "$RC" 'digest with a local last-attempt'
  assert_contains "$OUT" 'Nightly maintenance: last local run 2026-09-15 result=ok; verify state=verified equal=yes' \
    'digest carries the local verify line'
  assert_not_contains "$OUT" 'head=abc' 'digest printed the raw verify line'
  run_maint digest --record "$rec" --now "$NOW" --line-chars 40
  expect_code 0 "$RC" 'digest with a short line budget'
  assert_not_contains "$OUT" 'consequence 0' 'digest cuts a line at the character budget'
  pass 'fm-maintain: digest names each receipt state within its line budget'
}

test_outer_repository_stays_clean() {
  local after
  after=$(git -C "$ROOT" status --short --untracked-files=all)
  [ "$after" = "$OUTER_STATUS_BEFORE" ] \
    || fail "fixtures changed the outer repository"$'\n'"before: $OUTER_STATUS_BEFORE"$'\n'"after: $after"
  pass 'fm-maintain: fixtures leave the outer repository unchanged'
}

test_inputs_are_strict_about_now_and_record
test_r1_binds_a_deferral_to_a_hold_and_evaluator
test_r2_age_threshold_is_exact_at_fourteen_days
test_r2_reports_unknown_age_without_a_durable_source
test_r2_sidecar_binds_the_acknowledgement_to_the_brief_bytes
test_r2_brief_mtime_does_not_change_a_verdict
test_r3_classifies_every_twin_pointer_state
test_r4_flags_only_resolving_directory_tables
test_r5_qualifies_facts_without_touching_the_file
test_rule_selection_changes_the_rule_fingerprint
test_rollout_latches_enforce_on_the_seventh_clean_day
test_rollout_resets_on_a_gap_and_ignores_a_repeated_date
test_rollout_resets_when_the_fingerprint_or_lint_changes
test_rollout_cloud_coverage_never_advances_the_streak
test_rollout_enforce_never_reverts_and_reports_a_missing_record
test_rollout_advance_is_a_noop_when_unconfigured
test_stow_gate_blocks_only_under_enforce
test_fold_reports_the_receipt_and_proposes_duplicates
test_views_land_once_and_leave_hand_files_alone
test_measure_counts_reuse_once_and_names_missing_evidence
test_receipt_merges_its_own_host_only
test_digest_reports_every_receipt_state

test_outer_repository_stays_clean
