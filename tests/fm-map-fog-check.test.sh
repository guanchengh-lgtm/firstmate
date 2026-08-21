#!/usr/bin/env bash
# Behavioral coverage for map fog detection and spawn refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-map-fog-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-map-fog-check)

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config" "$home/state"
  printf '%s\n' "$home"
}

run_check() {
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$CHECK" "$@" 2>&1
}

test_absent_maps_are_silent() {
  local home out rc
  home=$(new_home absent)
  set +e
  out=$(run_check "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "absent maps exited $rc"
  [ -z "$out" ] || fail "absent maps should be silent, got: $out"
  pass "map-fog: no map files is silent success"
}

test_missing_section_is_structural() {
  local home out rc
  home=$(new_home nosection)
  mkdir -p "$home/data/prog"
  printf '# Map\n\n## Destination\n\nDone.\n' > "$home/data/prog/map.md"
  set +e
  out=$(run_check "$home" "$home/data/prog/map.md")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing section exited $rc"
  assert_contains "$out" 'missing a ## Not yet specified section' \
    "structural failure did not name the missing section"
  pass "map-fog: missing Not yet specified section is exit 2"
}

test_untokenized_bullet_is_live() {
  local home out rc
  home=$(new_home live)
  mkdir -p "$home/data/prog"
  cat > "$home/data/prog/map.md" <<'EOF'
# Map

## Not yet specified

- Whether Cursor becomes a verified harness.
EOF
  set +e
  out=$(run_check "$home" --strict "$home/data/prog/map.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "live fog exited $rc"
  assert_contains "$out" 'live unspecified item' "live fog was not reported"
  pass "map-fog: untokenized bullet is live fog"
}

test_parked_and_closed_and_none_are_clean() {
  local home out rc
  home=$(new_home clean)
  mkdir -p "$home/data/prog" "$home/data/decisions"
  printf 'lock\n' > "$home/data/decisions/lock.md"
  cat > "$home/data/prog/map.md" <<'EOF'
# Map

## Not yet specified

- [parked 2026-08-21] Overnight loops.
- [closed data/decisions/lock.md] Exact names.
- none
EOF
  set +e
  out=$(run_check "$home" --strict "$home/data/prog/map.md")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "clean tokens exited $rc with: $out"
  [ -z "$out" ] || fail "clean tokens should be silent, got: $out"
  pass "map-fog: parked, closed, and none are not live"
}

test_explicit_none_only_is_clean() {
  local home out rc
  home=$(new_home noneonly)
  mkdir -p "$home/data/prog"
  cat > "$home/data/prog/map.md" <<'EOF'
# Map

## Not yet specified

- none
EOF
  set +e
  out=$(run_check "$home" --strict "$home/data/prog/map.md")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "none-only exited $rc with: $out"
  pass "map-fog: explicit - none is clean"
}

test_closed_missing_pointer_is_finding() {
  local home out rc
  home=$(new_home badclose)
  mkdir -p "$home/data/prog"
  cat > "$home/data/prog/map.md" <<'EOF'
# Map

## Not yet specified

- [closed data/missing.md] Gone.
EOF
  set +e
  out=$(run_check "$home" --strict "$home/data/prog/map.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing closed pointer exited $rc"
  assert_contains "$out" 'closed pointer does not resolve' "missing pointer was not reported"
  pass "map-fog: closed pointer must resolve to an existing file"
}

test_expect_rule_pins_live_count() {
  local home out rc
  home=$(new_home expect)
  mkdir -p "$home/data/prog"
  cat > "$home/data/prog/map.md" <<'EOF'
# Map

## Not yet specified

- First hole.
- Second hole.
EOF
  set +e
  out=$(run_check "$home" --expect-rule R-MAP-FOG-LIVE --expect-count 2 \
    "$home/data/prog/map.md")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "expect-count 2 exited $rc with: $out"
  set +e
  out=$(run_check "$home" --expect-rule R-MAP-FOG-LIVE --expect-count 1 \
    "$home/data/prog/map.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "wrong expect-count exited $rc"
  pass "map-fog: exact-count regression pins live fog"
}

test_absent_maps_are_silent
test_missing_section_is_structural
test_untokenized_bullet_is_live
test_parked_and_closed_and_none_are_clean
test_explicit_none_only_is_clean
test_closed_missing_pointer_is_finding
test_expect_rule_pins_live_count

echo "# all fm-map-fog-check tests passed"
