#!/usr/bin/env bash
# Behavioral coverage for the session-progress retrieve refuse-hook.
# Exercises public CLI exit codes, exact-count regression, and retrieve
# surfaces. Does not assert checker source bytes.
# LIMITS: asides outside live jobs, open picks, and captain lock words are
# not covered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-session-progress-retrieve-check.sh"
FOLD="$ROOT/bin/fm-prior-session-fold.sh"
HIST="$ROOT/tests/fixtures/fm-session-progress-retrieve-check/historical-answered-pick"
TMP_ROOT=$(fm_test_tmproot fm-session-progress-retrieve-check)
LOCK_WORDS='Go with Playbook/TV.'
ASIDE='The weather is pleasant today.'

run_check() {
  "$CHECK" "$@" 2>&1
}

fold_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf '%s\n' "$home"
}

test_missing_and_empty_inputs_are_structural() {
  local out rc empty
  empty="$TMP_ROOT/empty.jsonl"
  : > "$empty"
  set +e
  out=$(run_check)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing args exited $rc"
  assert_contains "$out" "missing prior-log" "missing args did not name prior-log"
  set +e
  out=$(run_check --prior-log "$TMP_ROOT/no-such.jsonl" --retrieve "$HIST/retrieve-none.json")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing prior-log file exited $rc"
  assert_contains "$out" "missing prior-log" "missing file did not say missing"
  set +e
  out=$(run_check --prior-log "$empty" --retrieve "$HIST/retrieve-none.json")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty prior-log exited $rc"
  assert_contains "$out" "empty prior-log" "empty prior-log was not structural"
  set +e
  out=$(run_check --prior-log "$HIST/prior.jsonl" --retrieve "$empty")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty retrieve exited $rc"
  assert_contains "$out" "empty retrieve" "empty retrieve was not structural"
  pass "session-progress retrieve: missing and empty inputs exit 2"
}

test_historical_answered_pick_without_retrieve_fires_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --prior-log "$HIST/prior.jsonl" \
    --retrieve "$HIST/retrieve-none.json" \
    --expect-rule R-retrieve-omitted --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical fixture exact-count exited $rc: $out"
  set +e
  out=$(run_check \
    --prior-log "$HIST/prior.jsonl" \
    --retrieve "$HIST/retrieve-none.json")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical fixture gate exited $rc"
  assert_contains "$out" "R-retrieve-omitted-bar-item" \
    "historical fixture did not report omitted retrieve"
  assert_contains "$out" "$LOCK_WORDS" "historical fixture did not name the lock words"
  assert_not_contains "$out" "$ASIDE" "historical fixture treated an aside as a bar item"
  pass "session-progress retrieve: historical answered-pick with no retrieve fires exact count 1"
}

test_fold_retrieve_and_aside_omission_are_clean() {
  local home out rc retrieve
  home=$(fold_home fold-ok)
  retrieve="$TMP_ROOT/retrieve-ok.txt"
  FM_HOME="$home" FM_PRIOR_SESSION_LOG="$HIST/prior.jsonl" "$FOLD" > "$retrieve" \
    || fail "fold of historical prior log failed"
  assert_contains "$(cat "$retrieve")" "$LOCK_WORDS" "fold did not keep lock words"
  assert_not_contains "$(cat "$retrieve")" "$ASIDE" "fold leaked the aside"
  set +e
  out=$(run_check --prior-log "$HIST/prior.jsonl" --retrieve "$retrieve")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "fold retrieve still exited $rc: $out"
  [ -z "$out" ] || fail "fold retrieve printed findings: $out"
  printf '%s\n' "$LOCK_WORDS" > "$TMP_ROOT/lock-only.txt"
  set +e
  out=$(run_check --prior-log "$HIST/prior.jsonl" --retrieve "$TMP_ROOT/lock-only.txt")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "lock-words-only retrieve still exited $rc: $out"
  [ -z "$out" ] || fail "lock-words-only retrieve printed findings: $out"
  pass "session-progress retrieve: fold retrieve and aside-free lock words are clean"
}

test_expect_count_zero_and_empty_rules_are_structural() {
  local out rc
  set +e
  out=$(run_check \
    --prior-log "$HIST/prior.jsonl" \
    --retrieve "$HIST/retrieve-none.json" \
    --expect-rule R-retrieve-omitted --expect-count 0 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(run_check \
    --prior-log "$HIST/prior.jsonl" \
    --retrieve "$HIST/retrieve-none.json" \
    --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  pass "session-progress retrieve: expect-count 0 and empty rules exit 2"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_inputs_are_structural
test_historical_answered_pick_without_retrieve_fires_exact_count
test_fold_retrieve_and_aside_omission_are_clean
test_expect_count_zero_and_empty_rules_are_structural

echo "# all fm-session-progress-retrieve-check tests passed"
