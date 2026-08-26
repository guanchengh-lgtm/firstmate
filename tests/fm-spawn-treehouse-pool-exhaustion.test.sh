#!/usr/bin/env bash
# Regression test for fm-spawn's exhausted treehouse-pool refusal.
#
# Treehouse leaves the shell in the project checkout when every pooled
# worktree is in use or dirty.
# Spawn must relay that reason without waiting for its 60-second cwd timeout,
# and it must leave every dirty unused worktree untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-treehouse-pool-exhaustion)

make_pool_refusal_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_CALLS:?FM_FAKE_TREEHOUSE_CALLS unset}"
printf '%s\n' "all 1 worktrees are in use or dirty (max_trees = 1). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml" >&2
exit 1
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    capture_count=1
    if [ -n "${FM_FAKE_CAPTURE_COUNTFILE:-}" ]; then
      [ ! -f "$FM_FAKE_CAPTURE_COUNTFILE" ] || capture_count=$(( $(cat "$FM_FAKE_CAPTURE_COUNTFILE") + 1 ))
      printf '%s\n' "$capture_count" > "$FM_FAKE_CAPTURE_COUNTFILE"
    fi
    if [ "$capture_count" -gt "${FM_FAKE_CAPTURE_DELAY:-0}" ] \
      && [ -f "${FM_FAKE_SCREEN:?FM_FAKE_SCREEN unset}" ]; then
      fold -w 37 "$FM_FAKE_SCREEN"
    fi
    exit 0
    ;;
  display-message)
    case "$*" in
      *"#{pane_current_path}"*)
        pane_count=1
        if [ -n "${FM_FAKE_PANE_COUNTFILE:-}" ]; then
          [ ! -f "$FM_FAKE_PANE_COUNTFILE" ] || pane_count=$(( $(cat "$FM_FAKE_PANE_COUNTFILE") + 1 ))
          printf '%s\n' "$pane_count" > "$FM_FAKE_PANE_COUNTFILE"
        fi
        if [ "$pane_count" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
          printf '%s\n' "${FM_FAKE_PANE_STALE:?FM_FAKE_PANE_STALE unset}"
        else
          printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"
        fi
        ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  send-keys)
    if [ "${4:-}" = 'treehouse get' ]; then
      treehouse get > "${FM_FAKE_SCREEN:?FM_FAKE_SCREEN unset}" 2>&1 || true
    fi
    exit 0
    ;;
  list-windows|has-session|new-session|kill-window)
    exit 0
    ;;
  new-window)
    printf '@7\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_pool_refusal_is_fast_and_preserves_dirty_copy() {
  local case_dir home project dirty_copy fakebin screen calls id before out status start end elapsed
  case_dir="$TMP_ROOT/case"
  home="$case_dir/home"
  project="$case_dir/project"
  dirty_copy="$case_dir/dirty-copy"
  screen="$case_dir/screen"
  calls="$case_dir/treehouse-calls"
  id='pool-exhausted-r1'
  fakebin=$(make_pool_refusal_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf 'builder\n' > "$home/data/$id/role"
  printf 'no-mistakes\n' > "$home/data/$id/mode"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$dirty_copy" dirty-copy
  printf 'unlanded work must survive\n' > "$dirty_copy/unlanded.txt"
  before=$(git -C "$dirty_copy" rev-parse HEAD)

  start=$(date +%s)
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$project" \
      FM_FAKE_SCREEN="$screen" FM_FAKE_TREEHOUSE_CALLS="$calls" \
      PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -ne 0 ] || fail "spawn succeeded despite an exhausted treehouse pool"
  [ "$elapsed" -le 5 ] || fail "pool refusal took ${elapsed}s instead of failing fast"
  assert_contains "$out" "all 1 worktrees are in use or dirty (max_trees = 1)" \
    "spawn did not relay treehouse's pool refusal"
  assert_no_grep 'did not enter a worktree within 60s' <(printf '%s\n' "$out") \
    "spawn fell through to the generic cwd timeout"
  assert_grep 'get' "$calls" "spawn did not drive treehouse get"
  [ "$(git -C "$dirty_copy" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the dirty unused worktree's HEAD"
  assert_grep 'unlanded work must survive' "$dirty_copy/unlanded.txt" \
    "spawn discarded work from the dirty unused worktree"
  pass "an exhausted treehouse pool fails fast and preserves dirty unused work"
}

test_delayed_refusal_wins_over_stable_stale_path() {
  local case_dir home project dirty_copy fakebin screen calls capture_count pane_count id before out status
  case_dir="$TMP_ROOT/delayed-case"
  home="$case_dir/home"
  project="$case_dir/project"
  dirty_copy="$case_dir/dirty-copy"
  screen="$case_dir/screen"
  calls="$case_dir/treehouse-calls"
  capture_count="$case_dir/capture-count"
  pane_count="$case_dir/pane-count"
  id='pool-delayed-refusal-r2'
  fakebin=$(make_pool_refusal_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf 'builder\n' > "$home/data/$id/role"
  printf 'no-mistakes\n' > "$home/data/$id/mode"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$dirty_copy" dirty-copy
  printf 'delayed refusal must not expose this work\n' > "$dirty_copy/unlanded.txt"
  before=$(git -C "$dirty_copy" rev-parse HEAD)

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$project" \
      FM_FAKE_PANE_STALE="$dirty_copy" FM_FAKE_PANE_STALE_READS=2 \
      FM_FAKE_PANE_COUNTFILE="$pane_count" FM_FAKE_CAPTURE_DELAY=2 \
      FM_FAKE_CAPTURE_COUNTFILE="$capture_count" FM_FAKE_SCREEN="$screen" \
      FM_FAKE_TREEHOUSE_CALLS="$calls" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a stale path despite a delayed pool refusal"
  assert_contains "$out" "all 1 worktrees are in use or dirty (max_trees = 1)" \
    "a stable stale path won before the delayed treehouse refusal"
  assert_no_grep 'is not clean' <(printf '%s\n' "$out") \
    "spawn inspected the unrelated dirty copy before honoring treehouse's refusal"
  [ "$(git -C "$dirty_copy" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the stale dirty worktree's HEAD"
  assert_grep 'delayed refusal must not expose this work' "$dirty_copy/unlanded.txt" \
    "spawn discarded work after a delayed treehouse refusal"
  pass "a delayed pool refusal wins before two stale cwd reads can select another copy"
}

test_pool_refusal_is_fast_and_preserves_dirty_copy
test_delayed_refusal_wins_over_stable_stale_path

echo "# all fm-spawn-treehouse-pool-exhaustion tests passed"
