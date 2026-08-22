#!/usr/bin/env bash
# Behavioral coverage for the class-too-narrow claims refuse-hook.
# Exercises public CLI exit codes, exact-count regression, and derived
# 2026-08-22 naming. Does not assert checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-class-too-narrow-check.sh"
GENERATE="$ROOT/tests/fixtures/fm-class-too-narrow-check/generate-historical-narrow-naming.sh"
OWN_CLAIMS="$ROOT/docs/verification/class-too-narrow-check-claims.json"
STOW_CLAIMS="$ROOT/docs/verification/stow-open-lock-recurring-defect-claims.json"
TMP_ROOT=$(fm_test_tmproot fm-class-too-narrow-check)

run_check() {
  "$CHECK" "$@" 2>&1
}

write_claims() {
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
  [ "$rc" -eq 2 ] || fail "missing --input exited $rc"
  assert_contains "$out" "missing claims" "missing input did not name the claims"
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
  out=$(run_check --input "$empty" --expect-rule R-broader-than-shape --expect-count 0)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(run_check --input "$OWN_CLAIMS" --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  pass "class-too-narrow: missing and empty input, expect-count 0, empty rules exit 2"
}

test_derived_historical_naming_fires_exact_count() {
  local out rc derived
  derived="$TMP_ROOT/historical-narrow-naming.json"
  "$GENERATE" --output "$derived" || fail "generator failed on PR 29 claims"
  set +e
  out=$(run_check \
    --input "$derived" \
    --expect-rule R-broader-than-shape --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "derived fixture exact-count exited $rc: $out"
  set +e
  out=$(run_check --input "$derived")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "derived fixture gate exited $rc: $out"
  assert_contains "$out" "R-broader-than-shape-escaped" \
    "derived fixture did not report an escaped instance"
  assert_contains "$out" "stow" "derived fixture did not name the /stow token"
  pass "class-too-narrow: 2026-08-22 derived naming fires exact count 1"
}

test_unrelated_rule_does_not_satisfy_exact_count() {
  local out rc derived few
  derived="$TMP_ROOT/historical-narrow-naming.json"
  [ -f "$derived" ] || "$GENERATE" --output "$derived" \
    || fail "generator failed on PR 29 claims"
  # Property holds on the historical fixture, so expecting R-property to fire
  # must not go green just because a different rule fired.
  set +e
  out=$(run_check \
    --input "$derived" \
    --expect-rule R-property --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "unrelated R-property exact-count exited $rc: $out"
  assert_contains "$out" "regression:" "unrelated-rule miss was not a count mismatch"
  few="$TMP_ROOT/few-instances.json"
  write_claims "$few" '{
    "shape": "A recovery property about live work after a session ends.",
    "instances": ["only one clothes"]
  }'
  set +e
  out=$(run_check \
    --input "$few" \
    --expect-rule R-broader-than-shape --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "few-instances broader exact-count exited $rc: $out"
  pass "class-too-narrow: unrelated rule fire is not exact-count success"
}

test_property_and_two_clothes_findings() {
  local out rc claims
  claims="$TMP_ROOT/no-property.json"
  write_claims "$claims" '{
    "instances": [
      "2026-08-18 session-resume clothes",
      "2026-08-22 stow receipt clothes"
    ]
  }'
  set +e
  out=$(run_check --input "$claims")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing shape exited $rc: $out"
  assert_contains "$out" "R-property-missing" "missing shape did not report R-property"
  claims="$TMP_ROOT/token-shape.json"
  write_claims "$claims" '{
    "shape": "stow-reset-safe",
    "instances": [
      "2026-08-18 session-resume clothes",
      "2026-08-22 stow receipt clothes"
    ]
  }'
  set +e
  out=$(run_check --input "$claims")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "token shape exited $rc: $out"
  assert_contains "$out" "R-property-not-a-property" \
    "single-token shape did not report R-property"
  claims="$TMP_ROOT/one-instance.json"
  write_claims "$claims" '{
    "shape": "A recovery property about live work after a session ends.",
    "instances": ["only one clothes"]
  }'
  set +e
  out=$(run_check --input "$claims")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "one instance exited $rc: $out"
  assert_contains "$out" "R-two-clothes-few" "one instance did not report R-two-clothes"
  claims="$TMP_ROOT/same-clothes.json"
  write_claims "$claims" '{
    "shape": "A recovery property about live work after a session ends.",
    "instances": [
      "2026-08-18 picks lived in talk and the next session invented replacements.",
      "2026-08-22 picks lived in talk and the next session invented replacements."
    ]
  }'
  set +e
  out=$(run_check --input "$claims")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "same clothes exited $rc: $out"
  assert_contains "$out" "R-two-clothes-same" "date-only difference counted as clothes"
  pass "class-too-narrow: missing property and same clothes are findings"
}

test_consistent_command_class_and_own_claims_are_clean() {
  local out rc claims
  claims="$TMP_ROOT/consistent-stow.json"
  write_claims "$claims" '{
    "shape": "After /stow, a reset-safe receipt must list every still-open lock pick.",
    "instances": [
      "2026-08-22 stow said reset-safe while Q2 was still open.",
      "A later stow receipt omitted a Still-open lock-file pick."
    ]
  }'
  set +e
  out=$(run_check --input "$claims")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "consistent /stow class exited $rc: $out"
  [ -z "$out" ] || fail "consistent /stow class printed findings: $out"
  set +e
  out=$(run_check --input "$OWN_CLAIMS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "own claims file exited $rc: $out"
  [ -z "$out" ] || fail "own claims file printed findings: $out"
  pass "class-too-narrow: consistent command class and own claims are clean"
}

test_new_tracked_claims_are_gated() {
  local out rc path base grandfather
  grandfather="class-repeat-gate-claims.json
durable-sot-recurring-defect-claims.json
stow-open-lock-recurring-defect-claims.json"
  shopt -s nullglob
  for path in "$ROOT"/docs/verification/*claims.json; do
    base=$(basename "$path")
    case $'\n'"$grandfather"$'\n' in
      *$'\n'"$base"$'\n'*) continue ;;
    esac
    set +e
    out=$(run_check --input "$path")
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "new claims $base exited $rc: $out"
    [ -z "$out" ] || fail "new claims $base printed findings: $out"
  done
  shopt -u nullglob
  # PR 29 naming stays on disk as the historical instance; do not rewrite it.
  [ -f "$STOW_CLAIMS" ] || fail "PR 29 stow-open-lock claims are missing"
  pass "class-too-narrow: new tracked claims pass; PR 29 claims remain"
}

test_generator_asserts_historical_markers() {
  local out rc bad dest
  dest="$TMP_ROOT/should-not-write.json"
  bad="$TMP_ROOT/not-narrow.json"
  write_claims "$bad" '{
    "shape": "A recovery property about live work after a session ends.",
    "instances": [
      "2026-08-18 session-resume clothes",
      "2026-08-22 stow receipt clothes"
    ]
  }'
  set +e
  out=$("$GENERATE" --source "$bad" --output "$dest" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "generator accepted a mechanism-shaped source: $rc $out"
  assert_contains "$out" "/stow" "generator did not require the /stow marker"
  [ ! -e "$dest" ] || fail "generator wrote output after a failed assertion"
  pass "class-too-narrow: generator refuses a source that is not the 2026-08-22 naming"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_derived_historical_naming_fires_exact_count
test_unrelated_rule_does_not_satisfy_exact_count
test_property_and_two_clothes_findings
test_consistent_command_class_and_own_claims_are_clean
test_new_tracked_claims_are_gated
test_generator_asserts_historical_markers

echo "# all fm-class-too-narrow-check tests passed"
