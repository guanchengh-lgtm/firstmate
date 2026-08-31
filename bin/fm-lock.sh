#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the durable ancestry PID selected by bin/fm-session-lock-lib.sh.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
#        fm-lock.sh --help    print usage and exit 0; reads and writes nothing
#        fm-lock.sh --session-replacement
#                             INTERNAL, granted only by bin/fm-sessionstart-run.sh
#                             for a validated native Claude SessionStart payload
#                             whose source is an in-place replacement. It permits
#                             exactly one extra shape: a live recorded owner that
#                             is this hook's own direct Claude client process
#                             (the vendor-set CLAUDE_PID) AND a member of THIS
#                             session's verified harness ancestry, while the
#                             recorded sidecar names a different valid session,
#                             which is what a same-process /clear leaves behind.
#                             Every other shape - an absent lock, a dead owner,
#                             a live owner outside that ancestry, a live owner
#                             that is not this hook's own client process (a
#                             nested background Claude job) - exits 1 and changes
#                             nothing, so the mode can never widen ownership the
#                             way a generic ancestry reclaim would (PR #74).
set -u

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  cat <<'EOF'
usage: fm-lock.sh [status | --help | --session-replacement]

  (no argument)          acquire the per-home session lock; exit 1 unless
                         ownership is verified
  status                 print holder and liveness; always exits 0
  --help, -h             print this usage and exit 0; reads and writes nothing
  --session-replacement  INTERNAL: granted only by bin/fm-sessionstart-run.sh
                         for a validated native Claude in-place session
                         replacement; see the script header for the exact
                         shape it permits
EOF
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock.session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# The shared session-lock lib owns harness identity and holder liveness so the
# Claude Stop auto-arm applies the same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

session_replacement=0
if [ "${1:-}" = "--session-replacement" ]; then
  session_replacement=1
  shift
fi

fm_session_lock_identity || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
legacy_me=$FM_SESSION_ANCESTRY_PID
me=$FM_SESSION_ANCESTRY_PID
session_id=$FM_SESSION_ID
lock_tmp=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
if ! { printf '%s\n' "$me" > "$lock_tmp"; } 2>/dev/null; then
  rm -f "$lock_tmp" 2>/dev/null || true
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
session_tmp=''
rollback_tmp=''
rollback_session_tmp=''
rollback_remove_lock=0
publication_changed=0
publication_complete=0
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  local prior_pair_intact=0 rollback_lock_ok=0
  if [ "$publication_changed" -eq 1 ] && [ "$publication_complete" -eq 0 ]; then
    if [ "$rollback_remove_lock" -eq 0 ] && [ -n "$rollback_tmp" ] \
      && cmp -s "$rollback_tmp" "$LOCK" 2>/dev/null; then
      if [ -n "$rollback_session_tmp" ]; then
        cmp -s "$rollback_session_tmp" "$LOCK_SESSION" 2>/dev/null && prior_pair_intact=1
      elif [ ! -e "$LOCK_SESSION" ] && [ ! -L "$LOCK_SESSION" ]; then
        prior_pair_intact=1
      fi
    fi
    if [ "$prior_pair_intact" -eq 0 ]; then
      if ! rm -f "$LOCK_SESSION" 2>/dev/null; then
        rm -f "$LOCK" 2>/dev/null || true
      elif [ "$rollback_remove_lock" -eq 1 ]; then
        rm -f "$LOCK" 2>/dev/null && rollback_lock_ok=1
      elif [ -n "$rollback_tmp" ]; then
        if mv "$rollback_tmp" "$LOCK" 2>/dev/null; then
          rollback_tmp=''
          rollback_lock_ok=1
        else
          rm -f "$LOCK" 2>/dev/null || true
        fi
      fi
      if [ "$rollback_lock_ok" -eq 1 ] && [ "$rollback_remove_lock" -eq 0 ] \
        && [ -n "$rollback_session_tmp" ]; then
        if mv "$rollback_session_tmp" "$LOCK_SESSION" 2>/dev/null; then
          rollback_session_tmp=''
        else
          rm -f "$LOCK" 2>/dev/null || true
          rm -f "$LOCK_SESSION" 2>/dev/null || true
        fi
      fi
    fi
    publication_changed=0
  fi
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
  [ -z "$lock_tmp" ] || rm -f "$lock_tmp" 2>/dev/null || true
  [ -z "$session_tmp" ] || rm -f "$session_tmp" 2>/dev/null || true
  [ -z "$rollback_tmp" ] || rm -f "$rollback_tmp" 2>/dev/null || true
  [ -z "$rollback_session_tmp" ] || rm -f "$rollback_session_tmp" 2>/dev/null || true
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

matching_session=0
replacement_permitted=0

# True when pid $1 belongs to this session's own contiguous verified-harness
# ancestry. Equality with the recorded lock pid alone is not enough: only
# membership in that resolved run proves the pid is THIS process's session.
pid_in_session_ancestry() {  # <pid>
  local pid=$1 candidate
  [ -n "$pid" ] || return 1
  while IFS= read -r candidate; do
    [ "$candidate" = "$pid" ] && return 0
  done <<EOF
$FM_SESSION_ANCESTRY_PIDS
EOF
  return 1
}

# In replacement mode only the own-client-process replacement may proceed. An
# absent lock, a matching sidecar, a dead owner, a live owner outside this
# ancestry, and a live owner that is not this hook's own Claude client keep
# belonging to the ordinary path, so the intent can never be widened into a
# general reclaim.
refuse_unless_replacement_applies() {
  [ "$session_replacement" -eq 1 ] || return 0
  [ "$replacement_permitted" -eq 1 ] && return 0
  echo "error: no in-place session replacement applies to this session lock; leaving it unchanged" >&2
  exit 1
}

lock_refuses_current_session() {  # <recorded-pid>
  local old=$1 holder_session=''
  matching_session=0
  replacement_permitted=0
  if [ -n "$session_id" ]; then
    holder_session=$(fm_session_lock_read_session_id "$STATE" 2>/dev/null || true)
  fi
  if [ -n "$session_id" ] && [ -n "$holder_session" ]; then
    if [ "$holder_session" = "$session_id" ]; then
      matching_session=1
      return 1
    fi
    if fm_harness_pid_alive "$old"; then
      # A native in-place session replacement keeps this OS process and only
      # issues a new session id, so the live owner it names is this hook's own
      # direct Claude client process: the vendor resets CLAUDE_PID for every
      # Claude process, so a nested background job always presents its own pid
      # rather than the recorded owner's, and every other live sidecar mismatch
      # stays a competing session.
      if [ "$session_replacement" -eq 1 ] && [ "$old" = "${CLAUDE_PID:-}" ] \
        && pid_in_session_ancestry "$old"; then
        replacement_permitted=1
        return 1
      fi
      echo "error: another live firstmate session holds the lock (pid $old, Claude session $holder_session); operate read-only until resolved" >&2
      return 0
    fi
    return 1
  fi
  [ "$old" = "$legacy_me" ] && return 1
  if fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    return 0
  fi
  return 1
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if lock_refuses_current_session "$old"; then
    exit 1
  fi
fi
refuse_unless_replacement_applies

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    # A permitted replacement is the same OS process, so the sweep that claim
    # belongs to is this session's own and is waited for, not refused.
    if [ "$matching_session" -ne 1 ] && [ "$replacement_permitted" -ne 1 ]; then
      echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
      exit 1
    fi
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

matching_session=0
replacement_permitted=0
if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if lock_refuses_current_session "$old"; then
    exit 1
  fi
  rollback_tmp=$(mktemp "$STATE/.lock-rollback.XXXXXX" 2>/dev/null) || {
    echo "error: cannot prepare session lock rollback; operate read-only until resolved" >&2
    exit 1
  }
  if ! { cat "$LOCK" > "$rollback_tmp"; } 2>/dev/null; then
    echo "error: cannot prepare session lock rollback; operate read-only until resolved" >&2
    exit 1
  fi
else
  rollback_remove_lock=1
fi
refuse_unless_replacement_applies
if [ -f "$LOCK_SESSION" ] && [ ! -L "$LOCK_SESSION" ]; then
  rollback_session_tmp=$(mktemp "$STATE/.lock-session-rollback.XXXXXX" 2>/dev/null) || {
    echo "error: cannot prepare session lock rollback; operate read-only until resolved" >&2
    exit 1
  }
  if ! { cat "$LOCK_SESSION" > "$rollback_session_tmp"; } 2>/dev/null; then
    echo "error: cannot prepare session lock rollback; operate read-only until resolved" >&2
    exit 1
  fi
fi
if [ -n "$session_id" ]; then
  session_tmp=$(mktemp "$STATE/.lock-session-write.XXXXXX" 2>/dev/null) || {
    echo "error: cannot write session lock identity; operate read-only until resolved" >&2
    exit 1
  }
  if ! { printf '%s\n' "$session_id" > "$session_tmp"; } 2>/dev/null; then
    rm -f "$session_tmp" 2>/dev/null || true
    echo "error: cannot write session lock identity; operate read-only until resolved" >&2
    exit 1
  fi
fi
existing_session=$(fm_session_lock_read_session_id "$STATE" 2>/dev/null || true)
publication_changed=1
if { [ -z "$session_id" ] || [ "$existing_session" != "$session_id" ]; } \
  && ! rm -f "$LOCK_SESSION" 2>/dev/null; then
  echo "error: cannot replace session lock identity; operate read-only until resolved" >&2
  exit 1
fi
if ! mv "$lock_tmp" "$LOCK" 2>/dev/null; then
  echo "error: cannot publish session lock; operate read-only until resolved" >&2
  exit 1
fi
lock_tmp=''
if [ -n "$session_tmp" ] && ! mv "$session_tmp" "$LOCK_SESSION" 2>/dev/null; then
  echo "error: cannot publish session lock identity; operate read-only until resolved" >&2
  exit 1
fi
session_tmp=''
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
if [ -n "$session_id" ]; then
  written_session=$(fm_session_lock_read_session_id "$STATE" 2>/dev/null || true)
  if [ "$written_session" != "$session_id" ]; then
    echo "error: session lock identity verification failed; operate read-only until resolved" >&2
    exit 1
  fi
elif [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
  echo "error: stale session lock identity remains; operate read-only until resolved" >&2
  exit 1
fi
publication_complete=1
release_claim_lock
echo "lock acquired: harness pid $me"
