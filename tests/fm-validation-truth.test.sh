#!/usr/bin/env bash
# Behavioral coverage for no-mistakes validation-truth refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This file verifies the real refusal. Strip the suite-wide test bypass.
unset FM_VALIDATION_TRUTH_BYPASS

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-truth)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-validation-truth-lib.sh"

test_parse_run_step_done() {
  fm_validation_truth_parse 'state: done · source: run-step · passed'
  [ "$FM_VT_STATE" = done ] || fail "parse state=$FM_VT_STATE"
  [ "$FM_VT_SOURCE" = run-step ] || fail "parse source=$FM_VT_SOURCE"
  pass "validation-truth: parses run-step done"
}

test_parse_pane_is_not_run_step() {
  fm_validation_truth_parse 'state: working · source: pane · busy'
  [ "$FM_VT_SOURCE" = pane ] || fail "parse source=$FM_VT_SOURCE"
  pass "validation-truth: parses pane source"
}

write_stub_crew_state() {
  local file=$1 line=$2
  cat > "$file" <<STUB
#!/usr/bin/env bash
printf '%s\n' '$line'
STUB
  chmod +x "$file"
}

make_task_home() {
  local name=$1 mode=$2
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$dir/fakebin"
  fm_write_none_measure "$dir/home" task-a
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=$mode"
  printf '%s\n' "$dir"
}

test_direct_pr_is_exempt() {
  local dir rc
  dir=$(make_task_home exempt-direct direct-PR)
  write_stub_crew_state "$dir/fakebin/fm-crew-state.sh" 'state: working · source: pane · busy'
  SCRIPT_DIR="$dir/fakebin"
  set +e
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    fm_require_validation_truth "$dir/home/state/task-a.meta" task-a
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "direct-PR should be exempt, exited $rc"
  pass "validation-truth: direct-PR is exempt"
}

test_pane_source_refuses_no_mistakes() {
  local dir rc out
  dir=$(make_task_home pane-refuse no-mistakes)
  write_stub_crew_state "$dir/fakebin/fm-crew-state.sh" 'state: working · source: pane · busy'
  set +e
  out=$(FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    fm_require_validation_truth "$dir/home/state/task-a.meta" task-a 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "pane source exited $rc"
  assert_contains "$out" 'validation truth unreadable' "pane refusal used the wrong message"
  pass "validation-truth: pane source refuses as unreadable"
}

test_run_step_done_allows() {
  local dir rc
  dir=$(make_task_home run-ok no-mistakes)
  write_stub_crew_state "$dir/fakebin/fm-crew-state.sh" 'state: done · source: run-step · passed'
  set +e
  FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    fm_require_validation_truth "$dir/home/state/task-a.meta" task-a
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "run-step done should pass, exited $rc"
  pass "validation-truth: run-step done allows"
}

test_run_step_working_refuses() {
  local dir rc out
  dir=$(make_task_home run-working no-mistakes)
  write_stub_crew_state "$dir/fakebin/fm-crew-state.sh" 'state: working · source: run-step · ci'
  set +e
  out=$(FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    fm_require_validation_truth "$dir/home/state/task-a.meta" task-a 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "working run-step exited $rc"
  assert_contains "$out" 'validation run is not done' "working run used the unreadable message"
  pass "validation-truth: run-step not done refuses without unreadable wording"
}

test_pr_check_refuses_pane_truth() {
  local dir out rc fakebin
  dir=$(make_task_home pr-pane no-mistakes)
  fakebin="$dir/fakebin"
  write_stub_crew_state "$fakebin/fm-crew-state.sh" 'state: working · source: pane · busy'
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  set +e
  out=$(FM_HOME="$dir/home" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    PATH="$fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a https://github.com/o/r/pull/10 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pr-check armed a pane-truth no-mistakes ship"
  assert_contains "$out" 'validation truth unreadable' "pr-check pane refusal missing"
  pass "validation-truth: pr-check refuses pane-sourced no-mistakes ships"
}

prepare_teardown_home() {
  local dir=$1 line=$2
  mkdir -p "$dir/home/config" "$dir/fakebin"
  # No worktree path on disk so non-force teardown skips landed-work inspection
  # and reaches the validation-truth gate with a valid none: measure.
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/missing-wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  write_stub_crew_state "$dir/fakebin/fm-crew-state.sh" "$line"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse" "$dir/fakebin/no-mistakes"
}

test_teardown_non_force_refuses_pane_truth() {
  local dir out rc
  dir=$(make_task_home td-pane no-mistakes)
  prepare_teardown_home "$dir" 'state: working · source: pane · busy'
  set +e
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "non-force teardown cleaned a pane-truth no-mistakes ship"
  assert_contains "$out" 'validation truth unreadable' "non-force teardown pane refusal missing"
  assert_present "$dir/home/state/task-a.meta" \
    "non-force teardown removed meta after validation-truth refusal"
  pass "validation-truth: non-force teardown refuses pane-sourced no-mistakes ships"
}

test_teardown_force_skips_validation_truth() {
  local dir out rc
  dir=$(make_task_home td-force no-mistakes)
  prepare_teardown_home "$dir" 'state: failed · source: run-step · failed'
  set +e
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force 2>&1)
  rc=$?
  set -e
  case "$out" in
    *'validation truth unreadable'*|*'validation run is not done'*)
      fail "--force teardown still applied validation-truth: $out"
      ;;
  esac
  [ "$rc" -eq 0 ] || fail "--force teardown failed for a non-done run-step ship: $out"
  assert_absent "$dir/home/state/task-a.meta" \
    "--force teardown left task meta in place"
  pass "validation-truth: --force teardown skips validation-truth on discard"
}

test_teardown_force_still_requires_measure() {
  local dir out rc
  dir=$(make_task_home td-force-measure no-mistakes)
  prepare_teardown_home "$dir" 'state: failed · source: run-step · failed'
  rm -f "$dir/home/data/task-a/measure.md"
  set +e
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--force teardown skipped the measure gate"
  assert_contains "$out" 'no non-empty measure' "--force measure refusal missing"
  pass "validation-truth: --force teardown still requires a measure"
}

test_parse_run_step_done
test_parse_pane_is_not_run_step
test_direct_pr_is_exempt
test_pane_source_refuses_no_mistakes
test_run_step_done_allows
test_run_step_working_refuses
test_pr_check_refuses_pane_truth
test_teardown_non_force_refuses_pane_truth
test_teardown_force_skips_validation_truth
test_teardown_force_still_requires_measure

echo "# all fm-validation-truth tests passed"
