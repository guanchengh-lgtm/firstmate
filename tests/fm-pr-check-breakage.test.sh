#!/usr/bin/env bash
# Behavioral coverage for the advisory manufactured-breakage check in
# bin/fm-pr-check.sh. The check prints one BREAKAGE line when a changed test
# file has no covering second-token `breakage:` tested[] record, and never
# changes the exit code. Twelve engineering-review cases plus a real-log
# fixture.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-breakage)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.invalid

PR_URL='https://github.com/fm-breakage-test/repo/pull/7'
RUN_ID='01TESTBREAKAGE000000000001'
TASK_BRANCH='fm/task-a'

# Locked tested[] line shape used by the verifier DoD, as it appears inside
# pretty-printed axi logs --full output (leading spaces + JSON string quote).
breakage_line() {  # <test-file> [subject]
  local tf=$1 subj=${2:-app.sh:1}
  printf '    "breakage: %s subject %s selector unit red /tmp/red.txt"' "$tf" "$subj"
}

clean_breakage_line() {
  printf '    "breakage: porcelain-clean subject none selector none red none"'
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" \
    "$dir/nm-home" "$dir/root/bin" "$fakebin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*)
    if [ -n "${FM_TEST_GH_HEAD:-}" ]; then
      printf '%s\n' "$FM_TEST_GH_HEAD"
    fi
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" axi status "*)
    [ "${FM_TEST_NM_STATUS_RC:-0}" = 0 ] || exit "$FM_TEST_NM_STATUS_RC"
    printf 'run:\n  id: "%s"\n  branch: "%s"\n  pr: "%s"\n' \
      "${FM_TEST_NM_RUN_ID:-}" \
      "${FM_TEST_NM_BRANCH:-fm/task-a}" \
      "${FM_TEST_NM_PR:-}"
    exit 0
    ;;
  *" axi logs "*)
    [ "${FM_TEST_NM_LOGS_RC:-0}" = 0 ] || exit "$FM_TEST_NM_LOGS_RC"
    printf '%s\n' "${FM_TEST_NM_LOGS-}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/no-mistakes"
  fm_write_none_measure "$dir/home" task-a
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 mode=${2:-no-mistakes} kind=${3:-ship}
  fm_write_none_measure "$dir/home" task-a
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=$kind" \
    "mode=$mode"
}

init_ship_git() {
  local dir=$1
  shift
  mkdir -p "$dir/wt"
  git -C "$dir/wt" init -q -b main
  printf 'src\n' > "$dir/wt/app.sh"
  git -C "$dir/wt" add app.sh
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git -C "$dir/wt" checkout -q -b "$TASK_BRANCH"
  local path dirn
  for path in "$@"; do
    dirn=$(dirname "$path")
    mkdir -p "$dir/wt/$dirn"
    printf 'test body\n' > "$dir/wt/$path"
    git -C "$dir/wt" add "$path"
  done
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'add tests'
}

run_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    NO_MISTAKES_HOME="$dir/nm-home" \
    FM_TEST_NM_RUN_ID="${FM_TEST_NM_RUN_ID:-$RUN_ID}" \
    FM_TEST_NM_PR="${FM_TEST_NM_PR:-$PR_URL}" \
    FM_TEST_NM_BRANCH="${FM_TEST_NM_BRANCH:-$TASK_BRANCH}" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

breakage_lines() {
  printf '%s\n' "$1" | grep -c '^BREAKAGE:' || true
}

# 1. Missing covering record prints one advisory line and still arms.
test_mismatch_prints_one_line_and_still_arms() {
  local dir out rc n
  dir=$(make_case mismatch)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  set +e
  out=$(FM_TEST_NM_LOGS='  "unit tests/foo.test.sh passed"' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "mismatch pr-check should stay exit 0 (got: $out / $(cat "$dir/stderr"))"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "mismatch should print exactly one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 1 changed test file(s), 0 red record(s) - run $RUN_ID" \
    "mismatch line was not the locked advisory wording"
  assert_contains "$out" "armed: state/task-a.check.sh" "mismatch pr-check did not arm"
  cmp -s "$POLL" "$dir/home/state/task-a.check.sh" \
    || fail "mismatch pr-check did not publish the static poll"
  pass "pr-check: missing breakage record prints one advisory line and still arms"
}

# 2. Matching second-token coverage is silent.
test_matching_coverage_prints_nothing() {
  local dir out rc n logs
  dir=$(make_case match)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  logs=$(breakage_line tests/foo.test.sh)
  set +e
  out=$(FM_TEST_NM_LOGS="$logs" \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "matching coverage should stay exit 0 (got: $out / $(cat "$dir/stderr"))"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "matching coverage must print no BREAKAGE line, got $n: $out"
  assert_contains "$out" "armed: state/task-a.check.sh" "matching pr-check did not arm"
  pass "pr-check: matching second-token coverage prints nothing"
}

# 3. Two changed test files, one covering record -> n=2 m=1.
test_two_test_files_one_record_differs() {
  local dir out rc n logs
  dir=$(make_case two-files)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh lib/bar.test.js
  logs=$(breakage_line tests/foo.test.sh)
  set +e
  out=$(FM_TEST_NM_LOGS="$logs" \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "two-file mismatch should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "two-file mismatch should print exactly one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 2 changed test file(s), 1 red record(s) - run $RUN_ID" \
    "two-file mismatch did not count both test paths with per-file m"
  pass "pr-check: two test files with one covering record reports m=1"
}

# 4. No changed test files -> silent even with empty logs.
test_non_test_change_is_silent() {
  local dir out rc n
  dir=$(make_case no-tests)
  write_task_meta "$dir"
  mkdir -p "$dir/wt"
  git -C "$dir/wt" init -q -b main
  printf 'src\n' > "$dir/wt/app.sh"
  git -C "$dir/wt" add app.sh
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git -C "$dir/wt" checkout -q -b "$TASK_BRANCH"
  printf 'src2\n' > "$dir/wt/app.sh"
  git -C "$dir/wt" add app.sh
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'change source'
  set +e
  out=$(FM_TEST_NM_LOGS='' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "non-test change should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "non-test change must print no BREAKAGE line, got $n: $out"
  pass "pr-check: no changed test files stays silent"
}

# 5. Unreadable axi logs with n>0 prints m=? (not silent).
test_logs_failure_prints_unknown_m() {
  local dir out rc n
  dir=$(make_case logs-fail)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  set +e
  out=$(FM_TEST_NM_LOGS_RC=1 \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "unreadable test log should stay exit 0 (got: $out / $(cat "$dir/stderr"))"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "unreadable test log with n>0 must print one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 1 changed test file(s), ? red record(s) - run $RUN_ID" \
    "unreadable logs must report m=? with known run id"
  assert_contains "$out" "armed: state/task-a.check.sh" "unreadable-log pr-check did not arm"
  pass "pr-check: unreadable test-step log prints m=? and still arms"
}

# 6. Unreadable axi status with n>0 prints m=? run unknown.
test_status_failure_prints_unknown_run() {
  local dir out rc n
  dir=$(make_case status-fail)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  set +e
  out=$(FM_TEST_NM_STATUS_RC=1 \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "unreadable axi status should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "unreadable status with n>0 must print one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 1 changed test file(s), ? red record(s) - run unknown" \
    "unreadable status must report m=? run unknown"
  pass "pr-check: unreadable axi status prints m=? run unknown"
}

# 7. Run branch != task branch -> silent.
test_branch_mismatch_is_silent() {
  local dir out rc n logs
  dir=$(make_case branch-mismatch)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  logs=$(breakage_line tests/foo.test.sh)
  set +e
  out=$(FM_TEST_NM_BRANCH=other-branch FM_TEST_NM_LOGS='' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "branch mismatch should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "branch mismatch must print no BREAKAGE line, got $n: $out"
  pass "pr-check: run branch mismatch stays silent"
}

# 8. direct-PR mode has no test step -> silent.
test_direct_pr_is_skipped() {
  local dir out rc n
  dir=$(make_case direct)
  write_task_meta "$dir" direct-PR
  init_ship_git "$dir" tests/foo.test.sh
  set +e
  out=$(FM_TEST_NM_LOGS='' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "direct-PR pr-check should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "direct-PR must print no BREAKAGE line, got $n: $out"
  pass "pr-check: direct-PR ships have no test step and stay silent"
}

# 9. Final clean breakage entry must not inflate m (no false positive).
test_final_clean_entry_does_not_inflate_m() {
  local dir out rc n logs
  dir=$(make_case clean-entry)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  logs="$(breakage_line tests/foo.test.sh)
$(clean_breakage_line)"
  set +e
  out=$(FM_TEST_NM_LOGS="$logs" \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "clean-entry case should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "final clean breakage entry must not make matching coverage print BREAKAGE, got $n: $out"
  pass "pr-check: final clean breakage entry does not inflate m"
}

# 10. Wrong second-token path does not cover the changed test file.
test_wrong_path_record_does_not_cover() {
  local dir out rc n logs
  dir=$(make_case wrong-path)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  logs=$(breakage_line tests/other.test.sh)
  set +e
  out=$(FM_TEST_NM_LOGS="$logs" \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "wrong-path case should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "wrong second-token must print one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 1 changed test file(s), 0 red record(s) - run $RUN_ID" \
    "wrong second-token must leave m=0 for the changed file"
  pass "pr-check: wrong second-token path does not cover the changed test"
}

# 11. spec/ directory and *_spec.rb basename both count as test files.
test_spec_paths_count() {
  local dir out rc n logs
  dir=$(make_case spec-paths)
  write_task_meta "$dir"
  init_ship_git "$dir" spec/foo_spec.rb nested/spec/bar.rb
  # Only cover one of the two so we observe n=2 m=1 and both paths counted.
  logs=$(breakage_line spec/foo_spec.rb)
  set +e
  out=$(FM_TEST_NM_LOGS="$logs" \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "spec-paths case should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "spec paths should print one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 2 changed test file(s), 1 red record(s) - run $RUN_ID" \
    "spec/ and *_spec.rb must both count as test files"
  pass "pr-check: spec/ paths and *_spec.rb count as test files"
}

# 12. Root-level test_*.py and __tests__/ paths count.
test_root_py_and_dunder_tests_count() {
  local dir out rc n logs
  dir=$(make_case root-py)
  write_task_meta "$dir"
  init_ship_git "$dir" test_widget.py __tests__/widget.js
  logs=$(breakage_line test_widget.py)
  set +e
  out=$(FM_TEST_NM_LOGS="$logs" \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "root-py case should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "root py / __tests__ should print one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 2 changed test file(s), 1 red record(s) - run $RUN_ID" \
    "root test_*.py and __tests__/ must both count"
  pass "pr-check: root test_*.py and __tests__/ count as test files"
}

# Real axi logs --full fixture: multi-line pretty JSON with locked line regex
# and second-token per-file set (two files fully covered + final clean entry).
test_real_log_fixture_full_coverage() {
  local dir out rc n logs
  dir=$(make_case real-log)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh lib/bar.spec.ts
  logs='{
  "tested": [
    "breakage: tests/foo.test.sh subject app.sh:1 selector unit red /tmp/foo-red.txt",
    "breakage: lib/bar.spec.ts subject app.sh:2 selector unit red /tmp/bar-red.txt",
    "breakage: porcelain-clean subject none selector none red none"
  ],
  "artifacts": [
    {"kind":"command-output","path":"/tmp/foo-red.txt"},
    {"kind":"command-output","path":"/tmp/bar-red.txt"}
  ]
}'
  set +e
  out=$(FM_TEST_NM_LOGS="$logs" \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "real-log fixture should stay exit 0 (got: $out / $(cat "$dir/stderr"))"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "real-log full coverage must print no BREAKAGE line, got $n: $out"
  assert_contains "$out" "armed: state/task-a.check.sh" "real-log pr-check did not arm"
  pass "pr-check: real axi logs --full fixture covers per-file second tokens"
}

test_mismatch_prints_one_line_and_still_arms
test_matching_coverage_prints_nothing
test_two_test_files_one_record_differs
test_non_test_change_is_silent
test_logs_failure_prints_unknown_m
test_status_failure_prints_unknown_run
test_branch_mismatch_is_silent
test_direct_pr_is_skipped
test_final_clean_entry_does_not_inflate_m
test_wrong_path_record_does_not_cover
test_spec_paths_count
test_root_py_and_dunder_tests_count
test_real_log_fixture_full_coverage
