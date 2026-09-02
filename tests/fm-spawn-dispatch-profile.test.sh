#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
endpoint_state=
[ -z "${FM_FAKE_ENDPOINT_STATE:-}" ] || endpoint_state=$(cat "$FM_FAKE_ENDPOINT_STATE" 2>/dev/null || true)
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*)
    [ "$endpoint_state" != missing ] || exit 1
    printf '%s\n' '%1'
    exit 0
    ;;
  *"#{pane_tty}"*) exit 1 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PRIOR_COMMAND:-${FM_FAKE_OV_COMMAND:-firstmate}}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ "$endpoint_state" = unreadable ]; then
      printf '%s\n' 'temporary inventory failure' >&2
      exit 1
    fi
    if [ -n "$endpoint_state" ] && [ "$endpoint_state" != missing ]; then
      printf '%s\n' "${FM_FAKE_ENDPOINT_LABEL:-}"
    elif [ -z "$endpoint_state" ] && [ -n "${FM_FAKE_OV_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_OV_WINDOW"
    fi
    exit 0
    ;;
  new-window)
    [ -z "${FM_FAKE_ENDPOINT_STATE:-}" ] || printf '%s\n' new > "$FM_FAKE_ENDPOINT_STATE"
    printf '%s\n' '%1'
    exit 0
    ;;
  kill-window)
    [ -z "${FM_FAKE_ENDPOINT_STATE:-}" ] \
      || printf '%s\n' "${FM_FAKE_TMUX_KILL_STATE:-missing}" > "$FM_FAKE_ENDPOINT_STATE"
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      saw_l=0
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
          saw_l=1
        fi
        prev=$a
      done
      if [ "$saw_l" -eq 0 ]; then
        for a in "$@"; do
          case "$a" in
            -t|Enter|C-*) ;;
            -*) ;;
            export\ *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG.exports" ;;
          esac
        done
      fi
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_HERDR_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
endpoint_state=
[ -z "${FM_FAKE_ENDPOINT_STATE:-}" ] || endpoint_state=$(cat "$FM_FAKE_ENDPOINT_STATE" 2>/dev/null || true)
stale_state=
[ -z "${FM_FAKE_HERDR_STALE_STATE:-}" ] || stale_state=$(cat "$FM_FAKE_HERDR_STALE_STATE" 2>/dev/null || true)
case "$*" in
  *"status --json"*) printf '%s\n' '{"server":{"running":true}}'; exit 0 ;;
  *"session list --json"*)
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fm-test-herdr.sock"}]}'
    exit 0
    ;;
  *"workspace list"*)
    if [ -n "$stale_state" ] && [ "$stale_state" != missing ]; then
      printf '%s\n' "{\"result\":{\"workspaces\":[{\"workspace_id\":\"w9\",\"label\":\"stale · p:${FM_FAKE_HERDR_TOKEN:-}\"}]}}"
    else
      printf '%s\n' '{"result":{"workspaces":[]}}'
    fi
    exit 0
    ;;
  *"pane list --workspace w9"*)
    if [ -n "$stale_state" ] && [ "$stale_state" != missing ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w9:p9","tab_id":"w9:t9"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[]}}'
    fi
    exit 0
    ;;
  *"tab list"*) printf '%s\n' '{"result":{"tabs":[]}}'; exit 0 ;;
  *"agent get"*) printf '%s\n' '{"error":{"code":"agent_not_found"}}'; exit 1 ;;
  *"pane close w9:p9"*)
    [ -z "${FM_FAKE_HERDR_STALE_STATE:-}" ] || printf '%s\n' missing > "$FM_FAKE_HERDR_STALE_STATE"
    printf '%s\n' '{"result":{}}'
    exit 0
    ;;
  *"pane close"*)
    [ -z "${FM_FAKE_ENDPOINT_STATE:-}" ] || printf '%s\n' missing > "$FM_FAKE_ENDPOINT_STATE"
    printf '%s\n' '{"result":{}}'
    exit 0
    ;;
  *"pane get"*)
    if [ "${3:-}" = w9:p9 ]; then
      if [ "$stale_state" = missing ]; then
        printf '%s\n' '{"error":{"code":"pane_not_found"}}'
        exit 1
      fi
      printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p9","tab_id":"w9:t9","workspace_id":"w9"}}}'
      exit 0
    fi
    if [ "$endpoint_state" = missing ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w2:p2","tab_id":"w2:t2","workspace_id":"w2"}}}'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_ORCA_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_ORCA_LOG"
case "$*" in
  "status --json")
    printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh-axi
  fm_fake_exit0 "$fakebin" no-mistakes
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_mv_failure_stub() {
  local fakebin=$1
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_path=
target_path=
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *)
      [ -n "$source_path" ] || source_path=$arg
      target_path=$arg
      ;;
  esac
done
case "$source_path" in
  *.meta.handoff.*|*.meta.spawn.*)
    if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ] \
       && [ "$target_path" = "$FM_FAKE_META_PUBLISH_MV_FAIL" ]; then
      exit 1
    fi
    ;;
esac
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
}

make_spawn_git_failure_stub() {
  local fakebin=$1
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = -C ] \
   && [ "${2:-}" = "${FM_FAKE_GIT_WORKTREE:-}" ] \
   && [ "${3:-}" = worktree ] \
   && [ "${4:-}" = list ] \
   && [ "${5:-}" = --porcelain ]; then
  exit 1
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf '%s\n' 'Role: builder' "brief for $id" > "$home/data/$id/brief.md"
    printf '%s\n' builder > "$home/data/$id/role"
    printf '%s\n' no-mistakes > "$home/data/$id/mode"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 endpoint_state endpoint_label tmuxlog prior_command
  shift 4
  endpoint_state="$home/state/.fake-endpoint-state"
  endpoint_label=$(cat "$home/state/.fake-endpoint-label" 2>/dev/null || true)
  tmuxlog="$home/state/.fake-tmux.log"
  prior_command=${FM_TEST_PRIOR_COMMAND:-}
  [ -z "$prior_command" ] && [ -n "$endpoint_label" ] && prior_command=zsh
  : > "$launchlog"
  : > "$launchlog.exports"
  : > "$tmuxlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_ENDPOINT_STATE="$endpoint_state" FM_FAKE_ENDPOINT_LABEL="$endpoint_label" \
    FM_FAKE_PRIOR_COMMAND="$prior_command" FM_FAKE_TMUX_LOG="$tmuxlog" \
    FM_FAKE_TMUX_KILL_STATE="${FM_TEST_TMUX_KILL_STATE:-}" \
    FM_FAKE_HERDR_LOG="${FM_FAKE_HERDR_LOG:-}" \
    FM_FAKE_HERDR_STALE_STATE="${FM_FAKE_HERDR_STALE_STATE:-}" \
    FM_FAKE_HERDR_TOKEN="${FM_FAKE_HERDR_TOKEN:-}" \
    HERDR_SESSION="${FM_TEST_HERDR_SESSION:-}" \
    FM_FAKE_ORCA_LOG="${FM_FAKE_ORCA_LOG:-}" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    FM_FAKE_OV_WINDOW="${FM_TEST_OV_WINDOW:-}" FM_FAKE_OV_COMMAND="${FM_TEST_OV_COMMAND:-}" \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_WORKTREE="${FM_FAKE_GIT_WORKTREE:-}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

prepare_verifier_handoff() {  # <home> <project> <worktree> <id>
  local home=$1 project=$2 worktree=$3 id=$4
  git -C "$worktree" branch -m "fm/$id"
  printf 'builder result\n' > "$worktree/builder-result.txt"
  git -C "$worktree" add builder-result.txt
  git -C "$worktree" -c user.name=test -c user.email=test@example.com \
    commit -q -m "test: seed builder result"
  printf '%s\n' 'Role: verifier' 'Delivery contract: mode=no-mistakes' '# Task' 'keep the original task' \
    > "$home/data/$id/verifier-brief.md"
  printf '%s\n' verifier > "$home/data/$id/verifier-role"
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$worktree"
    echo "project=$project"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "role=builder"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' old > "$home/state/.fake-endpoint-state"
  printf '%s\n' "fm-$id" > "$home/state/.fake-endpoint-label"
}

replace_meta_value() {  # <meta> <key> <value>
  local meta=$1 key=$2 value=$3 tmp line
  tmp="$meta.next"
  : > "$tmp"
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s=%s\n' "$key" "$value" >> "$tmp" ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$meta"
  mv "$tmp" "$meta"
}

assert_verifier_handoff_refusal_preserved() {  # <out> <status> <expected> <meta-before> <endpoint-before> <id>
  local out=$1 status=$2 expected=$3 meta_before=$4 endpoint_before=$5 id=$6
  local meta_after endpoint_after tmuxlog
  [ "$status" -ne 0 ] || fail "verifier handoff accepted $expected"
  assert_contains "$out" "$expected" "verifier handoff refusal did not report $expected"
  meta_after=$(cat "$HOME_DIR/state/$id.meta")
  [ "$meta_after" = "$meta_before" ] || fail "verifier handoff refusal mutated builder metadata for $expected"
  endpoint_after=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  [ "$endpoint_after" = "$endpoint_before" ] || fail "verifier handoff refusal mutated prior endpoint for $expected"
  [ ! -s "$LAUNCH_LOG" ] || fail "verifier handoff refusal launched an endpoint for $expected"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  assert_no_grep 'new-window ' "$tmuxlog" "verifier handoff refusal created an endpoint for $expected"
  assert_no_grep 'kill-window ' "$tmuxlog" "verifier handoff refusal retired the builder endpoint for $expected"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off --role builder
}

test_ship_spawn_refuses_missing_role_and_invalid_direct_pr_surface() {
  local rec id out status
  id=profile-role-surface-neg-z0
  rec=$(make_spawn_case profile-role-surface-neg claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn without --role should exit non-zero"
  assert_contains "$out" "ship spawns require --role" "missing --role did not refuse closed"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing --role published a launch command"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "missing --role published task metadata"

  : > "$LAUNCH_LOG"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode direct-PR --yolo off --role builder)
  status=$?
  [ "$status" -ne 0 ] || fail "direct-PR spawn without --surface should exit non-zero"
  assert_contains "$out" "requires --surface internal-only" "omitted surface did not fail closed"
  [ ! -s "$LAUNCH_LOG" ] || fail "omitted surface published a launch command"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "omitted surface published task metadata"

  : > "$LAUNCH_LOG"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode direct-PR --yolo off --role builder --surface product)
  status=$?
  [ "$status" -ne 0 ] || fail "product + direct-PR spawn should exit non-zero"
  assert_contains "$out" "refused for product work" "product + direct-PR did not name the refused surface"
  [ ! -s "$LAUNCH_LOG" ] || fail "product + direct-PR published a launch command"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "product + direct-PR published task metadata"
  pass "ship spawn refuses a missing --role and an invalid direct-PR surface"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default
  assert_grep 'role=builder' "$HOME_DIR/state/$id.meta" "builder spawn did not record role=builder"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id=profile-claude-cursor-markers-z1b
  rec=$(make_spawn_case profile-claude-cursor-markers claude "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn under Cursor markers should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=profile-unresolvable-paths-z1d
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_requires_explicit_model_for_ship() {
  local rec id out status
  id=profile-required-model-z21
  rec=$(make_spawn_case profile-required-model claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --effort high)
  status=$?
  expect_code 1 "$status" "ship spawn without --model should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit model resolved from the dispatch rules" \
    "spawn did not explain the missing-model dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "model refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit model for ship spawns"
}

test_active_dispatch_profile_requires_explicit_effort_for_ship() {
  local rec id out status
  id=profile-required-effort-z22
  rec=$(make_spawn_case profile-required-effort claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --model sonnet)
  status=$?
  expect_code 1 "$status" "ship spawn without --effort should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit effort resolved from the dispatch rules" \
    "spawn did not explain the missing-effort dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "effort refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit effort for ship spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model default --effort default "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  assert_not_contains "$launch" "--tui-mode" "non-Pi launches must not receive Pi's TUI mode override"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_threads_xhigh_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with xhigh reasoning effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'xhigh'" \
    "grok launch did not thread xhigh as --reasoning-effort"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --reasoning-effort xhigh"
}

test_cursor_threads_model_workspace_and_omits_effort_axis() {
  local rec id out status launch
  id=profile-cursor-z6c
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with a model-qualified reasoning class should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--trust --yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "cursor launch did not carry trust, autonomy, model, and exact workspace flags"
  # The executable is RESOLVED, never named: `cursor` is not the CLI, so a
  # literal `cursor agent` command cannot run on a machine that has only the
  # real installed names.
  assert_not_contains "$launch" "cursor agent --trust" \
    "cursor launch must resolve its executable, not invoke a literal 'cursor agent'"
  assert_contains "$launch" "cursor-agent" "cursor launch did not resolve a cursor executable"
  # -w/--worktree would allocate a SECOND worktree under ~/.cursor/worktrees and
  # break the isolation contract the spawn assertion depends on.
  assert_not_contains "$launch" " --worktree" "cursor launch must never allocate a second worktree"
  assert_not_contains "$launch" " -w " "cursor launch must never allocate a second worktree"
  # An inherited CLAUDECODE would otherwise outrank cursor's own marker.
  assert_contains "$launch" "env -u CLAUDECODE" "cursor launch must clear foreign primary markers"
  assert_contains "$launch" "encode launch-brief" "cursor launch did not deliver the brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
  pass "cursor receives its model-qualified reasoning class and exact task workspace"
}

test_cursor_refuses_model_absent_from_live_catalog() {
  local rec id out status
  id=profile-cursor-unsupported-z6d
  rec=$(make_spawn_case profile-cursor-unsupported cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a model absent from a successful catalog"
  assert_contains "$out" "Cursor model 'cursor-grok-4.5' is not available" \
    "cursor model refusal did not identify the unavailable model"
  assert_contains "$out" "--list-models" \
    "cursor model refusal did not tell the caller how to find valid ids"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor model refusal must happen before launch"
  pass "cursor refuses model ids absent from its resolved binary's live catalog"
}

test_cursor_failed_catalog_probe_does_not_block_spawn() {
  local rec id out status launch
  id=profile-cursor-catalog-unreachable-z6e
  rec=$(make_spawn_case profile-cursor-catalog-unreachable cursor "$id")
  read_case_record "$rec"

  FM_TEST_CURSOR_LIST_STATUS=124 \
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-catalog-unreachable)
  status=$?
  expect_code 0 "$status" "cursor spawn should fail open when the bounded catalog query fails"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-catalog-unreachable'" \
    "failed catalog lookup incorrectly removed the requested model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-catalog-unreachable default
  pass "cursor preserves the requested model when its live catalog is unreachable"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi FM_PI_CALM_WORKER=1 '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=profile-pi-signed-z8b
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed FM_PI_CALM_WORKER=1 '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_worker_marks_calm_inert_without_disabling_discovery() {
  local harness id launch out rec status
  for harness in pi pi-signed; do
    id="profile-${harness}-calm-worker-z8c"
    rec=$(make_spawn_case "profile-${harness}-calm-worker" "$harness" "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness worker spawn should succeed"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "FM_PI_CALM_WORKER=1 '$FAKEBIN_DIR/$harness'" \
      "$harness worker launch did not make Calm process-scoped and inert"
    assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" \
      "$harness worker launch lost its explicit task extension"
    assert_not_contains "$launch" "--no-extensions" \
      "$harness worker launch disabled extension discovery"
    assert_not_contains "$launch" "--no-approve" \
      "$harness worker launch disabled project resources"
    assert_not_contains "$launch" "PI_CODING_AGENT_DIR=" \
      "$harness worker launch replaced Pi's user directory"
    if [ -f "$LAUNCH_LOG.exports" ]; then
      assert_not_contains "$(cat "$LAUNCH_LOG.exports")" "FM_PI_CALM_WORKER=" \
        "$harness worker marker escaped into the parent shell"
    fi
  done
  pass "Pi workers scope Calm off while keeping discovery and the generated task extension"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=profile-pi-signed-missing-z8c
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --role builder 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=profile-pi-signed-secondmate-z8d
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  assert_not_contains "$launch" "FM_PI_CALM_WORKER=" \
    "pi-signed secondmate launch incorrectly disabled primary-session Calm"
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_spawn_records_map_and_refuses_live_fog() {
  local rec id out status meta map
  id=profile-map-fog-z14
  rec=$(make_spawn_case profile-map-fog claude "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/data/prog" "$HOME_DIR/data/decisions"
  printf 'lock\n' > "$HOME_DIR/data/decisions/lock.md"
  map="$HOME_DIR/data/prog/map.md"
  cat > "$map" <<'EOF'
# Map

## Not yet specified

- Whether this is still open.
EOF

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --map data/prog/map.md)
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn accepted a map with live fog"
  assert_contains "$out" 'live unspecified items' \
    "fog refusal did not name live unspecified items"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "live-fog spawn wrote task metadata"

  cat > "$map" <<'EOF'
# Map

## Destination

Done without a fog section.
EOF
  rec=$(make_spawn_case profile-map-fog-struct claude "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/data/prog"
  cat > "$HOME_DIR/data/prog/map.md" <<'EOF'
# Map

## Destination

Done without a fog section.
EOF
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --map data/prog/map.md)
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn accepted a map missing Not yet specified"
  assert_contains "$out" 'failed map structure checks' \
    "structural map failure was mislabeled as live fog"
  case "$out" in
    *'live unspecified items'*)
      fail "structural map failure still used the live-fog primary message"
      ;;
  esac
  assert_absent "$HOME_DIR/state/$id.meta" \
    "structural-fog spawn wrote task metadata"

  cat > "$map" <<'EOF'
# Map

## Not yet specified

- [parked 2026-08-21] Overnight loops.
- [closed data/decisions/lock.md] Exact names.
EOF
  rec=$(make_spawn_case profile-map-fog-clean claude "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/data/prog" "$HOME_DIR/data/decisions"
  printf 'lock\n' > "$HOME_DIR/data/decisions/lock.md"
  cat > "$HOME_DIR/data/prog/map.md" <<'EOF'
# Map

## Not yet specified

- [parked 2026-08-21] Overnight loops.
- [closed data/decisions/lock.md] Exact names.
EOF
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --map data/prog/map.md)
  status=$?
  expect_code 0 "$status" "ship spawn with parked/closed fog should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'map=data/prog/map.md' "$meta" \
    "spawn did not record map= in task metadata"
  pass "fm-spawn: --map refuses live and structural fog and records a clean map"
}

test_spawn_records_map_next_and_rejects_invalid_ids() {
  local rec id out status meta bad_id
  id=profile-map-next-z11
  rec=$(make_spawn_case profile-map-next claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --map-next slice-three)
  status=$?
  expect_code 0 "$status" "spawn with --map-next should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'map_next=slice-three' "$meta" \
    "spawn did not record the locked next slice in task metadata"

  bad_id=profile-map-next-bad-z12
  rec=$(make_spawn_case profile-map-next-bad claude "$bad_id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$bad_id" "$PROJ_DIR" --map-next 'bad/id')
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an invalid --map-next task id"
  assert_contains "$out" 'invalid --map-next task id' \
    "invalid --map-next refusal did not explain the bad id"
  assert_absent "$HOME_DIR/state/$bad_id.meta" \
    "invalid --map-next spawn wrote task metadata"
  pass "fm-spawn: --map-next records a valid id and refuses unsafe ids"
}

test_spawn_refuses_filled_ship_without_ov() {
  local rec id out status brief meta
  id=profile-ship-no-ov-z21
  rec=$(make_spawn_case profile-ship-no-ov claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  printf '# Task\nStart Spec compile-check. The next act is obvious.\n\n# Setup\nfixture\nDelivery contract: mode=no-mistakes\n' > "$brief"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a filled ship with no OV worker"
  assert_contains "$out" 'no separate OV worker' \
    "missing OV refusal did not name the OV requirement"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "missing OV refusal wrote task metadata"

  id=profile-ship-ov-z22
  rec=$(make_spawn_case profile-ship-ov claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  printf '# Task\nStart Spec compile-check. The next act is obvious.\n\n# Setup\nfixture\nDelivery contract: mode=no-mistakes\n' > "$brief"
  printf '%s\n' 'kind=scout' 'harness=claude' > "$HOME_DIR/state/spec-compile-check-ov.meta"
  mkdir -p "$HOME_DIR/data/spec-compile-check-ov"
  printf 'OV complete\n' > "$HOME_DIR/data/spec-compile-check-ov/report.md"
  printf 'plan-eng-review\n' > "$HOME_DIR/data/spec-compile-check-ov/skills"
  printf '7777\n' > "$HOME_DIR/state/.lock"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov spec-compile-check-ov)
  status=$?
  expect_code 0 "$status" "spawn with a distinct spawned OV worker should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'ov=spec-compile-check-ov' "$meta" \
    "spawn did not record ov= for the distinct OV worker"
  assert_grep 'ov_harness=claude' "$meta" \
    "spawn did not record ov_harness= from the OV worker harness"
  assert_grep 'session=7777' "$meta" \
    "spawn did not record session= from state/.lock"
  [ ! -e "$HOME_DIR/data/$id/skills" ] \
    || fail "spawn must not pre-create an empty skills file"
  assert_grep "export FM_TASK_ID='$id'" "$LAUNCH_LOG.exports" \
    "spawn did not export FM_TASK_ID into the worker pane"
  assert_grep 'export FM_HOME=' "$LAUNCH_LOG.exports" \
    "spawn did not export FM_HOME into the worker pane"

  id=profile-ship-ov-unloaded-z25
  rec=$(make_spawn_case profile-ship-ov-unloaded claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  printf '# Task\nStart Spec compile-check. The next act is obvious.\n\n# Setup\nfixture\nDelivery contract: mode=no-mistakes\n' > "$brief"
  printf '%s\n' 'kind=scout' 'harness=claude' > "$HOME_DIR/state/spec-compile-check-ov.meta"
  mkdir -p "$HOME_DIR/data/spec-compile-check-ov"
  printf 'OV complete\n' > "$HOME_DIR/data/spec-compile-check-ov/report.md"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov spec-compile-check-ov)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a Claude OV without plan-eng-review"
  assert_contains "$out" 'R-skill-unloaded-plan-eng-review' \
    "spawn refusal did not name the exact unloaded skill rule"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "unloaded skill refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unloaded skill refusal still launched an endpoint"

  id=profile-ship-ov-live-no-report-z29
  rec=$(make_spawn_case profile-ship-ov-live-no-report claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  printf '# Task\nStart Spec compile-check. The next act is obvious.\n\n# Setup\nfixture\nDelivery contract: mode=no-mistakes\n' > "$brief"
  printf '%s\n' 'kind=scout' 'harness=claude' 'window=firstmate:fm-ov-live' \
    > "$HOME_DIR/state/spec-compile-check-ov.meta"
  out=$(FM_TEST_OV_WINDOW=fm-ov-live FM_TEST_OV_COMMAND=claude \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov spec-compile-check-ov)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a live OV without a report"
  assert_contains "$out" 'R-ov-missing-report' \
    "live OV refusal did not name the missing report rule"
  assert_contains "$out" 'report is required before ship spawn' \
    "live OV refusal did not explain OV-first sequencing"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "live OV missing report refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "live OV missing report refusal still launched an endpoint"

  id=profile-ship-ov-torn-down-z26
  rec=$(make_spawn_case profile-ship-ov-torn-down claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  printf '# Task\nStart Spec compile-check. The next act is obvious.\n\n# Setup\nfixture\nDelivery contract: mode=no-mistakes\n' > "$brief"
  mkdir -p "$HOME_DIR/data/spec-compile-check-ov"
  printf 'OV complete\n' > "$HOME_DIR/data/spec-compile-check-ov/report.md"
  printf 'plan-eng-review\n' > "$HOME_DIR/data/spec-compile-check-ov/skills"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov spec-compile-check-ov)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a torn-down OV worker"
  assert_contains "$out" 'no separate OV worker' \
    "torn-down OV refusal did not preserve the worker requirement"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "torn-down OV refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "torn-down OV refusal still launched an endpoint"

  id=profile-ship-ov-codex-z24
  rec=$(make_spawn_case profile-ship-ov-codex claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  printf '# Task\nStart Spec compile-check. The next act is obvious.\n\n# Setup\nfixture\nDelivery contract: mode=no-mistakes\n' > "$brief"
  printf '%s\n' 'kind=scout' 'harness=codex' > "$HOME_DIR/state/spec-compile-check-ov.meta"
  mkdir -p "$HOME_DIR/data/spec-compile-check-ov"
  printf 'OV complete\n' > "$HOME_DIR/data/spec-compile-check-ov/report.md"
  printf '8888\n' > "$HOME_DIR/state/.lock"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov spec-compile-check-ov)
  status=$?
  expect_code 0 "$status" "spawn with a codex OV worker should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'ov_harness=codex' "$meta" \
    "spawn did not record non-Claude ov_harness= from the OV worker"

  id=profile-ship-self-ov-z23
  rec=$(make_spawn_case profile-ship-self-ov claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted --ov naming the ship itself"
  assert_contains "$out" 'builder self-review is not OV' \
    "self OV refusal did not reject builder self-review"
  pass "fm-spawn: filled ships require a distinct spawned OV worker"
}

test_spawn_refuses_fake_worker_slash_before_endpoint() {
  local rec id out status brief
  id=profile-fake-slash-z13
  rec=$(make_spawn_case profile-fake-slash claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  printf '# Task\nInvoke /harness-adapters before coding.\n\n# Setup\nfixture\n' > "$brief"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a worker brief with a lane-3 slash"
  assert_contains "$out" '/harness-adapters' \
    "spawn refusal did not name the forbidden worker slash"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "fake-slash refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "fake-slash refusal still typed an endpoint launch"
  pass "fm-spawn: fake worker slash refuses before endpoint creation"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch
  id=profile-claude-cfgdir-z17
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_claude_omits_config_dir_prefix_when_unset() {
  local rec id out status launch
  id=profile-claude-nocfgdir-z18
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"

  # run_spawn pins CLAUDE_CONFIG_DIR empty by default, exercising the single-store
  # default path where fm-spawn adds no prefix.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "claude launch must not add a config-dir prefix when firstmate has no CLAUDE_CONFIG_DIR set"
  pass "claude omits the config-dir prefix when firstmate runs with the single-store default"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id=profile-codex-nocfgdir-z19
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_role_verifier_encodes_verifier_brief() {
  local rec id out status launch expected meta head_before head_after branch tmuxlog gen
  id=profile-role-verifier-z14
  rec=$(make_spawn_case profile-role-verifier claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  printf '%s\n' 'surface=product' 'map_next=profile-next-task-z46' 'x_request=request-46' \
    >> "$HOME_DIR/state/$id.meta"
  printf 'product\n' > "$HOME_DIR/data/$id/surface"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "--role verifier spawn should succeed when verifier-brief.md exists"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'role=verifier' "$meta" "verifier spawn did not record role=verifier"
  assert_grep 'kind=ship' "$meta" "verifier spawn lost kind=ship"
  assert_grep 'surface=product' "$meta" "verifier spawn lost the builder surface"
  assert_grep 'map_next=profile-next-task-z46' "$meta" \
    "verifier spawn lost the task successor"
  assert_grep 'x_request=request-46' "$meta" \
    "verifier spawn lost the external request link"
  assert_contains "$out" "role=verifier" "spawned line did not report role=verifier"
  assert_grep "worktree=$WT_DIR" "$meta" "verifier spawn did not retain builder worktree"
  assert_present "$HOME_DIR/state/$id.busy-gen" \
    "verifier handoff EXIT trap retired the replacement busy generation"
  assert_present "$WT_DIR/.claude/settings.local.json" \
    "verifier handoff EXIT trap stripped replacement harness wiring"
  gen=$(sed -n 's/^busy_gen=//p' "$meta")
  [ -n "$gen" ] || fail "verifier metadata missing replacement busy_gen"
  [ "$(cat "$HOME_DIR/state/$id.busy-gen")" = "$gen" ] \
    || fail "verifier busy-gen file does not match published meta"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "verifier spawn changed builder HEAD"
  branch=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  [ "$branch" = "fm/$id" ] || fail "verifier spawn changed builder task branch"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  assert_no_grep 'treehouse get' "$tmuxlog" "verifier spawn acquired a second treehouse worktree"
  [ "$(grep -c '^new-window ' "$tmuxlog" || true)" -eq 1 ] \
    || fail "verifier spawn did not create exactly one fresh endpoint"

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/verifier-brief.md')\""
  [ "$launch" = "$expected" ] || fail "verifier spawn did not encode verifier-brief.md"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "fm-spawn: --role verifier encodes verifier-brief.md and records role=verifier"
}

test_verifier_handoff_preserves_yolo_authority() {
  local rec id out status meta_before endpoint_before
  id=profile-verifier-yolo-authority-z59
  rec=$(make_spawn_case profile-verifier-yolo-authority claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo on --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: requested yolo posture 'on' does not match builder yolo posture 'off'" \
    "$meta_before" "$endpoint_before" "$id"
  pass "fm-spawn: verifier handoff preserves builder yolo authority"
}

test_verifier_handoff_refuses_surface_synthesis() {
  local rec id out status meta_before endpoint_before
  id=profile-verifier-surface-authority-z60
  rec=$(make_spawn_case profile-verifier-surface-authority claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  printf 'product\n' > "$HOME_DIR/data/$id/surface"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier --surface product)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: requested surface 'product' but builder metadata records no surface" \
    "$meta_before" "$endpoint_before" "$id"
  pass "fm-spawn: verifier handoff cannot synthesize missing builder surface metadata"
}

test_verifier_handoff_retires_builder_wiring() {
  local rec id out status old_token old_auth new_token new_auth pointer exclude
  id=profile-verifier-wiring-z47
  rec=$(make_spawn_case profile-verifier-wiring grok "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  replace_meta_value "$HOME_DIR/state/$id.meta" harness grok
  old_token=fm.111111111111
  mkdir -p "$HOME_DIR/grok-home/hooks/fm-turn-end.d"
  printf '%s\n' "$old_token" > "$HOME_DIR/state/$id.grok-turnend-token"
  old_auth="$HOME_DIR/grok-home/hooks/fm-turn-end.d/$old_token"
  printf '%s\n' "$HOME_DIR/state/$id.turn-ended" > "$old_auth"
  printf 'token=%s\n' "$old_token" > "$WT_DIR/.fm-grok-turnend"
  exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  printf '%s\n' '.fm-grok-turnend' >> "$exclude"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "verifier handoff from a grok builder should succeed"
  assert_absent "$old_auth" "verifier handoff left the builder authorization file"
  new_token=$(cat "$HOME_DIR/state/$id.grok-turnend-token")
  [ "$new_token" != "$old_token" ] || fail "verifier handoff reused the builder wiring token"
  new_auth="$HOME_DIR/grok-home/hooks/fm-turn-end.d/$new_token"
  assert_present "$new_auth" "verifier handoff did not arm fresh verifier wiring"
  pointer=$(sed -n 's/^token=//p' "$WT_DIR/.fm-grok-turnend")
  [ "$pointer" = "$new_token" ] || fail "verifier handoff pointer does not name verifier wiring"
  pass "fm-spawn: verifier handoff retires builder wiring before replacement"
}

test_verifier_handoff_retires_builder_busy_generation() {
  local rec id out status gen verdict
  id=profile-verifier-busy-generation-z56
  rec=$(make_spawn_case profile-verifier-busy-generation grok "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$id") \
    || fail "could not arm builder busy generation"
  printf 'busy_gen=%s\n' "$gen" >> "$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "verifier handoff to Grok should retire the builder busy generation"
  assert_absent "$HOME_DIR/state/$id.busy-gen" \
    "verifier handoff retained the builder busy generation"
  assert_absent "$HOME_DIR/state/$id.busy-state" \
    "verifier handoff retained the builder busy record"
  assert_no_grep '^busy_gen=' "$HOME_DIR/state/$id.meta" \
    "verifier metadata retained the builder busy generation"
  verdict=$(bash -c '
    . "$0/bin/fm-busy-lib.sh"
    fm_busy_classify tmux firstmate:fm-test grok "$1" "$2" ""
  ' "$ROOT" "$id" "$HOME_DIR/state")
  [ "$verdict" != "unknown source-mismatch" ] \
    || fail "verifier handoff exposed the builder busy source to Grok"
  pass "fm-spawn: verifier handoff retires builder busy generation"
}

test_verifier_handoff_refuses_dirty_builder_worktrees() {
  local rec id out status meta_before endpoint_before status_before status_after
  local head_before head_after branch_before branch_after file_before file_after

  id=profile-verifier-staged-z29
  rec=$(make_spawn_case profile-verifier-staged claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  printf 'staged change\n' >> "$WT_DIR/builder-result.txt"
  git -C "$WT_DIR" add builder-result.txt
  status_before=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_before=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  file_before=$(cat "$WT_DIR/builder-result.txt")
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$WT_DIR' has uncommitted changes" \
    "$meta_before" "$endpoint_before" "$id"
  status_after=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  [ "$status_after" = "$status_before" ] || fail "staged verifier refusal changed builder worktree state"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_after=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  file_after=$(cat "$WT_DIR/builder-result.txt")
  [ "$head_after" = "$head_before" ] || fail "staged verifier refusal changed builder HEAD"
  [ "$branch_after" = "$branch_before" ] || fail "staged verifier refusal changed branch attachment"
  [ "$file_after" = "$file_before" ] || fail "staged verifier refusal changed builder file content"

  id=profile-verifier-unstaged-z30
  rec=$(make_spawn_case profile-verifier-unstaged claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  printf 'unstaged change\n' >> "$WT_DIR/builder-result.txt"
  status_before=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_before=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  file_before=$(cat "$WT_DIR/builder-result.txt")
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$WT_DIR' has uncommitted changes" \
    "$meta_before" "$endpoint_before" "$id"
  status_after=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  [ "$status_after" = "$status_before" ] || fail "unstaged verifier refusal changed builder worktree state"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_after=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  file_after=$(cat "$WT_DIR/builder-result.txt")
  [ "$head_after" = "$head_before" ] || fail "unstaged verifier refusal changed builder HEAD"
  [ "$branch_after" = "$branch_before" ] || fail "unstaged verifier refusal changed branch attachment"
  [ "$file_after" = "$file_before" ] || fail "unstaged verifier refusal changed builder file content"

  id=profile-verifier-untracked-z31
  rec=$(make_spawn_case profile-verifier-untracked claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  printf 'untracked change\n' > "$WT_DIR/untracked-builder-file.txt"
  status_before=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_before=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  file_before=$(cat "$WT_DIR/untracked-builder-file.txt")
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$WT_DIR' has untracked files" \
    "$meta_before" "$endpoint_before" "$id"
  status_after=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  [ "$status_after" = "$status_before" ] || fail "untracked verifier refusal changed builder worktree state"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_after=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  file_after=$(cat "$WT_DIR/untracked-builder-file.txt")
  [ "$head_after" = "$head_before" ] || fail "untracked verifier refusal changed builder HEAD"
  [ "$branch_after" = "$branch_before" ] || fail "untracked verifier refusal changed branch attachment"
  [ "$file_after" = "$file_before" ] || fail "untracked verifier refusal changed untracked file content"
  pass "fm-spawn: verifier handoff preserves staged, unstaged, and untracked builder work"
}

test_verifier_handoff_refuses_rebase_and_preserves_stash() {
  local rec id out status meta_before endpoint_before rebase_dir porcelain
  local stash_before stash_after head_before head_after branch_before branch_after

  id=profile-verifier-rebase-z32
  rec=$(make_spawn_case profile-verifier-rebase claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  rebase_dir=$(git -C "$WT_DIR" rev-parse --git-path rebase-merge)
  mkdir -p "$rebase_dir"
  porcelain=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  [ -z "$porcelain" ] || fail "rebase fixture did not keep porcelain clean"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_before=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$WT_DIR' has an in-progress rebase" \
    "$meta_before" "$endpoint_before" "$id"
  [ -d "$rebase_dir" ] || fail "verifier handoff refusal removed builder rebase state"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_after=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  [ "$head_after" = "$head_before" ] || fail "rebase-merge refusal changed builder HEAD"
  [ "$branch_after" = "$branch_before" ] || fail "rebase-merge refusal changed branch attachment"

  id=profile-verifier-rebase-apply-z58
  rec=$(make_spawn_case profile-verifier-rebase-apply claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  rebase_dir=$(git -C "$WT_DIR" rev-parse --git-path rebase-apply)
  mkdir -p "$rebase_dir"
  porcelain=$(git -C "$WT_DIR" status --porcelain --untracked-files=all)
  [ -z "$porcelain" ] || fail "rebase-apply fixture did not keep porcelain clean"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_before=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$WT_DIR' has an in-progress rebase" \
    "$meta_before" "$endpoint_before" "$id"
  [ -d "$rebase_dir" ] || fail "verifier handoff refusal removed builder rebase-apply state"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  branch_after=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD)
  [ "$head_after" = "$head_before" ] || fail "rebase-apply refusal changed builder HEAD"
  [ "$branch_after" = "$branch_before" ] || fail "rebase-apply refusal changed branch attachment"

  id=profile-verifier-stash-z33
  rec=$(make_spawn_case profile-verifier-stash claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  printf 'stashed change\n' >> "$WT_DIR/builder-result.txt"
  git -C "$WT_DIR" stash push -q -m verifier-handoff-fixture
  stash_before=$(git -C "$WT_DIR" rev-parse --verify refs/stash)
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "verifier handoff with an existing stash should succeed"
  stash_after=$(git -C "$WT_DIR" rev-parse --verify refs/stash)
  [ "$stash_after" = "$stash_before" ] || fail "verifier handoff changed builder stash object"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "verifier handoff with stash changed builder HEAD"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "verifier handoff with stash did not retain builder worktree"
  pass "fm-spawn: verifier handoff refuses rebase state and preserves existing stash"
}

test_verifier_handoff_accepts_detached_builder_head() {
  local rec id out status head_before head_after branch meta_before endpoint_before owner_worktree
  id=profile-verifier-detached-z34
  rec=$(make_spawn_case profile-verifier-detached claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  git -C "$WT_DIR" checkout -q --detach "$head_before"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "verifier handoff from detached builder HEAD should succeed"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "detached verifier handoff changed exact builder HEAD"
  branch=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -z "$branch" ] || fail "verifier handoff attached detached builder HEAD before verifier checkout"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "detached verifier handoff did not retain builder worktree"

  id=profile-verifier-detached-owned-z44
  rec=$(make_spawn_case profile-verifier-detached-owned claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  git -C "$WT_DIR" checkout -q --detach "$head_before"
  owner_worktree="$CASE_DIR/task-branch-owner"
  git -C "$PROJ_DIR" worktree add -q "$owner_worktree" "fm/$id"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: task branch 'fm/$id' is checked out in worktree" \
    "$meta_before" "$endpoint_before" "$id"
  assert_contains "$out" "$(basename "$owner_worktree")" \
    "detached verifier refusal did not name branch-owning worktree"
  pass "fm-spawn: verifier handoff reuses detached builder HEAD exactly"
}

test_verifier_handoff_refuses_unreadable_worktree_ownership() {
  local rec id out status meta_before endpoint_before real_git head_before branch
  id=profile-verifier-worktree-list-failure-z55
  rec=$(make_spawn_case profile-verifier-worktree-list-failure claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)
  git -C "$WT_DIR" checkout -q --detach "$head_before"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  real_git=$(command -v git)
  make_spawn_git_failure_stub "$FAKEBIN_DIR"

  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_WORKTREE="$WT_DIR" run_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$WT_DIR' has unreadable worktree ownership" \
    "$meta_before" "$endpoint_before" "$id"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$head_before" ] \
    || fail "worktree ownership refusal changed detached builder HEAD"
  branch=$(git -C "$WT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -z "$branch" ] || fail "worktree ownership refusal attached the builder branch"
  pass "fm-spawn: verifier handoff refuses unreadable worktree ownership"
}

test_verifier_handoff_adoption_failure_retires_new_endpoint() {
  local rec id out status meta_before tmuxlog
  id=profile-verifier-adoption-failure-z45
  rec=$(make_spawn_case profile-verifier-adoption-failure claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")

  out=$(run_spawn "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "verifier handoff accepted an endpoint outside builder worktree"
  assert_contains "$out" "not builder worktree '$WT_DIR'" \
    "verifier handoff adoption failure did not name builder worktree"
  [ "$(cat "$HOME_DIR/state/$id.meta")" = "$meta_before" ] \
    || fail "verifier handoff adoption failure mutated builder metadata"
  [ "$(cat "$HOME_DIR/state/.fake-endpoint-state")" = missing ] \
    || fail "verifier handoff adoption failure left new endpoint alive"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  [ "$(grep -c '^new-window ' "$tmuxlog" || true)" -eq 1 ] \
    || fail "verifier handoff adoption failure did not create one endpoint"
  [ "$(grep -c '^kill-window ' "$tmuxlog" || true)" -eq 2 ] \
    || fail "verifier handoff adoption failure did not retire old and new endpoints"
  pass "fm-spawn: verifier handoff adoption failure retires its new endpoint"
}

test_verifier_handoff_requires_confirmed_endpoint_retirement() {
  local rec id out status meta meta_before tmuxlog
  id=profile-verifier-retirement-proof-z53
  rec=$(make_spawn_case profile-verifier-retirement-proof claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  meta_before=$(cat "$meta")

  out=$(FM_TEST_TMUX_KILL_STATE=unreadable run_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "verifier handoff accepted unreadable post-retirement state"
  assert_contains "$out" \
    "error: verifier handoff refused: stopped builder endpoint reads 'unreadable' after retirement, not missing" \
    "verifier handoff did not require confirmed endpoint retirement"
  [ "$(cat "$meta")" = "$meta_before" ] \
    || fail "unconfirmed endpoint retirement mutated builder metadata"
  [ "$(cat "$HOME_DIR/state/.fake-endpoint-state")" = unreadable ] \
    || fail "unconfirmed endpoint retirement did not preserve its observed state"
  [ ! -s "$LAUNCH_LOG" ] || fail "unconfirmed endpoint retirement launched the verifier"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  [ "$(grep -c '^kill-window ' "$tmuxlog" || true)" -eq 1 ] \
    || fail "unconfirmed endpoint retirement did not make exactly one close attempt"
  assert_no_grep '^new-window ' "$tmuxlog" \
    "unconfirmed endpoint retirement created a replacement endpoint"
  pass "fm-spawn: verifier handoff requires confirmed endpoint retirement"
}

test_verifier_handoff_prepublication_failure_retires_replacement_state() {
  local rec id out status meta meta_before real_mv tmuxlog
  id=profile-verifier-prepublish-failure-z48
  rec=$(make_spawn_case profile-verifier-prepublish-failure claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  meta_before=$(cat "$meta")
  real_mv=$(command -v mv)
  make_spawn_mv_failure_stub "$FAKEBIN_DIR"

  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "verifier handoff accepted failed metadata publication"
  [ "$(cat "$meta")" = "$meta_before" ] \
    || fail "verifier handoff publication failure changed builder metadata"
  [ "$(cat "$HOME_DIR/state/.fake-endpoint-state")" = missing ] \
    || fail "verifier handoff publication failure left the replacement endpoint"
  assert_absent "$HOME_DIR/state/$id.busy-gen" \
    "verifier handoff publication failure left the replacement busy generation"
  assert_absent "$HOME_DIR/state/$id.busy-state" \
    "verifier handoff publication failure left the seeded busy state"
  assert_absent "$WT_DIR/.claude/settings.local.json" \
    "verifier handoff publication failure left replacement harness wiring"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  [ "$(grep -c '^kill-window ' "$tmuxlog" || true)" -eq 2 ] \
    || fail "verifier handoff publication failure did not retire both endpoints"
  pass "fm-spawn: verifier handoff publication failure retires replacement state"
}

test_fresh_prepublication_failure_retires_endpoint() {
  local rec id out status meta real_mv tmuxlog treehouse_log
  id=profile-fresh-prepublish-failure-z48b
  rec=$(make_spawn_case profile-fresh-prepublish-failure claude "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  real_mv=$(command -v mv)
  make_spawn_mv_failure_stub "$FAKEBIN_DIR"
  treehouse_log="$HOME_DIR/state/.fake-treehouse.log"
  : > "$treehouse_log"

  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "fresh spawn accepted failed metadata publication"
  assert_absent "$meta" "fresh publication failure wrote task metadata"
  [ "$(cat "$HOME_DIR/state/.fake-endpoint-state")" = missing ] \
    || fail "fresh publication failure left an unowned endpoint"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  [ "$(grep -c '^kill-window ' "$tmuxlog" || true)" -eq 1 ] \
    || fail "fresh publication failure did not retire its endpoint"
  assert_grep "return --force $WT_DIR" "$treehouse_log" \
    "fresh publication failure did not return its local copy"
  assert_contains "$out" "task record for $id could not be published" \
    "fresh publication failure lacked its record diagnostic"
  pass "fm-spawn: fresh publication failure retires unowned resources"
}

test_verifier_handoff_teardown_returns_single_worktree() {
  local rec id out status treehouse_log tmuxlog return_count
  id=profile-verifier-teardown-z43
  rec=$(make_spawn_case profile-verifier-teardown claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "verifier handoff should succeed before teardown integration"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  assert_no_grep 'treehouse get' "$tmuxlog" \
    "verifier handoff teardown fixture acquired a second worktree"

  git -C "$WT_DIR" push -q origin "fm/$id"
  git -C "$PROJ_DIR" fetch -q origin
  treehouse_log="$HOME_DIR/state/.fake-treehouse.log"
  : > "$treehouse_log"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_ENDPOINT_STATE="$HOME_DIR/state/.fake-endpoint-state" \
    FM_FAKE_ENDPOINT_LABEL="fm-$id" FM_FAKE_PRIOR_COMMAND=zsh \
    FM_FAKE_TMUX_LOG="$tmuxlog" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "landed verifier handoff teardown should succeed (got: $out)"
  return_count=$(grep -Fxc "return --force $WT_DIR" "$treehouse_log" || true)
  [ "$return_count" -eq 1 ] \
    || fail "verifier handoff teardown did not return exactly one recorded worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "verifier handoff teardown left task metadata"
  [ "$(cat "$HOME_DIR/state/.fake-endpoint-state")" = missing ] \
    || fail "verifier handoff teardown left a task endpoint"
  pass "fm-spawn: verifier handoff teardown returns one worktree and one endpoint"
}

test_verifier_handoff_refuses_live_or_unverified_endpoint() {
  local rec id out status meta_before endpoint_before meta

  id=profile-verifier-live-z35
  rec=$(make_spawn_case profile-verifier-live claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(FM_TEST_PRIOR_COMMAND=claude run_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder endpoint reads 'alive', not positively stopped" \
    "$meta_before" "$endpoint_before" "$id"

  id=profile-verifier-unverified-z36
  rec=$(make_spawn_case profile-verifier-unverified claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  replace_meta_value "$meta" window session:1
  {
    printf '%s\n' 'backend=zellij' 'zellij_session=session' 'zellij_tab_id=1' 'zellij_pane_id=1'
  } >> "$meta"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder endpoint backend 'zellij' cannot prove the prior agent stopped" \
    "$meta_before" "$endpoint_before" "$id"
  pass "fm-spawn: verifier handoff refuses live and unverified builder endpoints"
}

test_verifier_handoff_allows_backend_change() {
  local rec id out status meta herdrlog tmuxlog
  id=profile-verifier-backend-change-z50
  rec=$(make_spawn_case profile-verifier-backend-change claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  replace_meta_value "$meta" window fmtest:w2:p2
  {
    printf '%s\n' 'backend=herdr' 'herdr_session=fmtest' 'herdr_workspace_id=w2' \
      'herdr_tab_id=w2:t2' 'herdr_pane_id=w2:p2'
  } >> "$meta"
  herdrlog="$HOME_DIR/state/.fake-herdr.log"; : > "$herdrlog"

  out=$(FM_FAKE_HERDR_LOG="$herdrlog" run_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend tmux --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "verifier handoff should allow a resolved backend change"
  assert_no_grep '^backend=herdr$' "$meta" \
    "verifier handoff retained the builder backend"
  assert_grep "window=firstmate:fm-$id" "$meta" \
    "verifier handoff did not record the resolved tmux endpoint"
  assert_grep 'pane close w2:p2' "$herdrlog" \
    "verifier handoff did not retire the stopped builder through its backend"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  [ "$(grep -c '^new-window ' "$tmuxlog" || true)" -eq 1 ] \
    || fail "verifier handoff backend change did not create one fresh endpoint"
  assert_grep "worktree=$WT_DIR" "$meta" \
    "verifier handoff backend change did not retain the builder worktree"
  pass "fm-spawn: verifier handoff follows resolved backend selection"
}

test_verifier_handoff_refuses_unbound_herdr_quarantine() {
  local rec id out status meta_before endpoint_before journal token stale_state herdrlog
  id=profile-verifier-unbound-herdr-z54
  rec=$(make_spawn_case profile-verifier-unbound-herdr claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  token=$(FM_HOME="$HOME_DIR" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_create "$1" "$2"
  ' "$ROOT" "$HOME_DIR/state" "$id") || fail "could not create unbound Herdr journal"
  journal="$HOME_DIR/state/$id.herdr-presentation"
  stale_state="$HOME_DIR/state/.fake-herdr-stale-state"
  printf '%s\n' no-agent > "$stale_state"
  herdrlog="$HOME_DIR/state/.fake-herdr.log"; : > "$herdrlog"

  out=$(FM_FAKE_HERDR_LOG="$herdrlog" \
    FM_FAKE_HERDR_STALE_STATE="$stale_state" FM_FAKE_HERDR_TOKEN="$token" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: version 1 Herdr presentation journal has no exact builder binding" \
    "$meta_before" "$endpoint_before" "$id"
  [ -f "$journal" ] || fail "unbound Herdr refusal removed the journal"
  [ "$(cat "$stale_state")" = no-agent ] \
    || fail "unbound Herdr refusal changed the stale pane"
  assert_no_grep 'pane close' "$herdrlog" \
    "unbound Herdr refusal closed a token-correlated pane"
  pass "fm-spawn: verifier handoff refuses an unbound Herdr quarantine"
}

test_verifier_handoff_retires_bound_herdr_quarantine_for_tmux() {
  local rec id out status meta journal token stale_state herdrlog home_real label tmuxlog
  id=profile-verifier-bound-herdr-z57
  rec=$(make_spawn_case profile-verifier-bound-herdr claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  token=$(FM_HOME="$HOME_DIR" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_create "$1" "$2"
  ' "$ROOT" "$HOME_DIR/state" "$id") || fail "could not create bound Herdr journal"
  journal="$HOME_DIR/state/$id.herdr-presentation"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  label=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_workspace_label "$1" "$2"
  ' "$ROOT" "$id" "$token") || fail "could not create Herdr projection label"
  FM_HOME="$HOME_DIR" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_journal_bind \
      "$1" "$2" "$3" fmtest w9 w9:t9 w9:p9 w1 firstmate "$4" "fm-$2"
  ' "$ROOT" "$journal" "$id" "$home_real" "$label" \
    || fail "could not bind the Herdr quarantine"
  stale_state="$HOME_DIR/state/.fake-herdr-stale-state"
  printf '%s\n' no-agent > "$stale_state"
  herdrlog="$HOME_DIR/state/.fake-herdr.log"; : > "$herdrlog"

  out=$(FM_FAKE_HERDR_LOG="$herdrlog" \
    FM_FAKE_HERDR_STALE_STATE="$stale_state" FM_FAKE_HERDR_TOKEN="$token" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --mode no-mistakes --yolo off --role verifier)
  status=$?
  expect_code 0 "$status" "tmux verifier should retire an exact Herdr quarantine"
  [ ! -e "$journal" ] && [ ! -L "$journal" ] \
    || fail "tmux verifier retained the bound Herdr journal"
  [ "$(cat "$stale_state")" = missing ] \
    || fail "tmux verifier retained the bound Herdr pane"
  assert_grep 'pane close w9:p9' "$herdrlog" \
    "tmux verifier did not retire the exact Herdr pane"
  tmuxlog="$HOME_DIR/state/.fake-tmux.log"
  [ "$(grep -c '^new-window ' "$tmuxlog" || true)" -eq 1 ] \
    || fail "tmux verifier did not create one fresh endpoint"
  assert_grep 'role=verifier' "$meta" \
    "tmux verifier did not publish verifier metadata"
  assert_grep "worktree=$WT_DIR" "$meta" \
    "tmux verifier did not retain the builder worktree"
  pass "fm-spawn: tmux verifier retires an exact Herdr quarantine"
}

test_verifier_handoff_refuses_orca_worktree_ownership() {
  local rec id out status meta meta_before endpoint_before orcalog
  id=profile-verifier-to-orca-z51
  rec=$(make_spawn_case profile-verifier-to-orca claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  orcalog="$HOME_DIR/state/.fake-orca.log"; : > "$orcalog"
  out=$(FM_FAKE_ORCA_LOG="$orcalog" run_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend orca --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: Orca owns a separate worktree and cannot reuse builder worktree '$WT_DIR'" \
    "$meta_before" "$endpoint_before" "$id"
  assert_no_grep 'worktree create' "$orcalog" \
    "verifier handoff allocated an Orca worktree"

  id=profile-verifier-from-orca-z52
  rec=$(make_spawn_case profile-verifier-from-orca claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  replace_meta_value "$meta" window "fm-$id"
  {
    printf '%s\n' 'backend=orca' 'terminal=term-builder' 'orca_worktree_id=wt-builder'
  } >> "$meta"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  orcalog="$HOME_DIR/state/.fake-orca.log"; : > "$orcalog"
  out=$(FM_FAKE_ORCA_LOG="$orcalog" run_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend tmux --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: Orca owns a separate worktree and cannot reuse builder worktree '$WT_DIR'" \
    "$meta_before" "$endpoint_before" "$id"
  [ ! -s "$orcalog" ] || fail "verifier handoff mutated the recorded Orca owner"
  pass "fm-spawn: verifier handoff refuses Orca worktree ownership changes"
}

test_verifier_handoff_refuses_lifecycle_lock_contention() {
  local rec id out status meta_before endpoint_before lock holder i=0
  id=profile-verifier-lifecycle-lock-z49
  rec=$(make_spawn_case profile-verifier-lifecycle-lock claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta_before=$(cat "$HOME_DIR/state/$id.meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  lock="$HOME_DIR/state/.control-$id.lock"
  bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; sleep 30' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$lock" &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage verifier lifecycle lock"; }
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: another lifecycle action is already running for task $id" \
    "$meta_before" "$endpoint_before" "$id"
  pass "fm-spawn: verifier handoff participates in lifecycle serialization"
}

test_verifier_handoff_refuses_invalid_builder_worktrees() {
  local rec id out status meta meta_before endpoint_before bad_path other_project other_worktree

  id=profile-verifier-missing-wt-z37
  rec=$(make_spawn_case profile-verifier-missing-wt claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  bad_path="$CASE_DIR/missing-builder-worktree"
  replace_meta_value "$meta" worktree "$bad_path"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" "$bad_path" \
    "$meta_before" "$endpoint_before" "$id"

  id=profile-verifier-nongit-wt-z38
  rec=$(make_spawn_case profile-verifier-nongit-wt claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  bad_path="$CASE_DIR/non-git-builder-worktree"
  mkdir -p "$bad_path"
  replace_meta_value "$meta" worktree "$bad_path"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" "$bad_path" \
    "$meta_before" "$endpoint_before" "$id"

  id=profile-verifier-nonroot-wt-z39
  rec=$(make_spawn_case profile-verifier-nonroot-wt claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  bad_path="$WT_DIR/nested"
  mkdir -p "$bad_path"
  replace_meta_value "$meta" worktree "$bad_path"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" "$bad_path" \
    "$meta_before" "$endpoint_before" "$id"

  id=profile-verifier-primary-wt-z40
  rec=$(make_spawn_case profile-verifier-primary-wt claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  meta="$HOME_DIR/state/$id.meta"
  replace_meta_value "$meta" worktree "$PROJ_DIR"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" "$PROJ_DIR" \
    "$meta_before" "$endpoint_before" "$id"

  id=profile-verifier-wrong-project-z41
  rec=$(make_spawn_case profile-verifier-wrong-project claude "$id")
  read_case_record "$rec"
  other_project="$CASE_DIR/other-project"
  other_worktree="$CASE_DIR/other-worktree"
  fm_git_worktree "$other_project" "$other_worktree" other-builder
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$other_worktree" "$id"
  meta="$HOME_DIR/state/$id.meta"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$other_worktree' belongs to another project" \
    "$meta_before" "$endpoint_before" "$id"

  id=profile-verifier-wrong-branch-z42
  rec=$(make_spawn_case profile-verifier-wrong-branch claude "$id")
  read_case_record "$rec"
  prepare_verifier_handoff "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$id"
  git -C "$WT_DIR" branch -m unexpected-builder-branch
  meta="$HOME_DIR/state/$id.meta"
  meta_before=$(cat "$meta")
  endpoint_before=$(cat "$HOME_DIR/state/.fake-endpoint-state")
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  assert_verifier_handoff_refusal_preserved "$out" "$status" \
    "error: verifier handoff refused: builder worktree '$WT_DIR' is on 'unexpected-builder-branch', expected 'fm/$id' or detached" \
    "$meta_before" "$endpoint_before" "$id"
  pass "fm-spawn: verifier handoff refuses invalid builder worktree records"
}

test_role_verifier_enforces_explicit_ov() {
  local rec id out status
  id=profile-role-verifier-missing-ov-z27
  rec=$(make_spawn_case profile-role-verifier-missing-ov claude "$id")
  read_case_record "$rec"
  printf '%s\n' 'Role: verifier' 'Delivery contract: mode=no-mistakes' '# Task' 'verify the task' \
    > "$HOME_DIR/data/$id/verifier-brief.md"
  printf '%s\n' verifier > "$HOME_DIR/data/$id/verifier-role"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov spec-compile-check-ov \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "verifier spawn accepted a missing OV worker"
  assert_contains "$out" 'no separate OV worker' \
    "verifier OV refusal did not preserve the worker requirement"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "verifier missing OV refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "verifier missing OV refusal still launched an endpoint"

  id=profile-role-verifier-unloaded-ov-z28
  rec=$(make_spawn_case profile-role-verifier-unloaded-ov claude "$id")
  read_case_record "$rec"
  printf '%s\n' 'Role: verifier' 'Delivery contract: mode=no-mistakes' '# Task' 'verify the task' \
    > "$HOME_DIR/data/$id/verifier-brief.md"
  printf '%s\n' verifier > "$HOME_DIR/data/$id/verifier-role"
  printf '%s\n' 'kind=scout' 'harness=claude' > "$HOME_DIR/state/spec-compile-check-ov.meta"
  mkdir -p "$HOME_DIR/data/spec-compile-check-ov"
  printf 'OV complete\n' > "$HOME_DIR/data/spec-compile-check-ov/report.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --ov spec-compile-check-ov \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "verifier spawn accepted a Claude OV without plan-eng-review"
  assert_contains "$out" 'R-skill-unloaded-plan-eng-review' \
    "verifier spawn did not apply the brief skill rule"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "verifier unloaded skill refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "verifier unloaded skill refusal still launched an endpoint"
  pass "fm-spawn: verifier ships enforce explicit OV worker and skill rules"
}

test_ship_spawn_refuses_missing_role_and_invalid_direct_pr_surface
test_no_profile_keeps_claude_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_requires_explicit_model_for_ship
test_active_dispatch_profile_requires_explicit_effort_for_ship
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_threads_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_worker_marks_calm_inert_without_disabling_discovery
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_spawn_records_map_next_and_rejects_invalid_ids
test_spawn_refuses_filled_ship_without_ov
test_spawn_records_map_and_refuses_live_fog
test_spawn_refuses_fake_worker_slash_before_endpoint
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch
test_role_verifier_encodes_verifier_brief
test_verifier_handoff_preserves_yolo_authority
test_verifier_handoff_refuses_surface_synthesis
test_verifier_handoff_retires_builder_wiring
test_verifier_handoff_retires_builder_busy_generation
test_verifier_handoff_refuses_dirty_builder_worktrees
test_verifier_handoff_refuses_rebase_and_preserves_stash
test_verifier_handoff_accepts_detached_builder_head
test_verifier_handoff_refuses_unreadable_worktree_ownership
test_verifier_handoff_adoption_failure_retires_new_endpoint
test_verifier_handoff_requires_confirmed_endpoint_retirement
test_verifier_handoff_prepublication_failure_retires_replacement_state
test_fresh_prepublication_failure_retires_endpoint
test_verifier_handoff_teardown_returns_single_worktree
test_verifier_handoff_refuses_live_or_unverified_endpoint
test_verifier_handoff_allows_backend_change
test_verifier_handoff_refuses_unbound_herdr_quarantine
test_verifier_handoff_retires_bound_herdr_quarantine_for_tmux
test_verifier_handoff_refuses_orca_worktree_ownership
test_verifier_handoff_refuses_lifecycle_lock_contention
test_verifier_handoff_refuses_invalid_builder_worktrees
test_role_verifier_enforces_explicit_ov

echo "# all fm-spawn-dispatch-profile tests passed"
