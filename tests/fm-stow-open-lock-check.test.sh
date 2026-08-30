#!/usr/bin/env bash
# Behavioral coverage for the stow open-lock refuse-hook.
# Exercises public CLI exit codes, exact-count regression, and --list-open.
# Does not assert checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-stow-open-lock-check.sh"
HIST="$ROOT/tests/fixtures/fm-stow-open-lock-check/historical-q2-open"
LOCKED="$ROOT/tests/fixtures/fm-stow-open-lock-check/locked-q2"
TMP_ROOT=$(fm_test_tmproot fm-stow-open-lock-check)
# Decision prose is stored as .fixture so it is not a maintained-doc surface;
# materialize the public *.md names under a temp decisions dir for the checker.
HIST_DECISIONS="$TMP_ROOT/historical-q2-open/decisions"
LOCKED_DECISIONS="$TMP_ROOT/locked-q2/decisions"
mkdir -p "$HIST_DECISIONS" "$LOCKED_DECISIONS"
cp "$HIST/secondmate-2026-08-22.fixture" "$HIST_DECISIONS/secondmate-2026-08-22.md"
cp "$LOCKED/secondmate-2026-08-22.fixture" "$LOCKED_DECISIONS/secondmate-2026-08-22.md"

run_check() {
  "$CHECK" "$@" 2>&1
}

test_missing_and_empty_input_are_structural() {
  local out rc empty not_dir
  empty="$TMP_ROOT/empty.json"
  : > "$empty"
  set +e
  out=$(run_check)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing --input exited $rc"
  assert_contains "$out" "missing receipt" "missing input did not name the receipt"
  set +e
  out=$(run_check --input "$TMP_ROOT/no-such.json")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing file exited $rc"
  assert_contains "$out" "missing receipt" "missing file did not say missing"
  set +e
  out=$(run_check --input "$empty")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty receipt exited $rc"
  assert_contains "$out" "empty receipt" "empty receipt was not structural"
  not_dir="$TMP_ROOT/not-a-decisions-directory"
  printf 'not a directory\n' > "$not_dir"
  set +e
  out=$(run_check --list-open --decisions-dir "$not_dir" --file lock.md)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "scoped reader non-directory exited $rc: $out"
  assert_contains "$out" "decisions path is not a regular directory" \
    "scoped reader non-directory did not stay structural"
  pass "stow open-lock: missing and empty input exit 2"
}

test_historical_q2_open_fires_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$HIST/receipt.json" \
    --decisions-dir "$HIST_DECISIONS" \
    --expect-rule R-stow-open-lock --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical fixture exact-count exited $rc: $out"
  set +e
  out=$(run_check \
    --input "$HIST/receipt.json" \
    --decisions-dir "$HIST_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical fixture gate exited $rc"
  assert_contains "$out" "R-stow-open-lock-unlisted" \
    "historical fixture did not report the unlisted Q2 pick"
  assert_contains "$out" "Q2" "historical fixture did not name Q2"
  pass "stow open-lock: historical Q2-open fixture fires exact count 1"
}

test_listed_pick_and_locked_file_are_clean() {
  local out rc listed
  listed="$TMP_ROOT/listed.json"
  printf '%s\n' '{"reset_safe":true,"remaining_session_picks":["Q2"]}' > "$listed"
  set +e
  out=$(run_check --input "$listed" --decisions-dir "$HIST_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "listed Q2 still exited $rc: $out"
  [ -z "$out" ] || fail "listed Q2 printed findings: $out"
  set +e
  out=$(run_check --input "$LOCKED/receipt.json" --decisions-dir "$LOCKED_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "locked Q2 still exited $rc: $out"
  [ -z "$out" ] || fail "locked Q2 printed findings: $out"
  pass "stow open-lock: listed remaining pick and locked Q2 are clean"
}

test_bearings_omit_fires_exact_count() {
  local out rc receipt
  receipt="$TMP_ROOT/not-safe.json"
  printf '%s\n' '{"reset_safe":false,"remaining_session_picks":[]}' > "$receipt"
  set +e
  out=$(run_check \
    --input "$receipt" \
    --decisions-dir "$HIST_DECISIONS" \
    --snapshot "$HIST/snapshot-omit.json" \
    --expect-rule R-bearings-lists-open-locks --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "bearings-omit exact-count exited $rc: $out"
  set +e
  out=$(run_check \
    --input "$receipt" \
    --decisions-dir "$HIST_DECISIONS" \
    --snapshot "$HIST/snapshot-list.json")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "listed snapshot still exited $rc: $out"
  pass "stow open-lock: omitted snapshot fires exact count 1; listed snapshot is clean"
}

test_list_open_and_expect_count_zero_are_structural_or_public() {
  local out rc
  set +e
  out=$(run_check --list-open --decisions-dir "$HIST_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--list-open exited $rc: $out"
  printf '%s' "$out" | jq -e '
    length == 1
      and .[0].key == "Q2"
      and .[0].id == "secondmate-2026-08-22/Q2"
      and .[0].verb == "lock-open"
      and .[0].source == "decision-lock"
  ' >/dev/null || fail "--list-open JSON missed Q2: $out"
  set +e
  out=$(run_check --list-open --decisions-dir "$LOCKED_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "locked --list-open exited $rc"
  printf '%s' "$out" | jq -e 'length == 0' >/dev/null \
    || fail "locked file listed open picks: $out"
  set +e
  out=$(run_check \
    --input "$HIST/receipt.json" \
    --decisions-dir "$HIST_DECISIONS" \
    --expect-rule R-stow-open-lock --expect-count 0 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(run_check --input "$HIST/receipt.json" --decisions-dir "$HIST_DECISIONS" --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  set +e
  out=$(run_check --input "$HIST/receipt.json" --decisions-dir "$HIST_DECISIONS" \
    --file secondmate-2026-08-22.md)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "receipt mode accepted scoped --file with exit $rc"
  assert_contains "$out" "--file requires --list-open" \
    "receipt mode did not reject scoped --file"
  pass "stow open-lock: --list-open is public JSON; expect-count 0 and empty rules exit 2"
}

test_quoted_still_open_mention_is_not_a_marker() {
  local out rc
  set +e
  out=$(run_check --list-open --decisions-dir "$LOCKED_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "mention check --list-open exited $rc"
  printf '%s' "$out" | jq -e 'length == 0' >/dev/null \
    || fail "quoted Still open mention became an open pick: $out"
  pass "stow open-lock: locked Q-item with quoted Still open is not a marker"
}

test_summary_substring_remaining_pick_is_not_clean() {
  local out rc bogus
  bogus="$TMP_ROOT/substring-remaining.json"
  printf '%s\n' '{"reset_safe":true,"remaining_session_picks":["still open"]}' > "$bogus"
  set +e
  out=$(run_check --input "$bogus" --decisions-dir "$HIST_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "summary-substring remaining pick exited $rc: $out"
  assert_contains "$out" "R-stow-open-lock-unlisted" \
    "summary-substring remaining pick did not fire unlisted"
  assert_contains "$out" "Q2" \
    "summary-substring remaining pick did not name Q2"
  printf '%s\n' '{"reset_safe":true,"remaining_session_picks":["open"]}' > "$bogus"
  set +e
  out=$(run_check --input "$bogus" --decisions-dir "$HIST_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "generic 'open' remaining pick exited $rc: $out"
  assert_contains "$out" "R-stow-open-lock-unlisted" \
    "generic 'open' remaining pick did not fire unlisted"
  pass "stow open-lock: summary substring remaining picks are not clean"
}

test_file_stem_remaining_pick_is_not_clean() {
  local out rc bogus decisions
  bogus="$TMP_ROOT/file-stem-remaining.json"
  decisions="$TMP_ROOT/session-stem-decisions"
  mkdir -p "$decisions"
  cat > "$decisions/session.md" <<'EOF'
# session
- **Q1 Scope.** Still open.
- **Q2 Scope.** Still open.
EOF
  # File stem alone must not cover every open pick in that decision file.
  printf '%s\n' '{"reset_safe":true,"remaining_session_picks":["session"]}' > "$bogus"
  set +e
  out=$(run_check --input "$bogus" --decisions-dir "$decisions")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "session stem remaining pick exited $rc: $out"
  assert_contains "$out" "R-stow-open-lock-unlisted" \
    "session stem remaining pick did not fire unlisted"
  assert_contains "$out" "Q1" "session stem remaining pick did not name Q1"
  assert_contains "$out" "Q2" "session stem remaining pick did not name Q2"
  printf '%s\n' '{"reset_safe":true,"remaining_session_picks":["secondmate-2026-08-22"]}' > "$bogus"
  set +e
  out=$(run_check --input "$bogus" --decisions-dir "$HIST_DECISIONS")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical file-stem remaining pick exited $rc: $out"
  assert_contains "$out" "R-stow-open-lock-unlisted" \
    "historical file-stem remaining pick did not fire unlisted"
  assert_contains "$out" "Q2" \
    "historical file-stem remaining pick did not name Q2"
  pass "stow open-lock: decision file-stem remaining picks are not clean"
}

test_snapshot_key_collision_is_not_clean() {
  local out rc receipt decisions snap
  receipt="$TMP_ROOT/not-safe-key-collision.json"
  decisions="$TMP_ROOT/two-q2-decisions"
  snap="$TMP_ROOT/snap-key-collision.json"
  mkdir -p "$decisions"
  printf '%s\n' '{"reset_safe":false,"remaining_session_picks":[]}' > "$receipt"
  cat > "$decisions/secondmate-2026-08-22.md" <<'EOF'
# secondmate 2026-08-22
- **Q2 Scope.** Still open.
EOF
  cat > "$decisions/secondmate-2026-08-23.md" <<'EOF'
# secondmate 2026-08-23
- **Q2 Scope.** Still open.
EOF
  # Snapshot lists only one lock-open full id; bare key Q2 must not cover the other.
  cat > "$snap" <<'EOF'
{
  "decisions_open": [
    {
      "id": "secondmate-2026-08-22/Q2",
      "key": "Q2",
      "verb": "lock-open",
      "summary": "Q2 Scope still open"
    },
    {
      "id": "Q2",
      "key": "Q2",
      "verb": "captain-hold",
      "summary": "unrelated hold with colliding key"
    }
  ]
}
EOF
  set +e
  out=$(run_check \
    --input "$receipt" \
    --decisions-dir "$decisions" \
    --snapshot "$snap" \
    --expect-rule R-bearings-lists-open-locks --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "key-collision exact-count exited $rc: $out"
  set +e
  out=$(run_check \
    --input "$receipt" \
    --decisions-dir "$decisions" \
    --snapshot "$snap")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "key-collision gate exited $rc: $out"
  assert_contains "$out" "R-bearings-lists-open-locks-omitted" \
    "key-collision did not report omitted lock pick"
  assert_contains "$out" "secondmate-2026-08-23/Q2" \
    "key-collision did not name the omitted full pick id"
  # Mate-prefixed full id still covers the pick (bearings secondmate projection).
  cat > "$snap" <<'EOF'
{
  "decisions_open": [
    {
      "id": "mate/mate-picks/secondmate-2026-08-22/Q2",
      "key": "Q2",
      "verb": "lock-open",
      "summary": "Q2 Scope still open"
    },
    {
      "id": "mate/mate-picks/secondmate-2026-08-23/Q2",
      "key": "Q2",
      "verb": "lock-open",
      "summary": "Q2 Scope still open"
    }
  ]
}
EOF
  set +e
  out=$(run_check \
    --input "$receipt" \
    --decisions-dir "$decisions" \
    --snapshot "$snap")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "mate-prefixed lock-open ids still exited $rc: $out"
  [ -z "$out" ] || fail "mate-prefixed lock-open ids printed findings: $out"
  pass "stow open-lock: snapshot key collision is not clean; mate-prefixed ids cover"
}

test_scaled_decision_fixture_keeps_verdict_and_cost_bounded() {
  local small="$TMP_ROOT/scale-small" scaled="$TMP_ROOT/scale-large"
  local small_out scaled_out scoped_out start small_ms scaled_ms rc
  fm_test_seed_guard_scale_fixture "$small" 3
  fm_test_seed_guard_scale_fixture "$scaled" 200

  start=$(fm_test_monotonic_ms)
  set +e
  small_out=$(run_check --list-open --decisions-dir "$small/data/decisions")
  rc=$?
  set -e
  small_ms=$(($(fm_test_monotonic_ms) - start))
  [ "$rc" -eq 0 ] || fail "small scaled-fixture oracle exited $rc: $small_out"

  start=$(fm_test_monotonic_ms)
  set +e
  scaled_out=$(run_check --list-open --decisions-dir "$scaled/data/decisions")
  rc=$?
  set -e
  scaled_ms=$(($(fm_test_monotonic_ms) - start))
  [ "$rc" -eq 0 ] || fail "large scaled-fixture oracle exited $rc: $scaled_out"
  [ "$(printf '%s' "$small_out" | jq -cS .)" = "$(printf '%s' "$scaled_out" | jq -cS .)" ] \
    || fail "scaled decision fixture changed --list-open verdict"
  printf '%s' "$scaled_out" | jq -e \
    'length == 1 and .[0].file == "data/decisions/open.md"' >/dev/null \
    || fail "scaled decision fixture included the symlinked lock"
  scoped_out=$(run_check --list-open --decisions-dir "$scaled/data/decisions" \
    --file claim.md)
  printf '%s' "$scoped_out" | jq -e 'length == 0' >/dev/null \
    || fail "--file scanned decisions outside its requested file"
  fm_test_assert_scale_bound "$small_ms" "$scaled_ms" "stow open-lock"
  pass "stow open-lock: 200 decision files preserve verdict with bounded scaling"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_historical_q2_open_fires_exact_count
test_listed_pick_and_locked_file_are_clean
test_bearings_omit_fires_exact_count
test_list_open_and_expect_count_zero_are_structural_or_public
test_quoted_still_open_mention_is_not_a_marker
test_summary_substring_remaining_pick_is_not_clean
test_file_stem_remaining_pick_is_not_clean
test_snapshot_key_collision_is_not_clean
test_scaled_decision_fixture_keeps_verdict_and_cost_bounded

echo "# all fm-stow-open-lock-check tests passed"
