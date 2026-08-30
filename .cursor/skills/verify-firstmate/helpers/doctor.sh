#!/usr/bin/env bash
# Read-only check: is this isolated firstmate home worth driving?
# Usage: doctor.sh
#        VERIFY_HOME=... doctor.sh
#        doctor.sh /path/to/.fm-verify-env
# Exit 0 when the isolated home is driveable for bin-script and test-runner
# features. Missing optional toolchain lines are reported, not failed.
# Exit 1 when the home is missing, unmarked, or a required script will not parse.
set -eu

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HELPER_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"

if [ "${1:-}" != "" ] && [ -f "$1" ]; then
  # shellcheck disable=SC1090
  . "$1"
fi

if [ -z "${VERIFY_HOME:-}" ] && [ -n "${VERIFY_ENV:-}" ] && [ -f "$VERIFY_ENV" ]; then
  # shellcheck disable=SC1090
  . "$VERIFY_ENV"
fi

if [ -z "${VERIFY_HOME:-}" ]; then
  printf 'error: VERIFY_HOME is unset; run helpers/launch.sh first\n' >&2
  exit 1
fi

failed=0
missing_count=0

fail_line() {
  printf 'doctor: FAILED - %s\n' "$1" >&2
  failed=1
}

if [ ! -f "$VERIFY_HOME/.fm-verify-home" ]; then
  fail_line "no .fm-verify-home marker at $VERIFY_HOME"
  exit 1
fi

if ! grep -qx 'fm-verify-home 1' "$VERIFY_HOME/.fm-verify-home"; then
  fail_line "unrecognized .fm-verify-home marker"
  exit 1
fi

for dir in state data config projects; do
  if [ ! -d "$VERIFY_HOME/$dir" ]; then
    fail_line "missing $dir/ under $VERIFY_HOME"
  fi
done

printf 'home: %s\n' "$VERIFY_HOME"
printf 'repo: %s\n' "$REPO_ROOT"

if [ ! -x "$REPO_ROOT/bin/fm-brief.sh" ]; then
  fail_line "bin/fm-brief.sh is not executable in $REPO_ROOT"
fi

for script in \
  bin/fm-session-start.sh \
  bin/fm-bootstrap.sh \
  bin/fm-brief.sh \
  bin/fm-bearings-snapshot.sh \
  bin/fm-lock.sh \
  bin/fm-test-run.sh
do
  if [ ! -f "$REPO_ROOT/$script" ]; then
    fail_line "missing $script"
    continue
  fi
  if /bin/bash -n "$REPO_ROOT/$script"; then
    printf 'parse: ok %s\n' "$script"
  else
    fail_line "bash -n $script failed"
  fi
done

lock_out=$(FM_HOME="$VERIFY_HOME" "$REPO_ROOT/bin/fm-lock.sh" status) || true
printf '%s\n' "$lock_out"

detect_out=$(FM_HOME="$VERIFY_HOME" FM_BOOTSTRAP_DETECT_ONLY=1 "$REPO_ROOT/bin/fm-bootstrap.sh" 2>&1) || true
if [ -z "$detect_out" ]; then
  printf 'bootstrap: silent (all detected tools present)\n'
else
  printf 'bootstrap:\n'
  printf '%s\n' "$detect_out"
  missing_count=$(printf '%s\n' "$detect_out" | grep -c '^MISSING' || true)
fi

if ! "$REPO_ROOT/bin/fm-test-run.sh" --list tests/fm-brief.test.sh >/dev/null; then
  fail_line "bin/fm-test-run.sh --list tests/fm-brief.test.sh failed"
else
  printf 'test-run: lists tests/fm-brief.test.sh\n'
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'doctor: driveable isolated-bin-scripts (missing_tools=%s)\n' "$missing_count"
printf 'note: MISSING treehouse/no-mistakes/axi tools block spawn and no-mistakes delivery, not brief, bearings, session-start, or the behavior suite.\n'
exit 0
