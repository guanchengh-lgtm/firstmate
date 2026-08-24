#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges via gh
#   (b) merge is refused when gh pr merge itself fails (no silent success)
#   (c) extra gh pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh (defaults to --squash)
#   (f) malformed PR URL fails fast without calling the forge merge command
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL,
#       including a bundled short-option cluster that carries -R
#   (i) a well-formed GitLab MR URL is refused: this path is GitHub-only by
#       standing captain decision (see bin/fm-pr-merge.sh header invariant)
#   (j) --method=<value> is translated to the gh shorthand gh accepts
#   (k) --match-head-commit is delivered to gh, never gh-axi which drops it
#   (l) a red GitHub forge rollup refuses before the merge command
#   (m) --sha in extra args still forwards on GitHub (caller's business)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# The GitLab fixture, used only to prove refusal. A placeholder host that
# resolves nowhere, and a namespace deeper than one group so the URL parses as
# a genuine merge request rather than failing on shape.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh mock recording every invocation and answering headRefOid/rollup for the
# metadata record and merge pin. gh-axi remains present to prove it never gets
# the pinned merge command. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_AXI_LOG:-/dev/null}"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${FM_TEST_GH_LOG:-/dev/null}"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*)
        printf '%s %s\n' '$head' "\${FM_TEST_GH_ROLLUP_VERDICT:-EMPTY}"
        exit 0
        ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "pr merge") exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1 head=${2:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_AXI_LOG:-/dev/null}"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${FM_TEST_GH_LOG:-/dev/null}"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*)
        printf '%s %s\n' '$head' "\${FM_TEST_GH_ROLLUP_VERDICT:-EMPTY}"
        exit 0
        ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}


run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

assert_gh_merge_line() {
  local case_dir=$1 expected=$2 label=$3
  grep -qxF "$expected" "$case_dir/gh.log" \
    || fail "$label: gh pr merge was not invoked as: $expected (got: $(tr '\n' '|' <"$case_dir/gh.log"))"
  if [ -f "$case_dir/gh-axi.log" ] && grep -q 'pr merge' "$case_dir/gh-axi.log" 2>/dev/null; then
    fail "$label: gh-axi received pr merge (pin would be dropped): $(cat "$case_dir/gh-axi.log")"
  fi
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  assert_gh_merge_line "$case_dir" \
    'pr merge 9 --repo example/repo --squash --match-head-commit deadbeefcafefeed0000000000000000deadbeef' \
    "records-before-merge"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh pr merge with head pin"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  assert_grep 'pr merge' "$case_dir/gh.log" \
    "merge-fails: gh pr merge was never attempted"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 15 --repo example/repo --squash --delete-branch --match-head-commit 2222222222222222222222222222222222222222' \
    "extra-args"
  pass "fm-pr-merge forwards extra flags to gh pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "missing-meta: gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two, so this refusal is proven on a URL that genuinely does not
  # parse, distinct from the provider refusal of a well-formed MR URL.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "malformed-url: gh pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling the forge merge command"
}

# The merge path is GitHub-only by standing captain decision (2026-08-24); a
# well-formed GitLab merge request URL parses in bin/fm-pr-lib.sh for the
# watcher's benefit but must refuse here before anything is recorded or read.
test_wellformed_gitlab_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case gitlab-url-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "gitlab-url-refused: fm-pr-merge should refuse a GitLab merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "gitlab-url-refused: refusal was not fixed and non-probing"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-url-refused: the merge request URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-url-refused: a refused merge request armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "gitlab-url-refused: gh pr merge was invoked for a GitLab URL"
  pass "fm-pr-merge refuses a well-formed GitLab merge request URL: GitHub-only by captain decision"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unsafe-url-segment: gh pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

# A bundled short-option cluster carries -R without ever being exactly -R, and
# gh expands it one character at a time, so the guard has to read the whole
# cluster and refuse before anything is recorded or read.
test_bundled_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "bundled-repo-override: gh pr merge was invoked despite the bundled repo override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-non-repo-cluster: fm-pr-merge refused a short flag that overrides nothing"

  assert_gh_merge_line "$case_dir" \
    'pr merge 8 --repo example/repo --squash -d --match-head-commit bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc' \
    "bundled-non-repo-cluster"
  pass "fm-pr-merge refuses a bundled short-option repo override and forwards other short flags"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 22 --repo example/repo --merge --match-head-commit 5555555555555555555555555555555555555555' \
    "explicit-merge-method"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 23 --repo example/repo --merge --match-head-commit 7777777777777777777777777777777777777777' \
    "method-equals-merge-method"
  pass "fm-pr-merge translates --method=<value> to the gh shorthand without default --squash"
}

test_parses_pr_url_for_gh() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 126 --repo my-org/my-repo --squash --match-head-commit 6666666666666666666666666666666666666666' \
    "url-parsing"
  pass "fm-pr-merge parses a GitHub PR URL into gh number and --repo arguments"
}

test_github_still_forwards_sha_arg() {
  local case_dir
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  # --sha is rejected only where the head is firstmate's to determine. GitHub's
  # extra args are the caller's business exactly as they were.
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-sha-arg: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 44 --repo example/repo --squash --sha abc123 --match-head-commit dddddddddddddddddddddddddddddddddddddddd' \
    "github-sha-arg"
  pass "fm-pr-merge leaves GitHub extra-arg handling unchanged, including --sha"
}

test_red_rollup_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case red-rollup)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_GH_ROLLUP_VERDICT=RED run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/9 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "red-rollup: fm-pr-merge should refuse a red forge rollup"
  assert_grep 'forge check rollup is red' "$case_dir/stderr" \
    "red-rollup: refusal did not name the red rollup"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "red-rollup: gh pr merge was invoked for a red rollup"
  pass "fm-pr-merge refuses a red forge rollup before invoking gh pr merge"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_wellformed_gitlab_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh
test_github_still_forwards_sha_arg
test_red_rollup_refuses_before_merge
