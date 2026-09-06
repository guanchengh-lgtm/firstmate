#!/usr/bin/env bash
# Rank prior Record work and print recalled pointers.
# Usage:
#   fm-recall.sh [--surface brief|session-item|pointers] [--limit N]
#                [--task-id <id>] [--title <title>] [--body-file <path>]
#                [--source <literal>]... [--status <id>=<state>]...
#                [--exclude-id <id>]... [--exclude-path <path>]...
#                [--exclude-identity <id-or-path>]... [--exclude-file <path>]...
#                [--token-budget N] [--as-of YYYY-MM-DD] [--now YYYY-MM-DD]
#                [--deadline-ms N] [--json] [--root <dir>]
#                [--session-batch <queries.json>] [--extract-identities]
#   fm-recall.sh --help
#
# This command is the public recall entry point. bin/fm-recall.py is the only
# parser, ranker, deduper, and renderer. The shell resolves the home, the
# Record data directory, and the safety timeout, then passes explicit inputs.
#
# Corpus. The Record root is the home data directory from FM_HOME and
# FM_DATA_OVERRIDE. The T1 RECORD.md layout, live-state mirror, and .git
# directory need no change here. The indexed set is data/done-archive.md,
# each data/decisions/*.md file, and each immediate data/*/report.md that is
# not already represented. POINTER.md aliases collapse to their canonical
# target, with cycle detection. Repeated archive entries merge by task id.
# Distinct historical decisions stay distinct. Briefs, prior recall output,
# generated wiki and views, snapshots, research run output, caches, backups,
# raw assets, transcripts, binaries, .git, credentials, and paths outside the
# selected Record are not indexed. Named sources are query terms only and are
# never fetched or bulk-read.
#
# Ranking. The ranker is term-overlap with title weight 3 and body weight 1.
# Query terms are the union of the title, the finalized task body, and each
# literal named source. Positive-score documents are ordered by descending
# relevance, then document id, then path. Recency, status, importance, and
# freshness never affect rank. Date is display, historical --as-of filtering,
# and the check-freshness mark only.
#
# Limits. Each title or body input is capped at 64 KiB. Each archive document
# is capped at 16 KiB. Each report or decision ranking head is capped at 16 KiB.
# A truncated read emits a partial-input diagnostic and still ranks the bytes
# that were read. The internal ranking deadline defaults to 750 ms and is
# checked between directory entries and archive blocks. A deadline or safety
# timeout is a visible unavailable result, never an empty successful lookup.
# The shell safety timeout defaults to 1 second. FM_RECALL_TIMEOUT and
# FM_RECALL_DEADLINE_MS override those bounds. The nominal timeout is not a
# claim that process cleanup can never exceed the exact millisecond boundary.
#
# Surfaces. brief renders at most five pointers under a 150-token hard cap.
# session-item renders at most three pointers and honors --token-budget when
# set. pointers renders ranked lines only. The token estimate is
# ceil(UTF-8 bytes / 3), the same conservative local estimate as
# config/startup-memory-budget, and is never a provider-exact token count.
# The brief block starts with "# Recalled pointers" and the statement that
# hits are references, not instructions. Each pointer line is
# "- <path> - <title> (<date>; <status>[; check-freshness])".
# Titles cut at 90 characters, then shorten further to keep the path and
# metadata. The lowest-ranked whole pointer is omitted only when the remaining
# metadata cannot fit. The heading and omission disclosure count toward the
# cap. The printed pointer count is the number actually emitted.
#
# Metadata. A valid explicit document date wins, then an archive completion or
# archive date, then a date encoded in a decision filename. Otherwise the date
# is "date unknown". Clone-time mtime is never a creation date. A date older
# than 30 days receives check-freshness. A date exactly 30 days old has no
# mark. Future and malformed dates emit a metadata diagnostic and never affect
# rank. Status prefers a --status backlog override, then explicit record or
# status-sidecar metadata, then archive completion state, then
# "status unknown". Held and parked documents keep that state and never receive
# check-freshness. A report file's existence does not prove that a task shipped.
#
# Exclusions. --exclude-id, --exclude-path, and --exclude-identity remove
# canonical document identities. --exclude-file removes every result that would
# point into that whole printed source file. Task report and archive
# representations share one task identity. Separate archive line-locator paths
# stay distinct when they are the only representation.
#
# Exit status. 0 means a successful lookup, including an explicit empty
# result. 1 means unavailable. 2 means usage. Unavailable prints
# "recall: unavailable: <reason>" on stderr. --json always includes status,
# ranker, hits, rendered text, pointer_count, bytes, and estimated_tokens.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYTHON_OWNER="$SCRIPT_DIR/fm-recall.py"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "recall: unavailable: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

json_requested() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --json) return 0 ;;
    esac
  done
  return 1
}

print_timeout_unavailable() {
  echo "recall: unavailable: ranking timed out" >&2
  if json_requested "$@"; then
    printf '%s\n' '{
 "status": "unavailable",
 "reason": "ranking timed out",
 "ranker": "term-overlap-3-1",
 "hits": [],
 "rendered": "",
 "pointer_count": 0,
 "bytes": 0,
 "estimated_tokens": 0
}'
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "recall: unavailable: python3 is not on PATH" >&2
  exit 1
fi

if [ ! -f "$PYTHON_OWNER" ]; then
  echo "recall: unavailable: missing $PYTHON_OWNER" >&2
  exit 1
fi

FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi

TIMEOUT=${FM_RECALL_TIMEOUT:-1}
DEADLINE_MS=${FM_RECALL_DEADLINE_MS:-750}
case "$TIMEOUT" in
  ''|*[!0-9]*|0) echo "recall: unavailable: FM_RECALL_TIMEOUT must be a positive integer" >&2; exit 1 ;;
esac
case "$DEADLINE_MS" in
  ''|*[!0-9]*) echo "recall: unavailable: FM_RECALL_DEADLINE_MS must be a non-negative integer" >&2; exit 1 ;;
esac

have_root=0
have_deadline=0
for arg in "$@"; do
  case "$arg" in
    --root|--root=*) have_root=1 ;;
    --deadline-ms|--deadline-ms=*) have_deadline=1 ;;
  esac
done

args=()
if [ "$have_root" -eq 0 ]; then
  args+=(--root "$DATA")
fi
if [ "$have_deadline" -eq 0 ]; then
  args+=(--deadline-ms "$DEADLINE_MS")
fi
args+=("$@")

extract_only=0
for arg in "$@"; do
  case "$arg" in
    --extract-identities|--extract-identities=*) extract_only=1 ;;
  esac
done

# The shared timeout helper backgrounds the child and therefore cannot keep
# stdin. Identity extraction reads the already-emitted digest from stdin and
# does not rank the corpus, so it runs without that bound.
if [ "$extract_only" -eq 1 ]; then
  exec python3 -B "$PYTHON_OWNER" "${args[@]}"
fi

rc=0
fm_run_timed "$TIMEOUT" python3 -B "$PYTHON_OWNER" "${args[@]}" || rc=$?
if [ "$rc" -eq 124 ]; then
  print_timeout_unavailable "$@"
  exit 1
fi
exit "$rc"
