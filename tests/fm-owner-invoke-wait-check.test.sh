#!/usr/bin/env bash
# Behavioral coverage for the owner-invoke-wait refuse-hook.
# Exercises public CLI exit codes, exact-count regression, and reconstructed
# 2026-08-22 turns. Does not assert checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-owner-invoke-wait-check.sh"
FIXTURES="$ROOT/tests/fixtures/fm-owner-invoke-wait-check"
OWN_CLAIMS="$ROOT/docs/verification/owner-invoke-wait-claims.json"
TMP_ROOT=$(fm_test_tmproot fm-owner-invoke-wait-check)
fm_git_identity fmtest fmtest@example.invalid

run_check() {
  "$CHECK" "$@" 2>&1
}

write_turn() {
  local path=$1
  shift
  printf '%s\n' "$@" > "$path"
}

test_missing_and_empty_input_are_structural() {
  local out rc empty
  empty="$TMP_ROOT/empty.json"
  : > "$empty"
  set +e
  out=$(run_check)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "hook mode with empty stdin exited $rc"
  set +e
  out=$(run_check --input "$TMP_ROOT/no-such.json")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing file exited $rc"
  assert_contains "$out" "missing claims" "missing file did not say missing"
  set +e
  out=$(run_check --input "$empty")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty claims exited $rc"
  assert_contains "$out" "empty claims" "empty claims was not structural"
  set +e
  out=$(run_check --brief "$empty")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty brief exited $rc"
  assert_contains "$out" "empty brief" "empty brief was not structural"
  set +e
  out=$(run_check --input "$empty" --expect-rule R-owner-invoke-wait --expect-count 0)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(run_check --input "$FIXTURES/historical-yes-ask.json" --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  pass "owner-invoke-wait: missing and empty input, expect-count 0, empty rules exit 2"
}

test_historical_yes_ask_fires_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-yes-ask.json" \
    --expect-rule R-owner-invoke-wait --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical yes-ask exact-count exited $rc: $out"
  set +e
  out=$(run_check --input "$FIXTURES/historical-yes-ask.json")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical yes-ask gate exited $rc: $out"
  assert_contains "$out" "R-owner-invoke-wait-yes-ask" \
    "historical yes-ask did not report owner-invoke wait"
  assert_contains "$out" "recurring-defect" \
    "historical yes-ask did not name /recurring-defect"
  pass "owner-invoke-wait: 2026-08-22 reconstructed yes-ask fires exact count 1"
}

test_historical_fog_pin_fires_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-fog-pin.json" \
    --expect-rule R-fog-pin-wait --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical fog-pin exact-count exited $rc: $out"
  pass "owner-invoke-wait: 2026-08-22 reconstructed fog pin fires exact count 1"
}

test_historical_ship_omission_fires_exact_count() {
  local out rc brief
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-ship-without-ov.json" \
    --expect-rule R-ov-missing --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical ship without OV exact-count exited $rc: $out"
  set +e
  out=$(run_check --input "$FIXTURES/historical-ship-without-ov.json")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical ship without OV gate exited $rc: $out"
  assert_contains "$out" "R-ov-missing-none" \
    "historical compile-check ship did not report missing OV"
  pass "owner-invoke-wait: 2026-08-22 compile-check with no OV fires exact count 1"
}

test_held_locked_next_and_date_cleared() {
  local out rc turn
  turn="$TMP_ROOT/held-map-next.json"
  write_turn "$turn" '{
    "held": [{"id":"map-s2","hold_kind":"captain","hold_reason":"waiting for captain go","hold_until":"-"}],
    "map_next": ["map-s2"],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-held-locked-next --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "held map_next exact-count exited $rc: $out"
  turn="$TMP_ROOT/held-owned.json"
  write_turn "$turn" '{
    "held": [{"id":"map-s2","hold_kind":"captain","hold_reason":"waiting for captain go","hold_until":"-"}],
    "map_next": ["map-s2"],
    "owned_meta": ["map-s2"],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "owned held map_next exited $rc: $out"
  [ -z "$out" ] || fail "owned held map_next printed findings: $out"
  turn="$TMP_ROOT/date-cleared.json"
  write_turn "$turn" '{
    "held": [{"id":"slice-old","hold_kind":"future","hold_reason":"wait","hold_until":"2020-01-01"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-held-locked-next --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "date-cleared hold exact-count exited $rc: $out"
  turn="$TMP_ROOT/future-hold.json"
  write_turn "$turn" '{
    "held": [{"id":"later","hold_kind":"future","hold_reason":"start later","hold_until":"2099-01-01"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "future hold exited $rc: $out"
  [ -z "$out" ] || fail "future hold printed findings: $out"
  turn="$TMP_ROOT/real-captain.json"
  write_turn "$turn" '{
    "held": [{"id":"merge-q","hold_kind":"captain","hold_reason":"captain decision pending","hold_until":"-"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "real captain hold exited $rc: $out"
  [ -z "$out" ] || fail "real captain hold printed findings: $out"
  turn="$TMP_ROOT/english-hold.json"
  write_turn "$turn" '{
    "held": [{"id":"slice-go","hold_kind":"captain","hold_reason":"waiting for captain go","hold_until":"-"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "English hold reason without map_next exited $rc: $out"
  [ -z "$out" ] || fail "English hold reason printed findings: $out"
  pass "owner-invoke-wait: held map_next, date-cleared, future, and real captain holds"
}

test_invoked_and_english_without_marker_are_clean() {
  local out rc turn
  turn="$TMP_ROOT/invoked.json"
  write_turn "$turn" '{
    "assistant_text": "OWNER_INVOKE_WAIT /recurring-defect",
    "invoked_skills": ["recurring-defect"],
    "held": [],
    "map_next": [],
    "owned_meta": [],
    "fog_live": false
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "invoked skill with marker exited $rc: $out"
  [ -z "$out" ] || fail "invoked skill printed findings: $out"
  turn="$TMP_ROOT/english.json"
  write_turn "$turn" '{
    "assistant_text": "Want me to run /recurring-defect?",
    "invoked_skills": [],
    "held": [],
    "map_next": [],
    "owned_meta": [],
    "fog_live": false
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "English yes-ask without marker exited $rc: $out"
  [ -z "$out" ] || fail "English yes-ask printed findings: $out"
  pass "owner-invoke-wait: invoked skill and English without marker are clean"
}

test_placeholder_and_stub_briefs_are_clean() {
  local out rc brief
  brief="$TMP_ROOT/placeholder.md"
  printf '# Task\n{TASK}\n\n# Setup\nfixture\n' > "$brief"
  set +e
  out=$(run_check --brief "$brief")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "placeholder brief exited $rc: $out"
  [ -z "$out" ] || fail "placeholder brief printed findings: $out"
  brief="$TMP_ROOT/no-task.md"
  printf 'brief for stub\n' > "$brief"
  set +e
  out=$(run_check --brief "$brief")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "no-task stub exited $rc: $out"
  pass "owner-invoke-wait: placeholder and no-task briefs are clean"
}

test_builder_self_review_is_not_ov() {
  local out rc turn
  turn="$TMP_ROOT/self-review.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"","task":"Start Spec compile-check.","skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check"]
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-ov-missing --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "builder self-review exact-count exited $rc: $out"
  turn="$TMP_ROOT/ov-self.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check","skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check"]
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "self OV id exited $rc: $out"
  assert_contains "$out" "R-ov-missing-self" "self OV id did not report self-review"
  pass "owner-invoke-wait: builder self-review is not OV"
}

test_distinct_ov_worker_is_clean() {
  local out rc turn
  turn="$TMP_ROOT/ov-ok.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":true,"skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check", "spec-compile-check-ov"]
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "distinct OV worker exited $rc: $out"
  [ -z "$out" ] || fail "distinct OV worker printed findings: $out"
  turn="$TMP_ROOT/ov-missing-worker.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":true,"skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check"]
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing OV worker exited $rc: $out"
  assert_contains "$out" "R-ov-missing-worker" "missing OV worker did not report unspawned OV"
  pass "owner-invoke-wait: distinct spawned OV worker is required"
}

test_ov_report_and_skill_records() {
  local out rc turn
  turn="$TMP_ROOT/no-report.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":false,"skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check", "spec-compile-check-ov"]
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-ov-missing --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing OV report exact-count exited $rc: $out"
  turn="$TMP_ROOT/no-skill.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":true,"skills":[]}],
    "owned_meta": ["spec-compile-check", "spec-compile-check-ov"]
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-skill-unloaded --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "unloaded plan-eng-review exact-count exited $rc: $out"
  pass "owner-invoke-wait: OV report and skills records own the wait"
}

test_unrelated_rule_does_not_satisfy_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-yes-ask.json" \
    --expect-rule R-held-locked-next --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "unrelated held exact-count exited $rc: $out"
  assert_contains "$out" "regression:" "unrelated-rule miss was not a count mismatch"
  pass "owner-invoke-wait: unrelated rule fire is not exact-count success"
}

test_own_claims_pass_class_too_narrow() {
  local out rc
  set +e
  out=$("$ROOT/bin/fm-class-too-narrow-check.sh" --input "$OWN_CLAIMS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "own claims exited $rc: $out"
  [ -z "$out" ] || fail "own claims printed findings: $out"
  pass "owner-invoke-wait: tracked claims pass class-too-narrow"
}

make_primary_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

test_pretool_yes_ask_is_denied() {
  local home out rc payload
  home=$(make_primary_home "$TMP_ROOT/pretool")
  payload=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"OWNER_INVOKE_WAIT /recurring-defect"}]}}')
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --pretool --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "pretool yes-ask exited $rc with: $out"
  assert_contains "$out" 'permissionDecision":"deny' "pretool refusal was not a deny object"
  pass "owner-invoke-wait: AskUserQuestion PreToolUse denies an owner-invoke yes-ask"
}

test_hook_gathers_ship_skill_and_ov_report_records() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-ships")
  mkdir -p "$home/data/spec-compile-check"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' > "$home/state/spec-compile-check.meta"
  printf '%s\n' 'kind=scout' > "$home/state/spec-compile-check-ov.meta"
  printf '%s\n' 'codebase-design' > "$home/data/spec-compile-check/skills"
  printf 'OV done\n' > "$home/data/spec-compile-check/ov-report.md"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "hook skill gather exited $rc with: $out"
  assert_contains "$out" 'R-skill-unloaded-plan-eng-review' \
    "hook did not refuse unloaded plan-eng-review from durable skills record"
  printf '%s\n' 'plan-eng-review' > "$home/data/spec-compile-check/skills"
  rm -f "$home/data/spec-compile-check/ov-report.md"
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "hook missing ov-report exited $rc with: $out"
  assert_contains "$out" 'R-ov-missing-report' \
    "hook did not refuse missing ov-report.md for ship with ov="
  printf 'OV done\n' > "$home/data/spec-compile-check/ov-report.md"
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "hook clean ship records exited $rc with: $out"
  [ -z "$out" ] || fail "hook clean ship records printed: $out"
  pass "owner-invoke-wait: hook gathers skills and ov-report durable ship records"
}

test_hook_does_not_rerefuse_inflight_ship_without_ov() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-no-ov")
  mkdir -p "$home/data/legacy-ship"
  printf '%s\n' 'kind=ship' > "$home/state/legacy-ship.meta"
  printf '%s\n' 'plan-eng-review' > "$home/data/legacy-ship/skills"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "in-flight ship without ov exited $rc with: $out"
  [ -z "$out" ] || fail "in-flight ship without ov printed: $out"
  pass "owner-invoke-wait: turn-end does not re-refuse in-flight ships without ov="
}

test_prior_turn_tool_mention_is_not_invoke_credit() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-prior-turn")
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo wayfinder docs"}}]}}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"ok"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OWNER_INVOKE_WAIT /wayfinder"}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "prior-turn tool mention exited $rc with: $out"
  assert_contains "$out" 'R-owner-invoke-wait-yes-ask' \
    "prior-turn tool-input mention incorrectly credited an invoke"
  assert_contains "$out" 'wayfinder' "prior-turn miss did not name wayfinder"
  pass "owner-invoke-wait: prior-turn tool-input mention is not invoke credit"
}

test_same_turn_skill_tool_load_is_invoke_credit() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-skill-load")
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"wayfinder"}},{"type":"text","text":"OWNER_INVOKE_WAIT /wayfinder"}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "same-turn Skill load exited $rc with: $out"
  [ -z "$out" ] || fail "same-turn Skill load printed: $out"
  pass "owner-invoke-wait: same-turn Skill tool load credits the invoke"
}

test_brief_reads_ov_meta_and_report() {
  local home out rc brief
  home=$(make_primary_home "$TMP_ROOT/brief-ov")
  mkdir -p "$home/data/spec-compile-check"
  brief="$home/data/spec-compile-check/brief.md"
  printf '# Task\nfilled ship work\n' > "$brief"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' > "$home/state/spec-compile-check.meta"
  printf '%s\n' 'kind=scout' > "$home/state/spec-compile-check-ov.meta"
  printf '%s\n' 'plan-eng-review' > "$home/data/spec-compile-check/skills"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --brief "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "brief missing ov-report exited $rc with: $out"
  assert_contains "$out" 'R-ov-missing-report' \
    "brief mode did not use durable ov= and ov-report.md"
  printf 'OV ok\n' > "$home/data/spec-compile-check/ov-report.md"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --brief "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "brief with ov-report exited $rc with: $out"
  [ -z "$out" ] || fail "brief with ov-report printed: $out"
  pass "owner-invoke-wait: brief mode reads ov meta and ov-report.md"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_historical_yes_ask_fires_exact_count
test_historical_fog_pin_fires_exact_count
test_historical_ship_omission_fires_exact_count
test_held_locked_next_and_date_cleared
test_invoked_and_english_without_marker_are_clean
test_placeholder_and_stub_briefs_are_clean
test_builder_self_review_is_not_ov
test_distinct_ov_worker_is_clean
test_ov_report_and_skill_records
test_unrelated_rule_does_not_satisfy_exact_count
test_own_claims_pass_class_too_narrow
test_pretool_yes_ask_is_denied
test_hook_gathers_ship_skill_and_ov_report_records
test_hook_does_not_rerefuse_inflight_ship_without_ov
test_prior_turn_tool_mention_is_not_invoke_credit
test_same_turn_skill_tool_load_is_invoke_credit
test_brief_reads_ov_meta_and_report

echo "# all fm-owner-invoke-wait-check tests passed"
