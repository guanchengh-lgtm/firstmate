#!/usr/bin/env bash
# Session-open entry point for harnesses that RUN the digest instead of asking
# the agent to. It is the one command those harnesses' session-open adapters
# invoke, and it decides, from the session-open source, whether this open needs
# the full digest, a context re-emit, or nothing at all.
#
# Why running beats nudging: bin/fm-sessionstart-nudge.sh can only ASK the agent
# to take the helm, and an agent can defer that, including when a first-command
# skill has its own read-only path. When the harness injects hook stdout into
# model context, running the digest here removes that discretion - the helm is
# taken before the model's first turn, whatever the first turn is.
#
# Usage: fm-sessionstart-run.sh [--source <source>] [--session-end]
#   --source  The harness's own session-open source. When omitted, the source is
#             read from a Claude/Codex-shaped JSON hook payload on stdin
#             (the `source` field). An unreadable or unrecognized source is
#             treated as `startup`, because taking the helm redundantly is
#             cheap and idempotent while not taking it is the whole bug.
#   --session-end
#             INTERNAL Claude SessionEnd transport. It records a proven
#             clear/resume transition for the following native SessionStart.
#
# In-place session replacement (Claude /clear, /new, or an interactive /resume)
# keeps this OS process and only issues a NEW session id, so the recorded
# state/.lock.session names a session that no longer exists while state/.lock
# still names this session's own pid. This wrapper is the one grantor of
# bin/fm-lock.sh's narrow replacement-acquisition intent, because a matching
# native SessionEnd and SessionStart transition separates that event from a
# background Claude job whose own session id also differs (PR #74).
#
# Source routing (see docs/sessionstart-nudge.md for the per-harness names):
#   startup, new            full digest - this process has not taken the helm
#   clear, compact          `--reemit` digest only when this lock owner recorded
#                           a completed full startup; otherwise a full digest,
#                           so a startup killed mid-sweep is finished first
#   resume, reload, fork    delegate to the nudge wrapper. Prior context is
#                           restored on these, so re-running is redundant when
#                           this process still holds the lock (the nudge stays
#                           silent) and a plain instruction is enough when a new
#                           process resumed an old session (the nudge fires).
#
# Every path exits 0, exactly like the nudge wrapper: a Claude SessionStart
# exit 2 blocks session initialization, so a failed session start must reach the
# agent as digest text it can act on, never as a refusal to open the session.
# A lock another live session holds and a truncated digest are reported inside
# the digest, while broken GitHub auth arrives through the deferred network
# result inline or as a wake, for exactly that reason.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
COMPLETION_FILE="$STATE/.session-start-complete"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

SOURCE=
SOURCE_EXPLICIT=0
SESSION_END=0
PAYLOAD_EVENT=
PAYLOAD_REASON=
PAYLOAD_SESSION_ID=
PAYLOAD_DELIVERED=0
PAYLOAD_VALID=0
REPLACEMENT_END="$STATE/.session-replacement-end"
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE_EXPLICIT=1
      SOURCE=${2:-}
      # A bare trailing --source leaves the source empty rather than aborting,
      # so a malformed call still falls through to taking the helm.
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE_EXPLICIT=1; SOURCE=${1#--source=}; shift ;;
    --session-end) SESSION_END=1; shift ;;
    *) shift ;;
  esac
done

# The same two eligibility owners the nudge wrapper uses, so a no-mistakes gate
# agent and an unmarked task worktree can never run a session start for a home
# they do not own.
fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Print JSON string field <key> from payload <payload>, or nothing.
# Splitting on the quote character finds the FIRST occurrence of the key and its
# value without depending on greedy-regex luck, and it cannot mistake a string
# VALUE equal to the key for the key itself, because only a key is followed by a
# bare colon. Parsed without jq so a host missing it still routes correctly.
payload_string_field() {  # <payload> <key>
  printf '%s' "$1" | awk -v key="$2" '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == key { seen = 1 }
  '
}

payload_native_fields() {  # <payload>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -er '
      select(type == "object")
      | [
          (.hook_event_name | select(type == "string")),
          (.source // "" | select(type == "string")),
          (.reason // "" | select(type == "string")),
          (.session_id | select(type == "string"))
        ]
      | select(all(.[]; test("^[A-Za-z0-9-]*$")))
      | join("|")
    ' 2>/dev/null
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c '
import json
import re
import sys

def reject_constant(value):
    raise ValueError(value)

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(key)
        result[key] = value
    return result

try:
    value = json.load(
        sys.stdin,
        parse_constant=reject_constant,
        object_pairs_hook=reject_duplicates,
    )
    fields = [
        value["hook_event_name"],
        value.get("source", ""),
        value.get("reason", ""),
        value["session_id"],
    ]
    if not isinstance(value, dict):
        raise ValueError("root")
    if not all(isinstance(field, str) for field in fields):
        raise ValueError("field type")
    if not all(re.fullmatch(r"[A-Za-z0-9-]*", field) for field in fields):
        raise ValueError("field value")
    print("|".join(fields))
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
' 2>/dev/null
    return
  fi
  return 1
}

pid_in_resolved_ancestry() {  # <pid>
  local expected=$1 candidate
  while IFS= read -r candidate; do
    [ "$candidate" = "$expected" ] && return 0
  done <<EOF
$FM_SESSION_ANCESTRY_PIDS
EOF
  return 1
}

record_session_replacement_end() {
  local lock_pid lock_session now marker_tmp
  [ "$PAYLOAD_VALID" -eq 1 ] || return 0
  [ "$PAYLOAD_EVENT" = SessionEnd ] || return 0
  case "$PAYLOAD_REASON" in clear|resume) ;; *) return 0 ;; esac
  fm_session_id_valid "$PAYLOAD_SESSION_ID" || return 0
  fm_session_lock_identity || return 0
  [ -n "$FM_SESSION_ID" ] && [ "$FM_SESSION_ID" = "$PAYLOAD_SESSION_ID" ] || return 0
  fm_session_lock_owned_by_self "$STATE" || return 0
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 0
  lock_session=$(fm_session_lock_read_session_id "$STATE" 2>/dev/null || true)
  [ "$lock_session" = "$PAYLOAD_SESSION_ID" ] || return 0
  pid_in_resolved_ancestry "$lock_pid" || return 0
  now=$(date +%s 2>/dev/null || true)
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  marker_tmp=$(mktemp "$STATE/.session-replacement-end.XXXXXX" 2>/dev/null) || return 0
  if ! printf '%s|%s|%s|%s\n' "$lock_pid" "$lock_session" "$PAYLOAD_REASON" "$now" \
    > "$marker_tmp" 2>/dev/null; then
    rm -f "$marker_tmp" 2>/dev/null || true
    return 0
  fi
  mv "$marker_tmp" "$REPLACEMENT_END" 2>/dev/null || rm -f "$marker_tmp" 2>/dev/null || true
}

consume_session_replacement_end() {  # <source>
  local source=$1 consumed marker marker_pid marker_session marker_reason marker_time
  local lock_pid lock_session now age
  [ -f "$REPLACEMENT_END" ] && [ ! -L "$REPLACEMENT_END" ] || return 1
  consumed="$REPLACEMENT_END.consume.$$"
  mv "$REPLACEMENT_END" "$consumed" 2>/dev/null || return 1
  marker=$(cat "$consumed" 2>/dev/null || true)
  rm -f "$consumed" 2>/dev/null || true
  IFS='|' read -r marker_pid marker_session marker_reason marker_time <<EOF
$marker
EOF
  [ "$marker" = "$marker_pid|$marker_session|$marker_reason|$marker_time" ] || return 1
  case "$marker_pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_session_id_valid "$marker_session" || return 1
  case "$marker_reason:$source" in clear:clear|resume:resume) ;; *) return 1 ;; esac
  case "$marker_time" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null || true)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  age=$((now - marker_time))
  [ "$age" -ge 0 ] && [ "$age" -le 60 ] || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  lock_session=$(fm_session_lock_read_session_id "$STATE" 2>/dev/null || true)
  [ "$lock_pid" = "$marker_pid" ] && [ "$lock_session" = "$marker_session" ] || return 1
  pid_in_resolved_ancestry "$lock_pid"
}

session_start_completed() {
  local lock_pid completion_pid
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  [ -f "$COMPLETION_FILE" ] && [ ! -L "$COMPLETION_FILE" ] || return 1
  fm_session_lock_owned_by_self "$STATE" || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  completion_pid=$(cat "$COMPLETION_FILE" 2>/dev/null) || return 1
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$completion_pid" = "$lock_pid" ]
}

if { [ -z "$SOURCE" ] || [ "$SESSION_END" -eq 1 ]; } && [ ! -t 0 ]; then
  # Claude and Codex deliver JSON hook payloads on stdin. SessionStart carries
  # a `source` field with startup|resume|clear|compact.
  # A terminal stdin is skipped outright: a hook always pipes its payload, and
  # an operator running this by hand must not be left waiting on a read.
  PAYLOAD=$(cat 2>/dev/null || true)
  # Cursor loads the tracked Claude settings as well as its own registration,
  # so a Cursor-delivered payload here is the duplicate: bin/fm-sessionstart-
  # cursor.sh already owns that session open and calls this wrapper with an
  # explicit --source and no payload. Running twice would take the helm twice
  # and repeat every startup sweep.
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  SOURCE=$(payload_string_field "$PAYLOAD" source)
  # Retained only for the replacement-acquisition decision below, which needs
  # the event's own provenance rather than a source name any caller can supply.
  PAYLOAD_EVENT=$(payload_string_field "$PAYLOAD" hook_event_name)
  PAYLOAD_REASON=$(payload_string_field "$PAYLOAD" reason)
  PAYLOAD_SESSION_ID=$(payload_string_field "$PAYLOAD" session_id)
  PAYLOAD_DELIVERED=1
  NATIVE_FIELDS=$(payload_native_fields "$PAYLOAD" 2>/dev/null || true)
  if [ -n "$NATIVE_FIELDS" ]; then
    IFS='|' read -r PAYLOAD_EVENT NATIVE_SOURCE PAYLOAD_REASON PAYLOAD_SESSION_ID <<EOF
$NATIVE_FIELDS
EOF
    PAYLOAD_VALID=1
    [ "$SESSION_END" -eq 1 ] || SOURCE=$NATIVE_SOURCE
  fi
fi

if [ "$SESSION_END" -eq 1 ]; then
  [ "$SOURCE_EXPLICIT" -eq 0 ] && record_session_replacement_end
  exit 0
fi

# Repair a stale session sidecar left behind by an in-place replacement, before
# the completion check below reads ownership. Everything here is required: a
# native payload (never an explicit --source), a matching native SessionEnd
# transition, the SessionStart event itself, one of the two in-place replacement
# sources, and a payload session id that is valid and identical to this process's
# resolved Claude identity. `compact`, `fork`, `startup`, an unknown source, and
# a malformed payload all fall through unchanged.
if [ "$SOURCE_EXPLICIT" -eq 0 ] && [ "$PAYLOAD_DELIVERED" -eq 1 ] \
  && [ "$PAYLOAD_VALID" -eq 1 ] && [ "$PAYLOAD_EVENT" = SessionStart ] \
  && fm_session_id_valid "$PAYLOAD_SESSION_ID"; then
  case "$SOURCE" in
    clear|resume)
      if fm_session_lock_identity && [ -n "$FM_SESSION_ID" ] \
        && [ "$FM_SESSION_ID" = "$PAYLOAD_SESSION_ID" ] \
        && consume_session_replacement_end "$SOURCE"; then
        "$SCRIPT_DIR/fm-lock.sh" --session-replacement >/dev/null 2>&1 || true
      fi
      ;;
  esac
fi

case "$SOURCE" in
  resume|reload|fork)
    exec "$SCRIPT_DIR/fm-sessionstart-nudge.sh"
    ;;
  clear|compact)
    if session_start_completed; then
      "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SOURCE" || true
    else
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    fi
    ;;
  *)
    "$SCRIPT_DIR/fm-session-start.sh" --source "$SOURCE" || true
    ;;
esac
exit 0
