#!/usr/bin/env bash
# Regression test for fm-spawn.sh's exact leased-worktree settle loop.
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the leased worktree. A naive single-read loop can
# reject or accept the wrong location before the exact `cd` settles. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    holder=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease-holder) holder=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"path":"%s","lease_id":"lease-%s","lease_holder":"%s"}\n' \
      "${FM_FAKE_PANE_PATH:?}" "$holder" "$holder"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Role: builder' "brief for $id" > "$home/data/$id/brief.md"
  printf '%s\n' builder > "$home/data/$id/role"
  printf '%s\n' no-mistakes > "$home/data/$id/mode"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# A pooled worktree carries the previous task's untracked hook pointers back
# into the pool. The fresh lease must start without that dead wiring, or the
# new task's copy keeps signalling turn-end for a task that no longer exists.
test_fresh_lease_removes_stale_hook_wiring() {
  local rec id out status stale exclude
  id=settle-stale-hooks-z3
  rec=$(make_settle_case settle-stale-hooks "$id" 0)
  read_settle_record "$rec"

  mkdir -p "$WT_DIR/.claude" "$WT_DIR/.opencode/plugins"
  # The prior task excluded its own hook pointers from git's view, exactly as
  # spawn does, so they are invisible to every dirty-worktree check.
  exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude")"
  for stale in .claude/settings.local.json .opencode/plugins/fm-turn-end.js \
    .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
    printf '%s\n' "$stale" >> "$exclude"
  done
  printf 'token=fm.deadtaskdead\n' > "$WT_DIR/.fm-grok-turnend"
  printf 'token=fm.deadtaskdead\n' > "$WT_DIR/.fm-kimi-turnend"
  printf '{"hooks":"dead task"}\n' > "$WT_DIR/.claude/settings.local.json"
  printf '// dead task turn-end\n' > "$WT_DIR/.opencode/plugins/fm-turn-end.js"
  printf '// dead task busy-state\n' > "$WT_DIR/.opencode/plugins/fm-busy-state.js"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed on a reused pool worktree"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the leased worktree"
  for stale in .fm-grok-turnend .fm-kimi-turnend .opencode/plugins/fm-turn-end.js \
    .opencode/plugins/fm-busy-state.js; do
    [ ! -e "$WT_DIR/$stale" ] \
      || fail "reused pool worktree kept the dead task's $stale wiring"
  done
  if [ -e "$WT_DIR/.claude/settings.local.json" ]; then
    assert_no_grep 'dead task' "$WT_DIR/.claude/settings.local.json" \
      "reused pool worktree kept the dead task's claude hook settings"
  fi
  pass "a fresh lease clears the previous task's hook wiring from a reused pool worktree"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_fresh_lease_removes_stale_hook_wiring

echo "# all fm-spawn-worktree-settle tests passed"
