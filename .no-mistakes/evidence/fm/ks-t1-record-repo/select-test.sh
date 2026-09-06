#!/usr/bin/env bash
set -u
export FM_TEST_SELECTOR=$2 FM_TEST_SKIP_ORPHAN_REAP=1
bash -OT extdebug -c '
trap '\''case "$BASH_COMMAND" in
  test_*) [[ "$BASH_COMMAND" == "$FM_TEST_SELECTOR" ]] ;;
  expect_code*)
    if [[ "${FM_EVIDENCE_TRACE:-0}" == 1 ]]; then
      printf "\nObserved command result for %s\n%s\n" "$BASH_COMMAND" "${OUT:-}"
    fi
    ;;
esac'\'' DEBUG
source "$1"
' _ "$1"
