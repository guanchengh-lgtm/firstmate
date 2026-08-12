#!/usr/bin/env bash
# Record a captain-approved one-shot exception to the project-write guard.
#
# AGENTS.md hard rule 1 lets firstmate perform a concrete captain-approved
# project operation "with its own file tools". bin/fm-project-write-pretool-check.sh
# otherwise refuses every such write, so this script is the sanctioned path: it
# writes one short-TTL, path-scoped, single-use grant that the guard consumes on
# the next matching call and then expires.
#
# The grant is deliberate-and-audited, not unforgeable. Firstmate can run this
# script without a real approval, exactly as it can run any other script. What
# the grant buys is that the exception can never be taken absently: it requires
# naming the concrete path and quoting the captain's instruction, and it leaves
# a durable log line. That matches this guard family's threat model - agent
# mistakes, not adversarial agents - and honors an approval given in the moment
# without forcing a session restart. See docs/project-write-guard.md.
#
# Usage:
#   bin/fm-project-write-grant.sh <path> --reason '<captain instruction>' [--ttl <seconds>]
#   bin/fm-project-write-grant.sh --show
#   bin/fm-project-write-grant.sh --revoke
#
# One grant is active at a time; issuing a new one replaces it.
set -eu

DEFAULT_TTL=600
MAX_TTL=3600
MIN_REASON=12

TARGET=""
REASON=""
TTL=$DEFAULT_TTL
ACTION=grant

usage() {
  cat <<EOF
Usage: fm-project-write-grant.sh <path> --reason '<captain instruction>' [--ttl <seconds>]
       fm-project-write-grant.sh --show
       fm-project-write-grant.sh --revoke

Records ONE captain-approved exception to the project-write guard
(bin/fm-project-write-pretool-check.sh), which refuses primary-session file-tool
writes under this home's projects/ directory and under any live task worktree.

<path> is the exact file or directory the approved operation touches. It must
lie strictly below a protected root: a grant for the whole projects/ tree or for
a bare worktree root is refused, because a captain approves a concrete
operation, not a standing posture.

--reason must quote the captain's own instruction, at least $MIN_REASON characters.
--ttl defaults to ${DEFAULT_TTL}s and may not exceed ${MAX_TTL}s.

The grant covers exactly ONE later tool call and is consumed by it, so a
multi-file operation needs one grant per write. Issuing a new grant replaces any
active one. Every issue, consume, and revoke is appended to
state/.project-write-grant.log.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason)
      [ "$#" -gt 1 ] || { echo "error: --reason requires a value" >&2; exit 2; }
      REASON=$2
      shift 2
      ;;
    --reason=*)
      REASON=${1#--reason=}
      shift
      ;;
    --ttl)
      [ "$#" -gt 1 ] || { echo "error: --ttl requires a value" >&2; exit 2; }
      TTL=$2
      shift 2
      ;;
    --ttl=*)
      TTL=${1#--ttl=}
      shift
      ;;
    --show)
      ACTION=show
      shift
      ;;
    --revoke)
      ACTION=revoke
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [ -z "$TARGET" ] || { echo "error: only one path may be granted at a time" >&2; exit 2; }
      TARGET=$1
      shift
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
ACTIVE_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$ACTIVE_HOME/state}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-project-write-lib.sh
. "$SCRIPT_DIR/fm-project-write-lib.sh"

GRANT="$STATE/$FM_PROJECT_WRITE_GRANT_NAME"

if [ "$ACTION" = show ]; then
  if [ ! -f "$GRANT" ]; then
    echo "no active grant"
    exit 0
  fi
  cat "$GRANT"
  exit 0
fi

if [ "$ACTION" = revoke ]; then
  if [ ! -f "$GRANT" ]; then
    echo "no active grant"
    exit 0
  fi
  fm_project_write_grant_log "$STATE" revoked \
    "$(fm_project_write_grant_field "$GRANT" path)" \
    "$(fm_project_write_grant_field "$GRANT" reason)"
  rm -f "$GRANT"
  echo "revoked"
  exit 0
fi

[ -n "$TARGET" ] || { echo "error: a path to grant is required" >&2; usage >&2; exit 2; }

# A grant issued where the guard never fires would be a false reassurance, so
# refuse rather than write a record that protects nothing.
if ! fm_primary_scope_matches "$FM_ROOT" "$STATE"; then
  echo "error: $FM_ROOT is not a genuine primary home, so the project-write guard is inert here and no grant is needed" >&2
  exit 2
fi

case "$TTL" in
  ''|*[!0-9]*) echo "error: --ttl must be a whole number of seconds" >&2; exit 2 ;;
esac
[ "$TTL" -gt 0 ] || { echo "error: --ttl must be greater than zero" >&2; exit 2; }
[ "$TTL" -le "$MAX_TTL" ] || { echo "error: --ttl may not exceed ${MAX_TTL}s; a captain-approved operation is immediate, not standing" >&2; exit 2; }

[ -n "$REASON" ] || { echo "error: --reason is required and must quote the captain's concrete instruction" >&2; exit 2; }
[ "${#REASON}" -ge "$MIN_REASON" ] || { echo "error: --reason must quote the captain's concrete instruction (at least $MIN_REASON characters)" >&2; exit 2; }

RESOLVED=$(fm_project_write_resolve "$TARGET") || { echo "error: cannot resolve path: $TARGET" >&2; exit 2; }

TAB=$(printf '\t')
HIT_ROOT=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  root=${entry#*"$TAB"}
  if fm_project_write_path_under "$RESOLVED" "$root"; then
    HIT_ROOT=$root
    break
  fi
done < <(fm_project_write_protected_roots "$ACTIVE_HOME" "$STATE")

if [ -z "$HIT_ROOT" ]; then
  echo "error: $RESOLVED is not under a protected root, so the guard already allows writing it and no grant is needed" >&2
  exit 2
fi

if [ "$RESOLVED" = "$HIT_ROOT" ]; then
  echo "error: refusing to grant the whole protected root $HIT_ROOT; name the concrete file or directory the captain approved" >&2
  exit 2
fi

NOW=$(date +%s)
EXPIRES=$((NOW + TTL))
REASON_LINE=${REASON//$'\n'/ }
REASON_LINE=${REASON_LINE//$'\t'/ }

mkdir -p "$STATE"
TMP=$(mktemp "$STATE/.project-write-grant.XXXXXX")
{
  printf 'path=%s\n' "$RESOLVED"
  printf 'created=%s\n' "$NOW"
  printf 'expires=%s\n' "$EXPIRES"
  printf 'reason=%s\n' "$REASON_LINE"
} > "$TMP"
mv -f "$TMP" "$GRANT"
fm_project_write_grant_log "$STATE" issued "$RESOLVED" "$REASON_LINE"

printf 'granted %s for one write, expiring in %ss\n' "$RESOLVED" "$TTL"
