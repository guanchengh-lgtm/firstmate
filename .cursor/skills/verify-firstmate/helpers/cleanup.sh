#!/usr/bin/env bash
# Remove only the isolated verification home this skill created.
# Usage: cleanup.sh
#        VERIFY_HOME=... cleanup.sh
#        cleanup.sh /path/to/.fm-verify-env
# Never deletes VERIFY_EVIDENCE.
# Never deletes the live checkout, projects/, or an unmarked directory.
set -eu

if [ "${1:-}" != "" ] && [ -f "$1" ]; then
  # shellcheck disable=SC1090
  . "$1"
fi

if [ -z "${VERIFY_HOME:-}" ] && [ -n "${VERIFY_ENV:-}" ] && [ -f "$VERIFY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$VERIFY_ENV"
fi

if [ -z "${VERIFY_HOME:-}" ]; then
  printf 'error: VERIFY_HOME is unset; refuse to guess a cleanup target\n' >&2
  exit 1
fi

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HELPER_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

case "$VERIFY_HOME" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    printf 'error: refuse to delete the live checkout (%s)\n' "$VERIFY_HOME" >&2
    exit 1
    ;;
esac

if [ ! -e "$VERIFY_HOME" ]; then
  printf 'cleanup: already gone %s\n' "$VERIFY_HOME"
  if [ -n "${VERIFY_EVIDENCE:-}" ]; then
    printf 'evidence_kept: %s\n' "$VERIFY_EVIDENCE"
  fi
  exit 0
fi

if [ ! -f "$VERIFY_HOME/.fm-verify-home" ]; then
  printf 'error: %s has no .fm-verify-home marker; refuse to delete\n' "$VERIFY_HOME" >&2
  exit 1
fi

if ! grep -qx 'fm-verify-home 1' "$VERIFY_HOME/.fm-verify-home"; then
  printf 'error: %s marker is not a verify-firstmate home; refuse to delete\n' "$VERIFY_HOME" >&2
  exit 1
fi

rm -rf "$VERIFY_HOME"
printf 'cleanup: removed %s\n' "$VERIFY_HOME"
if [ -n "${VERIFY_EVIDENCE:-}" ]; then
  printf 'evidence_kept: %s\n' "$VERIFY_EVIDENCE"
fi
