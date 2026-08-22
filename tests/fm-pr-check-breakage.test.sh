#!/usr/bin/env bash
# Behavioral coverage for the advisory manufactured-breakage check in
# bin/fm-pr-check.sh. The check prints one BREAKAGE line when the count of
# changed test files disagrees with test-step `breakage:` records, and never
# changes the exit code.
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
    printf 'run:\n  id: "%s"\n  pr: "%s"\n' \
      "${FM_TEST_NM_RUN_ID:-}" "${FM_TEST_NM_PR:-}"
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
  git -C "$dir/wt" checkout -q -b fm/task-a
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
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

breakage_lines() {
  printf '%s\n' "$1" | grep -c '^BREAKAGE:' || true
}

test_mismatch_prints_one_line_and_still_arms() {
  local dir out rc n
  dir=$(make_case mismatch)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  set +e
  out=$(FM_TEST_NM_LOGS='{"tested":["unit tests/foo.test.sh passed"],"artifacts":[]}' \
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

test_matching_counts_print_nothing() {
  local dir out rc n
  dir=$(make_case match)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh
  set +e
  out=$(FM_TEST_NM_LOGS='{"tested":["breakage: app.sh:1 tests/foo.test.sh /tmp/red.txt"],"artifacts":[{"kind":"command-output","path":"/tmp/red.txt"}]}' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "matching counts should stay exit 0 (got: $out / $(cat "$dir/stderr"))"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "matching counts must print no BREAKAGE line, got $n: $out"
  assert_contains "$out" "armed: state/task-a.check.sh" "matching pr-check did not arm"
  pass "pr-check: matching breakage records print nothing"
}

test_two_test_files_one_record_differs() {
  local dir out rc n
  dir=$(make_case two-files)
  write_task_meta "$dir"
  init_ship_git "$dir" tests/foo.test.sh lib/bar.test.js
  set +e
  out=$(FM_TEST_NM_LOGS='{"tested":["breakage: app.sh:1 tests/foo.test.sh /tmp/red.txt"]}' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "two-file mismatch should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 1 ] || fail "two-file mismatch should print exactly one BREAKAGE line, got $n: $out"
  assert_contains "$out" \
    "BREAKAGE: 2 changed test file(s), 1 red record(s) - run $RUN_ID" \
    "two-file mismatch did not count tests/** plus a project test glob"
  pass "pr-check: tests/** and project test globs both count"
}

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
  git -C "$dir/wt" checkout -q -b fm/task-a
  printf 'src2\n' > "$dir/wt/app.sh"
  git -C "$dir/wt" add app.sh
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'change source'
  set +e
  out=$(FM_TEST_NM_LOGS='{"tested":[]}' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "non-test change should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "non-test change must print no BREAKAGE line, got $n: $out"
  pass "pr-check: no changed test files and no records stays silent"
}

test_logs_failure_is_fail_open() {
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
  [ "$n" = 0 ] || fail "unreadable test log must print no BREAKAGE line, got $n: $out"
  assert_contains "$out" "armed: state/task-a.check.sh" "fail-open pr-check did not arm"
  pass "pr-check: unreadable test-step log prints nothing and still arms"
}

test_direct_pr_is_skipped() {
  local dir out rc n
  dir=$(make_case direct)
  write_task_meta "$dir" direct-PR
  init_ship_git "$dir" tests/foo.test.sh
  set +e
  out=$(FM_TEST_NM_LOGS='{"tested":[]}' \
    run_check "$dir" task-a "$PR_URL" 2>"$dir/stderr")
  rc=$?
  set -e
  expect_code 0 "$rc" "direct-PR pr-check should stay exit 0"
  n=$(breakage_lines "$out")
  [ "$n" = 0 ] || fail "direct-PR must print no BREAKAGE line, got $n: $out"
  pass "pr-check: direct-PR ships have no test step and stay silent"
}

test_mismatch_prints_one_line_and_still_arms
test_matching_counts_print_nothing
test_two_test_files_one_record_differs
test_non_test_change_is_silent
test_logs_failure_is_fail_open
test_direct_pr_is_skipped
