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
# Usage: fm-sessionstart-run.sh [--source <source>]
#   --source  The harness's own session-open source. When omitted, the source is
#             read from a Claude/Codex-shaped JSON hook payload on stdin
#             (the `source` field). An unreadable or unrecognized source is
#             treated as `startup`, because taking the helm redundantly is
#             cheap and idempotent while not taking it is the whole bug.
#
# In-place session replacement (Claude /clear, /new, or an interactive /resume)
# keeps this OS process and only issues a NEW session id, so the recorded
# state/.lock.session names a session that no longer exists while state/.lock
# still names this session's own pid. This wrapper is the one grantor of
# bin/fm-lock.sh's narrow replacement-acquisition intent; the lock itself then
# requires the recorded owner to be this hook's own direct Claude client
# process (the vendor-set CLAUDE_PID), which separates that event from a
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
PAYLOAD_EVENT=
PAYLOAD_SESSION_ID=
PAYLOAD_DELIVERED=0
PAYLOAD_VALID=0
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

# Print "hook_event_name|source|session_id" from payload <payload>, or fail.
# One strict parser and one policy on purpose: the document must be exactly one
# complete top-level JSON object, a duplicated field anywhere is rejected, and
# every consumed field must be a string of lock-safe characters. A host with no
# python3 fails closed here - the replacement grant below is then never made -
# while source ROUTING still works through the loose awk extraction above.
payload_native_fields() {  # <payload>
  command -v python3 >/dev/null 2>&1 || return 1
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
    value = json.loads(
        sys.stdin.read(),
        parse_constant=reject_constant,
        object_pairs_hook=reject_duplicates,
    )
    if not isinstance(value, dict):
        raise ValueError("root")
    fields = [
        value["hook_event_name"],
        value.get("source", ""),
        value["session_id"],
    ]
    if not all(isinstance(field, str) for field in fields):
        raise ValueError("field type")
    if not all(re.fullmatch(r"[A-Za-z0-9-]*", field) for field in fields):
        raise ValueError("field value")
    print("|".join(fields))
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
' 2>/dev/null
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

if [ -z "$SOURCE" ] && [ ! -t 0 ]; then
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
  PAYLOAD_DELIVERED=1
  NATIVE_FIELDS=$(payload_native_fields "$PAYLOAD" 2>/dev/null || true)
  if [ -n "$NATIVE_FIELDS" ]; then
    IFS='|' read -r PAYLOAD_EVENT NATIVE_SOURCE PAYLOAD_SESSION_ID <<EOF
$NATIVE_FIELDS
EOF
    PAYLOAD_VALID=1
    SOURCE=$NATIVE_SOURCE
  fi
fi

# Repair a stale session sidecar left behind by an in-place replacement, before
# the completion check below reads ownership. Everything here is required: a
# native payload (never an explicit --source), the SessionStart event itself,
# one of the two in-place replacement sources, and a payload session id that is
# valid and identical to this process's resolved Claude identity. `compact`,
# `fork`, `startup`, an unknown source, and a malformed payload all fall through
# unchanged. bin/fm-lock.sh then owns the process-bound rule: the recorded
# owner must be this hook's own direct Claude client process (CLAUDE_PID) and
# a member of the verified ancestry, so a nested background Claude job that
# also sees `resume` with its own matching ids still changes nothing (PR #74).
if [ "$SOURCE_EXPLICIT" -eq 0 ] && [ "$PAYLOAD_DELIVERED" -eq 1 ] \
  && [ "$PAYLOAD_VALID" -eq 1 ] && [ "$PAYLOAD_EVENT" = SessionStart ] \
  && fm_session_id_valid "$PAYLOAD_SESSION_ID"; then
  case "$SOURCE" in
    clear|resume)
      if fm_session_lock_identity && [ -n "$FM_SESSION_ID" ] \
        && [ "$FM_SESSION_ID" = "$PAYLOAD_SESSION_ID" ]; then
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
