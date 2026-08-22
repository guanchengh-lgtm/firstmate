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
  local out rc
  set +e
  out=$(run_check \
    --brief "$FIXTURES/historical-ship-without-eng-review.md" \
    --expect-rule R-required-skill-omitted --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical ship omission exact-count exited $rc: $out"
  set +e
  out=$(run_check --brief "$FIXTURES/historical-ship-without-eng-review.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical ship omission gate exited $rc: $out"
  assert_contains "$out" "R-required-skill-omitted-brief" \
    "historical ship omission did not report the missing skill"
  pass "owner-invoke-wait: 2026-08-22 reconstructed ship omission fires exact count 1"
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
  pass "owner-invoke-wait: held map_next, date-cleared, future, and real captain holds"
}

test_invoked_and_freeze_are_clean() {
  local out rc turn
  turn="$TMP_ROOT/invoked.json"
  write_turn "$turn" '{
    "assistant_text": "Want me to run /recurring-defect?",
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
  [ "$rc" -eq 0 ] || fail "invoked skill yes-ask exited $rc: $out"
  [ -z "$out" ] || fail "invoked skill printed findings: $out"
  turn="$TMP_ROOT/freeze.json"
  write_turn "$turn" '{
    "assistant_text": "Want me to run /office-hours on this fork?",
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
  [ "$rc" -eq 0 ] || fail "freeze skill yes-ask exited $rc: $out"
  [ -z "$out" ] || fail "freeze skill printed findings: $out"
  pass "owner-invoke-wait: invoked skill and name-and-wait freeze are clean"
}

test_placeholder_and_named_brief_are_clean() {
  local out rc brief
  brief="$TMP_ROOT/placeholder.md"
  printf '# Task\n{TASK}\n\n# Setup\nfixture\n' > "$brief"
  set +e
  out=$(run_check --brief "$brief")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "placeholder brief exited $rc: $out"
  [ -z "$out" ] || fail "placeholder brief printed findings: $out"
  brief="$TMP_ROOT/named.md"
  printf '# Task\nBefore any implementation: run /plan-eng-review on this ship plan.\n\n# Setup\nfixture\n' > "$brief"
  set +e
  out=$(run_check --brief "$brief")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "named brief exited $rc: $out"
  [ -z "$out" ] || fail "named brief printed findings: $out"
  brief="$TMP_ROOT/no-task.md"
  printf 'brief for stub\n' > "$brief"
  set +e
  out=$(run_check --brief "$brief")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "no-task stub exited $rc: $out"
  pass "owner-invoke-wait: placeholder, named, and no-task briefs are clean"
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
  payload=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Want me to run /recurring-defect?"}]}}')
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

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_historical_yes_ask_fires_exact_count
test_historical_fog_pin_fires_exact_count
test_historical_ship_omission_fires_exact_count
test_held_locked_next_and_date_cleared
test_invoked_and_freeze_are_clean
test_placeholder_and_named_brief_are_clean
test_unrelated_rule_does_not_satisfy_exact_count
test_own_claims_pass_class_too_narrow
test_pretool_yes_ask_is_denied

echo "# all fm-owner-invoke-wait-check tests passed"
