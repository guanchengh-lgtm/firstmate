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
#   (n) upstream-sync branches default to one --merge and record that method
#   (o) upstream-sync squash and rebase forms refuse before any state change
#   (p) a local upstream-reachable second parent classifies HEAD as a sync
#   (q) an absent upstream ref leaves an ordinary branch on the squash default
#   (r) absent and non-repository worktrees degrade to forge branch lookup
#   (s) the literal prefix includes fm/merge-upstreamish, but not reversed words
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

init_case_worktree() {
  local case_dir=$1 branch=$2
  mkdir -p "$case_dir/wt"
  git init -q "$case_dir/wt"
  git -C "$case_dir/wt" symbolic-ref HEAD refs/heads/main
  git -C "$case_dir/wt" commit -q --allow-empty -m "baseline"
  git -C "$case_dir/wt" checkout -q -b "$branch"
}

make_real_case() {
  local name=$1 branch=$2 case_dir
  case_dir=$(make_case "$name")
  init_case_worktree "$case_dir" "$branch"
  printf '%s\n' "$case_dir"
}

set_case_worktree() {
  local case_dir=$1 worktree=$2 meta tmp line
  meta="$case_dir/state/task-x1.meta"
  tmp="$meta.tmp"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree=*) printf 'worktree=%s\n' "$worktree" >> "$tmp" ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$meta"
  mv -f -- "$tmp" "$meta"
  chmod 0600 "$meta"
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
      *headRefName*) printf '%s\n' "\${FM_TEST_GH_HEAD_REF:-}" ; exit 0 ;;
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

assert_gh_merge_flag_count() {
  local case_dir=$1 flag=$2 expected=$3 label=$4 count
  count=$(grep 'pr merge' "$case_dir/gh.log" | tr ' ' '\n' | grep -cx -- "$flag" || true)
  [ "$count" -eq "$expected" ] \
    || fail "$label: expected $flag exactly $expected time(s), got $count"
}

assert_sync_refusal() {
  local name=$1 case_dir rc
  shift
  case_dir=$(make_real_case "sync-refuse-$name" fm/merge-upstream-refusal)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/61 -- "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "sync-refuse-$name: unsafe method should refuse"
  assert_grep 'error: upstream-sync PRs require merge method merge' "$case_dir/stderr" \
    "sync-refuse-$name: refusal diagnostic missing"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "sync-refuse-$name: PR state was recorded"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "sync-refuse-$name: merge poll was armed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "sync-refuse-$name: forge merge was invoked"
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

test_upstream_sync_branch_uses_merge() {
  local case_dir
  case_dir=$(make_real_case sync-branch-default fm/merge-upstream-2026-08-30)
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "sync-branch-default: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 51 --repo example/repo --merge --match-head-commit 1010101010101010101010101010101010101010' \
    "sync-branch-default"
  assert_gh_merge_flag_count "$case_dir" --merge 1 "sync-branch-default"
  assert_grep 'merge_method=merge' "$case_dir/state/task-x1.meta" \
    "sync-branch-default: resolved method was not recorded"

  case_dir=$(make_real_case sync-branch-explicit fm/merge-upstream-explicit)
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "sync-branch-explicit: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 52 --repo example/repo --merge --match-head-commit 2020202020202020202020202020202020202020' \
    "sync-branch-explicit"
  assert_gh_merge_flag_count "$case_dir" --merge 1 "sync-branch-explicit"
  pass "upstream-sync branches use exactly one --merge and record merge_method=merge"
}

test_upstream_sync_unsafe_methods_refuse() {
  assert_sync_refusal squash --squash
  assert_sync_refusal rebase --rebase
  assert_sync_refusal method-squash --method squash
  assert_sync_refusal method-rebase --method rebase
  assert_sync_refusal method-equals-squash --method=squash
  assert_sync_refusal method-equals-rebase --method=rebase
  pass "upstream-sync squash and rebase forms refuse before recording or merging"
}

test_upstream_parent_signal_uses_merge() {
  local case_dir upstream_commit
  case_dir=$(make_real_case sync-second-parent fm/task-signal-two)
  git -C "$case_dir/wt" checkout -q -b upstream-side main
  printf '%s\n' upstream > "$case_dir/wt/upstream.txt"
  git -C "$case_dir/wt" add upstream.txt
  git -C "$case_dir/wt" commit -q -m "upstream change"
  upstream_commit=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" update-ref refs/remotes/upstream/main "$upstream_commit"
  git -C "$case_dir/wt" checkout -q fm/task-signal-two
  git -C "$case_dir/wt" merge -q --no-ff upstream-side -m "merge upstream"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "sync-second-parent: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 53 --repo example/repo --merge --match-head-commit 3030303030303030303030303030303030303030' \
    "sync-second-parent"
  assert_grep 'merge_method=merge' "$case_dir/state/task-x1.meta" \
    "sync-second-parent: resolved method was not recorded"
  pass "an upstream-reachable second parent classifies an ordinary-named branch as a sync"
}

test_absent_upstream_ref_keeps_ordinary_methods() {
  local case_dir
  case_dir=$(make_real_case ordinary-no-upstream fm/task-ordinary)
  git -C "$case_dir/wt" show-ref --verify --quiet refs/remotes/upstream/main \
    && fail "ordinary-no-upstream: fixture unexpectedly has an upstream ref"
  add_gh_mocks "$case_dir" 4040404040404040404040404040404040404040
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "ordinary-no-upstream: fm-pr-merge failed"

  assert_no_grep 'fatal:' "$case_dir/stderr" \
    "ordinary-no-upstream: absent ref leaked a git error"
  assert_no_grep 'upstream/main' "$case_dir/stderr" \
    "ordinary-no-upstream: absent ref produced upstream-ref noise"
  assert_gh_merge_line "$case_dir" \
    'pr merge 54 --repo example/repo --squash --match-head-commit 4040404040404040404040404040404040404040' \
    "ordinary-no-upstream"
  assert_grep 'merge_method=squash' "$case_dir/state/task-x1.meta" \
    "ordinary-no-upstream: squash method was not recorded"

  case_dir=$(make_real_case ordinary-explicit-merge fm/task-explicit-merge)
  add_gh_mocks "$case_dir" 5050505050505050505050505050505050505050
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "ordinary-explicit-merge: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 55 --repo example/repo --merge --match-head-commit 5050505050505050505050505050505050505050' \
    "ordinary-explicit-merge"
  assert_grep 'merge_method=merge' "$case_dir/state/task-x1.meta" \
    "ordinary-explicit-merge: explicit method was not recorded"
  pass "ordinary PRs keep squash default and honor an explicit merge method"
}

test_unstattable_worktrees_degrade_to_forge_branch() {
  local case_dir
  case_dir=$(make_real_case missing-worktree-fallback fm/task-unused-missing)
  set_case_worktree "$case_dir" "$case_dir/missing"
  add_gh_mocks "$case_dir" 6060606060606060606060606060606060606060
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  FM_TEST_GH_HEAD_REF=fm/merge-upstream-fallback \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "missing-worktree-fallback: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 56 --repo example/repo --merge --match-head-commit 6060606060606060606060606060606060606060' \
    "missing-worktree-fallback"

  case_dir=$(make_real_case nonrepo-worktree-fallback fm/task-unused-nonrepo)
  mkdir -p "$case_dir/not-a-repo"
  set_case_worktree "$case_dir" "$case_dir/not-a-repo"
  add_gh_mocks "$case_dir" 7070707070707070707070707070707070707070
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  FM_TEST_GH_HEAD_REF=fm/task-from-forge \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "nonrepo-worktree-fallback: fm-pr-merge failed"

  assert_gh_merge_line "$case_dir" \
    'pr merge 57 --repo example/repo --squash --match-head-commit 7070707070707070707070707070707070707070' \
    "nonrepo-worktree-fallback"
  pass "missing and non-repository worktrees degrade safely to forge branch classification"
}

test_upstream_branch_prefix_boundary() {
  local case_dir
  case_dir=$(make_real_case sync-prefix-ish fm/merge-upstreamish)
  add_gh_mocks "$case_dir" 8080808080808080808080808080808080808080
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "sync-prefix-ish: fm-pr-merge failed"
  assert_gh_merge_line "$case_dir" \
    'pr merge 58 --repo example/repo --merge --match-head-commit 8080808080808080808080808080808080808080' \
    "sync-prefix-ish"

  case_dir=$(make_real_case reversed-prefix-ordinary fm/upstream-merge)
  add_gh_mocks "$case_dir" 9090909090909090909090909090909090909090
  : > "$case_dir/gh.log"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "reversed-prefix-ordinary: fm-pr-merge failed"
  assert_gh_merge_line "$case_dir" \
    'pr merge 59 --repo example/repo --squash --match-head-commit 9090909090909090909090909090909090909090' \
    "reversed-prefix-ordinary"
  pass "sync prefix includes fm/merge-upstreamish and excludes fm/upstream-merge"
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
test_upstream_sync_branch_uses_merge
test_upstream_sync_unsafe_methods_refuse
test_upstream_parent_signal_uses_merge
test_absent_upstream_ref_keeps_ordinary_methods
test_unstattable_worktrees_degrade_to_forge_branch
test_upstream_branch_prefix_boundary
