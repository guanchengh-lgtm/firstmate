#!/usr/bin/env bash
# Direct tests for bin/fm-promote.sh owned surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)

test_promote_help_owns_the_workflow_without_runtime_state() {
  local isolated home out status
  isolated="$TMP_ROOT/promote-help"
  home="$TMP_ROOT/promote-help-home"
  mkdir -p "$isolated/bin"
  cp "$ROOT/bin/fm-promote.sh" "$isolated/bin/fm-promote.sh"

  out=$(FM_ROOT_OVERRIDE="$isolated" FM_HOME="$home" \
    "$isolated/bin/fm-promote.sh" --help 2>&1)
  status=$?
  expect_code 0 "$status" "promotion help should work without runtime dependencies"
  assert_contains "$out" "existing scout in place" \
    "promotion help did not preserve the no-duplicate-task workflow"
  assert_contains "$out" "[--surface <internal-only|product|mixed|uncertain>]" \
    "promotion help omitted the --surface usage"
  [ ! -e "$home" ] || fail "promotion help created runtime state"
  pass "fm-promote: help owns the promotion workflow without runtime state"
}

test_promote_help_owns_the_workflow_without_runtime_state
echo "# all fm-promote tests passed"
