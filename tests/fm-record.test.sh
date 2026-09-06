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
  local ignored
  for ignored in .env nested/.env search-anomaly-signal/.serpapi.env \
    .obsidian/workspace.json .obsidian/workspace-mobile.json .obsidian/workspace-extra.json; do
    git -C "$home/data" check-ignore -q -- "$ignored" || fail "setup did not ignore $ignored"
    mkdir -p "$(dirname "$home/data/$ignored")"
    printf 'private workspace\n' > "$home/data/$ignored"
  done
  printf '# note\n\nhello\n' > "$home/data/captain.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'first tick'
  assert_contains "$OUT" 'state=pushed' 'first tick should push'
  git --git-dir="$origin" rev-parse --verify main >/dev/null \
    || fail 'first tick did not push main'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:captain.md \
    || fail 'first tick did not commit captain.md'
  for ignored in .obsidian/workspace.json .obsidian/workspace-mobile.json .obsidian/workspace-extra.json; do
    if git -C "$home/data" cat-file -e "HEAD:$ignored" 2>/dev/null; then
      fail "tick committed $ignored"
    fi
  done
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

assert_lfs_blob() {
  local home=$1 path=$2 pointer oid
  [ "$(git -C "$home/data" check-attr --cached filter -- "$path")" = "$path: filter: lfs" ] \
    || fail "$path did not receive the LFS filter"
  pointer="$TMP_ROOT/indexed-lfs-pointer"
  git -C "$home/data" show "HEAD:$path" > "$pointer" || fail "$path was not committed"
  git lfs pointer --check --file="$pointer" || fail "$path was not stored as an LFS pointer"
  oid=$(awk '/^oid sha256:/ {sub(/^oid sha256:/, ""); print}' "$pointer")
  [ "$oid" = "$(shasum -a 256 "$home/data/$path" | cut -d ' ' -f1)" ] \
    || fail "$path points at the wrong LFS payload"
}

test_lfs_text_threshold_and_no_oscillation() {
  local home origin path
  IFS=$(printf '\t') read -r home origin < <(new_home lfs)
  setup_record "$home" "$origin"
  mkdir -p "$home/data/raw"
  dd if=/dev/zero of="$home/data/raw/small.txt" bs=1048575 count=1 2>/dev/null
  dd if=/dev/zero of="$home/data/raw/exact.txt" bs=1048576 count=1 2>/dev/null
  dd if=/dev/zero of="$home/data/raw/above.txt" bs=1048577 count=1 2>/dev/null
  for path in 'raw/space file.csv' raw/-dash.json 'raw/brack[et].vtt' 'raw/star*.txt' 'raw/question?.json'; do
    dd if=/dev/zero of="$home/data/$path" bs=1048576 count=1 2>/dev/null
  done
  for path in raw/bracke.vtt raw/starX.txt raw/questionX.json; do
    printf 'small\n' > "$home/data/$path"
  done
  printf 'PNG' > "$home/data/raw/pic.png"
  run_rec "$home" checkpoint --reason session-start
  expect_code 0 "$RC" 'lfs attributes'
  for path in raw/pic.png raw/exact.txt raw/above.txt 'raw/space file.csv' \
    raw/-dash.json 'raw/brack[et].vtt' 'raw/star*.txt' 'raw/question?.json'; do
    assert_lfs_blob "$home" "$path"
  done
  for path in raw/small.txt raw/bracke.vtt raw/starX.txt raw/questionX.json; do
    [ "$(git -C "$home/data" check-attr --cached filter -- "$path")" = "$path: filter: unspecified" ] \
      || fail "$path received an unintended LFS filter"
    git -C "$home/data" show "HEAD:$path" > "$TMP_ROOT/ordinary-blob"
    cmp -s "$TMP_ROOT/ordinary-blob" "$home/data/$path" || fail "$path did not retain ordinary bytes"
  done
  for path in raw/exact.txt 'raw/space file.csv' 'raw/brack[et].vtt' 'raw/star*.txt' 'raw/question?.json'; do
    printf 'shrunken\n' > "$home/data/$path"
  done
  run_rec "$home" setup --code-root "$ROOT"
  expect_code 0 "$RC" 'setup preserves LFS rules'
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'lfs shrink'
  for path in raw/exact.txt 'raw/space file.csv' 'raw/brack[et].vtt' 'raw/star*.txt' 'raw/question?.json'; do
    assert_lfs_blob "$home" "$path"
  done
  pass "fm-record: LFS attributes are literal and survive shrink and repeated setup"
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
  plist="$TMP_ROOT/job/record.plist"
  mkdir -p "$(dirname "$plist")" "$TMP_ROOT/job/logs"
  HOME="$TMP_ROOT/empty-home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RECORD_PLIST="$plist" FM_RECORD_LOG_DIR="$TMP_ROOT/job/logs" \
    "$RECORD" setup --write-plist --code-root "$ROOT" >/dev/null
  python3 - "$plist" "$ROOT" "$home" "$TMP_ROOT/job/logs" <<'PYTEST' || fail 'incorrect LaunchAgent configuration'
import plistlib
import sys
with open(sys.argv[1], "rb") as stream:
    job = plistlib.load(stream)
assert job["Label"] == "com.firstmate.record-tick"
assert type(job["StartInterval"]) is int and job["StartInterval"] == 60
assert "KeepAlive" not in job
assert job["ProgramArguments"] == [sys.argv[2] + "/bin/fm-record.sh", "tick"]
assert job["EnvironmentVariables"]["FM_HOME"] == sys.argv[3]
assert job["RunAtLoad"] is True
assert job["StandardOutPath"] == sys.argv[4] + "/firstmate-record-tick.stdout.log"
assert job["StandardErrorPath"] == sys.argv[4] + "/firstmate-record-tick.stderr.log"
PYTEST
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

test_commit_and_publication_failures_refuse() {
  local home origin before fakebin
  IFS=$(printf '\t') read -r home origin < <(new_home commit-failure)
  setup_record "$home" "$origin"
  printf 'old\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'commit failure seed'
  before=$(git -C "$home/data" rev-parse HEAD)
  printf 'new\n' > "$home/data/captain.md"
  touch "$home/data/.git/HEAD.lock"
  run_rec "$home" checkpoint --reason teardown --required
  expect_code 9 "$RC" 'required commit failure'
  assert_not_contains "$OUT" 'committed-local' 'failed commit reported success'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'locked HEAD changed'
  rm "$home/data/.git/HEAD.lock"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != read-tree ] || exit 1
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  FM_TEST_REAL_GIT=$(command -v git) PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason teardown --required
  expect_code 9 "$RC" 'required index publication failure'
  assert_not_contains "$OUT" 'committed-local' 'failed publication reported success'
  pass "fm-record: required checkpoints refuse commit and publication failures"
}

test_inventory_failures_refuse_partial_snapshots() {
  local home origin before fakebin scope
  IFS=$(printf '\t') read -r home origin < <(new_home enumeration)
  setup_record "$home" "$origin"
  mkdir -p "$home/state/task.inbox"
  printf 'old\n' > "$home/data/captain.md"
  printf 'message\n' > "$home/state/task.inbox/001.msg"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'inventory failure seed'
  before=$(git -C "$home/data" rev-parse HEAD)
  printf 'new\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/find" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "$FM_TEST_FIND_FAILURE" ]; then
  printf '%s\0' "$1"
  exit 1
fi
exec "$FM_TEST_REAL_FIND" "$@"
SH
  chmod +x "$fakebin/find"
  for scope in "$home/data" "$home/state/task.inbox"; do
    FM_TEST_REAL_FIND=$(command -v find) FM_TEST_FIND_FAILURE="$scope" PATH="$fakebin:$PATH" \
      run_rec "$home" checkpoint --reason stow
    expect_code 4 "$RC" 'enumeration failure'
    [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'partial inventory changed HEAD'
  done
  pass "fm-record: failed data and inbox enumeration cannot commit deletions"
}

test_frozen_bytes_must_match_the_settled_inventory() {
  local home origin before fakebin
  IFS=$(printf '\t') read -r home origin < <(new_home freeze)
  setup_record "$home" "$origin"
  printf 'old\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'freeze seed'
  before=$(git -C "$home/data" rev-parse HEAD)
  printf 'settled\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/data/captain.md" ]; then
    printf 'changed after settling\n' > "$arg"
  fi
done
exec "$FM_TEST_REAL_CP" "$@"
SH
  chmod +x "$fakebin/cp"
  FM_TEST_REAL_CP=$(command -v cp) PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason stow
  expect_code 4 "$RC" 'copy changed bytes'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'unsettled copied bytes changed HEAD'
  pass "fm-record: copied bytes must match the settled inventory"
}

test_cleanup_keeps_the_lock_until_candidates_are_removed() {
  local home origin fakebin pid n
  IFS=$(printf '\t') read -r home origin < <(new_home cleanup)
  setup_record "$home" "$origin"
  printf 'snapshot\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/data/.git/record-candidate" ] && [ -d "$arg/work" ]; then
    : > "$FM_HOME/cleanup-started"
    n=0
    while [ ! -e "$FM_HOME/cleanup-continue" ] && [ "$n" -lt 100 ]; do
      sleep 0.05
      n=$((n + 1))
    done
  fi
done
exec "$FM_TEST_REAL_RM" "$@"
SH
  chmod +x "$fakebin/rm"
  (
    trap - EXIT
    FM_TEST_REAL_RM=$(command -v rm) PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason stow
    expect_code 0 "$RC" 'cleanup checkpoint'
  ) &
  pid=$!
  n=0
  while [ ! -e "$home/cleanup-started" ] && [ "$n" -lt 200 ]; do
    sleep 0.05
    n=$((n + 1))
  done
  [ -e "$home/cleanup-started" ] || fail 'cleanup did not start'
  run_rec "$home" tick
  touch "$home/cleanup-continue"
  wait "$pid" || fail 'cleanup checkpoint failed'
  expect_code 3 "$RC" 'tick during candidate cleanup'
  [ ! -e "$home/data/.git/record-candidate" ] || fail 'candidate cleanup did not finish'
  pass "fm-record: cleanup retains the lock until candidate removal finishes"
}

test_first_delivery_is_retried_without_new_bytes() {
  local home origin mode before
  for mode in checkpoint offline; do
    IFS=$(printf '\t') read -r home origin < <(new_home "first-delivery-$mode")
    setup_record "$home" "$origin"
    printf 'snapshot\n' > "$home/data/captain.md"
    if [ "$mode" = checkpoint ]; then
      run_rec "$home" checkpoint --reason stow
      expect_code 0 "$RC" 'initial checkpoint'
    else
      mv "$origin" "$origin.away"
      run_rec "$home" tick
      expect_code 6 "$RC" 'initial offline push'
      mv "$origin.away" "$origin"
    fi
    before=$(git -C "$home/data" rev-parse HEAD)
    run_rec "$home" tick
    expect_code 0 "$RC" 'first delivery retry'
    assert_contains "$OUT" 'state=pushed' 'first delivery was skipped'
    [ "$(git --git-dir="$origin" rev-parse main)" = "$before" ] || fail 'first delivery did not reach origin'
  done
  pass "fm-record: an unchanged tick retries unconfirmed first delivery"
}

test_push_retains_credentials_and_classifies_lfs_failure() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home lfs-failure)
  setup_record "$home" "$origin"
  git -C "$home/data" config --local credential.helper '!f() { printf "username=fixture\npassword=fixture\n"; }; f'
  cat > "$home/data/.git/hooks/pre-push" <<'SH'
#!/usr/bin/env bash
printf 'protocol=https\nhost=example.invalid\n\n' | git credential fill > "$FM_TEST_CREDENTIAL_RESULT" || exit 1
printf 'git lfs upload failed\n' >&2
exit 1
SH
  chmod +x "$home/data/.git/hooks/pre-push"
  printf 'snapshot\n' > "$home/data/captain.md"
  FM_TEST_CREDENTIAL_RESULT="$home/credentials" run_rec "$home" tick
  expect_code 6 "$RC" 'LFS pre-push failure'
  assert_contains "$OUT" 'class=lfs' 'LFS upload failure was misclassified'
  assert_contains "$(cat "$home/credentials")" 'username=fixture' 'configured credential helper was disabled'
  git -C "$home/data" cat-file -e HEAD:captain.md || fail 'LFS failure lost the local commit'
  pass "fm-record: push retains credential helpers and reports LFS upload failure"
}

test_manual_lfs_commit_requires_resolved_payloads() {
  local home origin oid object
  IFS=$(printf '\t') read -r home origin < <(new_home missing-lfs)
  setup_record "$home" "$origin"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'missing LFS seed'
  secret_fixture github-classic > "$home/data/manual.png"
  git -C "$home/data" add manual.png
  set +e
  OUT=$(FM_HOME="$home" git -C "$home/data" commit -m 'manual LFS' 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'indexed LFS content bypassed scanning'
  assert_contains "$OUT" 'scan-blocked' 'indexed LFS content was not scanned'
  oid=$(git -C "$home/data" show :manual.png | sed -n 's/^oid sha256://p')
  object="$home/data/.git/lfs/objects/${oid:0:2}/${oid:2:2}/$oid"
  git -C "$home/data" show :manual.png > "$home/data/manual.png"
  rm "$object"
  set +e
  OUT=$(FM_HOME="$home" git -C "$home/data" commit -m 'missing LFS' 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'missing LFS content bypassed scanning'
  assert_contains "$OUT" 'cannot resolve indexed payloads' 'missing LFS object was not refused'
  pass "fm-record: manual LFS commits scan resolved bytes and refuse absent objects"
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
test_commit_and_publication_failures_refuse
test_inventory_failures_refuse_partial_snapshots
test_frozen_bytes_must_match_the_settled_inventory
test_cleanup_keeps_the_lock_until_candidates_are_removed
test_first_delivery_is_retried_without_new_bytes
test_push_retains_credentials_and_classifies_lfs_failure
test_manual_lfs_commit_requires_resolved_payloads
test_outer_repository_stays_clean
