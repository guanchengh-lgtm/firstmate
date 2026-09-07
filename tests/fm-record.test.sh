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

test_effective_push_destinations_must_match_binding() {
  local home origin other mode before
  IFS=$(printf '\t') read -r home origin < <(new_home push-destinations)
  setup_record "$home" "$origin"
  printf 'before\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'push destination seed'
  before=$(git -C "$home/data" rev-parse HEAD)
  printf 'private fixture\n' > "$home/data/captain.md"
  other="$TMP_ROOT/push-destinations/other.git"
  git init --quiet --bare --initial-branch=main "$other"
  for mode in pushurl multiple rewrite; do
    case "$mode" in
      pushurl) git -C "$home/data" config remote.origin.pushurl "file://$other" ;;
      multiple)
        git -C "$home/data" config --add remote.origin.pushurl "file://$origin"
        git -C "$home/data" config --add remote.origin.pushurl "file://$other"
        ;;
      rewrite) git -C "$home/data" config "url.file://$other.pushInsteadOf" "file://$origin" ;;
    esac
    run_rec "$home" tick
    expect_code 8 "$RC" "redirected push $mode"
    assert_contains "$OUT" 'push URL does not match' "redirected push $mode message"
    [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'redirected push advanced HEAD'
    [ -z "$(git --git-dir="$other" for-each-ref)" ] || fail 'unbound remote received Record contents'
    case "$mode" in
      rewrite) git -C "$home/data" config --remove-section "url.file://$other" ;;
      *) git -C "$home/data" config --unset-all remote.origin.pushurl ;;
    esac
  done
  git -C "$home/data" config remote.origin.pushurl "file://$origin"
  run_rec "$home" tick
  expect_code 0 "$RC" 'bound explicit push URL'
  [ "$(git --git-dir="$origin" show main:captain.md)" = 'private fixture' ] || fail 'bound push failed'
  pass 'fm-record: every effective push destination must match the binding'
}

test_lfs_uploads_require_the_bound_origin() {
  local home origin other key global before
  IFS=$(printf '\t') read -r home origin < <(new_home lfs-destinations)
  setup_record "$home" "$origin"
  other="$TMP_ROOT/lfs-destinations/other.git"
  git init --quiet --bare --initial-branch=main "$other"
  mkdir "$home/data/raw"
  printf 'private fixture image\n' > "$home/data/raw/photo.png"
  for key in lfs.url lfs.pushurl remote.origin.lfsurl remote.origin.lfspushurl; do
    git -C "$home/data" config "$key" "file://$other"
    run_rec "$home" tick
    expect_code 8 "$RC" "LFS redirect through $key"
    assert_contains "$OUT" 'LFS destination overrides' 'LFS redirect refusal'
    assert_not_contains "$OUT" "$other" 'LFS refusal exposed its URL'
    git -C "$home/data" config --unset "$key"
  done
  global="$home/global.gitconfig"
  git config --file "$global" lfs.url "file://$other"
  GIT_CONFIG_GLOBAL="$global" run_rec "$home" tick
  expect_code 8 "$RC" 'global LFS redirect'
  for key in lfs.url lfs.pushurl remote.origin.lfsurl; do
    git config --file "$home/data/.lfsconfig" "$key" "file://$other"
    run_rec "$home" tick
    expect_code 8 "$RC" "working .lfsconfig redirect through $key"
    rm "$home/data/.lfsconfig"
  done
  printf '[lfs\n' > "$home/data/.lfsconfig"
  run_rec "$home" tick
  expect_code 8 "$RC" 'malformed LFS configuration'
  assert_contains "$OUT" 'cannot validate the Record LFS destination' 'invalid LFS configuration message'
  rm "$home/data/.lfsconfig"
  git config --file "$home/data/.lfsconfig" lfs.url "file://$other"
  git -C "$home/data" add .lfsconfig
  rm "$home/data/.lfsconfig"
  run_rec "$home" tick
  expect_code 8 "$RC" 'indexed .lfsconfig redirect'
  assert_contains "$OUT" 'LFS destination overrides' 'indexed LFS configuration was ignored'
  git -C "$home/data" commit --quiet --no-verify -m 'Unsupported LFS configuration fixture'
  before=$(git -C "$home/data" rev-parse HEAD)
  git -C "$home/data" read-tree --empty
  run_rec "$home" tick
  expect_code 8 "$RC" 'committed .lfsconfig redirect'
  assert_contains "$OUT" 'LFS destination overrides' 'committed LFS configuration was ignored'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'LFS refusal advanced HEAD'
  [ -z "$(git --git-dir="$origin" for-each-ref)" ] || fail 'LFS refusal pushed Git history'
  git -C "$home/data" read-tree HEAD
  printf '[lfs]\nfetchinclude = raw/*\n' > "$home/data/.lfsconfig"
  run_rec "$home" tick
  expect_code 0 "$RC" 'default LFS destination with harmless configuration'
  [ "$(git --git-dir="$origin" rev-parse main)" = "$(git -C "$home/data" rev-parse HEAD)" ] \
    || fail 'bound origin did not receive Git history'
  python3 - "$other" "$origin" <<'PYTEST' || fail 'LFS objects reached the wrong remote'
from pathlib import Path
import sys
assert not list((Path(sys.argv[1]) / "lfs" / "objects").rglob("*"))
objects = [p for p in (Path(sys.argv[2]) / "lfs" / "objects").rglob("*") if p.is_file()]
assert len(objects) == 1
assert objects[0].read_bytes() == b"private fixture image\n"
PYTEST
  pass 'fm-record: LFS configuration cannot redirect uploads from the bound origin'
}

test_redirected_hooks_refuse_setup_and_transactions() {
  local home origin hooks global
  IFS=$(printf '\t') read -r home origin < <(new_home hook-path)
  git init --quiet --initial-branch=main "$home/data"
  git -C "$home/data" remote add origin "file://$origin"
  hooks="$home/redirected-hooks"
  mkdir -p "$hooks"
  git -C "$home/data" config core.hooksPath "$hooks"
  run_rec "$home" setup --code-root "$ROOT"
  expect_code 8 "$RC" 'setup with redirected hooks'
  [ ! -e "$home/data/.git/hooks/pre-commit" ] || fail 'refused setup installed a hook'
  [ ! -e "$hooks/pre-push" ] || fail 'refused setup installed LFS in redirected hooks'
  git -C "$home/data" config --unset core.hooksPath
  run_rec "$home" setup --code-root "$ROOT"
  expect_code 0 "$RC" 'setup with default hooks'
  printf 'safe\n' > "$home/data/captain.md"
  git -C "$home/data" config core.hooksPath "$hooks"
  run_rec "$home" tick
  expect_code 8 "$RC" 'tick with redirected local hooks'
  git -C "$home/data" config --unset core.hooksPath
  global="$home/global.gitconfig"
  git config --file "$global" core.hooksPath "$hooks"
  GIT_CONFIG_GLOBAL="$global" run_rec "$home" checkpoint --reason stow
  expect_code 8 "$RC" 'checkpoint with redirected global hooks'
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'checkpoint after restoring hook path'
  pass 'fm-record: setup and transactions refuse redirected hook directories'
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
  rm "$home/data/leaky.md"
  printf 'harmless content\n' > "$home/data/${secret}.md"
  run_rec "$home" tick
  expect_code 5 "$RC" 'credential filename'
  assert_not_contains "$OUT" "$secret" 'filename scan echoed the secret'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'credential filename changed HEAD'
  rm "$home/data/${secret}.md"
  secret=$(secret_fixture stripe-test)
  printf '%s\n' "$secret" > "$home/data/response.bin"
  run_rec "$home" tick
  expect_code 5 "$RC" 'binary Gitleaks credential'
  assert_not_contains "$OUT" "$secret" 'binary scan echoed the secret'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'binary credential changed HEAD'
  pass "fm-record: the scan chain blocks the commit without echoing secrets"
}

test_mirror_state_subset_and_removal() {
  local home origin inbox owner
  IFS=$(printf '\t') read -r home origin < <(new_home mirror)
  setup_record "$home" "$origin"
  printf 'working: start\n' > "$home/state/task-a.status"
  printf 'kind=ship\n' > "$home/state/task-a.meta"
  mkdir -p "$home/state/task-a.inbox/handled"
  printf 'hello\n' > "$home/state/task-a.inbox/001.msg"
  printf 'ack\n' > "$home/state/task-a.inbox/handled/001.msg"
  inbox="$home/state/task-a.inbox"
  owner="$inbox/.seq.lock.owner.fixture"
  mkdir -p "$owner" "$inbox/.seq.lock.owner.orphan"
  printf '99999999\n' > "$owner/pid"
  printf '99999998\n' > "$inbox/.seq.lock.owner.orphan/pid"
  ln -s "$owner" "$inbox/.seq.lock"
  printf 'durable\n' > "$inbox/.seq.lock-not-runtime.msg"
  printf 'pid\n' > "$home/state/.watch.lock-not-a-lock"
  run_rec "$home" checkpoint --reason session-start
  expect_code 0 "$RC" 'mirror checkpoint'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:.record-state/task-a.status \
    || fail 'status was not mirrored'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:.record-state/task-a.inbox/handled/001.msg \
    || fail 'handled inbox was not mirrored'
  [ "$(git -C "$home/data" ls-tree -r --name-only HEAD -- .record-state/task-a.inbox)" = ".record-state/task-a.inbox/.seq.lock-not-runtime.msg
.record-state/task-a.inbox/001.msg
.record-state/task-a.inbox/handled/001.msg" ] || fail 'mirror included runtime locks or omitted durable messages'
  [ -L "$inbox/.seq.lock" ] && [ -f "$owner/pid" ] || fail 'checkpoint changed live lock objects'
  rm "$inbox/.seq.lock"
  mkdir "$inbox/.seq.lock"
  printf '99999997\n' > "$inbox/.seq.lock/pid"
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
  assert_contains "$OUT" 'absolute symlink is not portable' 'absolute symlink message'
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

test_validation_omits_paths_and_cleans_transaction_files() {
  local home origin token path kind fakebin
  IFS=$(printf '\t') read -r home origin < <(new_home validation-cleanup)
  setup_record "$home" "$origin"
  mkdir "$home/tmp"
  token=$(secret_fixture github-classic)
  path="$home/data/$token"
  printf 'outside fixture\n' > "$home/outside.md"
  for kind in absolute broken outside special; do
    case "$kind" in
      absolute) ln -s "$home/outside.md" "$path" ;;
      broken) ln -s missing-target "$path" ;;
      outside) ln -s ../outside.md "$path" ;;
      special) mkfifo "$path" ;;
    esac
    TMPDIR="$home/tmp" run_rec "$home" tick
    expect_code 8 "$RC" "invalid $kind path"
    assert_not_contains "$OUT" "$token" 'validation exposed a credential-shaped filename'
    assert_contains "$OUT" 'fm-record:' 'validation did not give a safe diagnostic'
    [ ! -e "$home/data/.git/record-candidate" ] || fail 'validation retained its candidate files'
    [ ! -e "$home/data/.git/firstmate-record.lock" ] || fail 'validation retained its transaction lock'
    [ -z "$(find "$home/tmp" -mindepth 1 -print)" ] || fail 'validation retained inventory files'
    rm "$path"
  done
  printf 'safe content\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/sort" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */attributes | */fm-record-attr.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_SORT" "$@"
SH
  chmod +x "$fakebin/sort"
  FM_TEST_REAL_SORT=$(command -v sort) TMPDIR="$home/tmp" PATH="$fakebin:$PATH" \
    run_rec "$home" checkpoint --reason stow
  [ "$RC" -ne 0 ] || fail 'attribute write failure was accepted'
  [ ! -e "$home/data/.git/record-candidate" ] || fail 'attribute failure retained candidate files'
  [ -z "$(find "$home/tmp" -mindepth 1 -print)" ] || fail 'attribute failure retained temporary files'
  rm "$fakebin/sort"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$FM_HOME/data/.git/record-health" ] || exit 1
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
  FM_TEST_REAL_MV=$(command -v mv) TMPDIR="$home/tmp" PATH="$fakebin:$PATH" \
    run_rec "$home" checkpoint --reason stow
  [ "$RC" -ne 0 ] || fail 'health write failure was accepted'
  [ ! -e "$home/data/.git/record-candidate" ] || fail 'health failure retained candidate files'
  [ -z "$(find "$home/data/.git" -name 'record-health.tmp.*' -print)" ] \
    || fail 'health failure retained its temporary file'
  TMPDIR="$home/tmp" run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'checkpoint after validation failures'
  [ ! -e "$home/data/.git/record-candidate" ] || fail 'successful checkpoint retained candidate files'
  [ -z "$(find "$home/tmp" -mindepth 1 -print)" ] || fail 'successful checkpoint retained temporary files'
  pass 'fm-record: validation omits untrusted paths and cleans transaction files on every exit'
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
  cp "$home/data/.git/record-health" "$home/pending-health"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'local checkpoint while push is pending'
  assert_contains "$OUT" 'delivery=push-pending' 'checkpoint hid pending delivery'
  cmp -s "$home/pending-health" "$home/data/.git/record-health" || fail 'checkpoint replaced pending delivery health'
  run_rec "$home" health
  expect_code 0 "$RC" 'pending health'
  assert_contains "$OUT" 'state=push-pending' 'health lost pending delivery'
  mv "$origin.away" "$origin"
  run_rec "$home" tick
  expect_code 0 "$RC" 'retry push'
  assert_contains "$OUT" 'state=pushed' 'retry should push'
  run_rec "$home" health
  assert_contains "$OUT" 'state=pushed' 'successful push did not replace failure health'
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
  cp "$home/data/.git/record-health" "$home/diverged-health"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'local checkpoint while diverged'
  assert_contains "$OUT" 'delivery=diverged' 'checkpoint hid divergence'
  cmp -s "$home/diverged-health" "$home/data/.git/record-health" || fail 'checkpoint replaced divergence health'
  run_rec "$home" health
  expect_code 0 "$RC" 'divergence health'
  assert_contains "$OUT" 'state=diverged' 'health lost divergence'
  git --git-dir="$home/data/.git" --work-tree="$home/data" cat-file -e HEAD:local.md \
    || fail 'local commit was lost on diverge'
  printf 'later local edit\n' > "$home/data/local.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'changed checkpoint after divergence'
  assert_contains "$OUT" 'delivery=diverged' 'changed checkpoint lost delivery failure'
  assert_contains "$OUT" 'failure_class=diverged' 'changed checkpoint lost failure class'
  python3 - "$home/diverged-health" "$home/data/.git/record-health" <<'PYTEST' || fail 'delivery health was not preserved'
import sys
def read(path):
    return dict(line.rstrip("\n").split("=", 1) for line in open(path))
before, after = map(read, sys.argv[1:])
assert before["last_push_at"] == after["last_push_at"]
assert before["pending_since"] == after["pending_since"]
assert int(after["pending"]) > int(before["pending"])
assert int(after["pending_age_seconds"]) >= int(before["pending_age_seconds"])
PYTEST
  pass "fm-record: a non-fast-forward push reports diverged and keeps both histories"
}

test_job_plist_has_sixty_seconds_and_no_keepalive() {
  local home origin plist code_root fakebin tool
  IFS=$(printf '\t') read -r home origin < <(new_home job)
  setup_record "$home" "$origin"
  plist="$TMP_ROOT/job/record.plist"
  mkdir -p "$(dirname "$plist")" "$TMP_ROOT/job/logs"
  code_root="$TMP_ROOT/job/code"
  mkdir -p "$code_root"
  cp -R "$ROOT/bin" "$code_root/bin"
  git init --quiet --initial-branch=main "$code_root"
  fakebin=$(fm_fakebin "$home")
  for tool in restic rclone; do
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/launchctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_TEST_LAUNCHCTL_LOG"
SH
  chmod +x "$fakebin/launchctl"
  FM_RECORD_PLIST="$plist" FM_RECORD_LOG_DIR="$TMP_ROOT/job/logs" \
    FM_TEST_LAUNCHCTL_LOG="$home/launchctl.log" PATH="$fakebin:$PATH" \
    run_rec "$home" setup --write-plist --bootstrap --code-root "$code_root"
  expect_code 0 "$RC" 'validated job setup and bootstrap'
  assert_contains "$(cat "$home/launchctl.log")" "bootstrap gui/$UID $plist" 'explicit bootstrap'
  python3 - "$plist" "$code_root" "$home" "$TMP_ROOT/job/logs" <<'PYTEST' || fail 'incorrect LaunchAgent configuration'
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
  cp "$home/launchctl.log" "$home/launchctl.before"
  python3 - "$plist" <<'PYTEST'
import plistlib
import sys
with open(sys.argv[1], "rb") as source:
    job = plistlib.load(source)
job["ProgramArguments"][0] += ".missing"
with open(sys.argv[1], "wb") as dest:
    dest.write(plistlib.dumps(job).replace(b"<plist", b"<!-- firstmate-record-tick-v1 -->\n<plist", 1))
PYTEST
  FM_RECORD_PLIST="$plist" FM_RECORD_LOG_DIR="$TMP_ROOT/job/logs" \
    FM_TEST_LAUNCHCTL_LOG="$home/launchctl.log" PATH="$fakebin:$PATH" \
    run_rec "$home" setup --bootstrap --code-root "$code_root"
  expect_code 8 "$RC" 'bootstrap with changed executable'
  cmp -s "$home/launchctl.before" "$home/launchctl.log" || fail 'invalid job reached launchctl'
  pass "fm-record: the LaunchAgent plist is a validated 60-second sibling job"
}

test_job_preflight_refuses_missing_tools_and_disposable_code() {
  local home origin code_root plist fakebin missing tool flag linked
  IFS=$(printf '\t') read -r home origin < <(new_home job-preflight)
  setup_record "$home" "$origin"
  code_root="$TMP_ROOT/job-preflight/code"
  mkdir -p "$code_root/bin"
  cp "$RECORD" "$code_root/bin/fm-record.sh"
  git init --quiet --initial-branch=main "$code_root"
  plist="$home/record.plist"
  for missing in gitleaks git-lfs restic rclone; do
    fakebin="$home/path-$missing"
    mkdir -p "$fakebin"
    for tool in bash dirname git gitleaks git-lfs restic rclone; do
      [ "$tool" != "$missing" ] || continue
      case "$tool" in
        restic | rclone)
          printf '#!/bin/sh\nexit 0\n' > "$fakebin/$tool"
          chmod +x "$fakebin/$tool"
          ;;
        *) ln -s "$(command -v "$tool")" "$fakebin/$tool" ;;
      esac
    done
    for flag in --write-plist --bootstrap; do
      FM_RECORD_PLIST="$plist" FM_RECORD_LOG_DIR="$home/logs" PATH="$fakebin" \
        run_rec "$home" setup "$flag" --code-root "$code_root"
      expect_code 8 "$RC" "job without $missing $flag"
      assert_contains "$OUT" "requires $missing on PATH" 'missing job dependency'
      [ ! -e "$plist" ] || fail 'missing dependency still wrote a job'
    done
  done
  fakebin=$(fm_fakebin "$home")
  for tool in restic rclone; do
    printf '#!/bin/sh\nexit 0\n' > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
  mkdir "$home/empty-code"
  FM_RECORD_PLIST="$plist" PATH="$fakebin:$PATH" \
    run_rec "$home" setup --write-plist --code-root "$home/empty-code"
  expect_code 8 "$RC" 'job without executable'
  assert_contains "$OUT" 'must contain executable' 'missing job executable'
  git -C "$code_root" add bin/fm-record.sh
  git -C "$code_root" commit --quiet -m 'Record job fixture'
  linked="$TMP_ROOT/job-preflight/linked"
  git -C "$code_root" worktree add --quiet --detach "$linked"
  FM_RECORD_PLIST="$plist" PATH="$fakebin:$PATH" \
    run_rec "$home" setup --write-plist --code-root "$linked"
  expect_code 8 "$RC" 'job with disposable code'
  assert_contains "$OUT" 'primary code checkout' 'disposable job code'
  git -C "$home/data" remote add extra "file://$origin"
  FM_RECORD_PLIST="$plist" PATH="$fakebin:$PATH" \
    run_rec "$home" setup --write-plist --code-root "$code_root"
  expect_code 8 "$RC" 'job with invalid Record binding'
  [ ! -e "$plist" ] || fail 'invalid setup wrote a job'
  pass 'fm-record: job preflight requires tools, stable code, and a valid binding'
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
  printf 'clean manual content\n' > "$home/data/manual.md"
  git -C "$home/data" add manual.md
  set +e
  OUT=$(env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u GIT_DIR -u GIT_WORK_TREE \
    git -C "$home/data" commit -m 'Clean manual snapshot' 2>&1)
  RC=$?
  set -e
  expect_code 0 "$RC" 'manual commit discovers the hook repository'
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
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'failed index preparation advanced HEAD'
  [ ! -e "$home/data/.git/index.lock" ] || fail 'failed checkpoint retained its index lock'
  pass "fm-record: required checkpoints refuse commit and publication failures"
}

test_index_lock_protects_commit_and_publication() {
  local home origin before fakebin
  IFS=$(printf '\t') read -r home origin < <(new_home index-lock)
  setup_record "$home" "$origin"
  printf 'before\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'index lock seed'
  before=$(git -C "$home/data" rev-parse HEAD)
  cp "$home/data/.git/index" "$home/index.before"
  printf 'foreign lock\n' > "$home/data/.git/index.lock"
  printf 'after\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason teardown --required
  expect_code 9 "$RC" 'checkpoint with foreign index lock'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$before" ] || fail 'locked index allowed HEAD advancement'
  cmp -s "$home/index.before" "$home/data/.git/index" || fail 'locked index changed'
  [ "$(cat "$home/data/.git/index.lock")" = 'foreign lock' ] || fail 'foreign index lock changed'
  rm "$home/data/.git/index.lock"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = commit ]; then
    printf 'later edit\n' > "$FM_HOME/data/later.md"
    env -u GIT_INDEX_FILE "$FM_TEST_REAL_GIT" -C "$FM_HOME/data" add later.md >/dev/null 2>&1
    printf '%s\n' "$?" > "$FM_HOME/competing-add.status"
  fi
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/data/.git/index.lock" ]; then
    "$FM_TEST_REAL_GIT" -C "$FM_HOME/data" add later.md >/dev/null 2>&1
    printf '%s\n' "$?" > "$FM_HOME/publication-add.status"
  fi
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/git" "$fakebin/mv"
  FM_TEST_REAL_GIT=$(command -v git) FM_TEST_REAL_MV=$(command -v mv) PATH="$fakebin:$PATH" \
    run_rec "$home" checkpoint --reason teardown --required
  expect_code 0 "$RC" 'checkpoint after foreign lock release'
  [ "$(cat "$home/competing-add.status")" != 0 ] || fail 'manual staging raced the commit'
  [ "$(cat "$home/publication-add.status")" != 0 ] || fail 'manual staging raced index publication'
  [ ! -e "$home/data/.git/index.lock" ] || fail 'checkpoint retained its index lock'
  git -C "$home/data" diff --cached --quiet || fail 'published index differs from HEAD'
  [ "$(git -C "$home/data" show HEAD:captain.md)" = after ] || fail 'checkpoint lost the snapshot'
  [ "$(cat "$home/data/later.md")" = 'later edit' ] || fail 'checkpoint lost later work'
  if git -C "$home/data" cat-file -e HEAD:later.md 2>/dev/null; then
    fail 'checkpoint included work created after scanning'
  fi
  pass 'fm-record: the Git index lock protects the commit and index publication'
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
  local home origin fakebin
  IFS=$(printf '\t') read -r home origin < <(new_home lfs-failure)
  setup_record "$home" "$origin"
  git -C "$home/data" config --local credential.helper '!f() { printf "username=fixture\npassword=fixture\n"; }; f'
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
git_args=()
for arg in "$@"; do
  if [ "$arg" = push ]; then
    printf 'protocol=https\nhost=example.invalid\n\n' | "$FM_TEST_REAL_GIT" "${git_args[@]}" credential fill > "$FM_TEST_CREDENTIAL_RESULT" || exit 1
    printf 'git lfs upload failed\n' >&2
    exit 1
  fi
  git_args+=("$arg")
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  printf 'snapshot\n' > "$home/data/captain.md"
  FM_TEST_REAL_GIT=$(command -v git) FM_TEST_CREDENTIAL_RESULT="$home/credentials" PATH="$fakebin:$PATH" run_rec "$home" tick
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

test_owned_publication_is_retried_without_new_bytes() {
  local home origin before committed fakebin timing
  for timing in before setup after; do
    IFS=$(printf '\t') read -r home origin < <(new_home "publication-retry-$timing")
    setup_record "$home" "$origin"
    run_rec "$home" checkpoint --reason stow
    expect_code 0 "$RC" 'publication retry seed'
    before=$(git -C "$home/data" rev-parse HEAD)
    dd if=/dev/zero of="$home/data/large.txt" bs=1048576 count=1 2>/dev/null
    printf 'working: saved\n' > "$home/state/task.status"
    fakebin=$(fm_fakebin "$home")
    cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$FM_HOME/data/.record-state/task.status" ] || exit 1
done
exec "$FM_TEST_REAL_MV" "$@"
SH
    chmod +x "$fakebin/mv"
    FM_TEST_REAL_MV=$(command -v mv) PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason teardown --required
    expect_code 9 "$RC" 'owned publication failure'
    committed=$(git -C "$home/data" rev-parse HEAD)
    [ "$committed" != "$before" ] || fail 'publication fixture did not commit before failure'
    git -C "$home/data" diff --cached --quiet || fail 'publication fixture failed before updating the index'
    [ ! -e "$home/data/.record-state/task.status" ] || fail 'publication fixture did not block the mirror'
    if [ "$timing" != after ]; then
      printf 'shrunken before retry\n' > "$home/data/large.txt"
      if [ "$timing" = setup ]; then
        run_rec "$home" setup --code-root "$ROOT"
        expect_code 0 "$RC" 'setup after failed publication'
      fi
    fi
    run_rec "$home" checkpoint --reason stow
    expect_code 0 "$RC" 'owned publication retry'
    if [ "$timing" = after ]; then
      assert_contains "$OUT" 'state=unchanged' 'publication retry created another commit'
      [ "$(git -C "$home/data" rev-parse HEAD)" = "$committed" ] || fail 'publication retry changed HEAD'
    fi
    assert_lfs_blob "$home" large.txt
    cmp -s "$home/state/task.status" "$home/data/.record-state/task.status" || fail 'publication retry left the mirror stale'
    printf 'shrunken\n' > "$home/data/large.txt"
    run_rec "$home" checkpoint --reason stow
    expect_code 0 "$RC" 'LFS shrink after publication recovery'
    assert_lfs_blob "$home" large.txt
  done
  pass "fm-record: publication recovery retains LFS rules when files shrink before or after retry"
}

test_restored_lfs_pointers_require_resolved_payloads() {
  local home origin restored before oid object command secret
  IFS=$(printf '\t') read -r home origin < <(new_home restored-lfs)
  setup_record "$home" "$origin"
  printf 'clean image payload\n' > "$home/data/image.png"
  run_rec "$home" tick
  expect_code 0 "$RC" 'restored LFS seed'
  oid=$(git -C "$home/data" show HEAD:image.png | sed -n 's/^oid sha256://p')
  object="lfs/objects/${oid:0:2}/${oid:2:2}/$oid"
  restored="$TMP_ROOT/restored-lfs/clone"
  mkdir -p "$restored/state" "$restored/config"
  # A machine with global LFS filters, like the CI runner, installs the Git LFS
  # hooks during the clone itself; setup must accept them as LFS-owned.
  GIT_CONFIG_GLOBAL="$TMP_ROOT/restored-lfs/gitconfig" git lfs install --skip-repo >/dev/null
  GIT_CONFIG_GLOBAL="$TMP_ROOT/restored-lfs/gitconfig" GIT_LFS_SKIP_SMUDGE=1 \
    git clone --quiet "file://$origin" "$restored/data"
  [ -f "$restored/data/.git/hooks/pre-push" ] || fail 'clone with global LFS filters did not install the LFS hooks'
  run_rec "$restored" setup --code-root "$ROOT"
  expect_code 0 "$RC" 'restored LFS setup'
  git lfs pointer --check --file="$restored/data/image.png" || fail 'clone did not retain the pointer'
  [ ! -f "$restored/data/.git/$object" ] || fail 'clone unexpectedly has the LFS payload'
  before=$(git -C "$restored/data" rev-parse HEAD)
  printf 'new snapshot\n' > "$restored/data/captain.md"
  for command in tick checkpoint; do
    if [ "$command" = tick ]; then
      run_rec "$restored" tick
    else
      run_rec "$restored" checkpoint --reason stow
    fi
    expect_code 5 "$RC" "$command with absent LFS payload"
    [ "$(git -C "$restored/data" rev-parse HEAD)" = "$before" ] || fail 'missing LFS object changed HEAD'
  done
  mkdir -p "$(dirname "$restored/data/.git/$object")"
  cp "$home/data/.git/$object" "$restored/data/.git/$object"
  run_rec "$restored" checkpoint --reason stow
  expect_code 0 "$RC" 'resolved clean LFS payload'
  before=$(git -C "$restored/data" rev-parse HEAD)
  secret=$(secret_fixture github-classic)
  printf '%s\n' "$secret" > "$restored/data/image.png"
  git -C "$restored/data" add image.png
  git -C "$restored/data" show :image.png > "$restored/data/image.png"
  git -C "$restored/data" read-tree HEAD
  run_rec "$restored" checkpoint --reason stow
  expect_code 5 "$RC" 'resolved credential LFS payload'
  assert_not_contains "$OUT" "$secret" 'resolved LFS scan echoed the secret'
  [ "$(git -C "$restored/data" rev-parse HEAD)" = "$before" ] || fail 'credential LFS pointer changed HEAD'
  pass "fm-record: ticks and checkpoints scan resolved LFS payloads after a restore"
}

test_indexed_archive_links_keep_their_types() {
  local home origin mode
  IFS=$(printf '\t') read -r home origin < <(new_home archive-links)
  setup_record "$home" "$origin"
  python3 - "$home/data/archive.zip" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("safe.txt", "clean archive content")
PY
  ln -s archive.zip "$home/data/alias.zip"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'checkpoint with an archive link'
  mode=$(git -C "$home/data" ls-tree HEAD -- alias.zip)
  [ "${mode%% *}" = 120000 ] || fail 'checkpoint changed the indexed link type'
  [ "$(git -C "$home/data" show HEAD:alias.zip)" = archive.zip ] || fail 'checkpoint changed the link target'
  ln -s archive.zip "$home/data/manual.zip"
  git -C "$home/data" add manual.zip
  set +e
  OUT=$(git -C "$home/data" commit -m 'Add an internal archive link' 2>&1)
  RC=$?
  set -e
  expect_code 0 "$RC" 'manual commit with an archive link'
  printf 'outside data\n' > "$home/outside.txt"
  ln -s ../outside.txt "$home/data/outside.zip"
  git -C "$home/data" add outside.zip
  set +e
  OUT=$(git -C "$home/data" commit -m 'Reject an outside archive link' 2>&1)
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail 'manual commit accepted an outside link'
  assert_contains "$OUT" 'scan-blocked' 'outside indexed link was not refused by the scanner'
  pass "fm-record: indexed archive links retain their types without outside traversal"
}

test_outgoing_history_and_prohibited_paths_are_scanned() {
  local home origin before secret path
  IFS=$(printf '\t') read -r home origin < <(new_home outgoing-history)
  setup_record "$home" "$origin"
  printf 'clean\n' > "$home/data/captain.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'outgoing seed'
  before=$(git --git-dir="$origin" rev-parse main)
  for path in .env nested/.env search-anomaly-signal/.serpapi.env; do
    mkdir -p "$(dirname "$home/data/$path")"
    printf 'ACCOUNT_NAME=alice\n' > "$home/data/$path"
    git -C "$home/data" add -f "$path"
    set +e
    OUT=$(git -C "$home/data" commit -qm 'prohibited path' 2>&1)
    RC=$?
    set -e
    [ "$RC" -ne 0 ] || fail 'a prohibited path passed the real pre-commit hook'
    assert_contains "$OUT" 'prohibited path' 'hook omitted the prohibited path refusal'
    git -C "$home/data" read-tree HEAD
    rm "$home/data/$path"
  done
  secret=$(secret_fixture github-classic)
  printf '%s\n' "$secret" > "$home/data/unsafe.txt"
  git -C "$home/data" add unsafe.txt
  git -C "$home/data" commit --no-verify -qm 'unsupported manual commit'
  git -C "$home/data" rm -q unsafe.txt
  git -C "$home/data" commit --no-verify -qm 'remove unsafe file'
  run_rec "$home" tick
  expect_code 5 "$RC" 'outgoing deleted credential'
  assert_not_contains "$OUT" "$secret" 'history scan disclosed the credential'
  [ "$(git --git-dir="$origin" rev-parse main)" = "$before" ] || fail 'unsafe history reached origin'
  pass 'fm-record: manual hooks reject prohibited paths and tick scans outgoing history'
}

test_activation_roots_permissions_and_hooks_refuse_unsafe_setup() {
  local home origin other command hook before
  IFS=$(printf '\t') read -r home origin < <(new_home activation-boundaries)
  setup_record "$home" "$origin"
  python3 - "$home/data/.git" <<'PYTEST' || fail 'setup did not protect private Git content'
import os, stat, sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o700
PYTEST
  chmod 755 "$home/data/.git"
  run_rec "$home" checkpoint --reason teardown --required
  expect_code 8 "$RC" 'publicly readable Git directory'
  chmod 700 "$home/data/.git"
  other="$TMP_ROOT/other-boundary-home"
  mkdir -p "$other/state" "$other/data"
  printf 'other private content\n' > "$other/state/task.meta"
  for command in tick setup; do
    set +e
    OUT=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$other/state" \
      "$RECORD" "$command" 2>&1)
    RC=$?
    set -e
    expect_code 8 "$RC" 'mismatched state root'
    set +e
    OUT=$(FM_HOME="$other" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" \
      "$RECORD" "$command" 2>&1)
    RC=$?
    set -e
    expect_code 8 "$RC" 'mismatched data root'
  done
  [ ! -e "$other/.record-enabled" ] || fail 'setup activated the wrong home'
  for hook in pre-commit pre-push; do
    cp "$home/data/.git/hooks/$hook" "$home/$hook.before"
    printf '#!/bin/sh\nexit 1\n' > "$home/data/.git/hooks/$hook"
    before=$(shasum -a 256 "$home/data/.gitattributes")
    run_rec "$home" setup --code-root "$ROOT"
    expect_code 8 "$RC" 'unknown existing hook'
    [ "$(cat "$home/data/.git/hooks/$hook")" = "$(printf '#!/bin/sh\nexit 1')" ] || fail 'setup replaced an unknown protection'
    [ "$(shasum -a 256 "$home/data/.gitattributes")" = "$before" ] || fail 'refused setup changed attributes'
    cp "$home/$hook.before" "$home/data/.git/hooks/$hook"
  done
  mv "$home/data/.git" "$home/git.saved"
  for command in tick health; do
    run_rec "$home" "$command"
    expect_code 8 "$RC" 'activated home without Git metadata'
    assert_not_contains "$OUT" 'state=disabled' 'activated home became disabled'
  done
  run_rec "$home" checkpoint --reason teardown --required
  expect_code 8 "$RC" 'required checkpoint without activated Git metadata'
  pass 'fm-record: activation, root ownership, private modes, and existing hooks are enforced'
}

test_scope_ignores_only_record_exclusions_and_refuses_separators() {
  local home origin path name
  IFS=$(printf '\t') read -r home origin < <(new_home scope-and-separators)
  setup_record "$home" "$origin"
  mkdir -p "$home/data/raw" "$home/data/.git/info" "$home/state/task.inbox/handled"
  printf '*.log\n' > "$home/global-ignore"
  git -C "$home/data" config core.excludesFile "$home/global-ignore"
  printf '*.txt\n' > "$home/data/.git/info/exclude"
  printf '*.json\n' > "$home/data/raw/.gitignore"
  for path in raw/measurement.log raw/notes.txt raw/events.json; do
    printf 'durable content\n' > "$home/data/$path"
  done
  for name in .seq.lock.steal .seq.lock.steal.owner.fixture .ring-state .escalated .staging.fixture .dedup.fixture .lock-probe.fixture; do
    ln -s "$home/runtime-lease" "$home/state/task.inbox/$name"
  done
  printf 'handled message\n' > "$home/state/task.inbox/handled/001.msg"
  printf 'ordinary hidden message\n' > "$home/state/task.inbox/.seq.lock-not-runtime.msg"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'Record scope'
  for path in raw/measurement.log raw/notes.txt raw/events.json .record-state/task.inbox/handled/001.msg .record-state/task.inbox/.seq.lock-not-runtime.msg; do
    git -C "$home/data" cat-file -e "HEAD:$path" || fail "required content was omitted: $path"
  done
  for name in .seq.lock.steal .ring-state .escalated .staging.fixture .dedup.fixture .lock-probe.fixture; do
    if git -C "$home/data" cat-file -e "HEAD:.record-state/task.inbox/$name" 2>/dev/null; then
      fail 'runtime inbox object entered the mirror'
    fi
  done
  printf 'a\n' > "$home/data/a"
  printf 'b\n' > "$home/data/b"
  for path in "$home/data/"$'a\nb' "$home/state/task.inbox/"$'a\tb'; do
    printf 'must not disappear\n' > "$path"
    run_rec "$home" checkpoint --reason stow
    expect_code 8 "$RC" 'unsupported filename separator'
    assert_contains "$OUT" 'unsupported separators' 'separator refusal is not explicit'
    if [ "$path" = "$home/data/"$'a\nb' ]; then
      git -C "$home/data" add -f "$path"
      set +e
      OUT=$(git -C "$home/data" commit -qm 'unsupported filename' 2>&1)
      RC=$?
      set -e
      [ "$RC" -ne 0 ] || fail 'manual commit accepted an ambiguous filename'
      [ -z "$(find "$home/data/.git" -maxdepth 1 -name 'record-precommit.*' -print)" ] || fail 'manual refusal retained scan temporaries'
      git -C "$home/data" read-tree HEAD
    fi
    rm "$path"
  done
  pass 'fm-record: fixed scope preserves durable files and refuses ambiguous filenames'
}

test_quiet_ticks_skip_copy_hash_and_scan_work() {
  local home origin fakebin pushed stamp
  IFS=$(printf '\t') read -r home origin < <(new_home cheap-quiet-tick)
  setup_record "$home" "$origin"
  printf 'aaaa\n' > "$home/data/captain.md"
  printf 'status\n' > "$home/state/task.status"
  run_rec "$home" tick
  expect_code 0 "$RC" 'quiet tick seed'
  pushed=$(sed -n 's/^last_push_at=//p' "$home/data/.git/record-health")
  stamp=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns,s.st_ctime_ns)' "$home/data/.record-state/task.status")
  fakebin=$(fm_fakebin "$home")
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/cp"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/gitleaks"
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */captain.md | */task.status) exit 1 ;; esac
done
exec "$FM_TEST_REAL_SHASUM" "$@"
SH
  chmod +x "$fakebin/cp" "$fakebin/gitleaks" "$fakebin/shasum"
  for _ in 1 2 3; do
    FM_TEST_REAL_SHASUM=$(command -v shasum) PATH="$fakebin:$PATH" run_rec "$home" tick
    expect_code 0 "$RC" 'quiet tick without copies or scans'
    assert_contains "$OUT" 'state=unchanged' 'quiet tick result'
    assert_contains "$OUT" "last_push_at=$pushed" 'quiet tick lost the successful push receipt'
  done
  [ "$stamp" = "$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns,s.st_ctime_ns)' "$home/data/.record-state/task.status")" ] || fail 'quiet tick rewrote the mirror'
  python3 - "$home/data/captain.md" <<'PYTEST'
import os, sys
path = sys.argv[1]
s = os.stat(path)
with open(path, "w") as output:
    output.write("bbbb\n")
os.utime(path, ns=(s.st_atime_ns, s.st_mtime_ns))
PYTEST
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'same size and mtime rewrite'
  assert_contains "$OUT" 'delivery=pending' 'new local content was reported as delivered'
  [ "$(git -C "$home/data" show HEAD:captain.md)" = bbbb ] || fail 'metadata hint hid changed bytes'
  pass 'fm-record: quiet ticks skip corpus work and changed bytes still receive content checks'
}

test_head_race_preserves_the_competing_commit() {
  local home origin fakebin
  IFS=$(printf '\t') read -r home origin < <(new_home head-race)
  setup_record "$home" "$origin"
  printf 'seed\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'HEAD race seed'
  printf 'candidate\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = add ] && [ -n "${GIT_INDEX_FILE:-}" ]; then
    "$FM_TEST_REAL_GIT" "$@" || exit 1
    printf 'competing commit\n' > "$FM_HOME/data/later.md"
    env -u GIT_INDEX_FILE "$FM_TEST_REAL_GIT" -C "$FM_HOME/data" add -A || exit 1
    env -u GIT_INDEX_FILE "$FM_TEST_REAL_GIT" -C "$FM_HOME/data" commit --no-verify -qm competing || exit 1
    "$FM_TEST_REAL_GIT" -C "$FM_HOME/data" rev-parse HEAD > "$FM_HOME/competing-head"
    exit 0
  fi
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  FM_TEST_REAL_GIT=$(command -v git) PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason stow
  expect_code 8 "$RC" 'HEAD advanced after freezing'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$(cat "$home/competing-head")" ] || fail 'checkpoint replaced the competing commit'
  git -C "$home/data" diff --cached --quiet || fail 'checkpoint changed the competing index'
  git -C "$home/data" cat-file -e HEAD:later.md || fail 'competing file disappeared'
  pass 'fm-record: changed HEAD refuses the frozen snapshot without replacing competing work'
}

test_index_publication_restart_preserves_user_staging() {
  local home origin fakebin before after
  IFS=$(printf '\t') read -r home origin < <(new_home publication-recovery)
  setup_record "$home" "$origin"
  printf 'before\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'publication recovery seed'
  before=$(git -C "$home/data" rev-parse HEAD)
  cp "$home/data/.git/index" "$home/index.before"
  printf 'after\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$FM_HOME/data/.git/index.lock" ] || exit 1
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
  FM_TEST_REAL_MV=$(command -v mv) PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason teardown --required
  expect_code 9 "$RC" 'failed final index rename'
  after=$(git -C "$home/data" rev-parse HEAD)
  [ "$after" != "$before" ] || fail 'fixture did not reach the committed publication boundary'
  cmp -s "$home/index.before" "$home/data/.git/index" || fail 'failed rename changed the old index'
  git -C "$home/data" read-tree HEAD
  printf 'user staging\n' > "$home/data/user.md"
  git -C "$home/data" add user.md
  cp "$home/data/.git/index" "$home/index.user"
  run_rec "$home" checkpoint --reason stow
  expect_code 8 "$RC" 'recovery with competing staging'
  cmp -s "$home/index.user" "$home/data/.git/index" || fail 'recovery replaced genuine staging'
  cp "$home/index.before" "$home/data/.git/index"
  rm "$home/data/user.md"
  run_rec "$home" checkpoint --reason teardown --required
  expect_code 0 "$RC" 'restart reconciles prepared index'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$after" ] || fail 'recovery created a second commit'
  git -C "$home/data" diff --cached --quiet || fail 'recovery did not publish the committed index'
  [ "$(cat "$home/data/captain.md")" = after ] || fail 'recovery lost source bytes'
  pass 'fm-record: restart recovers prepared publication while preserving competing staging'
}

test_index_recovery_locks_before_comparing_staged_content() {
  local home origin fakebin after
  IFS=$(printf '\t') read -r home origin < <(new_home recovery-race)
  setup_record "$home" "$origin"
  printf 'before\n' > "$home/data/captain.md"
  run_rec "$home" checkpoint --reason stow
  expect_code 0 "$RC" 'recovery race seed'
  printf 'after\n' > "$home/data/captain.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$FM_HOME/data/.git/index.lock" ] || exit 1
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
  FM_TEST_REAL_MV=$(command -v mv) PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason teardown --required
  expect_code 9 "$RC" 'recovery race publication failure'
  after=$(git -C "$home/data" rev-parse HEAD)
  rm "$fakebin/mv"
  cat > "$fakebin/stage-race" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_HOME/add-code" ] || exit 0
printf 'staged bytes\n' > "$FM_HOME/data/user.md"
"$FM_TEST_REAL_GIT" -C "$FM_HOME/data" add user.md > "$FM_HOME/add-output" 2>&1
printf '%s\n' "$?" > "$FM_HOME/add-code"
printf 'working bytes\n' > "$FM_HOME/data/user.md"
ln -s missing "$FM_HOME/data/broken"
SH
  cat > "$fakebin/shasum" <<'SH'
#!/usr/bin/env bash
output=$("$FM_TEST_REAL_SHASUM" "$@") || exit 1
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/data/.git/index" ]; then stage-race; fi
done
printf '%s\n' "$output"
SH
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ -d "$FM_HOME/data/.git/record-publication" ] && [ -z "${GIT_INDEX_FILE:-}" ]; then
  for arg in "$@"; do
    if [ "$arg" = --cached ]; then
      output=$("$FM_TEST_REAL_GIT" "$@")
      rc=$?
      stage-race
      printf '%s' "$output"
      exit "$rc"
    fi
  done
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/stage-race" "$fakebin/shasum" "$fakebin/git"
  FM_TEST_REAL_SHASUM=$(command -v shasum) FM_TEST_REAL_GIT=$(command -v git) \
    PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason stow
  expect_code 8 "$RC" 'broken source after recovery'
  [ -s "$home/add-code" ] || fail 'fixture did not race recovery with git add'
  [ "$(cat "$home/add-code")" -ne 0 ] || fail 'git add succeeded inside the recovery comparison and publication window'
  [ "$(git -C "$home/data" rev-parse HEAD)" = "$after" ] || fail 'recovery race changed the committed snapshot'
  git -C "$home/data" diff --cached --quiet || fail 'recovery race left an inconsistent index'
  [ "$(cat "$home/data/user.md")" = 'working bytes' ] || fail 'recovery changed the competing working bytes'
  pass 'fm-record: recovery holds the index lock throughout staged-content checks and publication'
}

test_index_recovery_accepts_a_status_refresh() {
  local home origin fakebin fault target after entries
  for fault in mv rm; do
    IFS=$(printf '\t') read -r home origin < <(new_home "recovery-refresh-$fault")
    setup_record "$home" "$origin"
    printf 'before\n' > "$home/data/captain.md"
    run_rec "$home" checkpoint --reason stow
    expect_code 0 "$RC" 'refresh recovery seed'
    printf 'after\n' > "$home/data/captain.md"
    fakebin=$(fm_fakebin "$home")
    if [ "$fault" = mv ]; then target=index.lock; else target=record-publication; fi
    cat > "$fakebin/$fault" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$FM_HOME/data/.git/$FM_TEST_FAULT_TARGET" ] || exit 1
done
exec "$FM_TEST_REAL_COMMAND" "$@"
SH
    chmod +x "$fakebin/$fault"
    FM_TEST_REAL_COMMAND=$(command -v "$fault") FM_TEST_FAULT_TARGET=$target \
      PATH="$fakebin:$PATH" run_rec "$home" checkpoint --reason teardown --required
    expect_code 9 "$RC" "interrupted index publication at $fault"
    after=$(git -C "$home/data" rev-parse HEAD)
    [ -d "$home/data/.git/record-publication" ] || fail 'publication interruption lost its recovery journal'
    cp "$home/data/.git/index" "$home/index.before-refresh"
    entries=$(git -C "$home/data" ls-files --stage)
    GIT_OPTIONAL_LOCKS=1 git -C "$home/data" status --porcelain >/dev/null
    if cmp -s "$home/index.before-refresh" "$home/data/.git/index"; then fail 'status did not refresh the index cache'; fi
    [ "$(git -C "$home/data" ls-files --stage)" = "$entries" ] || fail 'status changed the staged entries'
    run_rec "$home" checkpoint --reason teardown --required
    expect_code 0 "$RC" "recovery after status at $fault"
    [ "$(git -C "$home/data" rev-parse HEAD)" = "$after" ] || fail 'recovery repeated the committed snapshot'
    git -C "$home/data" diff --cached --quiet || fail 'recovery did not reconcile the index'
    [ ! -e "$home/data/.git/record-publication" ] || fail 'recovery retained the completed journal'
    [ "$(cat "$home/data/captain.md")" = after ] || fail 'recovery changed the source bytes'
  done
  pass 'fm-record: recovery accepts stat refreshes before and after index publication'
}

test_health_reads_current_pending_commits_and_age() {
  local home origin receipt before age first_age
  IFS=$(printf '\t') read -r home origin < <(new_home current-health)
  setup_record "$home" "$origin"
  printf 'seed\n' > "$home/data/captain.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'current health seed push'
  receipt="$home/data/.git/record-health"
  cp "$receipt" "$home/pushed-health"
  printf 'manual note\n' > "$home/data/manual.md"
  git -C "$home/data" add manual.md
  before=$(($(date +%s) - 120))
  HOME="$TMP_ROOT/empty-home" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    GIT_AUTHOR_DATE="$before +0000" GIT_COMMITTER_DATE="$before +0000" \
    git -C "$home/data" commit -qm 'Manual checkpoint'
  cp "$home/data/.git/index" "$home/index.before-health"
  run_rec "$home" health
  expect_code 0 "$RC" 'health after manual commit'
  assert_contains "$OUT" 'state=committed-local' 'health claimed the manual commit was pushed'
  assert_contains "$OUT" 'pending=1' 'health missed the outgoing manual commit'
  assert_contains "$OUT" 'delivery=pending' 'health missed pending delivery'
  assert_contains "$OUT" "last_push_at=$(sed -n 's/^last_push_at=//p' "$home/pushed-health")" 'health lost the last push receipt'
  first_age=$(printf '%s\n' "$OUT" | sed -n 's/^pending_age_seconds=//p')
  [ "$first_age" -ge 120 ] || fail 'health omitted elapsed age after the manual commit'
  cmp -s "$receipt" "$home/pushed-health" || fail 'health rewrote the saved push receipt'
  cmp -s "$home/data/.git/index" "$home/index.before-health" || fail 'health changed the index'
  mv "$origin" "$origin.away"
  run_rec "$home" tick
  expect_code 6 "$RC" 'current health pending push'
  cp "$receipt" "$home/pending-health"
  sleep 2
  run_rec "$home" health
  expect_code 0 "$RC" 'current health pending age'
  assert_contains "$OUT" 'state=push-pending' 'health lost the delivery failure'
  assert_contains "$OUT" 'failure_class=offline' 'health lost the sanitized failure class'
  assert_contains "$OUT" "last_push_at=$(sed -n 's/^last_push_at=//p' "$home/pushed-health")" 'pending health lost the push receipt'
  age=$(printf '%s\n' "$OUT" | sed -n 's/^pending_age_seconds=//p')
  first_age=$(sed -n 's/^pending_age_seconds=//p' "$home/pending-health")
  [ "$age" -ge "$((first_age + 2))" ] || fail 'health did not advance the elapsed pending age'
  cmp -s "$receipt" "$home/pending-health" || fail 'health rewrote pending delivery health'
  pass 'fm-record: read-only health reports current commits and age while retaining delivery receipts'
}

seed_authored_record() {
  local home=$1
  mkdir -p "$home/data/decisions"
  printf '# Captain\n\nFleet memory.\n' > "$home/data/captain.md"
  printf '# Old\n\nPrior choice.\n' > "$home/data/decisions/old.md"
}

commit_footer_candidate() {
  local live=$1 dest=$2 out
  git clone --quiet "$live" "$dest"
  out="$dest.out"
  python3 "$ROOT/bin/fm-record-links.py" propose --root "$dest" --out "$out"
  python3 "$ROOT/bin/fm-record-links.py" apply --root "$dest" --plan "$out/manifest.json"
  git -C "$dest" add -A
  git -C "$dest" commit --quiet -m 'related footer'
}

test_land_related_disabled_home_is_noop() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home land-disabled)
  run_rec "$home" land-related --candidate "$TMP_ROOT/missing" --expected-head deadbeef
  expect_code 0 "$RC" 'disabled land-related'
  assert_contains "$OUT" 'state=disabled' 'disabled land-related state'
  pass "fm-record: a disabled home is a no-op for land-related"
}

test_land_related_lands_one_footer_commit() {
  local home origin expected candidate landed remote
  IFS=$(printf '\t') read -r home origin < <(new_home land-ok)
  setup_record "$home" "$origin"
  seed_authored_record "$home"
  run_rec "$home" tick
  expect_code 0 "$RC" 'land seed tick'
  expected=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  remote=$(git --git-dir="$origin" rev-parse main)
  candidate="$TMP_ROOT/land-ok/candidate"
  commit_footer_candidate "$home/data" "$candidate"
  run_rec "$home" land-related --candidate "$candidate" --expected-head "$expected"
  expect_code 0 "$RC" 'land-related success'
  assert_contains "$OUT" 'state=committed-local' 'land-related state'
  assert_contains "$OUT" 'detail=land-related' 'land-related detail'
  landed=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  [ "$landed" = "$(git -C "$candidate" rev-parse HEAD)" ] \
    || fail 'live HEAD is not the candidate commit'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD^)" = "$expected" ] \
    || fail 'landed commit parent is not the expected HEAD'
  [ "$(git --git-dir="$origin" rev-parse main)" = "$remote" ] \
    || fail 'land-related pushed'
  git --git-dir="$home/data/.git" --work-tree="$home/data" diff --quiet \
    || fail 'land-related left a dirty worktree'
  grep -q '^Related: supersedes: none; cites: none; relates: none$' "$home/data/captain.md" \
    || fail 'landed captain.md is missing the Related footer'
  run_rec "$home" tick
  expect_code 0 "$RC" 'tick after land-related'
  assert_contains "$OUT" 'state=pushed' 'tick after land-related should push'
  [ "$(git --git-dir="$origin" rev-parse main)" = "$landed" ] \
    || fail 'next tick did not push the landed commit'
  pass "fm-record: land-related fast-forwards one footer-only commit and leaves push to tick"
}

test_land_related_refuses_lock_dirty_and_advanced_head() {
  local home origin expected candidate lock pid before
  IFS=$(printf '\t') read -r home origin < <(new_home land-refuse)
  setup_record "$home" "$origin"
  seed_authored_record "$home"
  run_rec "$home" tick
  expect_code 0 "$RC" 'refuse seed tick'
  expected=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  candidate="$TMP_ROOT/land-refuse/candidate"
  commit_footer_candidate "$home/data" "$candidate"

  lock="$home/data/.git/firstmate-record.lock"
  mkdir -p "$lock"
  sleep 30 &
  pid=$!
  printf '%s\n' "$pid" > "$lock/pid"
  run_rec "$home" land-related --candidate "$candidate" --expected-head "$expected"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 3 "$RC" 'busy land-related'
  assert_contains "$OUT" 'state=busy' 'busy land-related state'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$expected" ] \
    || fail 'busy land-related moved HEAD'
  [ "$(git -C "$candidate" rev-parse HEAD)" != "$expected" ] \
    || fail 'busy land-related consumed the candidate'

  printf 'dirty\n' >> "$home/data/captain.md"
  run_rec "$home" land-related --candidate "$candidate" --expected-head "$expected"
  expect_code 8 "$RC" 'dirty land-related'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$expected" ] \
    || fail 'dirty land-related moved HEAD'
  grep -q dirty "$home/data/captain.md" || fail 'dirty land-related discarded live edits'
  git -C "$home/data" checkout --quiet -- captain.md

  printf 'later\n' > "$home/data/later.md"
  run_rec "$home" tick
  expect_code 0 "$RC" 'advanced live tick'
  before=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  run_rec "$home" land-related --candidate "$candidate" --expected-head "$expected"
  expect_code 8 "$RC" 'advanced HEAD land-related'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$before" ] \
    || fail 'advanced-HEAD land-related replaced live work'
  [ "$(git -C "$candidate" rev-parse HEAD^)" = "$expected" ] \
    || fail 'advanced-HEAD land-related rewrote the candidate'
  pass "fm-record: land-related refuses a busy lock, dirty worktree, and advanced HEAD"
}

test_land_related_scan_git_failure_and_push_pending() {
  local home origin expected candidate secret before landed
  IFS=$(printf '\t') read -r home origin < <(new_home land-scan)
  setup_record "$home" "$origin"
  seed_authored_record "$home"
  run_rec "$home" tick
  expect_code 0 "$RC" 'scan seed tick'
  secret=$(secret_fixture github-classic)
  printf '%s\n' "$secret" > "$home/data/leaky.md"
  git -C "$home/data" add leaky.md
  git -C "$home/data" commit --no-verify --quiet -m leak
  expected=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  candidate="$TMP_ROOT/land-scan/candidate"
  commit_footer_candidate "$home/data" "$candidate"
  run_rec "$home" land-related --candidate "$candidate" --expected-head "$expected"
  expect_code 5 "$RC" 'scan-blocked land-related'
  assert_contains "$OUT" 'scan-blocked' 'scan-blocked land-related state'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$expected" ] \
    || fail 'scan-blocked land-related created a live commit'
  git -C "$candidate" rev-parse --verify HEAD >/dev/null \
    || fail 'scan-blocked land-related removed the candidate'

  IFS=$(printf '\t') read -r home origin < <(new_home land-fetch)
  setup_record "$home" "$origin"
  seed_authored_record "$home"
  run_rec "$home" tick
  expect_code 0 "$RC" 'fetch-fail seed tick'
  expected=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  candidate="$TMP_ROOT/land-fetch/candidate"
  commit_footer_candidate "$home/data" "$candidate"
  rm -rf "$candidate/.git/objects"
  before=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  run_rec "$home" land-related --candidate "$candidate" --expected-head "$expected"
  expect_code 8 "$RC" 'failed fetch land-related'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$before" ] \
    || fail 'failed Git land-related moved HEAD'

  IFS=$(printf '\t') read -r home origin < <(new_home land-pending)
  setup_record "$home" "$origin"
  seed_authored_record "$home"
  run_rec "$home" tick
  expect_code 0 "$RC" 'pending seed tick'
  expected=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  candidate="$TMP_ROOT/land-pending/candidate"
  commit_footer_candidate "$home/data" "$candidate"
  run_rec "$home" land-related --candidate "$candidate" --expected-head "$expected"
  expect_code 0 "$RC" 'pending land-related'
  landed=$(git --git-dir="$home/data/.git" rev-parse HEAD)
  mv "$origin" "$origin.away"
  run_rec "$home" tick
  expect_code 6 "$RC" 'tick after land-related while remote is away'
  assert_contains "$OUT" 'push-pending' 'push-pending after land-related'
  [ "$(git --git-dir="$home/data/.git" rev-parse HEAD)" = "$landed" ] \
    || fail 'push-pending tick lost the landed commit'
  mv "$origin.away" "$origin"
  run_rec "$home" tick
  expect_code 0 "$RC" 'retry push after land-related'
  assert_contains "$OUT" 'state=pushed' 'retry after land-related should push'
  [ "$(git --git-dir="$origin" rev-parse main)" = "$landed" ] \
    || fail 'retry tick did not push the landed commit'
  pass "fm-record: land-related scan refusal, Git failure, and push-pending keep both copies"
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
test_effective_push_destinations_must_match_binding
test_lfs_uploads_require_the_bound_origin
test_redirected_hooks_refuse_setup_and_transactions
test_busy_tick_when_lock_is_held
test_abandoned_lock_is_recovered
test_unsettled_candidate_is_not_committed
test_scan_blocks_commit_and_prints_no_secret
test_mirror_state_subset_and_removal
test_special_names_and_outside_symlink_refuse
test_validation_omits_paths_and_cleans_transaction_files
test_lfs_text_threshold_and_no_oscillation
test_push_failure_keeps_local_commit
test_divergence_does_not_force
test_job_plist_has_sixty_seconds_and_no_keepalive
test_job_preflight_refuses_missing_tools_and_disposable_code
test_old_data_prefix_history_stays_an_ancestor
test_pre_commit_hook_blocks_manual_commit
test_required_checkpoint_times_out_when_lock_is_live
test_commit_and_publication_failures_refuse
test_index_lock_protects_commit_and_publication
test_inventory_failures_refuse_partial_snapshots
test_frozen_bytes_must_match_the_settled_inventory
test_cleanup_keeps_the_lock_until_candidates_are_removed
test_first_delivery_is_retried_without_new_bytes
test_push_retains_credentials_and_classifies_lfs_failure
test_manual_lfs_commit_requires_resolved_payloads
test_owned_publication_is_retried_without_new_bytes
test_restored_lfs_pointers_require_resolved_payloads
test_indexed_archive_links_keep_their_types
test_outgoing_history_and_prohibited_paths_are_scanned
test_activation_roots_permissions_and_hooks_refuse_unsafe_setup
test_scope_ignores_only_record_exclusions_and_refuses_separators
test_quiet_ticks_skip_copy_hash_and_scan_work
test_head_race_preserves_the_competing_commit
test_index_publication_restart_preserves_user_staging
test_index_recovery_locks_before_comparing_staged_content
test_index_recovery_accepts_a_status_refresh
test_health_reads_current_pending_commits_and_age
test_land_related_disabled_home_is_noop
test_land_related_lands_one_footer_commit
test_land_related_refuses_lock_dirty_and_advanced_head
test_land_related_scan_git_failure_and_push_pending

test_outer_repository_stays_clean
