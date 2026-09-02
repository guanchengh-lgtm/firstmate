#!/usr/bin/env bash
# Direct tests for bin/fm-promote.sh owned surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)

test_promote_help_owns_the_workflow_without_runtime_state() {
  local isolated home out status
  isolated="$TMP_ROOT/promote-help"
  home="$TMP_ROOT/promote-help-home"
  mkdir -p "$isolated/bin"
  cp "$ROOT/bin/fm-promote.sh" "$isolated/bin/fm-promote.sh"

  out=$(FM_ROOT_OVERRIDE="$isolated" FM_HOME="$home" \
    "$isolated/bin/fm-promote.sh" --help 2>&1)
  status=$?
  expect_code 0 "$status" "promotion help should work without runtime dependencies"
  assert_contains "$out" "existing scout in place" \
    "promotion help did not preserve the no-duplicate-task workflow"
  assert_contains "$out" "[--surface <internal-only|product|mixed|uncertain>]" \
    "promotion help omitted the --surface usage"
  [ ! -e "$home" ] || fail "promotion help created runtime state"
  pass "fm-promote: help owns the promotion workflow without runtime state"
}

test_promote_delivers_all_mode_dod_blocks() {
  local mode n=0 id actual_home expected_home actual expected out status
  local promote_args brief_args
  for mode in no-mistakes direct-PR local-only; do
    n=$((n + 1))
    id="promote-dod-$n"
    actual_home="$TMP_ROOT/dod-$n/actual"
    expected_home="$TMP_ROOT/dod-$n/expected"
    mkdir -p "$actual_home/state" "$expected_home/data"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/%s\n' "$id" "$id" \
      > "$actual_home/state/$id.meta"
    promote_args=("$id" --mode "$mode" --yolo off)
    brief_args=("$id" example --mode "$mode")
    if [ "$mode" = direct-PR ]; then
      promote_args+=(--surface internal-only)
      brief_args+=(--surface internal-only)
    fi

    out=$(FM_HOME="$actual_home" FM_STATE_OVERRIDE="$actual_home/state" \
      FM_DATA_OVERRIDE="$actual_home/data" \
      "$ROOT/bin/fm-promote.sh" "${promote_args[@]}" 2>&1)
    status=$?
    expect_code 0 "$status" "$mode promotion should write ship instructions (got: $out)"
    out=$(FM_HOME="$expected_home" \
      "$ROOT/bin/fm-brief.sh" "${brief_args[@]}" 2>&1)
    status=$?
    expect_code 0 "$status" "$mode brief should write the reference delivery contract (got: $out)"

    actual=$(awk 'seen || /^# Definition of done$/ { seen = 1; print }' \
      "$actual_home/data/$id/ship-instructions.md")
    expected=$(awk 'seen || /^# Definition of done$/ { seen = 1; print }' \
      "$expected_home/data/$id/brief.md")
    [ -n "$actual" ] || fail "$mode promotion omitted the Definition of done block"
    [ "$actual" = "$expected" ] \
      || fail "$mode promotion delivered a different Definition of done block than a ship brief"
  done
  pass "fm-promote: all delivery modes receive the ship brief Definition of done block"
}

test_promote_help_owns_the_workflow_without_runtime_state
test_promote_delivers_all_mode_dod_blocks
echo "# all fm-promote tests passed"
