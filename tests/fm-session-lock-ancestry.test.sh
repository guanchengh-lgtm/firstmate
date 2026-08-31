#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# A developer commonly runs this suite from Claude. Never let the runner's
# session identity leak into a case; cases that need it set explicit fakes.
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_CODE_CHILD_SESSION

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"
ln -s /bin/bash "$FAKEBIN/codex"
NAMED_CODEX="$FAKEBIN/codex"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

make_lock_identity_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  install_autoarm_scripts "$dir"
  cat > "$dir/contender.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=${FM_CONTENDER_SESSION_ID:?}
# The vendor sets CLAUDE_PID to each hook's own direct Claude client. A hook
# fired by the surviving in-place-replaced client sees the HOLDER pid; a
# nested background job always sees its own.
if [ "${FM_CONTENDER_CLAUDE_PID:-self}" = holder ]; then
  export CLAUDE_PID=${FM_HOLDER_PID:?}
else
  export CLAUDE_PID=$$
fi
export CLAUDE_CODE_CHILD_SESSION=1
rc=0
if [ -n "${FM_CONTENDER_FLAG:-}" ]; then
  "$FM_HOME/bin/fm-lock.sh" "$FM_CONTENDER_FLAG" > "$FM_HOME/state/contender.out" 2>&1 || rc=$?
else
  "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/contender.out" 2>&1 || rc=$?
fi
printf '%s\n' "$rc" > "$FM_HOME/state/contender.rc"
printf '%s\n' "$$" > "$FM_HOME/state/contender-pid"
SH
  cat > "$dir/holder.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=${FM_HOLDER_SESSION_ID:?}
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' "$$" > "$FM_HOME/state/holder-pid"
if [ "${FM_OLD_LOCK:-0}" = 1 ]; then
  printf '%s\n' "$$" > "$FM_HOME/state/.lock"
  rm -f "$FM_HOME/state/.lock.session"
else
  "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/holder.out" 2>&1 || exit $?
fi
FM_CONTENDER_SESSION_ID=${FM_CONTENDER_SESSION_ID:?} FM_HOLDER_PID=$$ \
  "$FM_CONTENDER_BIN" "$FM_HOME/contender.sh"
SH
  chmod +x "$dir/contender.sh" "$dir/holder.sh"
}

run_lock_pair() {  # <dir> <holder-session> <contender-session> [old-lock] [contender-flag] [contender-claude-pid]
  local dir=$1 holder_session=$2 contender_session=$3 old_lock=${4:-0} contender_flag=${5:-}
  local contender_claude_pid=${6:-self}
  FM_HOME="$dir" FM_HOLDER_SESSION_ID="$holder_session" \
    FM_CONTENDER_SESSION_ID="$contender_session" FM_CONTENDER_BIN="$NAMED_CLAUDE" \
    FM_CONTENDER_FLAG="$contender_flag" FM_CONTENDER_CLAUDE_PID="$contender_claude_pid" \
    FM_OLD_LOCK="$old_lock" "$NAMED_CLAUDE" "$dir/holder.sh"
}

# Run one lock acquisition in its own Claude-named process whose ancestry stops
# at this suite, with <setup> executed inside that process first. The state the
# setup writes is therefore recorded by a live pid the acquisition can see in
# its own ancestry, which is exactly the same-process shape /clear leaves.
OWN_ANCESTRY_RC=0
run_own_ancestry_lock() {  # <dir> <session-id> <setup> [lock-args...]
  local dir=$1 session_id=$2 setup=$3
  shift 3
  OWN_ANCESTRY_RC=0
  FM_HOME="$dir" FM_FIXTURE_SESSION_ID="$session_id" FM_FIXTURE_SETUP="$setup" \
    "$NAMED_CLAUDE" -c '
      export CLAUDE_CODE_SESSION_ID=${FM_FIXTURE_SESSION_ID:?}
      export CLAUDE_PID=$$
      export CLAUDE_CODE_CHILD_SESSION=1
      printf "%s\n" "$$" > "$FM_HOME/state/current-pid"
      eval "$FM_FIXTURE_SETUP"
      "$FM_HOME/bin/fm-lock.sh" "$@" > "$FM_HOME/state/current.out" 2>&1
    ' _ "$@" || OWN_ANCESTRY_RC=$?
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

test_same_claude_session_reacquires_with_durable_pid() {
  local dir contender_pid holder_pid
  dir="$TMP_ROOT/same-session"
  make_lock_identity_home "$dir"
  run_lock_pair "$dir" session-same session-same
  expect_code 0 "$(cat "$dir/state/contender.rc")" "the same Claude session id must reacquire the lock"
  contender_pid=$(cat "$dir/state/contender-pid")
  holder_pid=$(cat "$dir/state/holder-pid")
  [ "$contender_pid" != "$holder_pid" ] \
    || fail "the same-session fixture did not separate CLAUDE_PID from the ancestry pid"
  [ "$(cat "$dir/state/.lock")" = "$holder_pid" ] \
    || fail "same-session reacquire did not preserve the durable ancestry pid"
  [ "$(cat "$dir/state/.lock.session")" = session-same ] \
    || fail "same-session reacquire changed the session discriminator"
  pass "session-lock executable: same Claude session reacquires with its durable pid"
}

test_same_claude_session_reacquires_during_startup_lease() {
  local dir current_pid fakebin lease_pid releaser_pid real_sed rc=0
  dir="$TMP_ROOT/same-session-startup-lease"
  make_lock_identity_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-startup-owner\n' > "$dir/state/.lock.session"
  sleep 30 &
  lease_pid=$!
  mkdir "$dir/state/.lock.acquire"
  printf '%s\n' "$lease_pid" > "$dir/state/.lock.acquire/pid"
  printf 'pid=%s\n' "$lease_pid" > "$dir/state/.startup-network.status"
  fakebin=$(fm_fakebin "$dir/startup-lease-bin")
  real_sed=$(command -v sed)
  cat > "$fakebin/sed" <<'SH'
#!/usr/bin/env bash
set -u
"$FM_REAL_SED" "$@"
rc=$?
case "$*" in *'.startup-network.status'*) : > "$FM_HOME/state/startup-status-read" ;; esac
exit "$rc"
SH
  chmod +x "$fakebin/sed"
  (
    i=0
    while [ "$i" -lt 500 ] && [ ! -e "$dir/state/startup-status-read" ]; do
      sleep 0.01
      i=$((i + 1))
    done
    sleep 0.1
    rm -f "$dir/state/.lock.acquire/pid"
    rmdir "$dir/state/.lock.acquire" 2>/dev/null || true
    kill "$lease_pid" 2>/dev/null || true
  ) &
  releaser_pid=$!
  FM_HOME="$dir" FM_REAL_SED="$real_sed" PATH="$fakebin:$PATH" "$NAMED_CLAUDE" -c '
    export CLAUDE_CODE_SESSION_ID=session-startup-owner
    export CLAUDE_PID=$$
    export CLAUDE_CODE_CHILD_SESSION=1
    printf "%s\n" "$$" > "$FM_HOME/state/current-pid"
    "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
  ' || rc=$?
  wait "$releaser_pid" 2>/dev/null || true
  wait "$lease_pid" 2>/dev/null || true
  expect_code 0 "$rc" "the matching Claude session must reacquire during its startup lease"
  current_pid=$(cat "$dir/state/current-pid")
  [ "$(cat "$dir/state/.lock")" = "$current_pid" ] \
    || fail "startup-lease reacquire did not refresh the durable ancestry pid"
  [ "$(cat "$dir/state/.lock.session")" = session-startup-owner ] \
    || fail "startup-lease reacquire changed the matching session sidecar"
  if grep -F 'operate read-only' "$dir/state/current.out" >/dev/null; then
    fail "startup-lease reacquire refused the matching session"
  fi
  pass "session-lock executable: matching session reacquires during its startup lease"
}

test_background_claude_session_is_refused_under_live_holder() {
  local dir holder_pid
  dir="$TMP_ROOT/background-session"
  make_lock_identity_home "$dir"
  run_lock_pair "$dir" session-holder session-background
  expect_code 1 "$(cat "$dir/state/contender.rc")" "a background Claude session must not acquire its parent's live lock"
  holder_pid=$(cat "$dir/state/holder-pid")
  [ "$(cat "$dir/state/.lock")" = "$holder_pid" ] \
    || fail "the refused background session replaced the holder pid"
  [ "$(cat "$dir/state/.lock.session")" = session-holder ] \
    || fail "the refused background session replaced the holder session id"
  grep -F 'Claude session session-holder' "$dir/state/contender.out" >/dev/null \
    || fail "the live-holder refusal did not name the holder session id"
  pass "session-lock executable: background Claude session is refused under its live holder"
}

# --- in-place session replacement -------------------------------------------
#
# Claude's /clear replaces the session inside the SAME OS process: the recorded
# lock pid stays live and stays in this session's own ancestry, while the
# recorded sidecar names the session id that no longer exists. Only
# bin/fm-sessionstart-run.sh grants the replacement intent, and only for a
# validated native SessionStart payload; these cases pin what the intent may and
# may not do once granted.

test_session_replacement_reclaims_its_own_stale_sidecar() {
  local dir holder_pid
  dir="$TMP_ROOT/replacement-reclaim"
  make_lock_identity_home "$dir"
  run_lock_pair "$dir" session-before session-after 0 --session-replacement holder
  expect_code 0 "$(cat "$dir/state/contender.rc")" \
    "a replacement acquisition must reclaim the stale sidecar of its own client process"
  holder_pid=$(cat "$dir/state/holder-pid")
  [ "$(cat "$dir/state/.lock")" = "$holder_pid" ] \
    || fail "the replacement acquisition moved the durable ancestry pid"
  [ "$(cat "$dir/state/.lock.session")" = session-after ] \
    || fail "the replacement acquisition did not publish the new session id"
  pass "session-lock executable: a granted replacement reclaims its own stale sidecar"
}

test_session_replacement_is_idempotent_for_a_matching_sidecar() {
  local dir holder_pid
  dir="$TMP_ROOT/replacement-matching"
  make_lock_identity_home "$dir"
  run_lock_pair "$dir" session-unchanged session-unchanged 0 --session-replacement holder
  expect_code 0 "$(cat "$dir/state/contender.rc")" \
    "a replacement acquisition must still succeed when the sidecar already matches"
  holder_pid=$(cat "$dir/state/holder-pid")
  [ "$(cat "$dir/state/.lock")" = "$holder_pid" ] \
    || fail "an already-matching replacement acquisition moved the durable ancestry pid"
  [ "$(cat "$dir/state/.lock.session")" = session-unchanged ] \
    || fail "an already-matching replacement acquisition changed the session sidecar"
  pass "session-lock executable: a granted replacement is idempotent for a matching sidecar"
}

test_session_replacement_refuses_a_nested_background_contender() {
  local dir holder_pid
  dir="$TMP_ROOT/replacement-nested-contender"
  make_lock_identity_home "$dir"
  # The exact PR #74 shape armed with the intent itself: the nested contender
  # holds the replacement flag, sees the live holder pid in its own contiguous
  # ancestry, and presents matching ids, but its vendor-reset CLAUDE_PID names
  # itself rather than the recorded owner, so nothing may change.
  run_lock_pair "$dir" session-holder session-background 0 --session-replacement self
  expect_code 1 "$(cat "$dir/state/contender.rc")" \
    "a nested background contender must not win even with the replacement intent"
  holder_pid=$(cat "$dir/state/holder-pid")
  [ "$(cat "$dir/state/.lock")" = "$holder_pid" ] \
    || fail "the nested replacement contender replaced the holder pid"
  [ "$(cat "$dir/state/.lock.session")" = session-holder ] \
    || fail "the nested replacement contender replaced the holder session id"
  pass "session-lock executable: a nested background contender is refused even with the intent"
}

test_session_replacement_refuses_a_live_owner_outside_the_ancestry() {
  local dir foreign_pid
  dir="$TMP_ROOT/replacement-foreign-owner"
  make_lock_identity_home "$dir"
  "$NAMED_CLAUDE" -c 'sleep 30' &
  foreign_pid=$!
  printf '%s\n' "$foreign_pid" > "$dir/state/.lock"
  printf 'session-foreign\n' > "$dir/state/.lock.session"
  run_own_ancestry_lock "$dir" session-current : --session-replacement
  kill "$foreign_pid" 2>/dev/null || true
  wait "$foreign_pid" 2>/dev/null || true
  expect_code 1 "$OWN_ANCESTRY_RC" \
    "a replacement acquisition must refuse a live owner outside this session's ancestry"
  [ "$(cat "$dir/state/.lock")" = "$foreign_pid" ] \
    || fail "the refused replacement replaced another live session's lock pid"
  [ "$(cat "$dir/state/.lock.session")" = session-foreign ] \
    || fail "the refused replacement replaced another live session's sidecar"
  pass "session-lock executable: a replacement refuses a live owner outside its ancestry"
}

test_session_replacement_refuses_a_dead_owner() {
  local dir
  dir="$TMP_ROOT/replacement-dead-owner"
  make_lock_identity_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-dead\n' > "$dir/state/.lock.session"
  run_own_ancestry_lock "$dir" session-current : --session-replacement
  expect_code 1 "$OWN_ANCESTRY_RC" \
    "a replacement acquisition must leave a dead owner to the ordinary stale takeover"
  [ "$(cat "$dir/state/.lock")" = 9999999 ] \
    || fail "the replacement intent performed a stale takeover of its own"
  [ "$(cat "$dir/state/.lock.session")" = session-dead ] \
    || fail "the replacement intent rewrote a dead owner's sidecar"
  pass "session-lock executable: a replacement refuses a dead owner"
}

test_session_replacement_refuses_a_missing_sidecar() {
  local dir current_pid
  dir="$TMP_ROOT/replacement-missing-sidecar"
  make_lock_identity_home "$dir"
  run_own_ancestry_lock "$dir" session-current \
    'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; rm -f "$FM_HOME/state/.lock.session"' \
    --session-replacement
  expect_code 1 "$OWN_ANCESTRY_RC" \
    "a replacement acquisition must refuse an old lock that carries no sidecar"
  current_pid=$(cat "$dir/state/current-pid")
  [ "$(cat "$dir/state/.lock")" = "$current_pid" ] \
    || fail "the refused replacement changed the old-format lock pid"
  [ ! -e "$dir/state/.lock.session" ] \
    || fail "the refused replacement upgraded an old-format lock with a sidecar"
  pass "session-lock executable: a replacement refuses an old lock with no sidecar"
}

test_session_replacement_waits_for_its_own_startup_sweep() {
  local dir current_pid
  dir="$TMP_ROOT/replacement-startup-sweep"
  make_lock_identity_home "$dir"
  # The claim is held by this same process's earlier bounded startup sweep, so
  # the replacement must wait for it rather than refuse as a prior session.
  run_own_ancestry_lock "$dir" session-after '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "session-before\n" > "$FM_HOME/state/.lock.session"
    sleep 30 &
    lease_pid=$!
    # Off the job table, so reaping the killed lease cannot print a job-control
    # notice into the suite output.
    disown "$lease_pid" 2>/dev/null || true
    mkdir "$FM_HOME/state/.lock.acquire"
    printf "%s\n" "$lease_pid" > "$FM_HOME/state/.lock.acquire/pid"
    printf "pid=%s\n" "$lease_pid" > "$FM_HOME/state/.startup-network.status"
    (
      sleep 2
      rm -f "$FM_HOME/state/.lock.acquire/pid"
      rmdir "$FM_HOME/state/.lock.acquire" 2>/dev/null || true
      kill "$lease_pid" 2>/dev/null || true
    ) &
  ' --session-replacement
  expect_code 0 "$OWN_ANCESTRY_RC" \
    "a replacement must wait for its own session's startup sweep instead of refusing"
  current_pid=$(cat "$dir/state/current-pid")
  [ "$(cat "$dir/state/.lock")" = "$current_pid" ] \
    || fail "the replacement after the startup sweep did not keep this session's pid"
  [ "$(cat "$dir/state/.lock.session")" = session-after ] \
    || fail "the replacement after the startup sweep did not publish the new session id"
  if grep -F 'bounded startup sweep' "$dir/state/current.out" >/dev/null; then
    fail "the replacement treated its own session's startup sweep as a prior session"
  fi
  pass "session-lock executable: a replacement waits for its own startup sweep"
}

test_lock_help_is_read_only() {
  local dir out rc=0
  dir="$TMP_ROOT/lock-help"
  # No home is prepared on purpose: help must answer before any state
  # creation or acquisition, so nothing may appear on disk.
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-lock.sh" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-lock.sh --help must exit 0"
  case "$out" in
    usage:*) : ;;
    *) fail "fm-lock.sh --help did not print usage, got: $out" ;;
  esac
  case "$out" in
    *'lock acquired'*) fail "fm-lock.sh --help performed an acquisition" ;;
  esac
  [ ! -e "$dir" ] \
    || fail "fm-lock.sh --help created state on disk"
  rc=0
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-lock.sh" -h 2>&1) || rc=$?
  expect_code 0 "$rc" "fm-lock.sh -h must exit 0"
  [ ! -e "$dir" ] \
    || fail "fm-lock.sh -h created state on disk"
  pass "session-lock executable: --help answers read-only before any state creation"
}

test_foreign_session_takes_over_dead_holder() {
  local dir current_pid rc=0
  dir="$TMP_ROOT/dead-holder-session"
  make_lock_identity_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-dead\n' > "$dir/state/.lock.session"
  FM_HOME="$dir" "$NAMED_CLAUDE" -c '
    export CLAUDE_CODE_SESSION_ID=session-current
    export CLAUDE_PID=$$
    export CLAUDE_CODE_CHILD_SESSION=1
    printf "%s\n" "$$" > "$FM_HOME/state/current-pid"
    "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
  ' || rc=$?
  expect_code 0 "$rc" "a foreign Claude session must take over a dead holder"
  current_pid=$(cat "$dir/state/current-pid")
  [ "$(cat "$dir/state/.lock")" = "$current_pid" ] \
    || fail "dead-holder takeover did not publish the current liveness pid"
  [ "$(cat "$dir/state/.lock.session")" = session-current ] \
    || fail "dead-holder takeover did not publish the current session id"
  pass "session-lock executable: foreign Claude session takes over a dead holder"
}

test_dead_claude_pid_does_not_change_ancestry_pid() {
  local dir current_pid rc=0
  dir="$TMP_ROOT/dead-claude-pid"
  make_lock_identity_home "$dir"
  FM_HOME="$dir" "$NAMED_CLAUDE" -c '
    export CLAUDE_CODE_SESSION_ID=session-dead-claude-pid
    export CLAUDE_PID=9999999
    export CLAUDE_CODE_CHILD_SESSION=1
    printf "%s\n" "$$" > "$FM_HOME/state/current-pid"
    "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
  ' || rc=$?
  expect_code 0 "$rc" "a dead CLAUDE_PID must not affect acquisition"
  current_pid=$(cat "$dir/state/current-pid")
  [ "$(cat "$dir/state/.lock")" = "$current_pid" ] \
    || fail "a dead CLAUDE_PID changed the resolved ancestry pid"
  [ "$(cat "$dir/state/.lock.session")" = session-dead-claude-pid ] \
    || fail "a dead CLAUDE_PID prevented session discriminator publication"
  pass "session-lock executable: CLAUDE_PID does not change the ancestry pid"
}

test_non_claude_ancestry_ignores_inherited_claude_environment() {
  local dir current_pid rc=0
  dir="$TMP_ROOT/non-claude-inherited-env"
  make_lock_identity_home "$dir"
  FM_HOME="$dir" CLAUDE_CODE_SESSION_ID=session-inherited CLAUDE_PID=9999999 \
    CLAUDE_CODE_CHILD_SESSION=1 "$NAMED_CODEX" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/current-pid"
      "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
    ' || rc=$?
  expect_code 0 "$rc" "a non-Claude ancestry must acquire by ancestry despite inherited Claude variables"
  current_pid=$(cat "$dir/state/current-pid")
  [ "$(cat "$dir/state/.lock")" = "$current_pid" ] \
    || fail "non-Claude ancestry did not keep its innermost ancestry pid"
  [ ! -e "$dir/state/.lock.session" ] \
    || fail "non-Claude ancestry wrote an inherited Claude session sidecar"
  pass "session-lock executable: non-Claude ancestry ignores inherited Claude environment"
}

test_old_lock_without_sidecar_uses_pid_fallback() {
  local dir contender_pid holder_pid
  dir="$TMP_ROOT/old-lock-fallback"
  make_lock_identity_home "$dir"
  run_lock_pair "$dir" session-holder session-background 1
  expect_code 0 "$(cat "$dir/state/contender.rc")" "an old lock must use today's ancestry pid comparison"
  contender_pid=$(cat "$dir/state/contender-pid")
  holder_pid=$(cat "$dir/state/holder-pid")
  [ "$contender_pid" != "$holder_pid" ] \
    || fail "the old-lock fixture did not separate CLAUDE_PID from the ancestry pid"
  [ "$(cat "$dir/state/.lock")" = "$holder_pid" ] \
    || fail "old-lock fallback did not preserve the durable ancestry pid"
  [ "$(cat "$dir/state/.lock.session")" = session-background ] \
    || fail "old-lock fallback did not upgrade the acquired lock with a sidecar"
  pass "session-lock executable: old lock without a sidecar uses pid fallback"
}

test_real_stop_hook_owns_matching_claude_session() {
  local dir
  dir="$TMP_ROOT/e2e-session-sidecar"
  make_primary_home "$dir"
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-hook-owner
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
"$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/lock.out" 2>&1 || exit $?
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  chmod +x "$dir/session.sh"
  run_fixture_tree "$dir" "$NAMED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "the real Stop hook must own a matching Claude session sidecar"
  [ -e "$dir/state/arm-ran" ] || fail "the matching-session real Stop hook did not arm"
  [ "$(cat "$dir/state/.lock.session")" = session-hook-owner ] \
    || fail "the matching-session real Stop hook lost its session sidecar"
  pass "session-lock e2e: real Stop hook owns its matching Claude session"
}

test_real_stop_hook_refreshes_dead_matching_session() {
  local dir session_pid
  dir="$TMP_ROOT/e2e-dead-matching-session"
  make_primary_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-resumed\n' > "$dir/state/.lock.session"
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-resumed
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  chmod +x "$dir/session.sh"
  run_fixture_tree "$dir" "$NAMED_CLAUDE"
  session_pid=$(cat "$dir/state/session-pid")
  expect_code 2 "$(hook_rc "$dir")" "a matching session must refresh its dead recorded pid before arming"
  [ "$(cat "$dir/state/.lock")" = "$session_pid" ] \
    || fail "matching-session recovery did not publish the live ancestry pid"
  [ "$(cat "$dir/state/.lock.session")" = session-resumed ] \
    || fail "matching-session recovery changed the session sidecar"
  [ -e "$dir/state/arm-ran" ] || fail "the recovered matching-session hook did not arm"
  pass "session-lock e2e: matching session refreshes a dead pid before arming"
}

test_identity_publication_exposes_only_stable_pairs() {
  local dir observer_bin current_pid rc=0 saw_absent=0 saw_matching=0 lock session reader_rc
  dir="$TMP_ROOT/claude/e2e-stable-identity-publication"
  make_primary_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-old\n' > "$dir/state/.lock.session"
  observer_bin=$(fm_fakebin "$dir/observer/claude")
  cat > "$dir/observer.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-reader
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
rc=0
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null >> "$FM_HOME/state/reader.out" 2>&1 || rc=$?
printf '%s\n' "$rc" >> "$FM_HOME/state/reader.rcs"
SH
  cat > "$observer_bin/mv" <<'SH'
#!/usr/bin/env bash
set -u
dest=
for arg in "$@"; do dest=$arg; done
snapshot() {
  lock=$(cat "$FM_HOME/state/.lock" 2>/dev/null || printf absent)
  session=$(cat "$FM_HOME/state/.lock.session" 2>/dev/null || printf absent)
  printf '%s|%s\n' "$lock" "$session" >> "$FM_HOME/state/publication.snapshots"
}
case "$dest" in
  "$FM_HOME/state/.lock")
    snapshot
    touch -t 200001010000 "$FM_HOME/state/.lock.acquire"
    "$FM_OBSERVER_BIN" "$FM_HOME/observer.sh"
    /bin/mv "$@" || exit $?
    snapshot
    touch -t 200001010000 "$FM_HOME/state/.lock.acquire"
    "$FM_OBSERVER_BIN" "$FM_HOME/observer.sh"
    ;;
  "$FM_HOME/state/.lock.session")
    snapshot
    touch -t 200001010000 "$FM_HOME/state/.lock.acquire"
    "$FM_OBSERVER_BIN" "$FM_HOME/observer.sh"
    /bin/mv "$@" || exit $?
    snapshot
    ;;
  *) /bin/mv "$@" ;;
esac
SH
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-current
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' "$$" > "$FM_HOME/state/current-pid"
PATH="$FM_OBSERVER_PATH:$PATH" FM_OBSERVER_BIN="$FM_OBSERVER_BIN" \
  "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
SH
  chmod +x "$dir/observer.sh" "$observer_bin/mv" "$dir/session.sh"
  FM_HOME="$dir" FM_OBSERVER_PATH="$observer_bin" FM_OBSERVER_BIN="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/session.sh" || rc=$?
  expect_code 0 "$rc" "session identity publication must complete"
  current_pid=$(cat "$dir/state/current-pid")
  while IFS='|' read -r lock session; do
    if [ "$session" = absent ]; then
      case "$lock" in
        9999999|"$current_pid") saw_absent=1 ;;
        *) fail "reader saw an invalid old-format lock during publication: $lock|$session" ;;
      esac
    elif [ "$session" = session-current ] && [ "$lock" = "$current_pid" ]; then
      saw_matching=1
    else
      fail "reader saw a mismatched session identity during publication: $lock|$session"
    fi
  done < "$dir/state/publication.snapshots"
  [ "$saw_absent" -eq 1 ] || fail "reader never observed the old-format publication state"
  [ "$saw_matching" -eq 1 ] || fail "reader never observed the matching session publication state"
  while IFS= read -r reader_rc; do
    expect_code 0 "$reader_rc" "a foreign reader must stand down during identity publication"
  done < "$dir/state/reader.rcs"
  [ ! -e "$dir/state/arm-ran" ] || fail "a foreign reader armed during identity publication"
  grep -F 'standing down: session lock identity update in progress' "$dir/state/reader.out" >/dev/null \
    || fail "the live aged publication claim did not keep the foreign reader inert"
  pass "session-lock e2e: identity publication exposes only stable pairs"
}

test_real_stop_hook_ignores_aged_acquisition_claim() {
  local dir
  dir="$TMP_ROOT/e2e-aged-acquisition-claim"
  make_primary_home "$dir"
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-aged-claim-owner
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
"$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/lock.out" 2>&1 || exit $?
mkdir "$FM_HOME/state/.lock.acquire"
touch -t 200001010000 "$FM_HOME/state/.lock.acquire"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  chmod +x "$dir/session.sh"
  run_fixture_tree "$dir" "$NAMED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "an aged acquisition claim must not silence the real owner hook"
  [ -e "$dir/state/arm-ran" ] || fail "an aged acquisition claim prevented the real owner hook from arming"
  [ "$(cat "$dir/state/.lock.session")" = session-aged-claim-owner ] \
    || fail "the aged-claim real Stop hook lost its matching session sidecar"
  pass "session-lock e2e: real Stop hook ignores an aged acquisition claim"
}

test_real_stop_hook_uses_stable_identity_during_live_lease() {
  local dir
  dir="$TMP_ROOT/e2e-live-acquisition-lease"
  make_primary_home "$dir"
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-live-lease-owner
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
"$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/lock.out" 2>&1 || exit $?
mkdir "$FM_HOME/state/.lock.acquire"
printf '%s\n' "$$" > "$FM_HOME/state/.lock.acquire/pid"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  chmod +x "$dir/session.sh"
  run_fixture_tree "$dir" "$NAMED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a live acquisition lease must not hide stable session ownership"
  [ -e "$dir/state/arm-ran" ] || fail "the stable lock owner did not arm during a live acquisition lease"
  pass "session-lock e2e: stable identity survives a live acquisition lease"
}

test_failed_sidecar_publication_rolls_back_lock() {
  local dir fakebin rc=0
  dir="$TMP_ROOT/failed-sidecar-publication"
  make_lock_identity_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-old\n' > "$dir/state/.lock.session"
  fakebin=$(fm_fakebin "$dir/sidecar-failure")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
dest=
for arg in "$@"; do dest=$arg; done
if [ "$dest" = "$FM_HOME/state/.lock.session" ] \
  && [ ! -e "$FM_HOME/state/sidecar-failure-fired" ]; then
  : > "$FM_HOME/state/sidecar-failure-fired"
  exit 1
fi
/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  FM_HOME="$dir" PATH="$fakebin:$PATH" "$NAMED_CLAUDE" -c '
    export CLAUDE_CODE_SESSION_ID=session-current
    export CLAUDE_PID=$$
    export CLAUDE_CODE_CHILD_SESSION=1
    "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
  ' || rc=$?
  expect_code 1 "$rc" "a failed sidecar publication must fail acquisition"
  [ "$(cat "$dir/state/.lock")" = 9999999 ] \
    || fail "failed sidecar publication did not restore the prior lock pid"
  [ "$(cat "$dir/state/.lock.session")" = session-old ] \
    || fail "failed sidecar publication did not restore the prior session sidecar"
  pass "session-lock executable: sidecar failure restores the prior identity"
}

test_persistent_sidecar_failure_removes_legacy_lock() {
  local dir fakebin rc=0
  dir="$TMP_ROOT/persistent-sidecar-failure"
  make_lock_identity_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-old\n' > "$dir/state/.lock.session"
  fakebin=$(fm_fakebin "$dir/persistent-sidecar-failure-bin")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
dest=
for arg in "$@"; do dest=$arg; done
[ "$dest" != "$FM_HOME/state/.lock.session" ] || exit 1
/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  FM_HOME="$dir" PATH="$fakebin:$PATH" "$NAMED_CLAUDE" -c '
    export CLAUDE_CODE_SESSION_ID=session-current
    export CLAUDE_PID=$$
    export CLAUDE_CODE_CHILD_SESSION=1
    "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
  ' || rc=$?
  expect_code 1 "$rc" "a persistent sidecar failure must fail acquisition"
  [ ! -e "$dir/state/.lock" ] \
    || fail "persistent sidecar failure exposed the restored pid as a legacy lock"
  [ ! -e "$dir/state/.lock.session" ] \
    || fail "persistent sidecar failure left a session sidecar without its lock"
  pass "session-lock executable: persistent sidecar failure fails closed"
}

test_failed_sidecar_removal_preserves_prior_identity() {
  local dir fakebin rc=0
  dir="$TMP_ROOT/failed-sidecar-removal"
  make_lock_identity_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-old\n' > "$dir/state/.lock.session"
  fakebin=$(fm_fakebin "$dir/sidecar-removal-failure")
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
dest=
for arg in "$@"; do dest=$arg; done
[ "$dest" != "$FM_HOME/state/.lock.session" ] || exit 1
/bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  FM_HOME="$dir" PATH="$fakebin:$PATH" "$NAMED_CLAUDE" -c '
    export CLAUDE_CODE_SESSION_ID=session-current
    export CLAUDE_PID=$$
    export CLAUDE_CODE_CHILD_SESSION=1
    "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/current.out" 2>&1
  ' || rc=$?
  expect_code 1 "$rc" "a failed sidecar removal must fail acquisition"
  [ "$(cat "$dir/state/.lock")" = 9999999 ] \
    || fail "failed sidecar removal changed the prior lock pid"
  [ "$(cat "$dir/state/.lock.session")" = session-old ] \
    || fail "failed sidecar removal changed the prior session sidecar"
  pass "session-lock executable: sidecar removal failure preserves prior identity"
}

test_foreign_stop_hook_stands_down_with_session_reason() {
  local dir rc=0 holder_hook_pid
  dir="$TMP_ROOT/e2e-foreign-hook"
  make_primary_home "$dir"
  cat > "$dir/foreign-hook.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-foreign-hook
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/foreign-hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/foreign-hook.rc"
SH
  cat > "$dir/holder-hook.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-hook-holder
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' "$$" > "$FM_HOME/state/holder-hook-pid"
"$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/holder-lock.out" 2>&1 || exit $?
"$FM_FOREIGN_BIN" "$FM_HOME/foreign-hook.sh"
mv "$FM_HOME/state/foreign-hook.out" "$FM_HOME/state/foreign-stable.out"
mv "$FM_HOME/state/foreign-hook.rc" "$FM_HOME/state/foreign-stable.rc"
cp "$FM_HOME/state/.lock" "$FM_HOME/state/lock-after-foreign"
cp "$FM_HOME/state/.lock.session" "$FM_HOME/state/lock-session-after-foreign"
mkdir "$FM_HOME/state/.lock.acquire"
rm -f "$FM_HOME/state/.lock.session"
"$FM_FOREIGN_BIN" "$FM_HOME/foreign-hook.sh"
SH
  chmod +x "$dir/foreign-hook.sh" "$dir/holder-hook.sh"
  FM_HOME="$dir" FM_FOREIGN_BIN="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/holder-hook.sh" || rc=$?
  expect_code 0 "$rc" "a foreign Stop hook must stand down without failing the hook"
  expect_code 0 "$(cat "$dir/state/foreign-stable.rc")" "the foreign Stop hook must exit cleanly"
  grep -F 'standing down: lock belongs to Claude session session-hook-holder, not session-foreign-hook' \
    "$dir/state/foreign-stable.out" >/dev/null \
    || fail "the foreign Stop hook did not give one clear session-identity reason"
  # The exact PR #74 shape: the probe's own Claude ancestry contains the live
  # lock pid, and only the sidecar separates it from the owner. A Stop probe
  # never receives the SessionStart replacement intent, so it must leave both
  # lock files exactly as the holder published them.
  holder_hook_pid=$(cat "$dir/state/holder-hook-pid")
  [ "$(cat "$dir/state/lock-after-foreign")" = "$holder_hook_pid" ] \
    || fail "the same-tree foreign Stop probe rewrote the holder's lock pid"
  [ "$(cat "$dir/state/lock-session-after-foreign")" = session-hook-holder ] \
    || fail "the same-tree foreign Stop probe rewrote the holder's session sidecar"
  expect_code 0 "$(cat "$dir/state/foreign-hook.rc")" "a hook during identity publication must exit cleanly"
  grep -F 'standing down: session lock identity update in progress' \
    "$dir/state/foreign-hook.out" >/dev/null \
    || fail "the publication-gap hook did not stand down with one clear reason"
  [ ! -e "$dir/state/arm-ran" ] || fail "the foreign Stop hook armed supervision"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "the foreign Stop hook wrote an epoch"
  pass "session-lock e2e: foreign Stop hook stands down for a foreign id and during sidecar publication"
}

test_real_stop_hook_recovers_dead_foreign_sidecar() {
  local dir
  dir="$TMP_ROOT/e2e-dead-sidecar-hook"
  make_primary_home "$dir"
  printf '9999999\n' > "$dir/state/.lock"
  printf 'session-dead-hook\n' > "$dir/state/.lock.session"
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-live-hook
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  chmod +x "$dir/session.sh"
  run_fixture_tree "$dir" "$NAMED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "the real Stop hook must recover a dead foreign session holder"
  [ -e "$dir/state/arm-ran" ] || fail "the recovered real Stop hook did not arm"
  [ "$(cat "$dir/state/.lock.session")" = session-live-hook ] \
    || fail "stale-owner recovery did not replace the dead foreign sidecar"
  pass "session-lock e2e: real Stop hook recovers a dead foreign sidecar"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_same_claude_session_reacquires_with_durable_pid
test_same_claude_session_reacquires_during_startup_lease
test_background_claude_session_is_refused_under_live_holder
test_session_replacement_reclaims_its_own_stale_sidecar
test_session_replacement_is_idempotent_for_a_matching_sidecar
test_session_replacement_refuses_a_nested_background_contender
test_session_replacement_refuses_a_live_owner_outside_the_ancestry
test_session_replacement_refuses_a_dead_owner
test_session_replacement_refuses_a_missing_sidecar
test_session_replacement_waits_for_its_own_startup_sweep
test_lock_help_is_read_only
test_foreign_session_takes_over_dead_holder
test_dead_claude_pid_does_not_change_ancestry_pid
test_non_claude_ancestry_ignores_inherited_claude_environment
test_old_lock_without_sidecar_uses_pid_fallback
test_real_stop_hook_owns_matching_claude_session
test_real_stop_hook_refreshes_dead_matching_session
test_identity_publication_exposes_only_stable_pairs
test_real_stop_hook_ignores_aged_acquisition_claim
test_real_stop_hook_uses_stable_identity_during_live_lease
test_failed_sidecar_publication_rolls_back_lock
test_persistent_sidecar_failure_removes_legacy_lock
test_failed_sidecar_removal_preserves_prior_identity
test_foreign_stop_hook_stands_down_with_session_reason
test_real_stop_hook_recovers_dead_foreign_sidecar
