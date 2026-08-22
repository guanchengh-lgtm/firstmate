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
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-validation-truth)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=/dev/null
. "$ROOT/bin/fm-validation-truth-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-nm-run-lib.sh"

test_parse_run_step_done() {
  fm_validation_truth_parse 'state: done · source: run-step · passed'
  [ "$FM_VT_STATE" = "done" ] || fail "parse state=$FM_VT_STATE"
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

write_real_nm_fakebin() {  # <fakebin-dir>
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
}

passed_run_toon() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "$2"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

prepare_lagging_git_wt() {  # <dir> <branch>  — echoes remote SHA; objects absent
  local dir=$1 branch=$2 sibling remote_abs sha
  rm -rf "$dir/wt"
  mkdir -p "$dir/wt"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m parent-a
  git -C "$dir/wt" checkout -q -b "$branch"
  fm_git_add_origin "$dir/wt" "$dir/remote.git"
  git -C "$dir/wt" push -q origin HEAD
  remote_abs=$(cd "$dir/remote.git" && pwd)
  sibling="$dir/sibling"
  git clone -q --branch "$branch" "file://$remote_abs" "$sibling"
  git -C "$sibling" commit -q --allow-empty -m pipeline-b
  sha=$(git -C "$sibling" rev-parse HEAD)
  git -C "$sibling" push -q origin "$branch"
  if git -C "$dir/wt" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    fail "missing-object fixture leaked remote commit $sha"
  fi
  printf '%s' "$sha"
}

prepare_diverged_git_wt() {  # <dir> <branch>  — echoes remote SHA; objects present
  local dir=$1 branch=$2 sibling remote_abs sha
  rm -rf "$dir/wt"
  mkdir -p "$dir/wt"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m parent-a
  git -C "$dir/wt" checkout -q -b "$branch"
  fm_git_add_origin "$dir/wt" "$dir/remote.git"
  git -C "$dir/wt" push -q origin HEAD
  remote_abs=$(cd "$dir/remote.git" && pwd)
  sibling="$dir/sibling"
  git clone -q --branch "$branch" "file://$remote_abs" "$sibling"
  git -C "$sibling" checkout -q --orphan tmp-div
  git -C "$sibling" commit -q --allow-empty -m pipeline-rebase
  sha=$(git -C "$sibling" rev-parse HEAD)
  git -C "$sibling" push -q --force origin HEAD:"$branch"
  git -C "$dir/wt" fetch -q origin "$branch:refs/fm-test/diverged"
  git -C "$dir/wt" cat-file -e "${sha}^{commit}" 2>/dev/null \
    || fail "diverged fixture missing remote object $sha"
  printf '%s' "$sha"
}

# Real crew-state + real helper: missing-object lag must not refuse.
test_missing_object_lag_allows_validation_truth() {
  local dir rc out remote_sha
  dir=$(make_task_home miss-obj-allow no-mistakes)
  remote_sha=$(prepare_lagging_git_wt "$dir" fm/task-a)
  write_real_nm_fakebin "$dir/fakebin"
  fm_nm_head_matches_worktree "$dir/wt" "$remote_sha" \
    || fail "identity missed missing-object live remote $remote_sha"
  FM_FAKE_AXI_STATUS=$(passed_run_toon fm/task-a "$remote_sha")
  export FM_FAKE_AXI_STATUS
  set +e
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_CREW_STATE_BIN="$CREW_STATE" \
    fm_require_validation_truth "$dir/home/state/task-a.meta" task-a 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing-object lag refused validation truth: $out"
  pass "validation-truth: missing-object lag with live remote allows"
}

PROOF_URL=https://github.com/o/r/pull/99
PROOF_HEAD=89e4863d0123456789abcdef0123456789abcdef

proof_runs_row() {  # <status> [sha]
  local st=$1 sha=${2:-$PROOF_HEAD}
  printf '  %s    fm/task-a-nm %s  2026-08-23 01:23  %s\n' "$st" "$sha" "$PROOF_URL"
}

write_pr_url_proof_bin() {  # <dir> [forge-head]
  local dir=$1 head=${2:-$PROOF_HEAD}
  write_real_nm_fakebin "$dir/fakebin"
  write_stub_crew_state "$dir/fakebin/fm-crew-state.sh" \
    'state: done · source: status-log · leftover builder'
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*)
        printf '%s %s\n' "\${FM_TEST_GH_HEAD:-$head}" "\${FM_TEST_GH_ROLLUP_VERDICT:-GREEN}"
        exit 0
        ;;
      *headRefOid*)
        printf '%s\n' "\${FM_TEST_GH_HEAD:-$head}"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_AXI_LOG:-/dev/null}"
exit 0
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi" "$dir/fakebin/tmux" "$dir/fakebin/treehouse"
}

run_pr_url_proof() {  # <dir> <url>
  local dir=$1 url=$2
  PATH="$dir/fakebin:$BASE_PATH" FM_HOME="$dir/home" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    fm_require_validation_truth "$dir/home/state/task-a.meta" task-a "$url"
}

prepare_unsuffixed_builder() {  # <dir>
  fm_git_init_commit "$1/wt"
  git -C "$1/wt" checkout -q -b fm/task-a
}

# Real crew-state + real helper: diverged rebase lag must not refuse.
test_diverged_rebase_allows_validation_truth() {
  local dir rc out remote_sha
  dir=$(make_task_home div-allow no-mistakes)
  remote_sha=$(prepare_diverged_git_wt "$dir" fm/task-a)
  write_real_nm_fakebin "$dir/fakebin"
  fm_nm_head_matches_worktree "$dir/wt" "$remote_sha" \
    || fail "identity missed diverged live remote $remote_sha"
  FM_FAKE_AXI_STATUS=$(passed_run_toon fm/task-a "$remote_sha")
  export FM_FAKE_AXI_STATUS
  set +e
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_CREW_STATE_BIN="$CREW_STATE" \
    fm_require_validation_truth "$dir/home/state/task-a.meta" task-a 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "diverged rebase lag refused validation truth: $out"
  pass "validation-truth: diverged rebase lag with live remote allows"
}

test_pr_url_proof_cancelled_run_refuses() {
  local dir rc out
  dir=$(make_task_home pr-url-cancelled no-mistakes)
  prepare_unsuffixed_builder "$dir"
  write_pr_url_proof_bin "$dir"
  FM_FAKE_RUNS_LIST=$(proof_runs_row cancelled)
  export FM_FAKE_RUNS_LIST
  set +e
  out=$(run_pr_url_proof "$dir" "$PROOF_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "cancelled run exited $rc: $out"
  assert_contains "$out" 'validation run is cancelled' "cancelled run used the wrong message"
  pass "validation-truth: cancelled PR-URL run refuses"
}

test_pr_url_proof_forge_head_mismatch_refuses() {
  local dir rc out
  dir=$(make_task_home pr-url-mismatch no-mistakes)
  prepare_unsuffixed_builder "$dir"
  write_pr_url_proof_bin "$dir"
  FM_FAKE_RUNS_LIST=$(proof_runs_row completed)
  export FM_FAKE_RUNS_LIST
  set +e
  out=$(FM_TEST_GH_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    run_pr_url_proof "$dir" "$PROOF_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "mismatch exited $rc: $out"
  assert_contains "$out" 'does not match forge head' "mismatch used the wrong message"
  pass "validation-truth: forge head mismatch refuses"
}

test_pr_url_proof_red_rollup_refuses() {
  local dir rc out
  dir=$(make_task_home pr-url-red no-mistakes)
  prepare_unsuffixed_builder "$dir"
  write_pr_url_proof_bin "$dir"
  FM_FAKE_RUNS_LIST=$(proof_runs_row completed)
  export FM_FAKE_RUNS_LIST
  set +e
  out=$(FM_TEST_GH_ROLLUP_VERDICT=RED run_pr_url_proof "$dir" "$PROOF_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "red rollup exited $rc: $out"
  assert_contains "$out" 'forge check rollup is RED' "red rollup used the wrong message"
  pass "validation-truth: red forge rollup refuses"
}

test_pr_url_proof_builder_check_merge_cleanup_pass() {
  local dir rc out
  dir=$(make_task_home pr-url-builder-pass no-mistakes)
  prepare_unsuffixed_builder "$dir"
  write_pr_url_proof_bin "$dir"
  FM_FAKE_RUNS_LIST=$(proof_runs_row completed)
  export FM_FAKE_RUNS_LIST
  : > "$dir/gh-axi.log"

  set +e
  out=$(FM_HOME="$dir/home" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a "$PROOF_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "builder pr-check refused: $out"
  assert_grep "pr=$PROOF_URL" "$dir/home/state/task-a.meta" \
    "builder pr-check did not record pr="
  assert_grep "pr_head=$PROOF_HEAD" "$dir/home/state/task-a.meta" \
    "builder pr-check did not record pr_head="

  set +e
  out=$(FM_HOME="$dir/home" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_MERGE" task-a "$PROOF_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "builder pr-merge refused: $out"
  grep -qxF "pr merge 99 --repo o/r --squash --match-head-commit $PROOF_HEAD" "$dir/gh-axi.log" \
    || fail "builder pr-merge did not pin --match-head-commit $PROOF_HEAD: $(cat "$dir/gh-axi.log")"

  rm -rf "$dir/wt"
  set +e
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "builder leftover cleanup refused: $out"
  assert_absent "$dir/home/state/task-a.meta" \
    "builder leftover cleanup left task meta in place"
  pass "validation-truth: builder id with -nm PR-URL run passes check, merge, and cleanup"
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
test_missing_object_lag_allows_validation_truth
test_diverged_rebase_allows_validation_truth
test_pr_url_proof_cancelled_run_refuses
test_pr_url_proof_forge_head_mismatch_refuses
test_pr_url_proof_red_rollup_refuses
test_pr_url_proof_builder_check_merge_cleanup_pass

echo "# all fm-validation-truth tests passed"
