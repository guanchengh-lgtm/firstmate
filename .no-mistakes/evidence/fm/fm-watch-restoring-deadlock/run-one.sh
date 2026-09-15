#!/usr/bin/env bash
# Runs named test functions from tests/fm-pi-watch-extension.test.sh in isolation.
# Sources lib.sh first, then evals the definitions with the trailing invocation list stripped.
T=/Users/AI/.no-mistakes/worktrees/edb446952c22/01M2J411B3HDC622SQJW44FRZY/tests
cd "$T" || exit 2
set -u
. "$T/lib.sh"
src=$(sed -e '/^test_pi_extension_reports_external_healthy_watcher$/,$d' -e 's#^\. "\$(dirname.*lib.sh"$##' fm-pi-watch-extension.test.sh)
eval "$src"
for t in "$@"; do "$t"; done
