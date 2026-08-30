#!/usr/bin/env bash
# Create an isolated firstmate operational home for verification.
# Usage: launch.sh
# Prints:
#   VERIFY_HOME=<abs>
#   VERIFY_EVIDENCE=<abs>
#   VERIFY_ENV=<abs>
# Does not start a harness, session backend, or daemon.
# Ready when those three lines print and the home contains state/, data/,
# config/, projects/, and the .fm-verify-home marker.
set -eu

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HELPER_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

if [ ! -x "$REPO_ROOT/bin/fm-brief.sh" ] || [ ! -f "$REPO_ROOT/AGENTS.md" ]; then
  printf 'error: could not resolve firstmate repo root from %s\n' "$HELPER_DIR" >&2
  exit 1
fi

RUN_ID="${VERIFY_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
VERIFY_ROOT="${VERIFY_ROOT:-${TMPDIR:-/tmp}}"
VERIFY_HOME="${VERIFY_HOME:-$VERIFY_ROOT/fm-verify-$RUN_ID}"
VERIFY_EVIDENCE="${VERIFY_EVIDENCE:-$SKILL_DIR/evidence/$RUN_ID}"

case "$VERIFY_HOME" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    printf 'error: refuse to use the live checkout as VERIFY_HOME (%s)\n' "$VERIFY_HOME" >&2
    exit 1
    ;;
esac

if [ -e "$VERIFY_HOME" ] && [ ! -f "$VERIFY_HOME/.fm-verify-home" ]; then
  printf 'error: %s exists and is not a verify-firstmate home\n' "$VERIFY_HOME" >&2
  exit 1
fi

mkdir -p "$VERIFY_HOME/state" "$VERIFY_HOME/data" "$VERIFY_HOME/config" "$VERIFY_HOME/projects"
mkdir -p "$VERIFY_EVIDENCE"

{
  printf 'fm-verify-home 1\n'
  printf 'repo=%s\n' "$REPO_ROOT"
  printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'run_id=%s\n' "$RUN_ID"
} > "$VERIFY_HOME/.fm-verify-home"

VERIFY_ENV="$VERIFY_HOME/.fm-verify-env"
{
  printf 'export VERIFY_RUN_ID=%q\n' "$RUN_ID"
  printf 'export VERIFY_HOME=%q\n' "$VERIFY_HOME"
  printf 'export VERIFY_EVIDENCE=%q\n' "$VERIFY_EVIDENCE"
  printf 'export FM_HOME=%q\n' "$VERIFY_HOME"
} > "$VERIFY_ENV"

printf 'VERIFY_HOME=%s\n' "$VERIFY_HOME"
printf 'VERIFY_EVIDENCE=%s\n' "$VERIFY_EVIDENCE"
printf 'VERIFY_ENV=%s\n' "$VERIFY_ENV"
