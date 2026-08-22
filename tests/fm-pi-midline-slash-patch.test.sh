#!/usr/bin/env bash
# Behavior tests for bin/fm-pi-midline-slash-patch.sh through its public
# interface: skip a missing dist, patch a clean 0.84.x dist with mid-line
# replacements and the any-line gate, upgrade a first-line-only mid-line
# dist, leave a fully patched dist untouched, and fail without writing on a
# layout change.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PATCH="$ROOT/bin/fm-pi-midline-slash-patch.sh"
FIXTURE_ROOT="$ROOT/tests/fixtures/fm-pi-midline-slash-patch"
CLEAN_FIXTURE="$FIXTURE_ROOT/clean"
FIRST_LINE_ONLY_FIXTURE="$FIXTURE_ROOT/first-line-only"
TMP_ROOT=$(fm_test_tmproot fm-pi-midline-slash-patch)

copy_dist() {
  local src=$1 dest=$2
  mkdir -p "$dest/components"
  cp "$src/components/editor.js" "$dest/components/editor.js"
  cp "$src/autocomplete.js" "$dest/autocomplete.js"
  cp "$src/components/editor.d.ts" "$dest/components/editor.d.ts"
}

copy_clean_dist() {
  copy_dist "$CLEAN_FIXTURE" "$1"
}

copy_first_line_only_dist() {
  copy_dist "$FIRST_LINE_ONLY_FIXTURE" "$1"
}

run_patch() {
  local dist=$1
  "$PATCH" "$dist" 2>&1
}

assert_midline_markers() {
  local dist=$1
  assert_grep "isAtSlashCommandStart" "$dist/components/editor.js" \
    "$2 editor.js missing mid-line slash start"
  assert_grep "extractSlashCommandText" "$dist/autocomplete.js" \
    "$2 autocomplete.js missing mid-line slash extract"
  assert_grep "private isAtSlashCommandStart;" "$dist/components/editor.d.ts" \
    "$2 editor.d.ts missing mid-line slash start"
  assert_no_grep "isAtStartOfMessage" "$dist/components/editor.js" \
    "$2 editor.js still has the unpatched mid-line gate"
}

assert_any_line_gate() {
  local editor=$1 label=$2
  assert_grep "isSlashMenuAllowed() {" "$editor" \
    "$label missing isSlashMenuAllowed"
  assert_grep "// Slash menu allowed on any editor line" "$editor" \
    "$label missing any-line slash-menu gate"
  assert_no_grep "return this.state.cursorLine === 0;" "$editor" \
    "$label still has the first-line-only gate"
  assert_no_grep "// Slash menu only allowed on the first line of the editor" "$editor" \
    "$label still has the first-line-only comment"
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
  assert_midline_markers "$dist" "clean"
  assert_any_line_gate "$dist/components/editor.js" "clean"
  pass "fm-pi-midline-slash-patch.sh: clean dist is patched"
}

test_first_line_only_upgrades() {
  local dist out rc=0
  dist="$TMP_ROOT/first-line-only-dist"
  copy_first_line_only_dist "$dist"
  assert_grep "isAtSlashCommandStart" "$dist/components/editor.js" \
    "first-line-only fixture missing mid-line markers"
  assert_grep "return this.state.cursorLine === 0;" "$dist/components/editor.js" \
    "first-line-only fixture missing first-line gate"
  cp "$dist/components/editor.js" "$dist/editor.js.before"
  cp "$dist/autocomplete.js" "$dist/autocomplete.js.before"
  cp "$dist/components/editor.d.ts" "$dist/editor.d.ts.before"
  out=$(run_patch "$dist") || rc=$?
  expect_code 0 "$rc" "first-line-only exit"
  assert_contains "$out" "pi-midline-slash: patched " \
    "first-line-only dist did not report patched"
  assert_not_contains "$out" "pi-midline-slash: already patched " \
    "first-line-only dist was treated as already patched"
  assert_midline_markers "$dist" "first-line-only"
  assert_any_line_gate "$dist/components/editor.js" "first-line-only"
  diff -q "$dist/editor.js.before" "$dist/components/editor.js" >/dev/null \
    && fail "first-line-only upgrade did not rewrite editor.js"
  diff -q "$dist/autocomplete.js.before" "$dist/autocomplete.js" >/dev/null \
    || fail "first-line-only upgrade rewrote autocomplete.js"
  diff -q "$dist/editor.d.ts.before" "$dist/components/editor.d.ts" >/dev/null \
    || fail "first-line-only upgrade rewrote editor.d.ts"
  pass "fm-pi-midline-slash-patch.sh: first-line-only dist is upgraded"
}

test_already_patched_is_noop() {
  local dist out rc=0
  dist="$TMP_ROOT/already-patched-dist"
  copy_clean_dist "$dist"
  run_patch "$dist" >/dev/null || fail "setup patch of clean dist failed"
  assert_any_line_gate "$dist/components/editor.js" "fully patched setup"
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
test_first_line_only_upgrades
test_already_patched_is_noop
test_layout_change_fails_without_write

echo "# all fm-pi-midline-slash-patch tests passed"
