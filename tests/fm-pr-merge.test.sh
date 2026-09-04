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
#   (t) a successful gh pr merge is followed by a live GitHub outcome read-back
#   (u) a confirmed merge is recorded through bin/fm-merge-outcome-lib.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
REAL_MV=$(command -v mv) || fail "tests need mv"
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
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
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
case "${1:-} ${2:-}" in
  "pr merge")
    echo "error: gh-axi must not receive pr merge" >&2
    exit 1
    ;;
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: %s\n' "${3:-}" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
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

  "api graphql")
    cat "\${FM_TEST_GH_OUTCOME:-/dev/null}"
    exit 0
    ;;
  api\ *)
    cat "\${FM_TEST_GH_RULES:-/dev/null}"
    exit 0
    ;;
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
case "${1:-} ${2:-}" in
  "pr merge")
    echo "error: gh-axi must not receive pr merge" >&2
    exit 1
    ;;
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: %s\n' "${3:-}" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
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

  "api graphql")
    cat "\${FM_TEST_GH_OUTCOME:-/dev/null}"
    exit 0
    ;;
  api\ *)
    cat "\${FM_TEST_GH_RULES:-/dev/null}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}


run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_REAL_MV="$REAL_MV" \
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


write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
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
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/home"
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
  assert_sync_refusal short-squash -s
  assert_sync_refusal short-rebase -r
  assert_sync_refusal boolean-squash --squash=true
  assert_sync_refusal boolean-rebase --rebase=true
  assert_sync_refusal method-squash --method squash
  assert_sync_refusal method-rebase --method rebase
  assert_sync_refusal method-equals-squash --method=squash
  assert_sync_refusal method-equals-rebase --method=rebase
  assert_sync_refusal bundled-short-squash -ds
  assert_sync_refusal bundled-short-rebase -dr
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


add_gh_mocks_merge_prints() {
  local case_dir=$1 head=$2
  local msg=${3:-}
  add_gh_mocks "$case_dir" "$head"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*)
        printf '%s %s\\n' '$head' "\${FM_TEST_GH_ROLLUP_VERDICT:-EMPTY}"
        exit 0
        ;;
      *headRefOid*) printf '%s\\n' '$head' ; exit 0 ;;
      *headRefName*) printf '%s\\n' "\${FM_TEST_GH_HEAD_REF:-}" ; exit 0 ;;
    esac
    ;;
  "pr merge")
    [ -n '$msg' ] && printf '%s\\n' '$msg'
    exit 0
    ;;
  "api graphql")
    cat "\${FM_TEST_GH_OUTCOME:-/dev/null}"
    exit 0
    ;;
  api\\ *)
    cat "\${FM_TEST_GH_RULES:-/dev/null}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

add_gh_mock_outcome_read_fails() {
  local case_dir=$1 head=$2
  local msg=${3:-}
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
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
  "pr merge")
    [ -n '$msg' ] && printf '%s\n' '$msg'
    exit 0
    ;;
  "api graphql")
    echo 'error: could not reach the GitHub API' >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_prints "$case_dir" 6161616161616161616161616161616161616161 \
    "will be added to the merge queue when all requirements are met"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_auto_merge_without_queue_refuses_legibly() {
  local case_dir rc spelling
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-no-queue${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/github-rules"
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-auto-no-queue: an armed but unlanded auto-merge must still fail"
    assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
      "github-auto-no-queue: refusal did not name the concrete observed state"
    assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/66' \
      "$case_dir/stderr" "github-auto-no-queue: the refusal never explained the armed auto-merge"
    assert_grep 'nothing is merged or in the merge queue yet' "$case_dir/stderr" \
      "github-auto-no-queue: the refusal left the operator to infer the pending state"
    grep -qxF "pr merge 66 --repo example/repo $spelling --merge --match-head-commit 7171717171717171717171717171717171717171" "$case_dir/gh.log" \
      || fail "github-auto-no-queue: the attempted merge was changed unexpectedly"
    [ "$(grep -c 'pr merge' "$case_dir/gh.log")" = 1 ] \
      || fail "github-auto-no-queue: the wrapper attempted more than one merge"
    assert_grep 'pr=https://github.com/example/repo/pull/66' "$case_dir/state/task-x1.meta" \
      "github-auto-no-queue: the attempted merge lost its PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-auto-no-queue: the attempted merge did not leave its poll armed"
  done
  pass "fm-pr-merge explains an armed auto-merge that landed nothing on a queue-less base"
}

test_github_failed_merge_never_claims_armed_auto_merge() {
  local case_dir rc
  case_dir=$(make_case github-auto-merge-command-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-auto-merge-command-fails: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-auto-merge-command-fails: refusal did not name the concrete observed state"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: a failed merge command was reported as an armed auto-merge"
  assert_grep 'auto-merge was requested for https://github.com/example/repo/pull/67' \
    "$case_dir/stderr" \
    "github-auto-merge-command-fails: the refusal never said auto-merge had only been requested"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-auto-merge-command-fails: a failed merge command was reported as verified"
  pass "fm-pr-merge never reports auto-merge as armed when the merge command failed"
}

test_github_failed_merge_with_queue_flags_never_claims_acceptance() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-queue-flags: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: refusal did not name the concrete observed state"
  assert_no_grep 'was accepted with the exact flags' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an accepted request"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an armed auto-merge"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the failed merge command lost its concrete retry guidance"
  assert_grep 'task-x1 https://github.com/example/repo/pull/74 -- --auto --merge' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the retry guidance named no queue flags"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-queue-flags: a failed merge command was reported as verified"
  pass "fm-pr-merge claims no acceptance for a failed merge command carrying queue flags"
}

test_github_accepted_queue_flags_do_not_echo_back_the_same_command() {
  local case_dir rc
  case_dir=$(make_case github-accepted-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-accepted-queue-flags: an unproved merge must still fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-accepted-queue-flags: refusal did not name the concrete observed state"
  assert_grep 'this run refuses even though the request for https://github.com/example/repo/pull/68 was accepted with the exact flags base branch main requires (--auto --merge)' \
    "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal did not explain that the right flags were already used"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal named no concrete next step"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal echoed back the command that just refused"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-accepted-queue-flags: an unproved merge was reported as verified"
  pass "fm-pr-merge does not echo back queue flags the caller already used"
}

test_github_mismatched_queue_flags_still_name_the_retry() {
  local case_dir rc
  case_dir=$(make_case github-mismatched-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8282828282828282828282828282828282828282
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mismatched-queue-flags: an unproved merge must still fail"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-mismatched-queue-flags: a caller method the queue does not use lost its retry guidance"
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
    "github-mismatched-queue-flags: the exact compatible flags were not named"
  pass "fm-pr-merge still names retry flags when the caller used a different method"
}

test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unrecognised-queue-method: retry flags were named for a method nothing recognises"
  assert_no_grep '--auto --' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s %s\n' 8484848484848484848484848484848484848484 "${FM_TEST_GH_ROLLUP_VERDICT:-EMPTY}"
        exit 0
        ;;
      *headRefOid*) printf '%s\n' 8484848484848484848484848484848484848484 ; exit 0 ;;
    esac
    ;;
  "pr merge") exit 0 ;;
  "api graphql")
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unreadable-queue-rules: retry flags were named from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787 \
    "will be added to the merge queue when all requirements are met"
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  grep -qxF 'pr merge 56 --repo example/repo --squash --match-head-commit 2121212121212121212121212121212121212121' "$case_dir/gh.log" \
    || fail "github-zero-exit-queue-required: the attempted merge was changed unexpectedly"
  [ "$(grep -c 'pr merge' "$case_dir/gh.log")" = 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep '-- --auto --merge' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received retry flags"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  grep -F -- '-- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  grep -qxF 'pr merge 54 --repo example/repo --squash --match-head-commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$case_dir/gh.log" \
    || fail "github-queue-required: the wrapper silently changed the attempted merge semantics"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep '-- --auto --rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules omitted exact retry flags"
  assert_no_grep 'exact retry flags are ambiguous' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as ambiguous"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main has conflicting merge queue methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep '-- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '-- --auto --squash' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$replies" \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(wc -l <"$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward line"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$parent_status" \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  assert_absent "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
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
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_open_unqueued_outcome_refuses
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_auto_merge_without_queue_refuses_legibly
test_github_failed_merge_never_claims_armed_auto_merge
test_github_failed_merge_with_queue_flags_never_claims_acceptance
test_github_accepted_queue_flags_do_not_echo_back_the_same_command
test_github_mismatched_queue_flags_still_name_the_retry
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_failed_merge_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
