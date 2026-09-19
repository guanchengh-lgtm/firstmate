#!/usr/bin/env bash
# Rank prior Record work and print recalled pointers.
# Usage:
#   fm-recall.sh [--surface brief|pointers] [--limit N]
#                [--task-id <id>] [--title <title>] [--body-file <path>]
#                [--source <literal>]... [--status <id>=<state>]...
#                [--exclude-id <id>]... [--exclude-path <path>]...
#                [--exclude-identity <id-or-path>]... [--exclude-file <path>]...
#                [--token-budget N] [--as-of YYYY-MM-DD] [--now YYYY-MM-DD]
#                [--deadline-ms N] [--json] [--ranker overlap|hybrid|auto]
#                [--query <title>] [--session-batch <queries.json>]
#                [--extract-identities]
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
# Ranking. The ranker is term-overlap with title weight 3 and body weight 1
# unless --ranker hybrid or auto engages the loopback gbrain search.
# --ranker overlap never opens a socket. --ranker hybrid never falls back.
# --ranker auto is the brief and session-start default, from FM_RECALL_RANKER
# when unset. Query terms are the union of the title, the finalized task body,
# and each literal named source. --query is an alias of --title.
# Overlap is always computed first. Hybrid order is resolved served slugs
# first, then overlap-only fill, then the same cap as today.
# Recency, status, importance, and freshness never affect rank. Date is
# display, historical --as-of filtering, and the check-freshness mark only.
# GBRAIN_RECALL defaults to off when absent. auto then stays on overlap.
# I4 flips that home switch on after install smoke. Serve-up means a
# successful search POST, not GET /health. One bearer-token JSON-RPC
# tools/call search is posted to loopback /mcp. No MCP tool is registered
# in any harness. No MCP client library is used. No REST search path is
# used. No CLI search is used while serve holds the lock.
# The token is read from GBRAIN_RECALL_TOKEN_FILE, default
# $FM_HOME/config/gbrain-recall.token, and is never placed in argv values,
# receipts, diagnostics, or test output. GBRAIN_RECALL_URL defaults to
# http://127.0.0.1:$GBRAIN_PORT/mcp. FM_RECALL_HYBRID_MS defaults to 400.
# A recall URL whose host is not 127.0.0.1, ::1, or localhost is down; the
# token is never sent to it. The POST ignores proxy settings and refuses
# redirects. A session batch gives each query an equal share of the time
# left, and its retrieval_mode is the weakest mode of its queries.
# A missing token, a refused or timed-out POST, or a bad JSON-RPC shape is
# down: auto keeps overlap, hybrid is unavailable. keyword_relaxed or
# _meta.retrieval.vector_enabled false / embed_unavailable is keyword.
# A leading YAML header and a terminal Related: footer are metadata only:
# they are read for date and status, excluded from the title and ranking
# text, and never followed to other documents.
#
# Limits. Each title or body input is capped at 64 KiB. Each archive document
# is capped at 16 KiB. The ranking head is the first 16 KiB of each report or
# decision. Explicit metadata also reads an independent final 4096-byte tail.
# A truncated read emits a partial-input diagnostic and still ranks the bytes
# that were read. The internal ranking deadline defaults to 750 ms and is
# checked between directory entries and archive blocks. A deadline or safety
# timeout is a visible unavailable result, never an empty successful lookup.
# The deadline must be positive; zero does not disable it.
# The shell safety timeout defaults to 1 second. FM_RECALL_TIMEOUT and
# FM_RECALL_DEADLINE_MS override those bounds. The nominal timeout is not a
# claim that process cleanup can never exceed the exact millisecond boundary.
#
# Surfaces. brief renders at most five pointers with a default 150-token cap.
# --limit defaults to five when omitted or zero, and brief clamps it to five.
# --token-budget overrides the brief or session-batch allowance.
# pointers is the default surface; it renders ranked lines without a token cap.
# The token estimate is
# ceil(UTF-8 bytes / 3), the same conservative local estimate as
# config/startup-memory-budget, and is never a provider-exact token count.
# The brief block starts with "# Recalled pointers" and the statement that
# hits are references, not instructions. Each pointer line is
# "- <path> - <title> (<date>; <status>[; check-freshness])".
# Brief titles cut at 90 characters, then shorten toward a 40-character limit to
# keep the path and metadata. If the block still exceeds the cap, the renderer
# omits the lowest-ranked whole pointer.
# The heading and omission disclosure count toward the cap.
# The printed pointer count is the number actually emitted.
# --session-batch reads a JSON array of objects with id, title, and body
# strings and an optional sources array of strings, using one corpus load.
# bin/fm-session-start.sh owns its caller's item selection and placement.
# --extract-identities reads emitted text from stdin and prints one document
# identity per line without ranking or the ranking timeout.
#
# Metadata. A valid explicit document date wins, then an archive completion or
# archive date, then a date encoded in a decision filename. Otherwise the date
# is "date unknown". Clone-time mtime is never a creation date. A date older
# than 30 days receives check-freshness. A date exactly 30 days old has no
# mark. Future and malformed dates emit a metadata diagnostic and never affect
# rank. --as-of excludes documents with unknown dates or dates after its bound.
# Task status prefers a --status backlog override, then explicit record or
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
# "recall: unavailable: <reason>" on stderr. Successful lookups and ranking
# failures with --json include status, ranker, retrieval_mode, identities,
# hits, rendered text, pointer_count, bytes, and estimated_tokens.
# ranker is term-overlap-3-1, gbrain-hybrid+term-overlap-3-1, or
# gbrain-keyword+term-overlap-3-1. retrieval_mode is
# overlap, hybrid, keyword, hybrid-unverified, or unavailable.
# Shell preflight and usage failures can return without JSON. Successful
# lookup diagnostics appear on stderr for plain output and in diagnostics
# for JSON output. Diagnostics never include the token or response bodies.
# tests/fm-recall.test.sh owns the public-command regression and probe harness.
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
 "retrieval_mode": "unavailable",
 "hits": [],
 "identities": [],
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

load_gbrain_recall_env() {
  local file=$1 key val
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      GBRAIN_RECALL=*|GBRAIN_RECALL_TOKEN_FILE=*|GBRAIN_RECALL_URL=*|GBRAIN_PORT=*)
        key=${line%%=*}
        val=${line#*=}
        case "$key" in
          GBRAIN_RECALL)
            [ -n "${GBRAIN_RECALL:-}" ] || GBRAIN_RECALL=$val
            ;;
          GBRAIN_RECALL_TOKEN_FILE)
            [ -n "${GBRAIN_RECALL_TOKEN_FILE:-}" ] || GBRAIN_RECALL_TOKEN_FILE=$val
            ;;
          GBRAIN_RECALL_URL)
            [ -n "${GBRAIN_RECALL_URL:-}" ] || GBRAIN_RECALL_URL=$val
            ;;
          GBRAIN_PORT)
            [ -n "${GBRAIN_PORT:-}" ] || GBRAIN_PORT=$val
            ;;
        esac
        ;;
    esac
  done < "$file"
}

load_gbrain_recall_env "$FM_HOME/config/gbrain.env"
case "${GBRAIN_RECALL:-off}" in
  on) GBRAIN_RECALL=on ;;
  *) GBRAIN_RECALL=off ;;
esac
GBRAIN_PORT=${GBRAIN_PORT:-3131}
GBRAIN_RECALL_TOKEN_FILE=${GBRAIN_RECALL_TOKEN_FILE:-$FM_HOME/config/gbrain-recall.token}
GBRAIN_RECALL_URL=${GBRAIN_RECALL_URL:-http://127.0.0.1:${GBRAIN_PORT}/mcp}
FM_RECALL_RANKER=${FM_RECALL_RANKER:-auto}
FM_RECALL_HYBRID_MS=${FM_RECALL_HYBRID_MS:-400}

TIMEOUT=${FM_RECALL_TIMEOUT:-1}
DEADLINE_MS=${FM_RECALL_DEADLINE_MS:-750}
case "$TIMEOUT" in
  ''|*[!0-9]*|0) echo "recall: unavailable: FM_RECALL_TIMEOUT must be a positive integer" >&2; exit 1 ;;
esac
case "$DEADLINE_MS" in
  ''|*[!0-9]*) echo "recall: unavailable: FM_RECALL_DEADLINE_MS must be a non-negative integer" >&2; exit 1 ;;
esac

have_deadline=0
for arg in "$@"; do
  case "$arg" in
    --root|--root=*)
      echo "error: --root is not a public option; select the corpus with FM_HOME and FM_DATA_OVERRIDE" >&2
      exit 2
      ;;
    --deadline-ms|--deadline-ms=*) have_deadline=1 ;;
  esac
done

have_ranker=0
have_token_file=0
have_recall_url=0
have_gbrain_recall=0
have_hybrid_ms=0
for arg in "$@"; do
  case "$arg" in
    --ranker|--ranker=*) have_ranker=1 ;;
    --token-file|--token-file=*) have_token_file=1 ;;
    --recall-url|--recall-url=*) have_recall_url=1 ;;
    --gbrain-recall|--gbrain-recall=*) have_gbrain_recall=1 ;;
    --hybrid-ms|--hybrid-ms=*) have_hybrid_ms=1 ;;
  esac
done

args=()
args+=(--root "$DATA")
if [ "$have_deadline" -eq 0 ]; then
  args+=(--deadline-ms "$DEADLINE_MS")
fi
args+=("$@")
if [ "$have_ranker" -eq 0 ]; then
  args+=(--ranker "$FM_RECALL_RANKER")
fi
if [ "$have_gbrain_recall" -eq 0 ]; then
  args+=(--gbrain-recall "$GBRAIN_RECALL")
fi
if [ "$have_token_file" -eq 0 ]; then
  args+=(--token-file "$GBRAIN_RECALL_TOKEN_FILE")
fi
if [ "$have_recall_url" -eq 0 ]; then
  args+=(--recall-url "$GBRAIN_RECALL_URL")
fi
if [ "$have_hybrid_ms" -eq 0 ]; then
  args+=(--hybrid-ms "$FM_RECALL_HYBRID_MS")
fi

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
