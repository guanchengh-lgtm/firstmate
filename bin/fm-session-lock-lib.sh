#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness session holds this home's session
# lock, and does the current process belong to that session?" decision. Claude
# identity uses a valid CLAUDE_CODE_SESSION_ID only after the ancestry resolves
# to Claude. state/.lock records the durable ancestry pid, which is also the
# only liveness input. Replacement acquisition alone uses the vendor-set
# CLAUDE_PID to bind the hook to its direct Claude client process; every other
# lock decision remains CLAUDE_PID-free. Other harnesses and uncertain Claude
# states use ancestry unchanged.
# bin/fm-lock.sh uses it to acquire state/.lock and state/.lock.session;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in ${FM_HARNESS_NAMES[@]+"${FM_HARNESS_NAMES[@]}"}; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the durable ancestry pid written to state/.lock: the outermost pid of
# the contiguous run. That pid lives as long as the session - a Claude worker
# several levels in is reaped when its hook returns, and a lock naming it would
# look stale moments later while the session is still running. Every non-Claude
# harness reports a single pid, so this is its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when $1 is a valid vendor session discriminator.
fm_session_id_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  return 0
}

# Print state dir $1's valid Claude session sidecar, or return 1. A missing,
# malformed, or non-regular sidecar is an old or uncertain lock and must use
# the ancestry fallback.
fm_session_lock_read_session_id() {  # <state>
  local state=$1 session_id
  [ -f "$state/.lock.session" ] && [ ! -L "$state/.lock.session" ] || return 1
  session_id=$(cat "$state/.lock.session" 2>/dev/null) || return 1
  fm_session_id_valid "$session_id" || return 1
  printf '%s\n' "$session_id"
}

# Resolve the current lock identity into globals. The ancestry walk always runs
# first. Only a resolved Claude ancestry may use Claude's environment identity.
#
# FM_SESSION_ANCESTRY_PIDS: current contiguous harness run, innermost first
# FM_SESSION_ANCESTRY_PID:  today's lock pid, outermost for Claude
# FM_SESSION_ID:            valid Claude session id, or empty for fallback
# shellcheck disable=SC2034 # Globals are outputs consumed by sourcing scripts.
fm_session_lock_identity() {
  local pids pid innermost='' outermost='' comm args session_id
  FM_SESSION_ANCESTRY_PIDS=''
  FM_SESSION_ANCESTRY_PID=''
  FM_SESSION_ID=''

  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ -n "$innermost" ] || innermost=$pid
    outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$innermost" ] && [ -n "$outermost" ] || return 1

  FM_SESSION_ANCESTRY_PIDS=$pids
  FM_SESSION_ANCESTRY_PID=$outermost

  comm=$(ps -o comm= -p "$innermost" 2>/dev/null) || return 0
  args=$(ps -o args= -p "$innermost" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 0
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 0

  session_id=${CLAUDE_CODE_SESSION_ID:-}
  fm_session_id_valid "$session_id" || return 0
  FM_SESSION_ID=$session_id
  return 0
}

# True when state dir $1 belongs to the current session. A resolved Claude
# session with two valid discriminators compares the sidecar; every uncertain
# state and every other harness uses today's ancestry membership. A missing or
# malformed lock and an unresolved ancestry fail closed.
# shellcheck disable=SC2034 # The auto-arm reads this output after a false result.
FM_SESSION_LOCK_OWNER_REASON=''
fm_session_lock_claim_is_fresh() {
  local claim=$1 stale age modified claim_pid
  [ -e "$claim" ] || [ -L "$claim" ] || return 1
  claim_pid=$(cat "$claim/pid" 2>/dev/null || true)
  case "$claim_pid" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$claim_pid" 2>/dev/null && return 0 ;;
  esac
  stale=${FM_LOCK_STALE_AFTER:-2}
  case "$stale" in
    ''|*[!0-9]*) stale=2 ;;
  esac
  [ "$stale" -lt 2 ] && stale=2
  if command -v fm_path_age >/dev/null 2>&1; then
    age=$(fm_path_age "$claim")
  else
    if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
      modified=$(stat -f %m "$claim" 2>/dev/null || true)
    else
      modified=$(stat -c %Y "$claim" 2>/dev/null || true)
    fi
    case "$modified" in
      ''|*[!0-9]*) return 1 ;;
    esac
    age=$(( $(date +%s) - modified ))
  fi
  [ "$age" -lt "$stale" ]
}

fm_session_lock_owned_by_self() {
  local state=$1 lock_pid lock_session='' pid
  FM_SESSION_LOCK_OWNER_REASON=''
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_session_lock_identity || return 1
  if [ -n "$FM_SESSION_ID" ]; then
    lock_session=$(fm_session_lock_read_session_id "$state" 2>/dev/null || true)
  fi
  if [ -n "$lock_session" ]; then
    if [ "$lock_session" = "$FM_SESSION_ID" ]; then
      fm_harness_pid_alive "$lock_pid" && return 0
    elif fm_harness_pid_alive "$lock_pid"; then
      # shellcheck disable=SC2034 # The auto-arm reads this sourced output.
      FM_SESSION_LOCK_OWNER_REASON="lock belongs to Claude session $lock_session, not $FM_SESSION_ID"
      return 1
    fi
    if fm_session_lock_claim_is_fresh "$state/.lock.acquire"; then
      # shellcheck disable=SC2034 # The auto-arm reads this sourced output.
      FM_SESSION_LOCK_OWNER_REASON='session lock identity update in progress'
      return 1
    fi
    if [ "$lock_session" != "$FM_SESSION_ID" ]; then
      # shellcheck disable=SC2034 # The auto-arm reads this sourced output.
      FM_SESSION_LOCK_OWNER_REASON="lock belongs to Claude session $lock_session, not $FM_SESSION_ID"
    fi
    return 1
  fi
  if [ -n "$FM_SESSION_ID" ] && fm_session_lock_claim_is_fresh "$state/.lock.acquire"; then
    # shellcheck disable=SC2034 # The auto-arm reads this sourced output.
    FM_SESSION_LOCK_OWNER_REASON='session lock identity update in progress'
    return 1
  fi
  while IFS= read -r pid; do
    if [ "$pid" = "$lock_pid" ]; then
      return 0
    fi
  done <<EOF
$FM_SESSION_ANCESTRY_PIDS
EOF
  return 1
}
