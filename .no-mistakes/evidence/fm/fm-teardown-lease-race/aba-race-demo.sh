#!/usr/bin/env bash
# End-to-end manual demonstration of the task-worktree ABA race fix.
# Drives the REAL bin/fm-teardown.sh CLI against a real git worktree with a
# lease-enforcing fake `treehouse`, exactly as an operator would experience it.
set -u
ROOT=${1:?firstmate root}
WORK=${2:?scratch dir}
TEARDOWN="$ROOT/bin/fm-teardown.sh"

new_case() { # <name>
  local c="$WORK/$1"
  mkdir -p "$c/state" "$c/config" "$c/data/task-x1" "$c/fakebin"
  printf '%s\n' 'miss:' 'number:' 'pair:' 'pick:' 'none: demo fixture' > "$c/data/task-x1/measure.md"
  touch "$c/state/.last-watcher-beat"
  cat > "$c/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
  cat > "$c/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cp "$c/fakebin/gh-axi" "$c/fakebin/gh"
  cat > "$c/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # Lease-enforcing treehouse: only the CURRENT lease id may be returned.
  cat > "$c/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# Faithful stand-in for Treehouse's conditional release: a return that carries
# NO --if-lease-id has no condition to check, so it succeeds and performs the
# destructive release (hard reset of the worktree + reap of its processes).
# A return that carries a lease id succeeds only when that id is the CURRENT
# holder; otherwise it refuses and touches nothing.
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
release() {
  rm -f "${FM_TASK_B_FILE:-/nonexistent}"
  [ -s "${FM_TASK_B_PIDFILE:-/nonexistent}" ] && kill "$(cat "$FM_TASK_B_PIDFILE")" 2>/dev/null
  echo "released worktree (hard reset + process reap)"
  exit 0
}
case " $* " in
  *" --if-lease-id "*) ;;
  *) release ;;
esac
case " $* " in
  *" --if-lease-id ${FM_CURRENT_LEASE_ID:?} "*) release ;;
esac
echo 'treehouse: lease precondition failed: recorded lease is not the current holder of this worktree' >&2
exit 23
SH
  chmod +x "$c"/fakebin/*
  git init -q --bare "$c/origin.git"
  git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c/origin.git" "$c/_seed" 2>/dev/null
  git -C "$c/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$c/_seed" push -q origin main
  rm -rf "$c/_seed"
  git clone -q "$c/origin.git" "$c/project"
  git -C "$c/project" remote set-head origin main 2>/dev/null || true
  git -C "$c/project" worktree add -q -b fm/task-x1 "$c/wt" main
  printf '%s\n' "$c"
}

write_meta() { # <case> <lease-id> <state>
  local c=$1
  { printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$c/wt" "project=$c/project" "kind=ship" "mode=local-only"
    [ "$2" = none ] || printf '%s\n' "treehouse_lease_id=$2" "treehouse_lease_holder=task-x1" "treehouse_lease_state=$3"
  } > "$c/state/task-x1.meta"
}

run_td() { # <case> <current-lease-id>
  local c=$1 cur=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$c/data" FM_STATE_OVERRIDE="$c/state" \
  FM_CONFIG_OVERRIDE="$c/config" FM_GATE_REFUSE_BYPASS=1 FM_FAKE_TREEHOUSE_LOG="$c/treehouse.log" \
  FM_FAKE_TMUX_LOG="$c/tmux.log" FM_CURRENT_LEASE_ID="$cur" \
  FM_TASK_B_FILE="$c/wt/task-b-file.txt" FM_TASK_B_PIDFILE="$c/task-b.pid" \
  PATH="$c/fakebin:$PATH" "$TEARDOWN" task-x1 "$@"
}

hr() { printf '\n================================================================\n%s\n================================================================\n' "$1"; }

########################################################################
hr "SCENARIO 1 - the incident interleaving
Task A recorded lease-A on pool worktree P. A was partially torn down.
Task B has since re-leased the SAME path P as lease-B and is running there.
Operator now reruns teardown for task A."
C=$(new_case incident); : > "$C/treehouse.log"; : > "$C/tmux.log"
write_meta "$C" lease-A held
printf 'task B working file\n' > "$C/wt/task-b-file.txt"
( cd "$C/wt" && exec sleep 120 ) & B_PID=$!
echo "$B_PID" > "$C/task-b.pid"
echo "--- before: task B pid $B_PID is alive, task B file present, worktree = $C/wt"
echo "\$ fm-teardown.sh task-x1 --force"
run_td "$C" lease-B --force; RC=$?
echo "--- exit status: $RC"
echo "--- treehouse commands actually issued:"; cat "$C/treehouse.log"
echo "--- task B file still present: $([ -f "$C/wt/task-b-file.txt" ] && echo YES || echo NO)"
echo "--- task B process still alive: $(kill -0 $B_PID 2>/dev/null && echo YES || echo NO)"
echo "--- task B endpoint untouched (no tmux calls): $([ -s "$C/tmux.log" ] && echo NO || echo YES)"
echo "--- task A metadata preserved: $([ -f "$C/state/task-x1.meta" ] && echo YES || echo NO)"
kill $B_PID 2>/dev/null; wait $B_PID 2>/dev/null

########################################################################
hr "SCENARIO 2 - legacy path-only metadata (pre-upgrade live task)
Task metadata carries no lease id, as every task spawned before this change."
C=$(new_case legacy); : > "$C/treehouse.log"; : > "$C/tmux.log"
write_meta "$C" none -
echo "\$ fm-teardown.sh task-x1 --force"
run_td "$C" lease-anything --force; RC=$?
echo "--- exit status: $RC"
echo "--- treehouse commands issued: $(wc -l < "$C/treehouse.log" | tr -d ' ') (an unconditional path-only return would be 1)"
echo "--- task metadata preserved: $([ -f "$C/state/task-x1.meta" ] && echo YES || echo NO)"

########################################################################
hr "SCENARIO 3 - happy path, then crash-window rerun
Teardown owns the current lease. It returns conditionally, marks the record
released, and a rerun must never issue a second return."
C=$(new_case happy); : > "$C/treehouse.log"; : > "$C/tmux.log"
write_meta "$C" lease-A held
echo "\$ fm-teardown.sh task-x1 --force"
run_td "$C" lease-A --force; RC=$?
echo "--- exit status: $RC"
echo "--- treehouse commands issued:"; cat "$C/treehouse.log"
echo "--- task record removed: $([ -f "$C/state/task-x1.meta" ] && echo NO || echo YES)"

hr "SCENARIO 3b - released rerun after a crash between return and cleanup
Same task, state=released, and task B has since taken the path."
C=$(new_case released-rerun); : > "$C/treehouse.log"; : > "$C/tmux.log"
write_meta "$C" lease-A released
printf 'task B working file\n' > "$C/wt/task-b-file.txt"
( cd "$C/wt" && exec sleep 120 ) & B_PID=$!
echo "$B_PID" > "$C/task-b.pid"
echo "\$ fm-teardown.sh task-x1 --force"
run_td "$C" lease-B --force; RC=$?
echo "--- exit status: $RC"
echo "--- treehouse commands issued: $(wc -l < "$C/treehouse.log" | tr -d ' ') (must be 0 - the lease is already gone)"
echo "--- task B file still present: $([ -f "$C/wt/task-b-file.txt" ] && echo YES || echo NO)"
echo "--- task B process still alive: $(kill -0 $B_PID 2>/dev/null && echo YES || echo NO)"
echo "--- task A record cleaned up: $([ -f "$C/state/task-x1.meta" ] && echo NO || echo YES)"
kill $B_PID 2>/dev/null; wait $B_PID 2>/dev/null
echo
