#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh local-only fast-forward and --exact-sync.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
OUTCOME_LIB="$ROOT/bin/fm-merge-outcome-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

write_sync_ci() {
  local repo=$1
  mkdir -p "$repo/.github/workflows"
  cat > "$repo/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [main, fm/merge-upstream-2]
jobs:
  lint:
    name: lint
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
}

write_sync_nm() {
  local repo=$1 extra=${2-}
  cat > "$repo/.no-mistakes.yaml" <<EOF
disable_project_settings: true
$extra
EOF
}

add_gh_ci_ok() {
  local fakebin=$1 sha=$2 job_name=${3:-lint}
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\${FM_TEST_GH_LOG:-/dev/null}"
case "\$*" in
  "run list"*"--commit $sha"*"--branch fm/merge-upstream-2"*"--event push"*|"run list"*"--event push"*"--commit $sha"*)
    printf '%s\\n' '[{"databaseId":9,"headSha":"$sha","headBranch":"fm/merge-upstream-2","event":"push","conclusion":"success","status":"completed"}]'
    exit 0
    ;;
  run\ list*)
    printf '%s\\n' '[]'
    exit 0
    ;;
  run\ view*)
    printf '%s\\n' '{"jobs":[{"name":"$job_name","conclusion":"success","status":"completed"}],"conclusion":"success","headSha":"$sha","headBranch":"fm/merge-upstream-2","event":"push"}'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/gh"
}

add_gh_ci_missing() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:-/dev/null}"
printf '%s\n' '[]'
exit 0
SH
  chmod +x "$fakebin/gh"
}

add_gh_ci_red() {
  local fakebin=$1 sha=$2
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "\${FM_TEST_GH_LOG:-/dev/null}"
printf '%s\\n' '[{"databaseId":9,"headSha":"$sha","headBranch":"fm/merge-upstream-2","event":"push","conclusion":"failure","status":"completed"}]'
exit 0
SH
  chmod +x "$fakebin/gh"
}

make_sync_case() {
  local name=$1 case_dir origin proj home fakebin base upstream stage merge_sha
  case_dir="$TMP_ROOT/$name"
  origin="$case_dir/origin.git"
  proj="$case_dir/project"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$case_dir/_seed"
  write_sync_ci "$case_dir/_seed"
  write_sync_nm "$case_dir/_seed"
  git -C "$case_dir/_seed" add .github/workflows/ci.yml .no-mistakes.yaml
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q -m base
  git -C "$case_dir/_seed" push -q origin HEAD:main
  base=$(git -C "$case_dir/_seed" rev-parse HEAD)
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m upstream
  upstream=$(git -C "$case_dir/_seed" rev-parse HEAD)
  git -C "$case_dir/_seed" reset -q --hard "$base"
  printf '%s\n' staged > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q -m stage
  stage=$(git -C "$case_dir/_seed" rev-parse HEAD)
  merge_sha=$(git -C "$case_dir/_seed" commit-tree "$(git -C "$case_dir/_seed" rev-parse "$stage^{tree}")" -p "$base" -p "$upstream" -m synthesized)
  git -C "$case_dir/_seed" update-ref refs/heads/fm/task-x1 "$merge_sha"
  git -C "$case_dir/_seed" push -q origin "$base":refs/heads/main
  git -C "$case_dir/_seed" push -q origin "$merge_sha":refs/heads/fm/task-x1
  git -C "$case_dir/_seed" push -q origin "$stage":refs/heads/stage-tip
  rm -rf "$case_dir/_seed"
  git clone -q "$origin" "$proj"
  git -C "$proj" fetch -q origin fm/task-x1 stage-tip
  git -C "$proj" branch --no-track fm/task-x1 origin/fm/task-x1 >/dev/null
  git -C "$proj" remote set-head origin main >/dev/null 2>&1 || true
  fm_write_meta "$home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$proj" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir|$proj|$home|$fakebin|$base|$upstream|$stage|$merge_sha"
}

run_exact_sync() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_GH_LOG="$home/gh.log" \
    PATH="$fakebin:/usr/bin:/bin" \
    "$MERGE_LOCAL" "$@"
}

test_force_is_refused() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc
  rec=$(make_sync_case force-arg)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync --force \
    --base "$base" --upstream "$upstream" --stage "$stage" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "force-arg: --force was accepted"
  assert_contains "$out" "never take --force" "force-arg: refusal lost its wording"
  pass "--force is refused before any exact-sync landing"
}

test_stale_base_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc moved
  rec=$(make_sync_case stale-base)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  git clone -q "$case_dir/origin.git" "$case_dir/_move"
  git -C "$case_dir/_move" -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved
  git -C "$case_dir/_move" push -q origin HEAD:main
  moved=$(git -C "$case_dir/_move" rev-parse HEAD)
  rm -rf "$case_dir/_move"
  add_gh_ci_ok "$fakebin" "$merge_sha"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$stage" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "stale-base: landing succeeded after origin/main moved to $moved"
  assert_contains "$out" "not the pinned --base" "stale-base: refusal lost its wording"
  pass "stale origin/main is refused"
}

test_wrong_upstream_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc other
  rec=$(make_sync_case wrong-upstream)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  other=$(printf '%s\n' "$upstream" | tr '0-9a-f' 'a-f0-9')
  [ "$other" != "$upstream" ] || other=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  add_gh_ci_ok "$fakebin" "$merge_sha"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$other" --stage "$stage" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "wrong-upstream: landing succeeded with a mismatched U"
  assert_contains "$out" "parents are" "wrong-upstream: refusal lost its wording"
  pass "wrong --upstream is refused"
}

test_tree_mismatch_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc
  rec=$(make_sync_case tree-mismatch)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  add_gh_ci_ok "$fakebin" "$merge_sha"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$base" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "tree-mismatch: landing succeeded when --stage was not tree(M)"
  assert_contains "$out" "tree(" "tree-mismatch: refusal lost its wording"
  pass "tree mismatch against --stage is refused"
}

test_conflict_marker_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc marked
  rec=$(make_sync_case marker-present)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  git clone -q "$proj" "$case_dir/_mark"
  printf '%s\n' '<<<<<<< HEAD' 'x' '=======' 'y' '>>>>>>> U' > "$case_dir/_mark/conflict.txt"
  git -C "$case_dir/_mark" add conflict.txt
  git -C "$case_dir/_mark" -c user.email=t@t -c user.name=t commit -q -m marker
  marked=$(git -C "$case_dir/_mark" commit-tree "$(git -C "$case_dir/_mark" rev-parse 'HEAD^{tree}')" -p "$base" -p "$upstream" -m marked)
  git -C "$proj" fetch -q "$case_dir/_mark" "+$marked:refs/heads/fm/task-x1"
  rm -rf "$case_dir/_mark"
  add_gh_ci_ok "$fakebin" "$marked"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$marked" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "marker-present: landing succeeded with conflict markers in tree(M)"
  assert_contains "$out" "conflict markers" "marker-present: refusal lost its wording"
  pass "conflict markers in tree(M) are refused"
}

test_pr_base_branch_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc tainted
  rec=$(make_sync_case nm-base-branch)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  git clone -q "$proj" "$case_dir/_nm"
  write_sync_nm "$case_dir/_nm" 'pr.base_branch: fm/merge-upstream-2-stage'
  git -C "$case_dir/_nm" add .no-mistakes.yaml
  git -C "$case_dir/_nm" -c user.email=t@t -c user.name=t commit -q -m nm
  tainted=$(git -C "$case_dir/_nm" commit-tree "$(git -C "$case_dir/_nm" rev-parse 'HEAD^{tree}')" -p "$base" -p "$upstream" -m tainted)
  git -C "$proj" fetch -q "$case_dir/_nm" "+$tainted:refs/heads/fm/task-x1"
  rm -rf "$case_dir/_nm"
  add_gh_ci_ok "$fakebin" "$tainted"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$tainted" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "nm-base-branch: landing succeeded with pr.base_branch present"
  assert_contains "$out" "pr.base_branch" "nm-base-branch: refusal lost its wording"
  pass "pr.base_branch in tree(M) is refused"
}

test_missing_ci_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc
  rec=$(make_sync_case missing-ci)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  add_gh_ci_missing "$fakebin"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$stage" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing-ci: landing succeeded without a push-triggered run"
  assert_contains "$out" "no push-triggered CI" "missing-ci: refusal lost its wording"
  pass "missing CI evidence is refused"
}

test_red_ci_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc
  rec=$(make_sync_case red-ci)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  add_gh_ci_red "$fakebin" "$merge_sha"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$stage" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "red-ci: landing succeeded on a failed run"
  assert_contains "$out" "concluded failure" "red-ci: refusal lost its wording"
  pass "red CI evidence is refused"
}

test_non_ff_main_refuses() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out rc
  rec=$(make_sync_case non-ff)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  git clone -q "$case_dir/origin.git" "$case_dir/_div"
  git -C "$case_dir/_div" checkout --orphan diverged
  git -C "$case_dir/_div" -c user.email=t@t -c user.name=t commit -q --allow-empty -m diverge
  git -C "$case_dir/_div" push -q origin HEAD:refs/heads/diverged
  git -C "$case_dir/origin.git" update-ref refs/heads/main "$(git -C "$case_dir/_div" rev-parse HEAD)"
  rm -rf "$case_dir/_div"
  add_gh_ci_ok "$fakebin" "$merge_sha"
  set +e
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$stage" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "non-ff: landing succeeded after main diverged"
  assert_contains "$out" "not the pinned --base" "non-ff: refusal lost its wording"
  pass "non-fast-forward origin/main is refused"
}

test_happy_path_and_idempotent_rerun() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out landed
  rec=$(make_sync_case happy)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  add_gh_ci_ok "$fakebin" "$merge_sha"
  : > "$home/gh.log"
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$stage") \
    || fail "happy: first landing failed: $out"
  assert_contains "$out" "exact-sync landed $merge_sha" "happy: success line missing"
  git -C "$proj" fetch -q origin
  landed=$(git -C "$proj" rev-parse origin/main)
  [ "$landed" = "$merge_sha" ] || fail "happy: origin/main is $landed, not $merge_sha"
  assert_grep "check: merge landed: task-x1 origin/main@$merge_sha" "$home/state/.wake-queue" \
    "happy: sync outcome was not recorded"
  grep -q 'run list' "$home/gh.log" \
    || fail "happy: gh run list was not invoked"
  grep -q -- "--commit $merge_sha" "$home/gh.log" \
    || fail "happy: gh run list was not pinned to M"
  grep -q -- "--branch fm/merge-upstream-2" "$home/gh.log" \
    || fail "happy: gh run list was not pinned to fm/merge-upstream-2"
  grep -q -- "--event push" "$home/gh.log" \
    || fail "happy: gh run list was not pinned to push"
  grep -q 'run view' "$home/gh.log" \
    || fail "happy: gh run view was not invoked"

  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$stage") \
    || fail "happy: idempotent re-run failed: $out"
  assert_contains "$out" "already on origin/main" "happy: re-run lost its idempotent wording"
  [ "$(grep -c -F "origin/main@$merge_sha" "$home/state/.wake-queue")" -eq 1 ] \
    || fail "happy: idempotent re-run duplicated the outcome"
  pass "happy path lands M and a second run is idempotent"
}

test_foreign_tree_uses_its_own_guard_and_lease() {
  local home foreign out rc
  home="$TMP_ROOT/foreign-home"
  foreign="$TMP_ROOT/foreign-tree"
  mkdir -p "$home/state" "$home/bin" "$foreign/bin"
  cat > "$foreign/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'GUARD_FROM=%s\n' "$0" >> "${FM_HOME}/source.log"
exit 0
SH
  cat > "$foreign/bin/fm-lease-lib.sh" <<SH
printf 'LEASE_FROM=%s\n' "\${BASH_SOURCE[0]}" >> "\${FM_HOME}/source.log"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-lease-lib.sh"
SH
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'GUARD_FROM=%s\n' "$0" >> "${FM_HOME}/source.log"
exit 0
SH
  cat > "$home/bin/fm-lease-lib.sh" <<'SH'
printf 'LEASE_FROM=%s\n' "${BASH_SOURCE[0]}" >> "${FM_HOME}/source.log"
fm_lease_forbid_branch() { :; }
SH
  cp "$MERGE_LOCAL" "$foreign/bin/fm-merge-local.sh"
  chmod +x "$foreign/bin/fm-guard.sh" "$foreign/bin/fm-merge-local.sh" \
    "$home/bin/fm-guard.sh"
  : > "$home/source.log"
  set +e
  out=$(FM_HOME="$home" "$foreign/bin/fm-merge-local.sh" task-x 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 6 ] || fail "foreign-tree: main actor hit the branch refusal: $out"
  assert_contains "$out" "no meta for task task-x" "foreign-tree: ordinary error lost"
  grep -q "GUARD_FROM=$foreign/bin/fm-guard.sh" "$home/source.log" \
    || fail "foreign-tree: guard did not run from the foreign tree: $(cat "$home/source.log")"
  grep -q "LEASE_FROM=$foreign/bin/fm-lease-lib.sh" "$home/source.log" \
    || fail "foreign-tree: lease-lib was not sourced from the foreign tree: $(cat "$home/source.log")"
  grep -q "GUARD_FROM=$home/bin/fm-guard.sh" "$home/source.log" \
    && fail "foreign-tree: guard ran from FM_HOME"
  grep -q "LEASE_FROM=$home/bin/fm-lease-lib.sh" "$home/source.log" \
    && fail "foreign-tree: lease-lib was sourced from FM_HOME"

  set +e
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch \
    "$foreign/bin/fm-merge-local.sh" task-x 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 6 ] || fail "foreign-tree: branch actor exited $rc, not 6: $out"
  pass "foreign-tree copy sources its own guard and lease lib"
}

test_ordinary_local_ff_still_works() {
  local case_dir proj home out before after
  case_dir="$TMP_ROOT/ordinary-ff"
  home="$case_dir/home"
  proj="$case_dir/project"
  mkdir -p "$home/state"
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  printf '# %s\n' project > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q -m initial
  git -C "$proj" checkout -q -b fm/task-x1
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  git -C "$proj" checkout -q main
  fm_write_meta "$home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$proj" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  before=$(git -C "$proj" rev-parse main)
  out=$(FM_HOME="$home" "$MERGE_LOCAL" task-x1) \
    || fail "ordinary-ff: local fast-forward failed: $out"
  after=$(git -C "$proj" rev-parse main)
  [ "$after" != "$before" ] || fail "ordinary-ff: main did not move"
  assert_contains "$out" "merged fm/task-x1 into local main" "ordinary-ff: success line missing"
  pass "ordinary local-only fast-forward is unchanged"
}

test_outcome_sync_records_git_identity() {
  local home state sha rc
  home="$TMP_ROOT/outcome-sync"
  state="$home/state"
  sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$state"
  # shellcheck source=bin/fm-merge-outcome-lib.sh disable=SC1091
  . "$OUTCOME_LIB"
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin main "$sha" self \
    || fail "outcome-sync: valid report failed"
  assert_grep "check: merge landed: task-x1 origin/main@$sha" "$state/.wake-queue" \
    "outcome-sync: wake text missing"
  grep -q "merged-task-x1-sync-origin-main-$sha" "$state/.wake-queue" \
    || fail "outcome-sync: wake key missing"
  [ "$(grep -c -F "origin/main@$sha" "$state/.wake-queue")" -eq 1 ] \
    || fail "outcome-sync: first report wrote more than one wake"
  assert_absent "$state/parent-replies.status" \
    "outcome-sync: a main home wrote a parent reply channel"
  [ -f "$state/task-x1.pr-poll-merge-notified" ] \
    || fail "outcome-sync: notification marker was not written"
  grep -qx git "$state/task-x1.pr-poll-merge-notified" \
    || fail "outcome-sync: marker provider was not git"
  grep -qx origin "$state/task-x1.pr-poll-merge-notified" \
    || fail "outcome-sync: marker host was not the remote"
  grep -qx main "$state/task-x1.pr-poll-merge-notified" \
    || fail "outcome-sync: marker path was not the branch"
  grep -qx "$sha" "$state/task-x1.pr-poll-merge-notified" \
    || fail "outcome-sync: marker number was not the sha"

  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin main "$sha" self \
    || fail "outcome-sync: repeat report failed"
  [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ] \
    || fail "outcome-sync: repeat report was not marked already-recorded"
  [ "$(grep -c -F "origin/main@$sha" "$state/.wake-queue")" -eq 1 ] \
    || fail "outcome-sync: repeat report duplicated the wake"

  set +e
  fm_merge_outcome_report_sync "$home" "$state" 'bad/id' origin main "$sha" self
  rc=$?
  set -e
  expect_code 2 "$rc" "outcome-sync: invalid task-id"
  set +e
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin main deadbeef self
  rc=$?
  set -e
  expect_code 2 "$rc" "outcome-sync: short sha"
  set +e
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin/foo main "$sha" self
  rc=$?
  set -e
  expect_code 2 "$rc" "outcome-sync: slashed remote"
  set +e
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin feat/x "$sha" self
  rc=$?
  set -e
  expect_code 2 "$rc" "outcome-sync: slashed branch"
  set +e
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin main "$sha" other
  rc=$?
  set -e
  expect_code 2 "$rc" "outcome-sync: bad origin"
  pass "outcome-sync records a git identity and refuses illegal fields"
}

test_outcome_sync_secondmate_line() {
  local home state parent sha
  home="$TMP_ROOT/outcome-secondmate"
  parent="$TMP_ROOT/outcome-parent"
  state="$home/state"
  sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  mkdir -p "$state" "$parent/state"
  printf '%s\n' mate-x > "$home/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=remote\n'
  } > "$home/.fm-secondmate-parent"
  # shellcheck source=bin/fm-merge-outcome-lib.sh disable=SC1091
  . "$OUTCOME_LIB"
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin main "$sha" self \
    || fail "outcome-secondmate: valid report failed"
  assert_grep "done [key=merged-task-x1]: merged task-x1 origin/main@$sha" \
    "$state/parent-replies.status" \
    "outcome-secondmate: upward line missing"
  assert_absent "$state/.wake-queue" \
    "outcome-secondmate: a self-origin secondmate report also wrote a local wake"
  pass "outcome-sync secondmate line uses remote/branch@sha"
}

test_outcome_sync_unreadable_role() {
  local home state sha rc
  home="$TMP_ROOT/outcome-unbound"
  state="$home/state"
  sha=cccccccccccccccccccccccccccccccccccccccc
  mkdir -p "$state"
  printf '%s\n' mate-x > "$home/.fm-secondmate-home"
  # shellcheck source=bin/fm-merge-outcome-lib.sh disable=SC1091
  . "$OUTCOME_LIB"
  set +e
  fm_merge_outcome_report_sync "$home" "$state" task-x1 origin main "$sha" self
  rc=$?
  set -e
  expect_code 3 "$rc" "outcome-unbound: missing parent binding"
  pass "outcome-sync returns 3 when the home role is unreadable"
}

test_matrix_job_name_prefix_matches() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out matrix_tree matrix_m
  rec=$(make_sync_case matrix-ci)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  git clone -q "$proj" "$case_dir/_mx"
  mkdir -p "$case_dir/_mx/.github/workflows"
  cat > "$case_dir/_mx/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [main, fm/merge-upstream-2]
jobs:
  lint:
    name: lint ${{ matrix.shard }}
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
  git -C "$case_dir/_mx" add .github/workflows/ci.yml
  git -C "$case_dir/_mx" -c user.email=t@t -c user.name=t commit -q -m matrix-ci
  matrix_tree=$(git -C "$case_dir/_mx" rev-parse 'HEAD^{tree}')
  matrix_m=$(git -C "$case_dir/_mx" commit-tree "$matrix_tree" -p "$base" -p "$upstream" -m matrix-m)
  git -C "$proj" fetch -q "$case_dir/_mx" "+$matrix_m:refs/heads/fm/task-x1"
  git -C "$proj" fetch -q "$case_dir/_mx" "+$matrix_m:refs/heads/matrix-stage"
  rm -rf "$case_dir/_mx"
  add_gh_ci_ok "$fakebin" "$matrix_m" "lint 1"
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$matrix_m") \
    || fail "matrix-ci: landing failed when CI used an expanded matrix job name: $out"
  assert_contains "$out" "exact-sync landed $matrix_m" "matrix-ci: success line missing"
  pass "matrix job name templates match the expanded CI job name"
}

test_setext_underline_is_not_a_conflict_marker() {
  local rec case_dir proj home fakebin base upstream stage merge_sha out under_tree under_m
  rec=$(make_sync_case setext-underline)
  IFS='|' read -r case_dir proj home fakebin base upstream stage merge_sha <<EOF
$rec
EOF
  git clone -q "$proj" "$case_dir/_su"
  printf '%s\n' 'Title' '==========' 'body' > "$case_dir/_su/NOTES.md"
  git -C "$case_dir/_su" add NOTES.md
  git -C "$case_dir/_su" -c user.email=t@t -c user.name=t commit -q -m setext
  under_tree=$(git -C "$case_dir/_su" rev-parse 'HEAD^{tree}')
  under_m=$(git -C "$case_dir/_su" commit-tree "$under_tree" -p "$base" -p "$upstream" -m setext-m)
  git -C "$proj" fetch -q "$case_dir/_su" "+$under_m:refs/heads/fm/task-x1"
  rm -rf "$case_dir/_su"
  add_gh_ci_ok "$fakebin" "$under_m"
  out=$(run_exact_sync "$home" "$fakebin" task-x1 --exact-sync \
    --base "$base" --upstream "$upstream" --stage "$under_m") \
    || fail "setext-underline: landing was refused for a Markdown underline: $out"
  assert_contains "$out" "exact-sync landed $under_m" "setext-underline: success line missing"
  pass "a Markdown setext underline is not read as a conflict marker"
}

test_sync_flags_without_exact_sync_refuse() {
  local case_dir proj home before after out rc
  case_dir="$TMP_ROOT/flags-without-exact-sync"
  home="$case_dir/home"
  proj="$case_dir/project"
  mkdir -p "$home/state" "$proj"
  git -C "$proj" init -q -b main
  printf '# %s\n' project > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q -m initial
  git -C "$proj" checkout -q -b fm/task-x1
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  git -C "$proj" checkout -q main
  fm_write_meta "$home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$proj" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  before=$(git -C "$proj" rev-parse main)

  set +e
  out=$(FM_HOME="$home" "$MERGE_LOCAL" task-x1 \
    --base 1111111111111111111111111111111111111111 \
    --upstream 2222222222222222222222222222222222222222 \
    --stage 3333333333333333333333333333333333333333 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "flags-without-exact-sync: expected exit 2, got $rc: $out"
  assert_contains "$out" "require --exact-sync" \
    "flags-without-exact-sync: refusal lost its wording"

  set +e
  out=$(FM_HOME="$home" "$MERGE_LOCAL" task-x1 --base '' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "flags-without-exact-sync: empty --base gave exit $rc: $out"
  assert_contains "$out" "require --exact-sync" \
    "flags-without-exact-sync: empty value bypassed the gate"

  set +e
  out=$(FM_HOME="$home" "$MERGE_LOCAL" task-x1 --remote origin 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "flags-without-exact-sync: --remote gave exit $rc: $out"

  after=$(git -C "$proj" rev-parse main)
  [ "$after" = "$before" ] || fail "flags-without-exact-sync: main moved without --exact-sync"
  pass "exact-sync request flags without --exact-sync refuse and never move main"
}

test_force_is_refused
test_stale_base_refuses
test_wrong_upstream_refuses
test_tree_mismatch_refuses
test_conflict_marker_refuses
test_pr_base_branch_refuses
test_missing_ci_refuses
test_red_ci_refuses
test_non_ff_main_refuses
test_happy_path_and_idempotent_rerun
test_foreign_tree_uses_its_own_guard_and_lease
test_ordinary_local_ff_still_works
test_outcome_sync_records_git_identity
test_outcome_sync_secondmate_line
test_outcome_sync_unreadable_role
test_matrix_job_name_prefix_matches
test_setext_underline_is_not_a_conflict_marker
test_sync_flags_without_exact_sync_refuse
