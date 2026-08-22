#!/usr/bin/env bash
# Behavior tests for bin/fm-pi-midline-slash-patch.sh through its public
# interface: skip a missing dist, patch a clean 0.84.x dist, and leave an
# already-patched dist untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATCH="$ROOT/bin/fm-pi-midline-slash-patch.sh"
FIXTURE="$ROOT/tests/fixtures/fm-pi-midline-slash-patch/clean"
TMP_ROOT=$(fm_test_tmproot fm-pi-midline-slash-patch)

copy_clean_dist() {
  local dest=$1
  mkdir -p "$dest/components"
  cp "$FIXTURE/components/editor.js" "$dest/components/editor.js"
  cp "$FIXTURE/autocomplete.js" "$dest/autocomplete.js"
  cp "$FIXTURE/components/editor.d.ts" "$dest/components/editor.d.ts"
}

run_patch() {
  local dist=$1
  "$PATCH" "$dist" 2>&1
}

test_missing_dist_skips() {
  local out rc=0
  out=$(run_patch "$TMP_ROOT/missing-dist") || rc=$?
  expect_code 0 "$rc" "missing dist exit"
  assert_contains "$out" "pi-midline-slash: skipped: Pi tui dist not found" \
    "missing dist did not print a skip"
  pass "fm-pi-midline-slash-patch.sh: missing dist skips"
}

test_clean_dist_patches() {
  local dist out rc=0
  dist="$TMP_ROOT/clean-dist"
  copy_clean_dist "$dist"
  out=$(run_patch "$dist") || rc=$?
  expect_code 0 "$rc" "clean dist exit"
  assert_contains "$out" "pi-midline-slash: patched " "clean dist did not report patched"
  assert_grep "isAtSlashCommandStart" "$dist/components/editor.js" \
    "clean editor.js was not patched"
  assert_grep "extractSlashCommandText" "$dist/autocomplete.js" \
    "clean autocomplete.js was not patched"
  assert_grep "private isAtSlashCommandStart;" "$dist/components/editor.d.ts" \
    "clean editor.d.ts was not patched"
  assert_no_grep "isAtStartOfMessage" "$dist/components/editor.js" \
    "clean editor.js still has the unpatched gate"
  pass "fm-pi-midline-slash-patch.sh: clean dist is patched"
}

test_already_patched_is_noop() {
  local dist out rc=0
  dist="$TMP_ROOT/already-patched-dist"
  copy_clean_dist "$dist"
  run_patch "$dist" >/dev/null || fail "setup patch of clean dist failed"
  cp "$dist/components/editor.js" "$dist/editor.js.before"
  cp "$dist/autocomplete.js" "$dist/autocomplete.js.before"
  cp "$dist/components/editor.d.ts" "$dist/editor.d.ts.before"
  out=$(run_patch "$dist") || rc=$?
  expect_code 0 "$rc" "already patched exit"
  assert_contains "$out" "pi-midline-slash: already patched " \
    "already patched dist did not report already patched"
  diff -q "$dist/editor.js.before" "$dist/components/editor.js" >/dev/null \
    || fail "already patched re-run rewrote editor.js"
  diff -q "$dist/autocomplete.js.before" "$dist/autocomplete.js" >/dev/null \
    || fail "already patched re-run rewrote autocomplete.js"
  diff -q "$dist/editor.d.ts.before" "$dist/components/editor.d.ts" >/dev/null \
    || fail "already patched re-run rewrote editor.d.ts"
  pass "fm-pi-midline-slash-patch.sh: already patched dist is a no-op"
}

test_layout_change_fails_without_write() {
  local dist out rc=0
  dist="$TMP_ROOT/layout-changed-dist"
  mkdir -p "$dist/components"
  printf 'not a pi tui dist\n' > "$dist/components/editor.js"
  printf 'not a pi tui dist\n' > "$dist/autocomplete.js"
  printf 'not a pi tui dist\n' > "$dist/components/editor.d.ts"
  cp "$dist/components/editor.js" "$dist/editor.js.before"
  out=$(run_patch "$dist") || rc=$?
  expect_code 1 "$rc" "layout-changed exit"
  assert_contains "$out" "pi-midline-slash: failed: dist layout changed:" \
    "layout change did not print a fail"
  diff -q "$dist/editor.js.before" "$dist/components/editor.js" >/dev/null \
    || fail "layout-changed run wrote editor.js"
  pass "fm-pi-midline-slash-patch.sh: layout change fails without writing"
}

test_missing_dist_skips
test_clean_dist_patches
test_already_patched_is_noop
test_layout_change_fails_without_write

echo "# all fm-pi-midline-slash-patch tests passed"
