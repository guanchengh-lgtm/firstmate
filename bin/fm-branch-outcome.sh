#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One
#     OutcomeRecord JSON object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false}.
#     Legacy rows without `silent` or with unused status provenance remain
#     valid and are treated as visible.
#     Every read and append validates the complete log as a gap-free sequence;
#     malformed, duplicate, or reordered rows fail closed.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     Pi as a routine merge note, persisted as a sequence-keyed visible captain
#     entry, emitted by the locked session-start replay, or silently consumed
#     there because `silent` is true. Records above the cursor are unread.
#     A captain row advances only after its matching visible entry exists in
#     Pi's session, so reload recovery is idempotent across that crash window.
#     A cursor beyond the validated store tail fails closed.
#   - Processed marker: $STATE/.branch-outcomes-processed holds the highest
#     seq whose captain rows main has ACKNOWLEDGED as processed, separately
#     from the read cursor: reading (the visible entry) is the branch's act,
#     processing (main acting on the outcome and calling its acknowledgement
#     tool) is main's. A captain row between the two markers is "unprocessed":
#     delivered and shown, not yet acted on. Routine rows never wait on this
#     marker. It only advances through an explicit sequence-bound
#     acknowledgement naming a currently unprocessed captain row at or below
#     the read cursor; a routine, unread, or already-processed target is
#     refused. It never moves past the read cursor or backwards, so an
#     unrelated or empty model answer cannot move it. An absent marker reads as
#     0 (every delivered captain row is unprocessed, the safe direction);
#     processed-init is the one-time migration that sets an absent marker to
#     the read cursor so rows delivered before the marker existed are not
#     re-presented. A present marker is validated before the migration returns,
#     and a marker ahead of the read cursor fails closed.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the outcome is delivered to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after handing the records to Pi.
#   fm-branch-outcome.sh unprocessed
#     Print every captain record that is read but not yet processed (raw
#     JSONL, ascending seq). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-processed --through <seq>
#     Advance the processed marker after main acknowledged the captain rows
#     through <seq>; the target itself must be a currently unprocessed captain
#     row at or below the read cursor.
#   fm-branch-outcome.sh processed-init [--held-lock]
#     Create the processed marker at the current read cursor when it does not
#     exist yet; validate a present marker without changing it. --held-lock is
#     only for a descendant
#     of the process holding $STATE/.branch-outcomes.lock (fm-wake-drain.sh may
#     run its redirected presentation body in a subshell on Bash 3.2); it skips
#     the nested acquire so drain's bounded lock wait remains the deadline.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print the leading routine unread records under a
#     labeled header into the locked startup digest, skip rows whose `silent`
#     field is true, and mark those leading routine rows read. Stop before the
#     first captain row because only Pi's sequence-keyed visible entry may
#     acknowledge that row. Prints nothing when nothing replayable is unread.
#     Run it only when the session holds the lock (fm-session-start.sh owns the
#     call site).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
PROCESSED="$STATE/.branch-outcomes-processed"
LOCK="$STATE/.branch-outcomes.lock"
MAX_SAFE_SEQ=9007199254740991

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] | unread | mark-read --through <seq> | unprocessed | mark-processed --through <seq> | processed-init [--held-lock] | list [--recent <n>] | startup-replay" >&2
  exit 2
}

bounded_uint() {
  local value=$1
  case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#value}" -le "${#MAX_SAFE_SEQ}" ] || return 1
  [ "$value" -le "$MAX_SAFE_SEQ" ]
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  [ -e "$CURSOR" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$CURSOR" 2>/dev/null); then
    echo "error: refusing operation because the outcome cursor is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the outcome cursor is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the outcome cursor is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

read_processed() {
  local value
  [ -e "$PROCESSED" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$PROCESSED" 2>/dev/null); then
    echo "error: refusing operation because the processed marker is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the processed marker is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the processed marker is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

last_seq() {
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  jq -Rse '
    def valid:
      type == "object"
      and (
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
        or (
          keys == ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"]
          and (.silent | type) == "boolean"
          and ((.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint <= 9007199254740991 and .statusEndpoint == (.statusEndpoint | floor))
          and ((.statusIdent | type) == "string" and (.statusIdent | test("[\\t\\n]") | not))
        )
      )
      and ((.seq | type) == "number" and .seq >= 1 and .seq <= 9007199254740991 and .seq == (.seq | floor))
      and ((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
      and ((.task | type) == "string" and (.wake | type) == "string")
      and ((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
      and (.silent != true or (.task == "fleet" and .verdict == "routine"));
    if endswith("\n") then split("\n")[:-1]
    else error("unterminated outcome store")
    end
    | map(fromjson)
    | . as $rows
    | if reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid and .seq == ($i + 1)))
      then .[-1].seq
      else error("malformed or non-sequential outcome store")
      end
  ' "$STORE" 2>/dev/null
}

record_seq() { # <jsonl-line>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | jq -er '.seq'
}

print_unread() {
  local cursor last
  cursor=$(read_cursor) || return 1
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson cursor "$cursor" 'select(.seq > $cursor)' "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor processed tmp
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing cursor advancement because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX") || return 1
  printf '%s\n' "$through" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CURSOR" || { rm -f -- "$tmp"; return 1; }
}

write_processed() { # <seq>
  local through=$1 tmp
  tmp=$(mktemp "$STATE/.branch-outcomes-processed.XXXXXX") || return 1
  printf '%s\n' "$through" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$PROCESSED" || { rm -f -- "$tmp"; return 1; }
}

# Captain rows above the processed marker and at or below the read cursor.
print_unprocessed() {
  local cursor processed last
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing read because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson processed "$processed" --argjson cursor "$cursor" \
    'select(.verdict == "captain" and .seq > $processed and .seq <= $cursor)' "$STORE"
}

# Assumes $LOCK is already held. Callers that do not already hold it use the
# processed-init command, which acquires and releases around this body.
processed_init_locked() {
  local store_last cursor_seq processed_seq
  if ! store_last=$(last_seq); then
    echo "error: refusing processed initialization because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if ! cursor_seq=$(read_cursor); then
    return 1
  fi
  if [ "$cursor_seq" -gt "$store_last" ]; then
    echo "error: refusing processed initialization because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ -e "$PROCESSED" ]; then
    if ! processed_seq=$(read_processed); then
      return 1
    fi
    if [ "$processed_seq" -gt "$cursor_seq" ]; then
      echo "error: refusing processed initialization because the processed marker is ahead of the read cursor" >&2
      return 1
    fi
  else
    write_processed "$cursor_seq" || return 1
  fi
}

held_lock_owned_by_ancestor() {
  local owner owner_pid pid parent depth=0
  case "$PPID" in ''|*[!0-9]*|0|1) return 1 ;; esac
  if [ -L "$LOCK" ]; then
    owner=$(fm_lock_link_owner "$LOCK" 2>/dev/null) || return 1
    fm_lock_points_to_owner "$LOCK" "$owner" || return 1
  elif [ -d "$LOCK" ]; then
    owner=$LOCK
  else
    return 1
  fi
  owner_pid=$(cat "$owner/pid" 2>/dev/null) || return 1
  fm_pid_alive "$owner_pid" || return 1

  # Bash 3.2 keeps $$ unchanged in a redirected subshell while that subshell's
  # real pid becomes this script's parent. Walk the bounded live ancestry so
  # that legitimate drain shape is accepted without trusting an arbitrary
  # caller merely because it can name or observe the lock owner.
  pid=$PPID
  while [ "$depth" -lt 64 ]; do
    [ "$pid" = "$owner_pid" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
    depth=$((depth + 1))
  done
  return 1
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    case "$TASK" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    if [ "$SILENT" = true ] && { [ "$TASK" != fleet ] || [ "$VERDICT" != routine ]; }; then
      echo "error: silent outcomes must be routine fleet outcomes" >&2
      exit 2
    fi
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor) || [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome cursor is invalid or ahead of the store" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if print_unread; then
      STATUS=0
    else
      STATUS=$?
    fi
    fm_lock_release "$LOCK"
    exit "$STATUS"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement beyond a valid stored outcome" >&2
      exit 1
    fi
    if ! advance_cursor "$THROUGH"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  unprocessed)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if print_unprocessed; then
      STATUS=0
    else
      STATUS=$?
    fi
    fm_lock_release "$LOCK"
    exit "$STATUS"
    ;;
  mark-processed)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! CURSOR_SEQ=$(read_cursor) || ! PROCESSED_SEQ=$(read_processed); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$PROCESSED_SEQ" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the processed marker is ahead of the read cursor" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement beyond the read cursor ($CURSOR_SEQ)" >&2
      exit 1
    fi
    if [ "$THROUGH" -le "$PROCESSED_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is already processed" >&2
      exit 1
    fi
    VERDICT=$(jq -r --argjson through "$THROUGH" 'select(.seq == $through) | .verdict' "$STORE")
    if [ "$VERDICT" != captain ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is not an unprocessed captain outcome" >&2
      exit 1
    fi
    if ! write_processed "$THROUGH"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  processed-init)
    HELD_LOCK=0
    if [ "${1:-}" = --held-lock ]; then
      HELD_LOCK=1
      shift
    fi
    [ "$#" -eq 0 ] || usage
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_acquire_wait "$LOCK"
    elif ! held_lock_owned_by_ancestor; then
      echo "error: --held-lock requires an ancestor process to own the outcome lock" >&2
      exit 1
    fi
    if ! processed_init_locked; then
      if [ "$HELD_LOCK" -eq 0 ]; then
        fm_lock_release "$LOCK"
      fi
      exit 1
    fi
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_release "$LOCK"
    fi
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ -s "$STORE" ]; then
      tail -n "$RECENT" "$STORE"
    fi
    fm_lock_release "$LOCK"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if UNREAD=$(print_unread); then
      STATUS=0
    else
      STATUS=$?
    fi
    if [ "$STATUS" -ne 0 ]; then
      fm_lock_release "$LOCK"
      exit "$STATUS"
    fi
    if [ -n "$UNREAD" ]; then
      REPLAYABLE=$(printf '%s\n' "$UNREAD" | jq -sc '
        map(.verdict) as $verdicts
        | ($verdicts | index("captain")) as $captain
        | .[0:($captain // length)][]
      ')
      VISIBLE=$(printf '%s\n' "$REPLAYABLE" | jq -c 'select(.silent != true)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$REPLAYABLE" | tail -n 1)")
      if [ -n "$LAST" ] && ! advance_cursor "$LAST"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
    fi
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
