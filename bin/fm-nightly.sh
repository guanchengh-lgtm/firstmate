#!/usr/bin/env bash
# fm-nightly.sh - scheduled Record maintenance and transcript archive.
#
# One command walks a fixed stage table. Local homes use fm-record.sh for
# reconcile, checkpoint, tick, and verify. --record-only uses a plain git
# clone: fetch, merge --ff-only, commit, and push, and scans staged views
# with bin/fm-record-scan.sh chain --dir before commit. Cloud-ok stages
# are skipped in --record-only. Missing nightly.env leaves Record stages
# running and marks archive and compiler stages not-configured.
#
# Usage:
#   fm-nightly.sh run --fm-home PATH [--dry-run] [--now RFC3339]
#                    [--scheduled-date YYYY-MM-DD]
#   fm-nightly.sh run --record-only --record PATH [--dry-run]
#                    [--now RFC3339] [--scheduled-date YYYY-MM-DD]
#   fm-nightly.sh archive --fm-home PATH [--now RFC3339]
#                        [--scheduled-date YYYY-MM-DD]
#   fm-nightly.sh restore --fm-home PATH --target DIR
#                        [--snapshot ID|latest]
#   fm-nightly.sh install --fm-home PATH [--hour H] [--minute M]
#                        [--code-root PATH] [--bootstrap]
#   fm-nightly.sh status --fm-home PATH
#   fm-nightly.sh --help
#
# --fm-home and --record-only/--record are mutually exclusive. A home is
# never inferred from the working directory. --now is RFC3339 UTC, for
# example 2026-09-07T03:00:00Z. --scheduled-date defaults to the UTC date
# of --now. --dry-run prints one dry-run line per stage and writes nothing.
#
# Config is $FM_HOME/config/nightly.env, KEY=VALUE lines, parsed without
# source. Keys:
#   NIGHTLY_RESTIC_REPO (default rclone:fm-transcripts:restic)
#   NIGHTLY_RCLONE_CONFIG (absolute path; required for archive)
#   NIGHTLY_RESTIC_PASSWORD_COMMAND (default
#     /usr/bin/security find-generic-password -s com.firstmate.transcript-archive -a $USER -w)
#   NIGHTLY_ARCHIVE_HOST (default hostname -s)
#   NIGHTLY_TRANSCRIPT_ROOTS (space-separated family specs relative to
#     $HOME, or absolute). Default families:
#     .claude/projects
#     .codex/sessions
#     .pi/agent/sessions
#     .cursor/projects/*/agent-transcripts
#     .grok/sessions
#     Only the * in .cursor/projects/*/agent-transcripts is expanded,
#     with nullglob, into real directories passed after --. Zero matches
#     are a missing family. A symlinked family root is symlink-skipped.
#   NIGHTLY_RUN_BOUND_SECONDS (default 7200)
#   NIGHTLY_STAGE_BOUND_SECONDS (default 1800)
#   NIGHTLY_GBRAIN_SYNC_CMD (empty -> not-configured, awaiting T17)
#   NIGHTLY_GRAPHIFY_REPOS (empty -> not-configured, awaiting T10)
#   NIGHTLY_HOUR NIGHTLY_MINUTE (install defaults 3 and 0)
#
# Local run files live under <Record>/.git/nightly/ and are not tracked:
# lock, stages.tsv, last-attempt, last-complete, archive.json,
# weekly-check.json. Tracked writes stay under wiki/views/.
# Stage rows collect in a private temp file until the lock is held, so a
# busy run (exit 3) touches none of them and the in-flight run's table and
# last-attempt survive. A run that exits before every stage was walked
# records "aborted failed run-aborted" and result=failed, never a
# last-complete. When NIGHTLY_RUN_BOUND_SECONDS expires, the in-flight
# stage's process tree is terminated before the lock is released, and the
# run records "interrupted interrupted bound-hit".
#
# Stage table (name|scope). scope is local, record, or cloud-ok.
# --dry-run and --record-only derive skipped lines from this table.
#   config|local
#   lock|local
#   reconcile-local|cloud-ok   fm-record.sh on a home; skipped as cloud scope
#                              under --record-only
#   reconcile|record           git fetch/ff-only on --record-only; skipped
#                              as home path on a local home
#   lint|record
#   rollout|record
#   fold|record
#   views|record               skipped when RECORD_WRITES=0
#   gbrain|cloud-ok
#   graphify|cloud-ok
#   archive|cloud-ok
#   weekly-check|cloud-ok
#   injected-measures|cloud-ok skipped when RECORD_WRITES=0
#   drift|record
#   receipt|record
#   checkpoint|record
#   verify|record
#
# archive --fm-home runs only config, lock, archive, and weekly-check.
# restic backup uses --compression auto --json --host HOST --tag
# fm-transcripts and never forget, prune, unlock, or rewrite. restic
# exit 0 records last_complete_snapshot. exit 3 is finding incomplete
# and keeps the snapshot out of last_complete_snapshot. A previously
# present family that is now absent is finding coverage-regressed; every
# family absent is finding no-sources and restic is not invoked.
# Raw restic and rclone stderr never enter the Record. stages.tsv holds
# exit codes and a class string of at most 200 characters.
#
# restore refuses a non-empty target (exit 2). A missing target is
# created. The default snapshot is archive.json last_complete_snapshot.
# latest is used only when --snapshot latest is passed. Missing id and
# no --snapshot is exit 2.
#
# install renders bin/launchd/com.firstmate.nightly.plist.template to
# FM_NIGHTLY_PLIST (default ~/Library/LaunchAgents/com.firstmate.nightly.plist).
# An existing plist without the firstmate-nightly-v1 marker is left
# untouched (exit 8). code-root must be a primary checkout whose .git is
# a directory, not a worktree file, and must contain executable
# bin/fm-nightly.sh. --bootstrap runs launchctl bootout then bootstrap
# gui/$UID. Logs use FM_NIGHTLY_LOG_DIR (default ~/Library/Logs).
#
# Exit codes:
#   0  no failed/timeout/interrupted stage, or dry-run/install/status/restore ok
#   1  a stage failed, timed out, or was interrupted
#   2  usage, config parse failure, or restore refusal
#   3  busy (nightly lock held)
#   8  existing LaunchAgent is not the nightly job
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RECORD_SH="$FM_ROOT/bin/fm-record.sh"
MAINTAIN_PY="$FM_ROOT/bin/fm-maintain.py"
SCAN_SH="$FM_ROOT/bin/fm-record-scan.sh"

STAGES=(
  "config|local"
  "lock|local"
  "reconcile-local|cloud-ok"
  "reconcile|record"
  "lint|record"
  "rollout|record"
  "fold|record"
  "views|record"
  "gbrain|cloud-ok"
  "graphify|cloud-ok"
  "archive|cloud-ok"
  "weekly-check|cloud-ok"
  "injected-measures|cloud-ok"
  "drift|record"
  "receipt|record"
  "checkpoint|record"
  "verify|record"
)

CMD=
FM_HOME_ARG=
RECORD_ARG=
RECORD_ONLY=0
DRY_RUN=0
NOW_ARG=
SCHEDULED_DATE=
TARGET=
SNAPSHOT=
HOUR=
MINUTE=
HOUR_SET=0
MINUTE_SET=0
CODE_ROOT=
BOOTSTRAP=0
CONFIG_PRESENT=0
RECORD_WRITES=1
LOCK_HELD=0
LOCK_PATH=
RUN_STARTED=0
RUN_COMPLETED=0
STAGE_PID=
LOCK_LIBS_LOADED=0
FINALIZED=0
INTERRUPTED=0
DEADLINE_PID=
DEADLINE_FLAG=
STAGE_STDOUT=
STAGE_STDERR=
STAGE_RC=0
STAGE_ELAPSED=0
STAGE_OUTCOME=
STAGE_DETAIL=
STAGE_FINDING_CODES=
VERIFY_LINE=
LINT_JSON=
ROLLOUT_JSON=
NIGHTLY_DIR=
RECORD=
HOME_DIR=
TMP_DIR=
STAGES_TSV=
COVERAGE=local
RECEIPT_HOST=cloud
CONCURRENT_PATHS=
REGRESSED=0
PREV_PRESENT=
FAMILIES_FILE=
SOURCES=()
FAMILY_ROWS=()

NIGHTLY_RESTIC_REPO=rclone:fm-transcripts:restic
NIGHTLY_RCLONE_CONFIG=
NIGHTLY_RESTIC_PASSWORD_COMMAND="/usr/bin/security find-generic-password -s com.firstmate.transcript-archive -a ${USER:-} -w"
NIGHTLY_ARCHIVE_HOST=
NIGHTLY_TRANSCRIPT_ROOTS=".claude/projects .codex/sessions .pi/agent/sessions .cursor/projects/*/agent-transcripts .grok/sessions"
: "${NIGHTLY_RUN_BOUND_SECONDS:=7200}"
: "${NIGHTLY_STAGE_BOUND_SECONDS:=1800}"
NIGHTLY_GBRAIN_SYNC_CMD=
NIGHTLY_GRAPHIFY_REPOS=
NIGHTLY_HOUR=3
NIGHTLY_MINUTE=0
NIGHTLY_TICK_RETRY_SECONDS=${NIGHTLY_TICK_RETRY_SECONDS:-5}
NIGHTLY_TICK_RETRIES=${NIGHTLY_TICK_RETRIES:-3}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  local code=$1
  shift
  printf 'fm-nightly: %s\n' "$*" >&2
  exit "$code"
}

physical_dir() {
  cd -P -- "$1" 2>/dev/null && pwd -P
}

require_abs() {
  local label=$1 path=$2
  case "$path" in
    /*) ;;
    *) die 2 "$label must be an absolute path" ;;
  esac
  case "$path" in
    *$'\n'* | *$'\r'*) die 2 "$label must be one line" ;;
  esac
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\\&apos;/g"
}

sed_replacement() {
  sed -e 's/[\\&|]/\\&/g'
}

require_lock_libs() {
  [ "$LOCK_LIBS_LOADED" -eq 0 ] || return 0
  export FM_HOME
  export FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  export FM_ROOT_OVERRIDE="$FM_ROOT"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  LOCK_LIBS_LOADED=1
}

class_string() {
  local text=$1
  text=$(printf '%s' "$text" | tr '\n\r\t' '   ')
  if [ "${#text}" -gt 200 ]; then
    text=$(printf '%s' "$text" | cut -c1-200)
  fi
  printf '%s' "$text"
}

stage_record() {
  local name=$1 outcome=$2 elapsed=$3 detail=$4
  detail=$(class_string "$detail")
  [ -n "$STAGES_TSV" ] || return 0
  mkdir -p "$(dirname "$STAGES_TSV")"
  printf '%s\t%s\t%s\t%s\n' "$name" "$outcome" "$elapsed" "$detail" >> "$STAGES_TSV"
}

stage_rerecord_last() {
  local name=$1 outcome=$2 elapsed=$3 detail=$4 tmp
  [ -f "$STAGES_TSV" ] || { stage_record "$name" "$outcome" "$elapsed" "$detail"; return 0; }
  tmp="$STAGES_TSV.tmp.$$"
  awk -F '\t' -v n="$name" 'BEGIN { OFS="\t" } $1 == n { next } { print }' "$STAGES_TSV" > "$tmp"
  mv -f "$tmp" "$STAGES_TSV"
  stage_record "$name" "$outcome" "$elapsed" "$detail"
}

map_stage_outcome() {
  local rc=$1
  STAGE_OUTCOME=failed
  STAGE_DETAIL="exit-$rc"
  if [ "$rc" -eq 0 ]; then
    STAGE_OUTCOME=ok
    STAGE_DETAIL=
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    STAGE_OUTCOME=timeout
    STAGE_DETAIL="bound-hit"
    return 0
  fi
  if [ -n "$STAGE_FINDING_CODES" ]; then
    case " $STAGE_FINDING_CODES " in
      *" $rc "*)
        STAGE_OUTCOME=finding
        STAGE_DETAIL=${STAGE_FINDING_DETAIL:-"exit-$rc"}
        return 0
        ;;
    esac
  fi
  case "$rc" in
    7) STAGE_DETAIL="diverged" ;;
    6) STAGE_DETAIL="remote-unknown" ;;
    4) STAGE_DETAIL="local-changes" ;;
  esac
}

run_external() {
  local bound=$1 start finish
  shift
  STAGE_RC=0
  STAGE_ELAPSED=0
  : > "$STAGE_STDOUT"
  : > "$STAGE_STDERR"
  start=$(date +%s)
  set +e
  fm_run_timed "$bound" "$@" > "$STAGE_STDOUT" 2> "$STAGE_STDERR" &
  STAGE_PID=$!
  wait "$STAGE_PID"
  STAGE_RC=$?
  STAGE_PID=
  set -e
  finish=$(date +%s)
  STAGE_ELAPSED=$((finish - start))
  if [ "$STAGE_ELAPSED" -lt 0 ]; then
    STAGE_ELAPSED=0
  fi
}

stage_run() {
  local name=$1 bound=$2
  shift 2
  run_external "$bound" "$@"
  map_stage_outcome "$STAGE_RC"
  stage_record "$name" "$STAGE_OUTCOME" "$STAGE_ELAPSED" "$STAGE_DETAIL"
}

parse_now() {
  local raw=$1
  python3 -c '
import sys
from datetime import datetime
raw = sys.argv[1]
for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S+00:00"):
    try:
        dt = datetime.strptime(raw, fmt)
        print(dt.strftime("%Y-%m-%dT%H:%M:%SZ"))
        print(dt.strftime("%Y-%m-%d"))
        sys.exit(0)
    except ValueError:
        pass
sys.exit(1)
' "$raw"
}

date_plus_days() {
  python3 -c '
from datetime import date, timedelta
import sys
print(date.fromisoformat(sys.argv[1]) + timedelta(days=int(sys.argv[2])))
' "$1" "$2"
}

assign_config() {
  local key=$1 val=$2
  case "$key" in
    NIGHTLY_RESTIC_REPO) NIGHTLY_RESTIC_REPO=$val ;;
    NIGHTLY_RCLONE_CONFIG) NIGHTLY_RCLONE_CONFIG=$val ;;
    NIGHTLY_RESTIC_PASSWORD_COMMAND) NIGHTLY_RESTIC_PASSWORD_COMMAND=$val ;;
    NIGHTLY_ARCHIVE_HOST) NIGHTLY_ARCHIVE_HOST=$val ;;
    NIGHTLY_TRANSCRIPT_ROOTS) NIGHTLY_TRANSCRIPT_ROOTS=$val ;;
    NIGHTLY_RUN_BOUND_SECONDS) NIGHTLY_RUN_BOUND_SECONDS=$val ;;
    NIGHTLY_STAGE_BOUND_SECONDS) NIGHTLY_STAGE_BOUND_SECONDS=$val ;;
    NIGHTLY_GBRAIN_SYNC_CMD) NIGHTLY_GBRAIN_SYNC_CMD=$val ;;
    NIGHTLY_GRAPHIFY_REPOS) NIGHTLY_GRAPHIFY_REPOS=$val ;;
    NIGHTLY_HOUR) NIGHTLY_HOUR=$val ;;
    NIGHTLY_MINUTE) NIGHTLY_MINUTE=$val ;;
    *) ;;
  esac
}

parse_nightly_env() {
  local file=$1 line key val
  [ -f "$file" ] || return 0
  CONFIG_PRESENT=1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '' | \#*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *) die 2 "invalid nightly.env line" ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      '' | *[!A-Z0-9_]*) die 2 "invalid nightly.env key" ;;
    esac
    assign_config "$key" "$val"
  done < "$file"
}

require_positive_int() {
  local label=$1 value=$2
  case "$value" in
    '' | *[!0-9]* | 0) die 2 "invalid $label" ;;
  esac
}

require_hour() {
  case "$1" in
    '' | *[!0-9]*) die 2 "hour must be an integer 0-23" ;;
  esac
  [ "$1" -ge 0 ] && [ "$1" -le 23 ] || die 2 "hour must be an integer 0-23"
}

require_minute() {
  case "$1" in
    '' | *[!0-9]*) die 2 "minute must be an integer 0-59" ;;
  esac
  [ "$1" -ge 0 ] && [ "$1" -le 59 ] || die 2 "minute must be an integer 0-59"
}

load_config() {
  local env_file=
  if [ "$RECORD_ONLY" -eq 0 ] && [ -n "$FM_HOME" ]; then
    env_file="$FM_HOME/config/nightly.env"
    parse_nightly_env "$env_file"
  fi
  require_positive_int NIGHTLY_RUN_BOUND_SECONDS "$NIGHTLY_RUN_BOUND_SECONDS"
  require_positive_int NIGHTLY_STAGE_BOUND_SECONDS "$NIGHTLY_STAGE_BOUND_SECONDS"
  if [ -n "$NIGHTLY_RCLONE_CONFIG" ]; then
    require_abs NIGHTLY_RCLONE_CONFIG "$NIGHTLY_RCLONE_CONFIG"
  fi
  if [ -z "$NIGHTLY_ARCHIVE_HOST" ]; then
    NIGHTLY_ARCHIVE_HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'localhost\n')
  fi
  if [ "$RECORD_ONLY" -eq 1 ]; then
    RECEIPT_HOST=${NIGHTLY_ARCHIVE_HOST:-cloud}
    COVERAGE=cloud
  else
    RECEIPT_HOST=${NIGHTLY_ARCHIVE_HOST:-cloud}
    COVERAGE=local
  fi
  if [ "$RECORD_ONLY" -eq 1 ]; then
    RECEIPT_HOST=cloud
    if [ -n "${NIGHTLY_ARCHIVE_HOST:-}" ] && [ "$CONFIG_PRESENT" -eq 1 ]; then
      RECEIPT_HOST=$NIGHTLY_ARCHIVE_HOST
    fi
  fi
}

archive_ready() {
  [ "$CONFIG_PRESENT" -eq 1 ] || return 1
  [ -n "$NIGHTLY_RCLONE_CONFIG" ] || return 1
  [ -f "$NIGHTLY_RCLONE_CONFIG" ] || return 1
  command -v restic >/dev/null 2>&1 || return 1
  command -v rclone >/dev/null 2>&1 || return 1
  return 0
}

is_cursor_spec() {
  [ "$1" = ".cursor/projects/*/agent-transcripts" ]
}

family_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$HOME_DIR" "$1" ;;
  esac
}

path_via_symlink() {
  local current=$1
  while [ -n "$current" ] && [ "$current" != / ] && [ "$current" != "$HOME_DIR" ]; do
    if [ -L "$current" ]; then
      return 0
    fi
    current=$(dirname "$current")
  done
  return 1
}

append_family_row() {
  FAMILY_ROWS+=("$1	$2")
}

collect_cursor_matches() {
  local prefix="$HOME_DIR/.cursor/projects" d
  CURSOR_MATCHES=()
  [ -d "$prefix" ] || return 0
  shopt -s nullglob
  for d in "$prefix"/*/agent-transcripts; do
    CURSOR_MATCHES+=("$d")
  done
  shopt -u nullglob
}

collect_transcript_sources() {
  local spec path coverage d any=0
  SOURCES=()
  FAMILY_ROWS=()
  set -f
  # shellcheck disable=SC2086
  set -- $NIGHTLY_TRANSCRIPT_ROOTS
  set +f
  for spec in "$@"; do
    if is_cursor_spec "$spec"; then
      collect_cursor_matches
      coverage=missing
      if [ "${#CURSOR_MATCHES[@]}" -eq 0 ]; then
        append_family_row "$spec" missing
        continue
      fi
      any=0
      for d in "${CURSOR_MATCHES[@]}"; do
        if path_via_symlink "$d"; then
          continue
        fi
        if [ -d "$d" ]; then
          SOURCES+=("$d")
          any=1
        fi
      done
      if [ "$any" -eq 1 ]; then
        coverage=present
      else
        coverage=symlink-skipped
      fi
      append_family_row "$spec" "$coverage"
      continue
    fi
    path=$(family_path "$spec")
    if path_via_symlink "$path"; then
      append_family_row "$spec" symlink-skipped
      continue
    fi
    if [ -d "$path" ]; then
      SOURCES+=("$path")
      append_family_row "$spec" present
    else
      append_family_row "$spec" missing
    fi
  done
}

read_prev_present() {
  local archive=$NIGHTLY_DIR/archive.json
  PREV_PRESENT=
  [ -f "$archive" ] || return 0
  PREV_PRESENT=$(python3 - "$archive" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
families = data.get("families") or {}
names = []
for key, meta in families.items():
    cov = meta.get("coverage") if isinstance(meta, dict) else meta
    if cov == "present":
        names.append(key)
print("\n".join(names))
PY
)
}

detect_regression() {
  local spec cov row found
  REGRESSED=0
  [ -n "$PREV_PRESENT" ] || return 0
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    found=0
    cov=missing
    for row in "${FAMILY_ROWS[@]+"${FAMILY_ROWS[@]}"}"; do
      case "$row" in
        "$spec	"*)
          cov=${row#*	}
          found=1
          ;;
      esac
    done
    if [ "$found" -eq 0 ] || [ "$cov" != present ]; then
      REGRESSED=1
      return 0
    fi
  done <<EOF
$PREV_PRESENT
EOF
}

write_archive_json() {
  local dest=$1 snap=$2 last_exit=$3 last_result=$4
  FAMILIES_FILE="$TMP_DIR/families.tsv"
  : > "$FAMILIES_FILE"
  for row in "${FAMILY_ROWS[@]+"${FAMILY_ROWS[@]}"}"; do
    printf '%s\n' "$row" >> "$FAMILIES_FILE"
  done
  python3 - "$dest" "$snap" "$last_exit" "$last_result" "$FAMILIES_FILE" <<'PY'
import json, os, sys, tempfile
dest, snap, last_exit, last_result, famfile = sys.argv[1:6]
families = {}
if os.path.exists(famfile):
    with open(famfile, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or "\t" not in line:
                continue
            spec, cov = line.split("\t", 1)
            families[spec] = {"coverage": cov}
payload = {
    "last_complete_snapshot": snap or None,
    "last_exit": int(last_exit),
    "last_result": last_result,
    "families": families,
}
directory = os.path.dirname(dest)
fd, tmp = tempfile.mkstemp(prefix="archive.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(payload, out, indent=2, sort_keys=True)
        out.write("\n")
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

read_archive_snapshot() {
  local dest=$NIGHTLY_DIR/archive.json
  [ -f "$dest" ] || return 0
  python3 - "$dest" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
snap = data.get("last_complete_snapshot") or ""
print(snap)
PY
}

read_weekly_state() {
  local dest=$NIGHTLY_DIR/weekly-check.json state
  WEEKLY_SUBSET=1
  WEEKLY_NEXT_DUE=
  [ -f "$dest" ] || return 0
  state=$(python3 - "$dest" <<'PY'
import json, re, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
subset = data.get("subset", 1)
try:
    subset = int(subset)
except Exception:
    subset = 1
if subset < 1 or subset > 4:
    subset = 1
nd = data.get("next_due")
if not isinstance(nd, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", nd):
    nd = ""
print(subset)
print(nd)
PY
) || return 0
  [ -n "$state" ] || return 0
  WEEKLY_SUBSET=$(printf '%s\n' "$state" | sed -n '1p')
  WEEKLY_NEXT_DUE=$(printf '%s\n' "$state" | sed -n '2p')
}

write_weekly_json() {
  local dest=$1 subset=$2 next_due=$3 last=$4
  python3 - "$dest" "$subset" "$next_due" "$last" <<'PY'
import json, os, sys, tempfile
dest, subset, next_due, last = sys.argv[1:5]
payload = {"subset": int(subset), "next_due": next_due, "last_result": last}
directory = os.path.dirname(dest)
fd, tmp = tempfile.mkstemp(prefix="weekly.", suffix=".json", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(payload, out, indent=2, sort_keys=True)
        out.write("\n")
    os.replace(tmp, dest)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

parse_snapshot_id() {
  python3 - "$1" <<'PY'
import json, sys
sid = ""
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("message_type") == "summary" and obj.get("snapshot_id"):
            sid = obj["snapshot_id"]
print(sid)
PY
}

export_restic_env() {
  export RESTIC_PASSWORD_COMMAND="$NIGHTLY_RESTIC_PASSWORD_COMMAND"
  if [ -n "$NIGHTLY_RCLONE_CONFIG" ]; then
    export RCLONE_CONFIG="$NIGHTLY_RCLONE_CONFIG"
  fi
}

skip_reason() {
  local name=$1 scope=$2
  if [ "$RECORD_ONLY" -eq 1 ] && [ "$scope" = cloud-ok ]; then
    printf 'cloud scope'
    return 0
  fi
  if [ "$RECORD_ONLY" -eq 0 ] && [ "$name" = reconcile ]; then
    printf 'home path'
    return 0
  fi
  case "$name" in
    archive | weekly-check)
      if ! archive_ready; then
        printf 'not-configured'
        return 0
      fi
      ;;
    gbrain)
      if [ -z "$NIGHTLY_GBRAIN_SYNC_CMD" ]; then
        printf 'not-configured'
        return 0
      fi
      ;;
    graphify)
      if [ -z "$NIGHTLY_GRAPHIFY_REPOS" ]; then
        printf 'not-configured'
        return 0
      fi
      ;;
  esac
  return 0
}

would_text() {
  local name=$1
  case "$name" in
    config) printf 'validate nightly.env' ;;
    lock) printf 'acquire nightly lock' ;;
    reconcile-local) printf 'fm-record.sh reconcile' ;;
    reconcile) printf 'git fetch and merge --ff-only' ;;
    lint) printf 'fm-maintain.py lint' ;;
    rollout) printf 'fm-maintain.py rollout advance' ;;
    fold) printf 'fm-maintain.py fold' ;;
    views) printf 'fm-maintain.py views --apply' ;;
    gbrain) printf 'NIGHTLY_GBRAIN_SYNC_CMD' ;;
    graphify) printf 'graphify update' ;;
    archive) printf 'restic backup' ;;
    weekly-check) printf 'restic check --read-data-subset' ;;
    injected-measures) printf 'fm-maintain.py measure --apply' ;;
    drift) printf 'git status --porcelain' ;;
    receipt) printf 'fm-maintain.py receipt --apply' ;;
    checkpoint) printf 'checkpoint and push' ;;
    verify) printf 'fm-record.sh verify' ;;
    *) printf 'run' ;;
  esac
}

print_dry_run() {
  local spec name scope reason text
  for spec in "${STAGES[@]}"; do
    IFS='|' read -r name scope <<< "$spec"
    reason=$(skip_reason "$name" "$scope" || true)
    if [ -n "$reason" ]; then
      printf 'dry-run\t%s\twould: skip %s\n' "$name" "$reason"
    else
      text=$(would_text "$name")
      printf 'dry-run\t%s\twould: %s\n' "$name" "$text"
    fi
  done
}

write_last_attempt() {
  local result=$1 dest=$NIGHTLY_DIR/last-attempt
  {
    printf 'date=%s\n' "$SCHEDULED_DATE"
    printf 'result=%s\n' "$result"
    if [ -n "$VERIFY_LINE" ]; then
      printf 'verify=%s\n' "$VERIFY_LINE"
    fi
  } > "$dest"
}

write_last_complete() {
  printf 'date=%s\n' "$SCHEDULED_DATE" > "$NIGHTLY_DIR/last-complete"
}

tsv_has_problem() {
  [ -f "$STAGES_TSV" ] || return 1
  awk -F '\t' '$2 == "failed" || $2 == "timeout" || $2 == "interrupted" { found=1 } END { exit found ? 0 : 1 }' "$STAGES_TSV"
}

release_nightly_lock() {
  if [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCK_PATH" ]; then
    fm_lock_release "$LOCK_PATH" || true
    LOCK_HELD=0
  fi
}

signal_tree() {
  local sig=$1 pid=$2 child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    signal_tree "$sig" "$child"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}

stop_stage_child() {
  [ -n "$STAGE_PID" ] || return 0
  signal_tree TERM "$STAGE_PID"
  sleep 0.2
  signal_tree KILL "$STAGE_PID"
  wait "$STAGE_PID" 2>/dev/null || true
  STAGE_PID=
}

finalize_run() {
  local result=ok
  [ "$FINALIZED" -eq 0 ] || return 0
  FINALIZED=1
  if [ -n "$DEADLINE_PID" ]; then
    pkill -TERM -P "$DEADLINE_PID" 2>/dev/null || true
    kill -TERM "$DEADLINE_PID" 2>/dev/null || true
    DEADLINE_PID=
  fi
  stop_stage_child
  if [ "$INTERRUPTED" -eq 1 ] || [ -f "${DEADLINE_FLAG:-}" ]; then
    if [ -n "$STAGES_TSV" ]; then
      stage_record interrupted interrupted 0 bound-hit
    fi
  elif [ "$RUN_STARTED" -eq 1 ] && [ "$RUN_COMPLETED" -eq 0 ]; then
    stage_record aborted failed 0 run-aborted
  fi
  if [ "$RUN_STARTED" -eq 1 ] && [ "$LOCK_HELD" -eq 1 ]; then
    if tsv_has_problem; then
      result=failed
    fi
    write_last_attempt "$result"
    if [ "$result" = ok ]; then
      write_last_complete
    fi
  fi
  release_nightly_lock
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

on_term() {
  INTERRUPTED=1
  exit 1
}

stage_config() {
  local detail=ok
  if [ "$RECORD_ONLY" -eq 1 ]; then
    [ -d "$RECORD/.git" ] || die 2 "record is not a git clone"
  else
    [ -d "$RECORD/.git" ] || die 2 "FM_HOME data/.git is missing"
  fi
  if [ "$CONFIG_PRESENT" -eq 0 ]; then
    detail=not-configured
  fi
  mkdir -p "$NIGHTLY_DIR"
  stage_record config ok 0 "$detail"
}

stage_lock() {
  require_lock_libs
  LOCK_PATH="$NIGHTLY_DIR/lock"
  if ! fm_lock_try_acquire "$LOCK_PATH"; then
    printf 'busy\n'
    exit 3
  fi
  LOCK_HELD=1
  if [ "$STAGES_TSV" != "$NIGHTLY_DIR/stages.tsv" ]; then
    cat "$STAGES_TSV" > "$NIGHTLY_DIR/stages.tsv"
    STAGES_TSV="$NIGHTLY_DIR/stages.tsv"
  fi
  stage_record lock ok 0 acquired
}

record_state_from_output() {
  local out=$1
  case "$out" in
    *'state=local-changes'*) printf 'local-changes' ;;
    *'state=diverged'*) printf 'diverged' ;;
    *'state=remote-unknown'*) printf 'remote-unknown' ;;
    *'state=reconciled'*) printf 'reconciled' ;;
    *'state=disabled'*) printf 'disabled' ;;
    *) printf 'unknown' ;;
  esac
}

stage_reconcile_local() {
  local out rc=0 state
  [ -x "$RECORD_SH" ] || { stage_record reconcile-local failed 0 record-missing; RECORD_WRITES=0; return 0; }
  export FM_HOME
  export FM_ROOT_OVERRIDE="$FM_ROOT"
  STAGE_FINDING_CODES=
  stage_run reconcile-local "$NIGHTLY_STAGE_BOUND_SECONDS" env \
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_DATA_OVERRIDE="$RECORD" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
    "$RECORD_SH" reconcile
  out=$(cat "$STAGE_STDOUT" 2>/dev/null || true)
  state=$(record_state_from_output "$out")
  if [ "$STAGE_RC" -eq 4 ] || [ "$state" = local-changes ]; then
    stage_run reconcile-local "$NIGHTLY_STAGE_BOUND_SECONDS" env \
      FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_DATA_OVERRIDE="$RECORD" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
      "$RECORD_SH" checkpoint --reason maintain --summary "$SCHEDULED_DATE: pre-maintenance capture"
    if [ "$STAGE_OUTCOME" != ok ]; then
      RECORD_WRITES=0
      return 0
    fi
    stage_run reconcile-local "$NIGHTLY_STAGE_BOUND_SECONDS" env \
      FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_DATA_OVERRIDE="$RECORD" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
      "$RECORD_SH" reconcile
    out=$(cat "$STAGE_STDOUT" 2>/dev/null || true)
    state=$(record_state_from_output "$out")
  fi
  case "$state" in
    reconciled | disabled)
      stage_rerecord_last reconcile-local ok "$STAGE_ELAPSED" "$state"
      ;;
    diverged | remote-unknown)
      RECORD_WRITES=0
      stage_rerecord_last reconcile-local failed "$STAGE_ELAPSED" "$state"
      ;;
    *)
      if [ "$STAGE_OUTCOME" != ok ]; then
        RECORD_WRITES=0
      fi
      ;;
  esac
}

stage_reconcile_git() {
  local branch ahead=0 behind=0
  branch=$(git -C "$RECORD" rev-parse --abbrev-ref HEAD)
  export GIT_TERMINAL_PROMPT=0
  stage_run reconcile "$NIGHTLY_STAGE_BOUND_SECONDS" git -C "$RECORD" fetch origin
  if [ "$STAGE_OUTCOME" != ok ]; then
    RECORD_WRITES=0
    stage_rerecord_last reconcile failed "$STAGE_ELAPSED" remote-unknown
    return 0
  fi
  if [ -n "$(git -C "$RECORD" status --porcelain)" ]; then
    RECORD_WRITES=0
    stage_rerecord_last reconcile failed "$STAGE_ELAPSED" local-changes
    return 0
  fi
  if git -C "$RECORD" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    ahead=$(git -C "$RECORD" rev-list --count "origin/$branch..HEAD")
    behind=$(git -C "$RECORD" rev-list --count "HEAD..origin/$branch")
  else
    RECORD_WRITES=0
    stage_rerecord_last reconcile failed 0 remote-unknown
    return 0
  fi
  if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
    RECORD_WRITES=0
    stage_rerecord_last reconcile failed 0 diverged
    return 0
  fi
  if [ "$behind" -gt 0 ]; then
    stage_run reconcile "$NIGHTLY_STAGE_BOUND_SECONDS" git -C "$RECORD" merge --ff-only "origin/$branch"
    if [ "$STAGE_OUTCOME" != ok ]; then
      RECORD_WRITES=0
      stage_rerecord_last reconcile failed "$STAGE_ELAPSED" fast-forward
      return 0
    fi
    stage_rerecord_last reconcile ok "$STAGE_ELAPSED" fast-forwarded
    return 0
  fi
  if [ "$ahead" -gt 0 ]; then
    stage_rerecord_last reconcile ok 0 ahead
    return 0
  fi
  stage_rerecord_last reconcile ok 0 equal
}

require_maintain() {
  if [ ! -f "$MAINTAIN_PY" ]; then
    return 1
  fi
  return 0
}

stage_lint() {
  if ! require_maintain; then
    stage_record lint failed 0 maintain-missing
    return 0
  fi
  STAGE_FINDING_CODES="1"
  STAGE_FINDING_DETAIL=lint
  stage_run lint "$NIGHTLY_STAGE_BOUND_SECONDS" python3 "$MAINTAIN_PY" lint \
    --record "$RECORD" --now "$NOW_ARG" --format json
  STAGE_FINDING_CODES=
  STAGE_FINDING_DETAIL=
  if [ -s "$STAGE_STDOUT" ]; then
    cp "$STAGE_STDOUT" "$LINT_JSON"
  else
    printf '{}\n' > "$LINT_JSON"
  fi
}

stage_rollout() {
  if ! require_maintain; then
    stage_record rollout failed 0 maintain-missing
    return 0
  fi
  [ -f "$LINT_JSON" ] || printf '{}\n' > "$LINT_JSON"
  stage_run rollout "$NIGHTLY_STAGE_BOUND_SECONDS" python3 "$MAINTAIN_PY" rollout advance \
    --record "$RECORD" --now "$NOW_ARG" --lint-json "$LINT_JSON" \
    --scheduled-date "$SCHEDULED_DATE" --coverage "$COVERAGE"
  if python3 "$MAINTAIN_PY" rollout status --record "$RECORD" --format json > "$ROLLOUT_JSON" 2>/dev/null; then
    :
  else
    printf '-\n' > "$ROLLOUT_JSON"
  fi
}

stage_fold() {
  if ! require_maintain; then
    stage_record fold failed 0 maintain-missing
    return 0
  fi
  stage_run fold "$NIGHTLY_STAGE_BOUND_SECONDS" python3 "$MAINTAIN_PY" fold \
    --record "$RECORD" --now "$NOW_ARG"
}

stage_views() {
  if [ "$RECORD_WRITES" -eq 0 ]; then
    stage_record views skipped 0 writes-disabled
    return 0
  fi
  if ! require_maintain; then
    stage_record views failed 0 maintain-missing
    return 0
  fi
  stage_run views "$NIGHTLY_STAGE_BOUND_SECONDS" python3 "$MAINTAIN_PY" views \
    --record "$RECORD" --now "$NOW_ARG" --apply
}

stage_gbrain() {
  stage_run gbrain "$NIGHTLY_STAGE_BOUND_SECONDS" bash -c "$NIGHTLY_GBRAIN_SYNC_CMD"
}

stage_graphify() {
  local repo name marker head dirty recorded any=0
  set -f
  # shellcheck disable=SC2086
  set -- $NIGHTLY_GRAPHIFY_REPOS
  set +f
  for repo in "$@"; do
    any=1
    name=$(basename "$repo")
    marker="$NIGHTLY_DIR/graphify-$name"
    if [ ! -d "$repo/.git" ]; then
      stage_record graphify skipped 0 "missing-$name"
      continue
    fi
    dirty=$(git -C "$repo" status --porcelain)
    if [ -n "$dirty" ]; then
      stage_record graphify skipped 0 "dirty-$name"
      continue
    fi
    head=$(git -C "$repo" rev-parse HEAD)
    recorded=
    [ -f "$marker" ] && recorded=$(cat "$marker")
    if [ -n "$recorded" ] && [ "$recorded" = "$head" ]; then
      stage_record graphify skipped 0 "unchanged-$name"
      continue
    fi
    stage_run graphify "$NIGHTLY_STAGE_BOUND_SECONDS" graphify update "$repo"
    if [ "$STAGE_OUTCOME" = ok ]; then
      printf '%s\n' "$head" > "$marker"
    fi
  done
  if [ "$any" -eq 0 ]; then
    stage_record graphify not-configured 0 empty
  fi
}

stage_archive() {
  local snap='' last_exit=0 last_result=ok prev_snap
  collect_transcript_sources
  read_prev_present
  detect_regression
  prev_snap=$(read_archive_snapshot || true)
  export_restic_env
  if [ "${#SOURCES[@]}" -eq 0 ]; then
    # Every family absent is a coverage problem worth a digest line, not a
    # silent success and not a failed run.
    STAGE_ELAPSED=0
    STAGE_RC=0
    STAGE_OUTCOME=finding
    STAGE_DETAIL=no-sources
    stage_record archive finding 0 no-sources
    last_result=finding
  else
    STAGE_FINDING_CODES="3"
    STAGE_FINDING_DETAIL=incomplete
    stage_run archive "$NIGHTLY_STAGE_BOUND_SECONDS" restic -r "$NIGHTLY_RESTIC_REPO" \
      --compression auto backup --json --host "$NIGHTLY_ARCHIVE_HOST" \
      --tag fm-transcripts -- "${SOURCES[@]}"
    STAGE_FINDING_CODES=
    STAGE_FINDING_DETAIL=
    last_exit=$STAGE_RC
    snap=$(parse_snapshot_id "$STAGE_STDOUT")
    if [ "$STAGE_RC" -eq 0 ]; then
      last_result=ok
      prev_snap=$snap
    elif [ "$STAGE_RC" -eq 3 ]; then
      last_result=incomplete
    elif [ "$STAGE_RC" -eq 124 ]; then
      last_result=timeout
    else
      last_result=failed
    fi
  fi
  if [ "$REGRESSED" -eq 1 ]; then
    case "$STAGE_OUTCOME" in
      failed | timeout) ;;
      *)
        STAGE_OUTCOME=finding
        STAGE_DETAIL="coverage-regressed"
        stage_rerecord_last archive finding "$STAGE_ELAPSED" coverage-regressed
        ;;
    esac
    if [ "$last_result" = ok ]; then
      last_result=finding
    fi
  fi
  if [ "$last_result" != ok ]; then
    snap=$prev_snap
  fi
  write_archive_json "$NIGHTLY_DIR/archive.json" "$snap" "$last_exit" "$last_result"
}

stage_weekly_check() {
  local due=1
  read_weekly_state
  if [ -n "$WEEKLY_NEXT_DUE" ] && [ "$WEEKLY_NEXT_DUE" \> "$SCHEDULED_DATE" ]; then
    due=0
  fi
  if [ "$due" -eq 0 ]; then
    stage_record weekly-check skipped 0 not-due
    return 0
  fi
  export_restic_env
  stage_run weekly-check "$NIGHTLY_STAGE_BOUND_SECONDS" restic -r "$NIGHTLY_RESTIC_REPO" \
    check --read-data-subset="${WEEKLY_SUBSET}/4"
  if [ "$STAGE_OUTCOME" = ok ]; then
    WEEKLY_SUBSET=$((WEEKLY_SUBSET % 4 + 1))
    WEEKLY_NEXT_DUE=$(date_plus_days "$SCHEDULED_DATE" 7)
    write_weekly_json "$NIGHTLY_DIR/weekly-check.json" "$WEEKLY_SUBSET" "$WEEKLY_NEXT_DUE" ok
  else
    [ -n "$WEEKLY_NEXT_DUE" ] || WEEKLY_NEXT_DUE=$SCHEDULED_DATE
    write_weekly_json "$NIGHTLY_DIR/weekly-check.json" "$WEEKLY_SUBSET" "$WEEKLY_NEXT_DUE" failed
  fi
}

stage_measure() {
  if [ "$RECORD_WRITES" -eq 0 ]; then
    stage_record injected-measures skipped 0 writes-disabled
    return 0
  fi
  if ! require_maintain; then
    stage_record injected-measures failed 0 maintain-missing
    return 0
  fi
  stage_run injected-measures "$NIGHTLY_STAGE_BOUND_SECONDS" python3 "$MAINTAIN_PY" measure \
    --record "$RECORD" --now "$NOW_ARG" --state "$FM_HOME/state" --apply
}

stage_drift() {
  local line expected=0 concurrent=0
  CONCURRENT_PATHS=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "?? wiki/views/"* | " M wiki/views/"* | "M  wiki/views/"* | "MM wiki/views/"* | \
      "A  wiki/views/"* | "AM wiki/views/"*)
        expected=$((expected + 1))
        ;;
      *)
        concurrent=$((concurrent + 1))
        CONCURRENT_PATHS="$CONCURRENT_PATHS ${line#???}"
        ;;
    esac
  done <<EOF
$(git -C "$RECORD" status --porcelain)
EOF
  if [ "$concurrent" -gt 0 ]; then
    stage_record drift ok 0 "concurrent=$concurrent"
  else
    stage_record drift ok 0 "expected=$expected"
  fi
}

stage_receipt() {
  local fingerprint input_commit rollout_arg
  if ! require_maintain; then
    stage_record receipt failed 0 maintain-missing
    return 0
  fi
  [ -f "$LINT_JSON" ] || printf '{}\n' > "$LINT_JSON"
  if [ -f "$ROLLOUT_JSON" ] && [ "$(cat "$ROLLOUT_JSON")" != "-" ]; then
    rollout_arg=$ROLLOUT_JSON
  else
    rollout_arg=-
  fi
  input_commit=$(git -C "$RECORD" rev-parse HEAD 2>/dev/null || printf 'unknown\n')
  fingerprint=fm-nightly-v1
  if [ "$rollout_arg" = - ]; then
    stage_run receipt "$NIGHTLY_STAGE_BOUND_SECONDS" python3 "$MAINTAIN_PY" receipt \
      --record "$RECORD" --now "$NOW_ARG" --host "$RECEIPT_HOST" \
      --stages "$STAGES_TSV" --input-commit "$input_commit" \
      --lint-json "$LINT_JSON" --rollout-json - \
      --tool-fingerprint "$fingerprint" --apply
  else
    stage_run receipt "$NIGHTLY_STAGE_BOUND_SECONDS" python3 "$MAINTAIN_PY" receipt \
      --record "$RECORD" --now "$NOW_ARG" --host "$RECEIPT_HOST" \
      --stages "$STAGES_TSV" --input-commit "$input_commit" \
      --lint-json "$LINT_JSON" --rollout-json "$rollout_arg" \
      --tool-fingerprint "$fingerprint" --apply
  fi
}

retry_tick() {
  local i=1 rc=0
  while [ "$i" -le "$NIGHTLY_TICK_RETRIES" ]; do
    set +e
    env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_DATA_OVERRIDE="$RECORD" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
      "$RECORD_SH" tick > "$STAGE_STDOUT" 2> "$STAGE_STDERR"
    rc=$?
    set -e
    if [ "$rc" -ne 3 ]; then
      STAGE_RC=$rc
      return 0
    fi
    i=$((i + 1))
    if [ "$i" -le "$NIGHTLY_TICK_RETRIES" ]; then
      sleep "$NIGHTLY_TICK_RETRY_SECONDS"
    fi
  done
  STAGE_RC=$rc
}

stage_checkpoint_home() {
  [ -x "$RECORD_SH" ] || { stage_record checkpoint failed 0 record-missing; return 0; }
  stage_run checkpoint "$NIGHTLY_STAGE_BOUND_SECONDS" env \
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_DATA_OVERRIDE="$RECORD" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
    "$RECORD_SH" checkpoint --reason maintain \
    --summary "$SCHEDULED_DATE: lint, folds, archive, and measures"
  if [ "$STAGE_OUTCOME" != ok ]; then
    return 0
  fi
  retry_tick
  map_stage_outcome "$STAGE_RC"
  if [ "$STAGE_OUTCOME" != ok ]; then
    stage_rerecord_last checkpoint "$STAGE_OUTCOME" "$STAGE_ELAPSED" "$STAGE_DETAIL"
  fi
}

stage_checkpoint_record_only() {
  local branch
  branch=$(git -C "$RECORD" rev-parse --abbrev-ref HEAD)
  if [ -d "$RECORD/wiki/views" ]; then
    git -C "$RECORD" add -- "wiki/views"
    if [ -x "$SCAN_SH" ]; then
      stage_run checkpoint "$NIGHTLY_STAGE_BOUND_SECONDS" "$SCAN_SH" chain --dir "$RECORD/wiki/views"
      if [ "$STAGE_OUTCOME" != ok ]; then
        return 0
      fi
    fi
  fi
  if git -C "$RECORD" diff --cached --quiet && git -C "$RECORD" diff --quiet; then
    stage_rerecord_last checkpoint ok 0 unchanged
    return 0
  fi
  git -C "$RECORD" add -- "wiki/views" 2>/dev/null || true
  if git -C "$RECORD" diff --cached --quiet; then
    stage_rerecord_last checkpoint ok 0 unchanged
    return 0
  fi
  git -C "$RECORD" -c user.name="${GIT_AUTHOR_NAME:-fm-nightly}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-nightly@firstmate}" \
    commit --quiet -m "maintain $SCHEDULED_DATE: lint, folds, archive, and measures"
  export GIT_TERMINAL_PROMPT=0
  stage_run checkpoint "$NIGHTLY_STAGE_BOUND_SECONDS" git -C "$RECORD" push origin "HEAD:refs/heads/$branch"
  if [ "$STAGE_OUTCOME" != ok ]; then
    stage_rerecord_last checkpoint failed "$STAGE_ELAPSED" diverged
  fi
}

stage_verify_home() {
  [ -x "$RECORD_SH" ] || { stage_record verify failed 0 record-missing; return 0; }
  stage_run verify "$NIGHTLY_STAGE_BOUND_SECONDS" env \
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_DATA_OVERRIDE="$RECORD" FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}" \
    "$RECORD_SH" verify
  VERIFY_LINE=$(tr '\n' ' ' < "$STAGE_STDOUT" | sed 's/[[:space:]]*$//')
  if [ "$STAGE_RC" -eq 0 ]; then
    stage_rerecord_last verify ok "$STAGE_ELAPSED" equal=yes
  else
    stage_rerecord_last verify failed "$STAGE_ELAPSED" equal=no
  fi
}

stage_verify_record_only() {
  local branch head remote
  branch=$(git -C "$RECORD" rev-parse --abbrev-ref HEAD)
  export GIT_TERMINAL_PROMPT=0
  stage_run verify "$NIGHTLY_STAGE_BOUND_SECONDS" git -C "$RECORD" fetch origin
  head=$(git -C "$RECORD" rev-parse HEAD)
  remote=$(git -C "$RECORD" rev-parse "origin/$branch" 2>/dev/null || printf 'none\n')
  VERIFY_LINE="fm-nightly: state=verified equal=$([ "$head" = "$remote" ] && printf yes || printf no) head=$head remote=$remote"
  if [ "$head" = "$remote" ]; then
    stage_rerecord_last verify ok 0 equal=yes
  else
    stage_rerecord_last verify failed 0 equal=no
  fi
}

run_named_stage() {
  local name=$1
  case "$name" in
    config) stage_config ;;
    lock) stage_lock ;;
    reconcile-local) stage_reconcile_local ;;
    reconcile) stage_reconcile_git ;;
    lint) stage_lint ;;
    rollout) stage_rollout ;;
    fold) stage_fold ;;
    views) stage_views ;;
    gbrain) stage_gbrain ;;
    graphify) stage_graphify ;;
    archive) stage_archive ;;
    weekly-check) stage_weekly_check ;;
    injected-measures) stage_measure ;;
    drift) stage_drift ;;
    receipt) stage_receipt ;;
    checkpoint)
      if [ "$RECORD_ONLY" -eq 1 ]; then
        stage_checkpoint_record_only
      else
        stage_checkpoint_home
      fi
      ;;
    verify)
      if [ "$RECORD_ONLY" -eq 1 ]; then
        stage_verify_record_only
      else
        stage_verify_home
      fi
      ;;
    *) stage_record "$name" failed 0 unknown-stage ;;
  esac
}

walk_stages() {
  local spec name scope reason
  for spec in "${STAGES[@]}"; do
    IFS='|' read -r name scope <<< "$spec"
    if [ "$CMD" = archive ]; then
      case "$name" in
        config | lock | archive | weekly-check) ;;
        *) continue ;;
      esac
    fi
    reason=$(skip_reason "$name" "$scope" || true)
    if [ -n "$reason" ]; then
      if [ "$reason" = not-configured ]; then
        stage_record "$name" not-configured 0 "$reason"
      else
        stage_record "$name" skipped 0 "$reason"
      fi
      continue
    fi
    run_named_stage "$name"
  done
}

prepare_run_paths() {
  HOME_DIR=${HOME:-}
  [ -n "$HOME_DIR" ] || HOME_DIR=/
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-nightly.XXXXXX")
  STAGE_STDOUT="$TMP_DIR/stdout"
  STAGE_STDERR="$TMP_DIR/stderr"
  DEADLINE_FLAG="$TMP_DIR/deadline"
  : > "$STAGE_STDOUT"
  : > "$STAGE_STDERR"
  NIGHTLY_DIR="$RECORD/.git/nightly"
  mkdir -p "$NIGHTLY_DIR"
  STAGES_TSV="$TMP_DIR/stages.tsv"
  LINT_JSON="$NIGHTLY_DIR/lint.json"
  ROLLOUT_JSON="$NIGHTLY_DIR/rollout.json"
}

arm_deadline() {
  local main_pid
  main_pid=$$
  (
    trap 'exit 0' TERM
    sleep "$NIGHTLY_RUN_BOUND_SECONDS" &
    wait $! || exit 0
    printf 'expired\n' > "$DEADLINE_FLAG"
    kill -TERM "$main_pid" 2>/dev/null || true
  ) &
  DEADLINE_PID=$!
}

cmd_run() {
  local parsed now_line date_line result=ok
  if [ -z "$NOW_ARG" ]; then
    NOW_ARG=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  parsed=$(parse_now "$NOW_ARG") || die 2 "invalid --now"
  now_line=$(printf '%s\n' "$parsed" | sed -n '1p')
  date_line=$(printf '%s\n' "$parsed" | sed -n '2p')
  NOW_ARG=$now_line
  if [ -z "$SCHEDULED_DATE" ]; then
    SCHEDULED_DATE=$date_line
  fi
  case "$SCHEDULED_DATE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) die 2 "invalid --scheduled-date" ;;
  esac
  load_config
  if [ "$DRY_RUN" -eq 1 ]; then
    print_dry_run
    exit 0
  fi
  prepare_run_paths
  trap finalize_run EXIT
  trap on_term TERM
  RUN_STARTED=1
  arm_deadline
  : > "$STAGES_TSV"
  walk_stages
  RUN_COMPLETED=1
  if tsv_has_problem; then
    result=failed
  fi
  if [ "$result" = failed ]; then
    exit 1
  fi
  exit 0
}

target_is_empty() {
  local path=$1
  [ -d "$path" ] || return 1
  [ -z "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

cmd_restore() {
  local snap dest
  [ -n "$TARGET" ] || die 2 "restore requires --target"
  require_abs --target "$TARGET"
  load_config
  prepare_run_paths
  [ -d "$RECORD/.git" ] || die 2 "FM_HOME data/.git is missing"
  mkdir -p "$NIGHTLY_DIR"
  require_lock_libs
  trap finalize_run EXIT
  LOCK_PATH="$NIGHTLY_DIR/lock"
  if ! fm_lock_try_acquire "$LOCK_PATH"; then
    printf 'busy\n'
    exit 3
  fi
  LOCK_HELD=1
  if [ -e "$TARGET" ] && [ ! -d "$TARGET" ]; then
    die 2 "restore target must be a directory"
  fi
  if [ -d "$TARGET" ]; then
    target_is_empty "$TARGET" || die 2 "restore target must be empty"
  else
    mkdir -p "$TARGET"
  fi
  if [ -n "$SNAPSHOT" ]; then
    snap=$SNAPSHOT
  else
    snap=$(read_archive_snapshot || true)
    [ -n "$snap" ] || die 2 "no last_complete_snapshot and no --snapshot"
  fi
  archive_ready || die 2 "archive is not configured"
  export_restic_env
  dest=$(physical_dir "$TARGET") || dest=$TARGET
  set +e
  fm_run_timed "$NIGHTLY_STAGE_BOUND_SECONDS" restic -r "$NIGHTLY_RESTIC_REPO" \
    restore "$snap" --host "$NIGHTLY_ARCHIVE_HOST" --tag fm-transcripts --target "$dest" \
    > "$STAGE_STDOUT" 2> "$STAGE_STDERR"
  STAGE_RC=$?
  set -e
  [ "$STAGE_RC" -eq 0 ] || die 1 "restore failed class=$(class_string "restic-exit-$STAGE_RC")"
  exit 0
}

validate_code_root() {
  local code_root=$1 toplevel
  code_root=$(physical_dir "$code_root") || die 8 "cannot resolve the nightly code root"
  [ -x "$code_root/bin/fm-nightly.sh" ] || die 8 "code root must contain executable bin/fm-nightly.sh"
  [ -d "$code_root/.git" ] && [ ! -L "$code_root/.git" ] \
    || die 8 "nightly job requires a primary code checkout, not a disposable worktree"
  toplevel=$(git -C "$code_root" rev-parse --show-toplevel 2>/dev/null) \
    || die 8 "code root is not a Git checkout"
  [ "$toplevel" = "$code_root" ] || die 8 "code root must be the checkout root"
  printf '%s\n' "$code_root"
}

write_nightly_plist() {
  local code_root=$1 template script stdout_log stderr_log path_value home_value tmp plist logdir
  template="$SCRIPT_DIR/launchd/com.firstmate.nightly.plist.template"
  plist=${FM_NIGHTLY_PLIST:-$HOME/Library/LaunchAgents/com.firstmate.nightly.plist}
  logdir=${FM_NIGHTLY_LOG_DIR:-$HOME/Library/Logs}
  if [ -f "$plist" ] && ! grep -Fq 'firstmate-nightly-v1' "$plist"; then
    die 8 "existing LaunchAgent is not the nightly job; leaving it untouched"
  fi
  mkdir -p "$(dirname "$plist")"
  script=$(printf '%s' "$code_root/bin/fm-nightly.sh" | xml_escape | sed_replacement)
  stdout_log=$(printf '%s' "$logdir/firstmate-nightly.stdout.log" | xml_escape | sed_replacement)
  stderr_log=$(printf '%s' "$logdir/firstmate-nightly.stderr.log" | xml_escape | sed_replacement)
  path_value=$(printf '%s' "${PATH-}" | xml_escape | sed_replacement)
  home_value=$(printf '%s' "$(physical_dir "$FM_HOME")" | xml_escape | sed_replacement)
  tmp="$plist.tmp.$$"
  sed -e "s|__NIGHTLY_SCRIPT__|$script|g" \
    -e "s|__STDOUT_LOG__|$stdout_log|g" \
    -e "s|__STDERR_LOG__|$stderr_log|g" \
    -e "s|__PATH__|$path_value|g" \
    -e "s|__FM_HOME__|$home_value|g" \
    -e "s|__HOUR__|$HOUR|g" \
    -e "s|__MINUTE__|$MINUTE|g" "$template" > "$tmp"
  chmod 644 "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$tmp" >/dev/null; then
      rm -f "$tmp"
      die 8 "rendered nightly plist failed plutil -lint"
    fi
  fi
  mkdir -p "$logdir"
  mv -f "$tmp" "$plist"
}

bootstrap_nightly_job() {
  local plist=${FM_NIGHTLY_PLIST:-$HOME/Library/LaunchAgents/com.firstmate.nightly.plist}
  [ -f "$plist" ] || die 8 "nightly LaunchAgent plist is missing"
  grep -Fq 'firstmate-nightly-v1' "$plist" || die 8 "nightly LaunchAgent plist is not owned by install"
  launchctl bootout "gui/$UID/com.firstmate.nightly" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$plist"
}

cmd_install() {
  local code_root env_file
  [ -n "$FM_HOME" ] || die 2 "install requires --fm-home"
  require_abs --fm-home "$FM_HOME"
  FM_HOME=$(physical_dir "$FM_HOME") || die 2 "cannot resolve --fm-home"
  env_file="$FM_HOME/config/nightly.env"
  if [ -f "$env_file" ]; then
    parse_nightly_env "$env_file"
  fi
  if [ "$HOUR_SET" -eq 0 ]; then
    HOUR=$NIGHTLY_HOUR
  fi
  if [ "$MINUTE_SET" -eq 0 ]; then
    MINUTE=$NIGHTLY_MINUTE
  fi
  require_hour "$HOUR"
  require_minute "$MINUTE"
  if [ -z "$CODE_ROOT" ]; then
    CODE_ROOT=$FM_ROOT
  fi
  require_abs --code-root "$CODE_ROOT"
  code_root=$(validate_code_root "$CODE_ROOT")
  write_nightly_plist "$code_root"
  if [ "$BOOTSTRAP" -eq 1 ]; then
    bootstrap_nightly_job
  fi
  printf 'fm-nightly: installed\n'
  exit 0
}

cmd_status() {
  local plist=${FM_NIGHTLY_PLIST:-$HOME/Library/LaunchAgents/com.firstmate.nightly.plist}
  [ -n "$FM_HOME" ] || die 2 "status requires --fm-home"
  require_abs --fm-home "$FM_HOME"
  RECORD="$FM_HOME/data"
  NIGHTLY_DIR="$RECORD/.git/nightly"
  if [ -f "$NIGHTLY_DIR/last-attempt" ]; then
    printf 'last-attempt:\n'
    cat "$NIGHTLY_DIR/last-attempt"
  else
    printf 'last-attempt: none\n'
  fi
  if [ -f "$NIGHTLY_DIR/last-complete" ]; then
    printf 'last-complete:\n'
    cat "$NIGHTLY_DIR/last-complete"
  else
    printf 'last-complete: none\n'
  fi
  if [ -f "$NIGHTLY_DIR/archive.json" ]; then
    printf 'archive:\n'
    python3 - "$NIGHTLY_DIR/archive.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print("last_complete_snapshot=%s" % (data.get("last_complete_snapshot") or ""))
print("last_exit=%s" % data.get("last_exit"))
print("last_result=%s" % data.get("last_result"))
PY
  else
    printf 'archive: none\n'
  fi
  if [ -f "$NIGHTLY_DIR/weekly-check.json" ]; then
    printf 'weekly-check:\n'
    cat "$NIGHTLY_DIR/weekly-check.json"
  else
    printf 'weekly-check: none\n'
  fi
  if [ -f "$MAINTAIN_PY" ] && [ -d "$RECORD" ]; then
    printf 'rollout:\n'
    python3 "$MAINTAIN_PY" rollout status --record "$RECORD" || printf 'rollout: unavailable\n'
  else
    printf 'rollout: not-configured\n'
  fi
  if [ -f "$plist" ]; then
    printf 'plist: present %s\n' "$plist"
  else
    printf 'plist: absent\n'
  fi
  exit 0
}

# --- argv ---
case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  run | archive | restore | install | status)
    CMD=$1
    shift
    ;;
  '')
    usage
    exit 2
    ;;
  *)
    die 2 "unknown argument; run --help"
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fm-home)
      [ "$#" -ge 2 ] || die 2 "--fm-home requires a path"
      FM_HOME_ARG=$2
      shift 2
      ;;
    --record-only)
      RECORD_ONLY=1
      shift
      ;;
    --record)
      [ "$#" -ge 2 ] || die 2 "--record requires a path"
      RECORD_ARG=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --now)
      [ "$#" -ge 2 ] || die 2 "--now requires a timestamp"
      NOW_ARG=$2
      shift 2
      ;;
    --scheduled-date)
      [ "$#" -ge 2 ] || die 2 "--scheduled-date requires a date"
      SCHEDULED_DATE=$2
      shift 2
      ;;
    --target)
      [ "$#" -ge 2 ] || die 2 "--target requires a path"
      TARGET=$2
      shift 2
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || die 2 "--snapshot requires an id"
      SNAPSHOT=$2
      shift 2
      ;;
    --hour)
      [ "$#" -ge 2 ] || die 2 "--hour requires a value"
      HOUR=$2
      HOUR_SET=1
      shift 2
      ;;
    --minute)
      [ "$#" -ge 2 ] || die 2 "--minute requires a value"
      MINUTE=$2
      MINUTE_SET=1
      shift 2
      ;;
    --code-root)
      [ "$#" -ge 2 ] || die 2 "--code-root requires a path"
      CODE_ROOT=$2
      shift 2
      ;;
    --bootstrap)
      BOOTSTRAP=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die 2 "unknown argument; run --help"
      ;;
  esac
done

if [ "$RECORD_ONLY" -eq 1 ] || [ -n "$RECORD_ARG" ]; then
  [ "$CMD" = run ] || die 2 "--record-only is only valid with run"
  [ "$RECORD_ONLY" -eq 1 ] && [ -n "$RECORD_ARG" ] || die 2 "--record-only requires --record"
  [ -z "$FM_HOME_ARG" ] || die 2 "--fm-home cannot be combined with --record-only/--record"
  require_abs --record "$RECORD_ARG"
  RECORD=$(physical_dir "$RECORD_ARG") || die 2 "cannot resolve --record"
  FM_HOME=$RECORD
  export FM_HOME
  export FM_STATE_OVERRIDE="$RECORD/.git/nightly/state"
else
  if [ "$CMD" != run ] && [ "$CMD" != archive ] && [ "$CMD" != restore ] && [ "$CMD" != install ] && [ "$CMD" != status ]; then
    die 2 "unknown command"
  fi
  if [ "$CMD" = run ] || [ "$CMD" = archive ] || [ "$CMD" = restore ] || [ "$CMD" = install ] || [ "$CMD" = status ]; then
    [ -n "$FM_HOME_ARG" ] || die 2 "$CMD requires --fm-home"
    require_abs --fm-home "$FM_HOME_ARG"
    FM_HOME=$(physical_dir "$FM_HOME_ARG") || die 2 "cannot resolve --fm-home"
    RECORD="$FM_HOME/data"
    export FM_HOME
    export FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  fi
fi

if [ "$DRY_RUN" -eq 1 ] && [ "$CMD" != run ]; then
  die 2 "--dry-run is only valid with run"
fi

case "$CMD" in
  run | archive)
    cmd_run
    ;;
  restore)
    cmd_restore
    ;;
  install)
    cmd_install
    ;;
  status)
    cmd_status
    ;;
esac
