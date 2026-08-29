#!/usr/bin/env bash
# Behavioral coverage for map fog detection and spawn refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-map-fog-check.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
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

make_fake_toolchain() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION 0.1.29
  fm_fake_version_tool "$fakebin" quota-axi FM_FAKE_QUOTA_AXI_VERSION 0.1.17
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' '0.2.4' ;;
  update:--help) printf '%s\n' '--archive-body' ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  local home=$1 fakebin=$2 bootstrap=${3:-$BOOTSTRAP}
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$bootstrap" 2>&1
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

test_bootstrap_aggregates_findings_per_map() {
  local home fakebin out count
  home=$(new_home bootstrap-one-map)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap-one-map")
  mkdir -p "$home/data/prog"
  cat > "$home/data/prog/map.md" <<'EOF'
# Map

## Not yet specified

- First hole.
- Second hole.
EOF

  out=$(run_bootstrap "$home" "$fakebin")
  assert_contains "$out" \
    'MAP_FOG: data/prog/map.md - 2 findings; run bin/fm-map-fog-check.sh for details' \
    "bootstrap did not aggregate two findings for one map"
  assert_not_contains "$out" 'First hole.' "bootstrap exposed an ordinary fog detail"
  assert_not_contains "$out" 'Second hole.' "bootstrap exposed an ordinary fog detail"
  count=$(printf '%s\n' "$out" | grep -c '^MAP_FOG:' || true)
  [ "$count" -eq 1 ] || fail "bootstrap printed $count MAP_FOG lines for one map"
  pass "bootstrap: ordinary fog findings aggregate to one line per map"
}

test_bootstrap_aggregates_each_map_separately() {
  local home fakebin out count
  home=$(new_home bootstrap-two-maps)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap-two-maps")
  mkdir -p "$home/data/alpha - beta" "$home/data/gamma"
  cat > "$home/data/alpha - beta/map.md" <<'EOF'
# Alpha

## Not yet specified

- Alpha hole.
EOF
  cat > "$home/data/gamma/map.md" <<'EOF'
# Beta

## Not yet specified

- Beta hole.
EOF

  out=$(run_bootstrap "$home" "$fakebin")
  assert_contains "$out" \
    'MAP_FOG: data/alpha - beta/map.md - 1 finding; run bin/fm-map-fog-check.sh for details' \
    "bootstrap omitted the alpha map summary"
  assert_contains "$out" \
    'MAP_FOG: data/gamma/map.md - 1 finding; run bin/fm-map-fog-check.sh for details' \
    "bootstrap omitted the beta map summary"
  count=$(printf '%s\n' "$out" | grep -c '^MAP_FOG:' || true)
  [ "$count" -eq 2 ] || fail "bootstrap printed $count MAP_FOG lines for two maps"
  pass "bootstrap: separate maps keep separate fog summaries"
}

test_bootstrap_preserves_structural_failure() {
  local home fakebin out expected count
  home=$(new_home bootstrap-structural)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap-structural")
  mkdir -p "$home/data/prog"
  printf '# Map\n\n## Destination\n\nDone.\n' > "$home/data/prog/map.md"
  expected='MAP_FOG: registry invalid - data/prog/map.md is missing a ## Not yet specified section'

  out=$(run_bootstrap "$home" "$fakebin")
  assert_contains "$out" "$expected" "bootstrap changed the structural fog diagnostic"
  assert_not_contains "$out" 'checker failed with status' \
    "bootstrap added a checker-failure line for a structural failure"
  count=$(printf '%s\n' "$out" | grep -c '^MAP_FOG:' || true)
  [ "$count" -eq 1 ] || fail "bootstrap printed $count lines for one structural failure"
  pass "bootstrap: structural fog failure remains exact"
}

test_bootstrap_preserves_checker_failure_output() {
  local home fakebin lab out count
  home=$(new_home bootstrap-checker-failure)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap-checker-failure")
  lab="$TMP_ROOT/bootstrap-checker-failure/lab"
  mkdir -p "$lab"
  cp -R "$ROOT/bin" "$lab/bin"
  cat > "$lab/bin/fm-map-fog-check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'MAP_FOG: raw checker failure output'
exit 7
SH
  chmod +x "$lab/bin/fm-map-fog-check.sh"

  out=$(run_bootstrap "$home" "$fakebin" "$lab/bin/fm-bootstrap.sh")
  assert_contains "$out" 'MAP_FOG: raw checker failure output' \
    "bootstrap changed the checker failure output"
  assert_contains "$out" 'MAP_FOG: checker failed with status 7' \
    "bootstrap omitted the checker failure status"
  count=$(printf '%s\n' "$out" | grep -c '^MAP_FOG:' || true)
  [ "$count" -eq 2 ] || fail "bootstrap printed $count lines for one checker failure"
  pass "bootstrap: checker failure output and status remain exact"
}

test_absent_maps_are_silent
test_missing_section_is_structural
test_untokenized_bullet_is_live
test_parked_and_closed_and_none_are_clean
test_explicit_none_only_is_clean
test_closed_missing_pointer_is_finding
test_expect_rule_pins_live_count
test_bootstrap_aggregates_findings_per_map
test_bootstrap_aggregates_each_map_separately
test_bootstrap_preserves_structural_failure
test_bootstrap_preserves_checker_failure_output

echo "# all fm-map-fog-check tests passed"
