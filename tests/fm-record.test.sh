#!/usr/bin/env bash
# Behavior tests for bin/fm-record.sh through the public executable.
# Fixtures are standalone scratch repositories with a local bare remote.
# They never call git worktree add against the outer firstmate repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECORD="$ROOT/bin/fm-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-record)
OUTER_STATUS_BEFORE=$(git -C "$ROOT" status --short --untracked-files=all)
fm_git_identity fmtest fmtest@example.invalid
export FM_RECORD_SETTLE_SECONDS=${FM_RECORD_SETTLE_SECONDS:-0}
export FM_RECORD_LOCK_WAIT_SECONDS=${FM_RECORD_LOCK_WAIT_SECONDS:-1}
export FM_RECORD_PUSH_TIMEOUT=${FM_RECORD_PUSH_TIMEOUT:-5}

secret_fixture() {
  case "$1" in
    github-classic) printf '%s%s' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' ;;
    stripe-test) printf '%s%s' 'sk' '_test_0123456789abcdefgh' ;;
    *) fail "secret_fixture: unknown fixture $1" ;;
  esac
}

new_home() {
  local name=$1 home origin
  home="$TMP_ROOT/$name/home"
  origin="$TMP_ROOT/$name/origin.git"
  mkdir -p "$home/data" "$home/state" "$home/config" "$TMP_ROOT/$name/logs"
  git init --quiet --bare --initial-branch=main "$origin"
  printf '%s\t%s\n' "$home" "$origin"
}

run_rec() {
  local home=$1
  shift
  set +e
  OUT=$(
    HOME="$TMP_ROOT/empty-home" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_RECORD_SETTLE_SECONDS="${FM_RECORD_SETTLE_SECONDS}" \
    FM_RECORD_LOCK_WAIT_SECONDS="${FM_RECORD_LOCK_WAIT_SECONDS}" \
    FM_RECORD_PUSH_TIMEOUT="${FM_RECORD_PUSH_TIMEOUT}" \
    "$RECORD" "$@" 2>&1
  )
  RC=$?
  set -e
}

setup_record() {
  local home=$1 origin=$2
  mkdir -p "$TMP_ROOT/empty-home"
  run_rec "$home" setup --init --origin "file://$origin" --code-root "$ROOT"
  expect_code 0 "$RC" "setup $home"
}

test_disabled_home_is_explicit_noop() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home disabled)
  run_rec "$home" tick
  expect_code 0 "$RC" 'disabled tick'
  assert_contains "$OUT" 'state=disabled' 'disabled tick state'
  [ ! -e "$home/data/.git" ] || fail 'disabled tick created a repository'
  run_rec "$home" checkpoint --reason session-start
  expect_code 0 "$RC" 'disabled checkpoint'
  assert_contains "$OUT" 'state=disabled' 'disabled checkpoint state'
  run_rec "$home" health
  expect_code 0 "$RC" 'disabled health'
  assert_contains "$OUT" 'state=disabled' 'disabled health state'
  pass "fm-record: a disabled home is an explicit no-op"
}

test_disabled_home_does_not_need_hash_tools() {
  local home origin path_dir
  IFS=$(printf '\t') read -r home origin < <(new_home disabled-no-hash)
  path_dir="$TMP_ROOT/disabled-no-hash/path"
  mkdir -p "$path_dir"
  ln -sf "$(command -v bash)" "$path_dir/bash"
  ln -sf "$(command -v env)" "$path_dir/env"
  set +e
  OUT=$(
    PATH="$path_dir" HOME="$TMP_ROOT/empty-home" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
      "$RECORD" checkpoint --reason teardown --required 2>&1
  )
  RC=$?
  set -e
  expect_code 0 "$RC" 'disabled checkpoint without shasum'
  assert_contains "$OUT" 'state=disabled' 'disabled checkpoint without shasum state'
  pass "fm-record: a disabled home does not require hash tools"
}

test_setup_and_first_tick_commit_and_push() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home first-tick)
  setup_record "$home" "$origin"
  assert_contains "$(cat "$home/data/.gitignore")" '**/.env' 'setup omitted .env ignore'
  assert_contains "$(cat "$home/data/.gitignore")" 'search-anomaly-signal/.serpapi.env' \
    'setup omitted the serpapi env ignore'
  printf '# note\n\nhello\n' > "$home/data/captain.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'first tick'
  assert_contains "$OUT" 'state=pushed' 'first tick should push'
  git --git-dir="$origin" rev-parse --verify main >/dev/null \
    || fail 'first tick did not push main'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:captain.md \
    || fail 'first tick did not commit captain.md'
  pass "fm-record: the first tick commits and pushes a clean Record"
}

test_unchanged_ticks_make_no_new_commit() {
  local home origin first second
  IFS=$(printf '\t') read -r home origin < <(new_home unchanged)
  setup_record "$home" "$origin"
  printf 'x\n' > "$home/data/captain.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'seed tick'
  first=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  run_rec "$home" tick
  expect_code 0 "$RC" 'second tick'
  assert_contains "$OUT" 'state=unchanged' 'second tick should be unchanged'
  run_rec "$home" tick
  expect_code 0 "$RC" 'third tick'
  assert_contains "$OUT" 'state=unchanged' 'third tick should be unchanged'
  second=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  [ "$first" = "$second" ] || fail 'unchanged ticks created a new commit'
  pass "fm-record: unchanged ticks do not create commits"
}

test_git_overrides_and_wrong_root_refuse() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home overrides)
  setup_record "$home" "$origin"
  set +e
  OUT=$(
    HOME="$TMP_ROOT/empty-home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      GIT_DIR=/tmp/nope "$RECORD" tick 2>&1
  )
  RC=$?
  set -e
  expect_code 8 "$RC" 'GIT_DIR override'
  assert_contains "$OUT" 'GIT_DIR' 'GIT_DIR refusal'

  mkdir -p "$TMP_ROOT/other/data"
  set +e
  OUT=$(
    HOME="$TMP_ROOT/empty-home" FM_HOME="$TMP_ROOT/other" FM_ROOT_OVERRIDE="$ROOT" \
      FM_DATA_OVERRIDE="$home/data" "$RECORD" tick 2>&1
  )
  RC=$?
  set -e
  expect_code 8 "$RC" 'wrong-root'
  assert_contains "$OUT" 'exactly this home' 'wrong-root message'
  pass "fm-record: inherited Git overrides and a wrong root refuse"
}

test_busy_tick_when_lock_is_held() {
  local home origin lock pid
  IFS=$(printf '\t') read -r home origin < <(new_home busy)
  setup_record "$home" "$origin"
  printf 'x\n' > "$home/data/captain.md"
  lock="$home/data/.git/firstmate-record.lock"
  mkdir -p "$lock"
  sleep 30 &
  pid=$!
  printf '%s\n' "$pid" > "$lock/pid"
  run_rec "$home" tick
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 3 "$RC" 'busy tick'
  assert_contains "$OUT" 'state=busy' 'busy state'
  pass "fm-record: a live lock owner makes tick busy"
}

test_abandoned_lock_is_recovered() {
  local home origin lock
  IFS=$(printf '\t') read -r home origin < <(new_home abandoned)
  setup_record "$home" "$origin"
  printf 'x\n' > "$home/data/captain.md"
  lock="$home/data/.git/firstmate-record.lock"
  mkdir -p "$lock"
  printf '1\n' > "$lock/pid"
  run_rec "$home" tick
  expect_code 0 "$RC" 'abandoned lock tick'
  assert_contains "$OUT" 'state=pushed' 'abandoned lock recovered'
  pass "fm-record: an abandoned lock is recovered"
}

test_unsettled_candidate_is_not_committed() {
  local home origin before
  IFS=$(printf '\t') read -r home origin < <(new_home unsettled)
  setup_record "$home" "$origin"
  printf 'one\n' > "$home/data/captain.md"
  run_rec "$home" tick
  before=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  : > "$home/mutate"
  (
    n=0
    while [ -f "$home/mutate" ]; do
      printf 'mut-%s\n' "$n" > "$home/data/captain.md"
      sleep 0.05
      n=$((n + 1))
    done
  ) &
  FM_RECORD_SETTLE_SECONDS=2 run_rec "$home" checkpoint --reason stow
  rm -f "$home/mutate"
  wait || true
  [ "$RC" -eq 4 ] || fail "expected unsettled, got $RC $OUT"
  assert_contains "$OUT" 'state=unsettled' 'unsettled state'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$before" ] \
    || fail 'unsettled window produced a commit'
  pass "fm-record: an unstable settle window does not commit"
}

test_scan_blocks_commit_and_prints_no_secret() {
  local home origin secret before
  IFS=$(printf '\t') read -r home origin < <(new_home scan)
  setup_record "$home" "$origin"
  printf 'safe\n' > "$home/data/captain.md"
  run_rec "$home" tick
  before=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  secret=$(secret_fixture github-classic)
  printf '%s\n' "$secret" > "$home/data/leaky.md"
  run_rec "$home" tick
  expect_code 5 "$RC" 'scan-blocked'
  assert_contains "$OUT" 'scan-blocked' 'scan state'
  assert_not_contains "$OUT" "$secret" 'scan echoed the secret'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$before" ] \
    || fail 'scan-blocked tick created a commit'
  pass "fm-record: the scan chain blocks the commit without echoing secrets"
}

test_mirror_state_subset_and_removal() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home mirror)
  setup_record "$home" "$origin"
  printf 'working: start\n' > "$home/state/task-a.status"
  printf 'kind=ship\n' > "$home/state/task-a.meta"
  mkdir -p "$home/state/task-a.inbox/handled"
  printf 'hello\n' > "$home/state/task-a.inbox/001.msg"
  printf 'ack\n' > "$home/state/task-a.inbox/handled/001.msg"
  printf 'pid\n' > "$home/state/.watch.lock-not-a-lock"
  run_rec "$home" checkpoint --reason session-start
  expect_code 0 "$RC" 'mirror checkpoint'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:.record-state/task-a.status \
    || fail 'status was not mirrored'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:.record-state/task-a.inbox/handled/001.msg \
    || fail 'handled inbox was not mirrored'
  rm -f "$home/state/task-a.status"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'mirror removal'
  if git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:.record-state/task-a.status 2>/dev/null; then
    fail 'removed status stayed in the current tree'
  fi
  git --git-dir="$home/data/.git" cat-file -e HEAD~1:.record-state/task-a.status \
    || fail 'removed status vanished from history'
  pass "fm-record: the state mirror updates and keeps history"
}

test_special_names_and_outside_symlink_refuse() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home names)
  setup_record "$home" "$origin"
  printf 'ok\n' > "$home/data/-dash.md"
  printf 'ok\n' > "$home/data/space file.md"
  printf 'ok\n' > "$home/data/brackets[x].md"
  run_rec "$home" checkpoint --reason session-start
  expect_code 0 "$RC" 'special names'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e 'HEAD:-dash.md' \
    || fail 'leading-dash file was not committed'
  ln -s /etc/passwd "$home/data/outside.link"
  run_rec "$home" checkpoint --reason stow
  expect_code 8 "$RC" 'outside symlink'
  assert_contains "$OUT" 'outside' 'outside symlink message'
  pass "fm-record: special names commit and outside links refuse"
}

test_lfs_text_threshold_and_no_oscillation() {
  local home origin attrs
  IFS=$(printf '\t') read -r home origin < <(new_home lfs)
  setup_record "$home" "$origin"
  mkdir -p "$home/data/raw"
  dd if=/dev/zero of="$home/data/raw/small.txt" bs=1048575 count=1 2>/dev/null
  dd if=/dev/zero of="$home/data/raw/exact.txt" bs=1048576 count=1 2>/dev/null
  dd if=/dev/zero of="$home/data/raw/above.txt" bs=1048577 count=1 2>/dev/null
  printf 'x' > "$home/data/raw/space file.csv"
  dd if=/dev/zero of="$home/data/raw/space file.csv" bs=1048576 count=1 2>/dev/null
  printf 'x' > "$home/data/raw/-dash.json"
  dd if=/dev/zero of="$home/data/raw/-dash.json" bs=1048576 count=1 2>/dev/null
  printf 'x' > "$home/data/raw/brack[et].vtt"
  dd if=/dev/zero of="$home/data/raw/brack[et].vtt" bs=1048576 count=1 2>/dev/null
  printf 'PNG' > "$home/data/raw/pic.png"
  run_rec "$home" checkpoint --reason session-start
  expect_code 0 "$RC" 'lfs attributes'
  attrs=$(cat "$home/data/.gitattributes")
  assert_contains "$attrs" '*.png filter=lfs' 'png rule'
  assert_contains "$attrs" 'exact.txt' 'exact 1MiB path'
  assert_contains "$attrs" 'above.txt' 'above 1MiB path'
  assert_not_contains "$attrs" 'small.txt' 'below-threshold text should stay ordinary'
  dd if=/dev/zero of="$home/data/raw/exact.txt" bs=100 count=1 2>/dev/null
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'lfs shrink'
  attrs=$(cat "$home/data/.gitattributes")
  assert_contains "$attrs" 'exact.txt' 'shrunk LFS path must stay LFS'
  pass "fm-record: LFS attributes are deterministic and do not oscillate"
}

test_push_failure_keeps_local_commit() {
  local home origin first
  IFS=$(printf '\t') read -r home origin < <(new_home offline)
  setup_record "$home" "$origin"
  printf 'a\n' > "$home/data/captain.md"
  run_rec "$home" tick
  first=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  mv "$origin" "$origin.away"
  printf 'b\n' > "$home/data/captain.md"
  run_rec "$home" tick
  expect_code 6 "$RC" 'push-pending'
  assert_contains "$OUT" 'push-pending' 'push-pending state'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" != "$first" ] \
    || fail 'offline tick did not keep a new local commit'
  mv "$origin.away" "$origin"
  run_rec "$home" tick
  expect_code 0 "$RC" 'retry push'
  assert_contains "$OUT" 'state=pushed' 'retry should push'
  pass "fm-record: push failure keeps local commits and the next tick retries"
}

test_divergence_does_not_force() {
  local home origin other
  IFS=$(printf '\t') read -r home origin < <(new_home diverge)
  setup_record "$home" "$origin"
  printf 'a\n' > "$home/data/captain.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'base tick'
  other="$TMP_ROOT/diverge/other"
  git clone --quiet "file://$origin" "$other"
  git -C "$other" lfs install --local --force >/dev/null
  printf 'remote\n' > "$other/other.md"
  git -C "$other" add other.md
  git -C "$other" commit --quiet -m other
  git -C "$other" push --quiet origin main
  printf 'local\n' > "$home/data/local.md"
  run_rec "$home" tick
  expect_code 7 "$RC" 'diverged'
  assert_contains "$OUT" 'state=diverged' 'diverged state'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:local.md \
    || fail 'local commit was lost on diverge'
  pass "fm-record: a non-fast-forward push reports diverged and keeps both histories"
}

test_job_plist_has_sixty_seconds_and_no_keepalive() {
  local home origin plist
  IFS=$(printf '\t') read -r home origin < <(new_home job)
  setup_record "$home" "$origin"
  plist="$TMP_ROOT/diverge-job.plist"
  plist="$TMP_ROOT/job/record.plist"
  mkdir -p "$(dirname "$plist")" "$TMP_ROOT/job/logs"
  HOME="$TMP_ROOT/empty-home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RECORD_PLIST="$plist" FM_RECORD_LOG_DIR="$TMP_ROOT/job/logs" \
    "$RECORD" setup --write-plist --code-root "$ROOT" >/dev/null
  grep -Fq 'firstmate-record-tick-v1' "$plist" || fail 'plist missing owner mark'
  grep -Fq '<integer>60</integer>' "$plist" || fail 'plist missing 60 second interval'
  grep -Fq 'KeepAlive' "$plist" && fail 'plist has KeepAlive'
  grep -Fq "$ROOT/bin/fm-record.sh" "$plist" || fail 'plist does not point at the code-root script'
  grep -Fq "$home" "$plist" || fail 'plist missing FM_HOME'
  pass "fm-record: the LaunchAgent plist is a 60-second sibling job"
}

test_old_data_prefix_history_stays_an_ancestor() {
  local home origin work
  IFS=$(printf '\t') read -r home origin < <(new_home flatten)
  work="$TMP_ROOT/flatten/seed"
  mkdir -p "$work/data"
  git init --quiet -b main "$work"
  printf 'old\n' > "$work/data/seed.txt"
  git -C "$work" add data/seed.txt
  git -C "$work" commit --quiet -m seed
  git -C "$work" remote add origin "file://$origin"
  git -C "$work" push --quiet origin main
  old=$(git --git-dir="$origin" rev-parse main)
  rm -rf "$home/data"
  git clone --quiet "file://$origin" "$home/data"
  printf '%s\n' "file://$origin" > "$home/data/.git/record-origin"
  printf 'main\n' > "$home/data/.git/record-branch"
  printf '%s\n' "$ROOT" > "$home/data/.git/record-code-root"
  HOME="$TMP_ROOT/empty-home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$RECORD" setup --code-root "$ROOT" >/dev/null
  printf '# schema\n' > "$home/data/RECORD.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'flatten tick'
  git --git-dir="$home/data/.git" merge-base --is-ancestor "$old" HEAD \
    || fail 'old tip is not an ancestor'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:RECORD.md \
    || fail 'new root is missing RECORD.md'
  pass "fm-record: the new root commit keeps the old data/ tip as an ancestor"
}

test_pre_commit_hook_blocks_manual_commit() {
  local home origin secret
  IFS=$(printf '\t') read -r home origin < <(new_home hook)
  setup_record "$home" "$origin"
  printf 'safe\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason session-start
  secret=$(secret_fixture github-classic)
  printf '%s\n' "$secret" > "$home/data/manual.md"
  git --git-dir="$home/data/.git" --work-tree="$home/data" add manual.md
  set +e
  OUT=$(git --git-dir="$home/data/.git" --work-tree="$home/data" commit -m leak 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'manual commit bypassed the hook'
  assert_not_contains "$OUT" "$secret" 'hook echoed the secret'
  pass "fm-record: the installed pre-commit hook blocks a direct git commit"
}

test_required_checkpoint_times_out_when_lock_is_live() {
  local home origin lock pid
  IFS=$(printf '\t') read -r home origin < <(new_home required)
  setup_record "$home" "$origin"
  printf 'x\n' > "$home/data/captain.md"
  lock="$home/data/.git/firstmate-record.lock"
  mkdir -p "$lock"
  sleep 30 &
  pid=$!
  printf '%s\n' "$pid" > "$lock/pid"
  run_rec "$home" checkpoint --reason teardown --required
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 9 "$RC" 'required lock timeout'
  pass "fm-record: a required checkpoint refuses when the lock stays live"
}

test_outer_repository_stays_clean() {
  local after
  after=$(git -C "$ROOT" status --short --untracked-files=all)
  [ "$after" = "$OUTER_STATUS_BEFORE" ] \
    || fail "fixtures changed the outer repository"$'\n'"before: $OUTER_STATUS_BEFORE"$'\n'"after: $after"
  pass "fm-record: fixtures leave the outer repository unchanged"
}

test_disabled_home_is_explicit_noop
test_disabled_home_does_not_need_hash_tools
test_setup_and_first_tick_commit_and_push
test_unchanged_ticks_make_no_new_commit
test_git_overrides_and_wrong_root_refuse
test_busy_tick_when_lock_is_held
test_abandoned_lock_is_recovered
test_unsettled_candidate_is_not_committed
test_scan_blocks_commit_and_prints_no_secret
test_mirror_state_subset_and_removal
test_special_names_and_outside_symlink_refuse
test_lfs_text_threshold_and_no_oscillation
test_push_failure_keeps_local_commit
test_divergence_does_not_force
test_job_plist_has_sixty_seconds_and_no_keepalive
test_old_data_prefix_history_stays_an_ancestor
test_pre_commit_hook_blocks_manual_commit
test_required_checkpoint_times_out_when_lock_is_live
test_outer_repository_stays_clean
