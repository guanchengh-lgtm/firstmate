#!/usr/bin/env bash
# Behavioral coverage for the optional durable-SoT program registry and bootstrap signal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-sot-pointer-check.sh"
HISTORICAL_FIXTURE="$ROOT/tests/fixtures/fm-sot-pointer-check/historical-stale-authority"
TMP_ROOT=$(fm_test_tmproot fm-sot-pointer-check)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config"
  printf '%s\n' "$home"
}

enable_tasks() {  # <home>
  local home=$1
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  [ -f "$home/data/backlog.md" ] || cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

tasks_in() {  # <home> <args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decision() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

create_open_hold() {  # <home> <origin> <key>
  local home=$1 origin=$2 key=$3
  mkdir -p "$home/data/$origin"
  printf '# Historical decision origin\n' > "$home/data/$origin/report.md"
  run_decision "$home" hold "$origin" "$key" \
    --title "Choose the earlier authority" --reason "captain authority pending" --repo sample
}

reopen_derived_hold() {  # <home> <hold-id> <open-row-file>
  local home=$1 hold_id=$2 open_row=$3 rewritten
  rewritten="$home/data/backlog.rewritten"
  awk -v hold_id="$hold_id" -v open_row="$open_row" '
    BEGIN {
      getline replacement < open_row
      close(open_row)
    }
    $0 == "## Queued" {
      print
      print replacement
      next
    }
    skipping && /^  / { next }
    skipping { skipping = 0 }
    $1 == "-" && $2 == "[x]" && $3 == hold_id {
      skipping = 1
      next
    }
    { print }
  ' "$home/data/backlog.md" > "$rewritten" || fail "could not derive reopened hold fixture"
  mv "$rewritten" "$home/data/backlog.md"
}

assert_silent_success() {
  local label=$1 home=$2 out rc
  set +e
  out=$(FM_HOME="$home" "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "$label exited $rc"
  [ -z "$out" ] || fail "$label should be silent, got: $out"
}

test_absent_registry_is_silent() {
  local home
  home=$(new_home absent)
  assert_silent_success "absent registry" "$home"
  : > "$home/data/sot-programs.tsv"
  assert_silent_success "empty registry" "$home"
  pass "sot pointer check: absent and empty registries are silent success"
}

test_done_sources_with_matching_pointers_are_clean() {
  local home
  home=$(new_home matching)
  mkdir -p "$home/data/decisions"
  printf '%s\n' \
    '- [x] gex-research - Research complete' \
    '- [x] gex-review - Review complete' > "$home/data/done-archive.md"
  printf '%s\n' '- Standing pointer: gex-v1.1 is the durable source.' > "$home/data/captain.md"
  printf '%s\n' 'The material lock is filed as locked-by-review.' > "$home/data/decisions/2026-08-12-gex.md"
  printf '%s\t%s\t%s\n' \
    captain-pointer 'gex-v1\.1' 'gex-research,gex-review' \
    decision-pointer 'locked-by-review' 'gex-research,gex-review' \
    > "$home/config/sot-programs.tsv"

  assert_silent_success "matching captain and decision pointers" "$home"
  pass "sot pointer check: completed sources accept matching captain and decision pointers"
}

test_done_sources_without_pointer_report_gap_and_strict_fails() {
  local home registry expected out rc strict_out strict_rc
  home=$(new_home missing)
  registry="$home/explicit.tsv"
  printf '%s\n' \
    '- [x] source-a - Complete' \
    '- [x] source-b - Complete' > "$home/data/backlog.md"
  printf '%s\n' '# No matching standing pointer.' > "$home/data/captain.md"
  printf '%s\t%s\t%s\n' program-b 'program-b-v2\.0' 'source-a,source-b' > "$registry"
  expected='SOT_GAP: program-b - sources Done but no standing pointer matching /program-b-v2\.0/ in captain.md|decisions/'

  set +e
  out=$(FM_HOME="$home" "$CHECK" --registry "$registry" 2>&1)
  rc=$?
  strict_out=$(FM_HOME="$home" "$CHECK" --strict --registry "$registry" 2>&1)
  strict_rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "default gap check exited $rc instead of bootstrap-safe success"
  [ "$out" = "$expected" ] || fail "gap output mismatch: $out"
  [ "$strict_rc" -eq 1 ] || fail "strict gap check exited $strict_rc instead of 1"
  [ "$strict_out" = "$expected" ] || fail "strict gap output mismatch: $strict_out"
  pass "sot pointer check: missing pointers report exactly and fail only in strict mode"
}

test_incomplete_sources_are_not_enforced() {
  local home
  home=$(new_home incomplete)
  printf '%s\n' \
    '- [x] source-a - Complete' \
    '- [ ] source-b - Still open' > "$home/data/backlog.md"
  printf '%s\t%s\t%s\n' program-open 'missing-pointer' 'source-a,source-b' \
    > "$home/data/sot-programs.tsv"

  assert_silent_success "incomplete source set" "$home"
  pass "sot pointer check: incomplete source sets are skipped"
}

test_superseded_hold_reports_exact_rule_and_count() {
  local home registry hold expected out rc strict_rc exact_rc mismatch_out mismatch_rc
  home=$(new_home superseded-hold)
  enable_tasks "$home"
  registry="$home/config/sot-programs.tsv"
  mkdir -p "$home/data/decisions"
  tasks_in "$home" add look-ship "Later look shipped" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" look-ship >/dev/null
  hold=$(create_open_hold "$home" review layout)
  printf '%s\n' 'The locked look is the standing source.' > "$home/data/decisions/look-lock.md"
  printf '%s\t%s\t%s\t%s\n' \
    look-program 'locked look' look-ship "$hold" > "$registry"
  expected="SOT_GAP: look-program - captain hold $hold is open, not bound to the later authority"

  set +e
  out=$(FM_HOME="$home" "$CHECK" 2>&1)
  rc=$?
  FM_HOME="$home" "$CHECK" --strict >/dev/null 2>&1
  strict_rc=$?
  FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 1 >/dev/null 2>&1
  exact_rc=$?
  mismatch_out=$(FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 0 2>&1)
  mismatch_rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "detect-only superseded-hold finding exited $rc"
  [ "$out" = "$expected" ] || fail "superseded-hold output mismatch: $out"
  [ "$strict_rc" -eq 1 ] || fail "strict superseded-hold finding exited $strict_rc instead of 1"
  [ "$exact_rc" -eq 0 ] || fail "exact-count superseded-hold regression did not pass"
  [ "$mismatch_rc" -eq 1 ] || fail "wrong exact-count expectation exited $mismatch_rc instead of 1"
  assert_contains "$mismatch_out" \
    'SOT_EXPECTATION: R-SOT-SUPERSEDED-HOLD expected 0 finding(s) and 0 total, observed 1 and 1 total' \
    "wrong exact-count expectation did not identify the rule and counts"
  pass "sot pointer check: later ground truth reports one exact stale-hold finding"
}

test_bound_superseded_hold_is_clean() {
  local home hold
  home=$(new_home bound-hold)
  enable_tasks "$home"
  mkdir -p "$home/data/decisions"
  tasks_in "$home" add look-ship "Later look shipped" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" look-ship >/dev/null
  hold=$(create_open_hold "$home" review layout)
  printf '%s\n' 'The locked look is the standing source.' > "$home/data/decisions/look-lock.md"
  run_decision "$home" supersede review layout \
    --decision-file data/decisions/look-lock.md --shipped-task look-ship >/dev/null
  printf '%s\t%s\t%s\t%s\n' \
    look-program 'locked look' look-ship "$hold" \
    > "$home/data/sot-programs.tsv"

  assert_silent_success "resolved superseded hold" "$home"
  FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 0 >/dev/null \
    || fail "resolved hold did not produce an exact zero count"
  pass "sot pointer check: an exact later-authority binding is clean"
}

test_registry_structure_fails_closed_before_findings() {
  local home out rc
  home=$(new_home malformed)
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  printf '%s\n' \
    $'valid\tmissing-pointer\tsource-a' \
    $'broken\tonly-two-fields' \
    > "$home/data/sot-programs.tsv"

  set +e
  out=$(FM_HOME="$home" "$CHECK" 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 2 ] || fail "malformed registry exited $rc instead of structural 2"
  assert_contains "$out" \
    'SOT_GAP: registry invalid - line 2 must contain exactly 3 or 4 tab-separated fields' \
    "malformed registry did not name its structural failure"
  assert_not_contains "$out" 'sources Done but no standing pointer' \
    "checker printed a partial finding before validating the whole registry"
  pass "sot pointer check: malformed structure exits 2 before any findings"
}

test_registry_csv_errors_fail_closed_in_process() {
  local home out rc row label
  home=$(new_home malformed-csv)
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  for label in invalid duplicate empty; do
    case "$label" in
      invalid) row=$'program\tpointer\tsource/a' ;;
      duplicate) row=$'program\tpointer\tsource-a,source-a' ;;
      empty) row=$'program\tpointer\tsource-a,,source-b' ;;
    esac
    printf '%s\n' "$row" > "$home/data/sot-programs.tsv"
    set +e
    out=$(FM_HOME="$home" "$CHECK" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "$label CSV registry exited $rc instead of 2"
    assert_contains "$out" 'SOT_GAP: registry invalid -' \
      "$label CSV registry failure escaped its structural diagnostic"
  done
  pass "sot pointer check: invalid, duplicate, and empty CSV elements fail closed"
}

test_ineffective_data_registry_cannot_shadow_populated_config() {
  local home out expected
  home=$(new_home empty-data-shadow)
  : > "$home/data/sot-programs.tsv"
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  printf '%s\t%s\t%s\n' config-program config-pointer source-a \
    > "$home/config/sot-programs.tsv"
  expected='SOT_GAP: config-program - sources Done but no standing pointer matching /config-pointer/ in captain.md|decisions/'
  out=$(FM_HOME="$home" "$CHECK")
  [ "$out" = "$expected" ] || fail "empty data registry shadowed populated config: $out"
  printf '  # no effective rows\n\n' > "$home/data/sot-programs.tsv"
  out=$(FM_HOME="$home" "$CHECK")
  [ "$out" = "$expected" ] || fail "comment-only data registry shadowed populated config: $out"
  pass "sot pointer check: empty and comment-only data registries do not shadow populated config"
}

test_pointer_gap_does_not_skip_stale_hold_rule() {
  local home hold out rc
  home=$(new_home pointer-and-hold-gap)
  enable_tasks "$home"
  tasks_in "$home" add look-ship "Later look shipped" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" look-ship >/dev/null
  hold=$(create_open_hold "$home" review layout)
  printf '%s\t%s\t%s\t%s\n' \
    look-program missing-look-pointer look-ship "$hold" > "$home/data/sot-programs.tsv"
  set +e
  out=$(FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-POINTER --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "pointer-only exact count hid the stale hold finding"
  assert_contains "$out" 'captain hold review-decision-layout is open, not bound to the later authority' \
    "pointer gap skipped the registered stale hold"
  assert_contains "$out" 'expected 1 finding(s) and 1 total, observed 1 and 2 total' \
    "combined pointer and stale-hold gap did not enforce total count"
  pass "sot pointer check: pointer gap cannot suppress its stale-hold rule"
}

test_exact_count_rejects_unexpected_other_rule() {
  local home hold_a hold_b out rc
  home=$(new_home exact-total)
  enable_tasks "$home"
  mkdir -p "$home/data/decisions"
  tasks_in "$home" add look-ship "Later look shipped" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" look-ship >/dev/null
  hold_a=$(create_open_hold "$home" review-a layout)
  hold_b=$(create_open_hold "$home" review-b layout)
  printf '%s\n' 'The locked look is the standing source.' > "$home/data/decisions/look-lock.md"
  printf '%s\t%s\t%s\t%s\n' \
    look-a 'locked look' look-ship "$hold_a" \
    look-b 'locked look' look-ship "$hold_b" \
    > "$home/data/sot-programs.tsv"
  FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 2 >/dev/null \
    || fail "exact-count two did not accept exactly two same-class findings"
  printf '%s\t%s\t%s\n' other-program missing-other-pointer look-ship \
    >> "$home/data/sot-programs.tsv"
  set +e
  out=$(FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 2 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "exact-count mode accepted an unexpected other-rule finding"
  assert_contains "$out" 'expected 2 finding(s) and 2 total, observed 2 and 3 total' \
    "exact-count mismatch did not report selected and total counts"
  pass "sot pointer check: exact-count two rejects any unexpected extra rule"
}

test_registry_rejects_unknown_sources_and_rules() {
  local home source_out source_rc rule_out rule_rc
  home=$(new_home invalid-identities)
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  printf '%s\t%s\t%s\n' invalid-source pointer source-missing \
    > "$home/data/sot-programs.tsv"

  set +e
  source_out=$(FM_HOME="$home" "$CHECK" 2>&1)
  source_rc=$?
  rule_out=$(FM_HOME="$home" "$CHECK" --expect-rule NOT-A-RULE --expect-count 1 2>&1)
  rule_rc=$?
  set -e

  [ "$source_rc" -eq 2 ] || fail "unknown source identity exited $source_rc instead of 2"
  assert_contains "$source_out" 'source_task_id source-missing has 0 authoritative task rows' \
    "unknown source identity did not fail closed"
  [ "$rule_rc" -eq 2 ] || fail "unknown expectation rule exited $rule_rc instead of 2"
  assert_contains "$rule_out" 'error: unknown rule id: NOT-A-RULE' \
    "unknown expectation rule did not identify itself"
  pass "sot pointer check: unknown source and rule identities fail closed"
}

test_indented_body_checkbox_cannot_impersonate_task_row() {
  local home out rc
  home=$(new_home body-checkbox)
  cat > "$home/data/backlog.md" <<'EOF'
- [x] real-task - Complete
  - [x] source-missing - Mentioned only inside the real task body
EOF
  printf '%s\t%s\t%s\n' body-checkbox pointer source-missing \
    > "$home/data/sot-programs.tsv"
  set +e
  out=$(FM_HOME="$home" "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "indented body checkbox impersonated an authoritative task row"
  assert_contains "$out" 'source_task_id source-missing has 0 authoritative task rows' \
    "body checkbox failure did not preserve the exact task-row boundary"
  pass "sot pointer check: indented body checkboxes cannot impersonate tasks"
}

test_implicit_registry_and_decisions_symlinks_fail_closed() {
  local registry_home dangling_home decisions_home registry_out registry_rc dangling_out dangling_rc
  local decisions_out decisions_rc
  registry_home=$(new_home registry-symlink)
  printf '%s\n' '- [x] source-a - Complete' > "$registry_home/data/done-archive.md"
  printf '%s\t%s\t%s\n' linked pointer source-a > "$registry_home/registry-real"
  ln -s ../registry-real "$registry_home/data/sot-programs.tsv"

  dangling_home=$(new_home dangling-registry-symlink)
  ln -s ../missing-registry "$dangling_home/data/sot-programs.tsv"

  decisions_home=$(new_home decisions-symlink)
  printf '%s\n' \
    '- [x] source-a - Complete' \
    '- [ ] origin-decision-layout - Earlier layout (kind: captain) (hold: earlier pick) (hold-kind: captain)' \
    > "$decisions_home/data/backlog.md"
  printf '%s\t%s\t%s\t%s\n' \
    linked-decisions pointer source-a origin-decision-layout \
    > "$decisions_home/data/sot-programs.tsv"
  mkdir -p "$decisions_home/external-decisions"
  printf '%s\n' pointer > "$decisions_home/external-decisions/lock.md"
  ln -s ../external-decisions "$decisions_home/data/decisions"

  set +e
  registry_out=$(FM_HOME="$registry_home" "$CHECK" 2>&1)
  registry_rc=$?
  dangling_out=$(FM_HOME="$dangling_home" "$CHECK" 2>&1)
  dangling_rc=$?
  decisions_out=$(FM_HOME="$decisions_home" "$CHECK" 2>&1)
  decisions_rc=$?
  set -e

  [ "$registry_rc" -eq 2 ] || fail "implicit registry symlink exited $registry_rc instead of 2"
  assert_contains "$registry_out" 'registry invalid - path is not a regular non-symlink file' \
    "implicit registry symlink reported clean"
  [ "$dangling_rc" -eq 2 ] || fail "dangling registry symlink exited $dangling_rc instead of 2"
  assert_contains "$dangling_out" 'registry invalid - path is not a regular non-symlink file' \
    "dangling implicit registry symlink reported clean"
  [ "$decisions_rc" -eq 2 ] || fail "decisions symlink exited $decisions_rc instead of 2"
  assert_contains "$decisions_out" \
    'pointer source is not a readable non-symlink directory' \
    "decisions symlink supplied an out-of-home clean pointer"
  pass "sot pointer check: registry and decisions symlinks fail closed"
}

test_historical_checkout_fixture_reverses_clean_to_one_and_back() {
  local home hold clean_hash roundtrip_hash clean_rows broken_rows out rc expected artifact expected_hash actual_hash source_date
  home=$(new_home historical-checkout)
  enable_tasks "$home"
  mkdir -p "$home/data/decisions"
  cp "$HISTORICAL_FIXTURE/backlog.fixture" "$home/data/backlog.md"
  cp "$HISTORICAL_FIXTURE/decision.fixture" "$home/data/decisions/look-lock.md"
  cp "$HISTORICAL_FIXTURE/registry.fixture" "$home/data/sot-programs.tsv"
  hold=tv-gamma-impl-intake-decision-level-coincidence
  expected="SOT_GAP: gamma-look-ship-20260815 - captain hold $hold is open, not bound to the later authority"
  source_date=$(jq -r '.source_date // empty' "$HISTORICAL_FIXTURE/provenance.json")
  case "$source_date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) fail "historical fixture provenance lacks a canonical source_date" ;;
  esac

  FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 0 >/dev/null \
    || fail "derived canonical fixture was not clean"
  sed 's/Supersession recorded by fm-decision-hold\./Supersession recorded by fm-captain-hold./' \
    "$home/data/backlog.md" > "$home/data/backlog.normalized"
  clean_hash=$(shasum -a 256 "$home/data/backlog.normalized" | awk '{print $1}')
  clean_rows=$(grep -c -- "$hold" "$home/data/backlog.md")
  [ "$clean_rows" -eq 1 ] || fail "canonical fixture has $clean_rows rows for the selected hold"

  reopen_derived_hold "$home" "$hold" "$HISTORICAL_FIXTURE/open-hold.fixture"
  broken_rows=$(grep -c -- "$hold" "$home/data/backlog.md")
  [ "$broken_rows" -eq 1 ] || fail "derived reversal has $broken_rows rows for the selected hold"

  set +e
  out=$(FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 1 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "historical exact-count fixture exited $rc: $out"
  [ "$out" = "$expected" ] || fail "historical fixture finding mismatch: $out"
  run_decision "$home" supersede tv-gamma-impl-intake level-coincidence \
    --decision-file data/decisions/look-lock.md --shipped-task tv-gamma-look-ship >/dev/null \
    || fail "derived fixture could not rebind the later authority"
  FM_HOME="$home" "$CHECK" \
    --expect-rule R-SOT-SUPERSEDED-HOLD --expect-count 0 >/dev/null \
    || fail "rebound derived fixture was not clean"
  # tasks-axi stamps (done YYYY-MM-DD) from the local wall clock. The generator
  # pins that stamp to provenance.source_date so the checked-in backlog bytes stay
  # stable across timezones; mirror that pin before the round-trip hash compare.
  sed -E 's/\(done [0-9]{4}-[0-9]{2}-[0-9]{2}\)/(done '"$source_date"')/' \
    "$home/data/backlog.md" > "$home/data/backlog.pinned"
  mv "$home/data/backlog.pinned" "$home/data/backlog.md"
  sed 's/Supersession recorded by fm-decision-hold\./Supersession recorded by fm-captain-hold./' \
    "$home/data/backlog.md" > "$home/data/backlog.normalized"
  roundtrip_hash=$(shasum -a 256 "$home/data/backlog.normalized" | awk '{print $1}')
  [ "$roundtrip_hash" = "$clean_hash" ] \
    || fail "derived fixture did not round-trip to its canonical backlog hash"
  jq -e '
    .derived == true
      and .project_commit == "0d8bb3bb62ada54197185924bfc4ce1908432b1a"
      and .project_pr == 98
  ' "$HISTORICAL_FIXTURE/provenance.json" >/dev/null \
    || fail "historical fixture provenance is incomplete"
  for artifact in decision.fixture backlog.fixture open-hold.fixture done-archive.fixture; do
    expected_hash=$(jq -r --arg artifact "$artifact" '.sha256[$artifact] // empty' \
      "$HISTORICAL_FIXTURE/provenance.json")
    actual_hash=$(shasum -a 256 "$HISTORICAL_FIXTURE/$artifact" | awk '{print $1}')
    [ -n "$expected_hash" ] && [ "$actual_hash" = "$expected_hash" ] \
      || fail "historical fixture provenance hash mismatch: $artifact"
  done
  pass "sot pointer check: checked-out PR 98 fixture reverses 0 to 1 and round-trips clean"
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

test_bootstrap_surfaces_gap_in_detect_only_local_phase() {
  local home fakebin out expected
  home=$(new_home bootstrap)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap")
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  printf '%s\t%s\t%s\n' bootstrap-program 'standing-pointer' source-a \
    > "$home/data/sot-programs.tsv"
  expected='SOT_GAP: bootstrap-program - sources Done but no standing pointer matching /standing-pointer/ in captain.md|decisions/'

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "$expected" "detect-only bootstrap did not surface the SoT gap"
  pass "bootstrap: detect-only local startup surfaces SOT_GAP diagnostics"
}

test_bootstrap_surfaces_structural_failure_without_aborting() {
  local home fakebin out rc expected
  home=$(new_home bootstrap-invalid)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap-invalid")
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  printf '%s\n' $'broken\tonly-two-fields' > "$home/data/sot-programs.tsv"
  expected='SOT_GAP: registry invalid - line 1 must contain exactly 3 or 4 tab-separated fields'

  set +e
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "bootstrap aborted on structural SoT failure with exit $rc"
  assert_contains "$out" "$expected" "bootstrap did not surface structural SoT failure"
  pass "bootstrap: structural SoT failure stays loud without aborting startup detection"
}

test_bootstrap_surfaces_csv_structural_failures() {
  local home fakebin out rc row label
  home=$(new_home bootstrap-invalid-csv)
  fakebin=$(make_fake_toolchain "$TMP_ROOT/bootstrap-invalid-csv")
  printf '%s\n' '- [x] source-a - Complete' > "$home/data/done-archive.md"
  for label in invalid duplicate empty; do
    case "$label" in
      invalid) row=$'program\tpointer\tsource/a' ;;
      duplicate) row=$'program\tpointer\tsource-a,source-a' ;;
      empty) row=$'program\tpointer\tsource-a,,source-b' ;;
    esac
    printf '%s\n' "$row" > "$home/data/sot-programs.tsv"
    set +e
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
      FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "bootstrap aborted on $label CSV structural failure"
    assert_contains "$out" 'SOT_GAP: registry invalid -' \
      "bootstrap hid $label CSV structural failure"
  done
  pass "bootstrap: invalid, duplicate, and empty CSV elements stay loud"
}

test_absent_registry_is_silent
test_done_sources_with_matching_pointers_are_clean
test_done_sources_without_pointer_report_gap_and_strict_fails
test_incomplete_sources_are_not_enforced
test_superseded_hold_reports_exact_rule_and_count
test_bound_superseded_hold_is_clean
test_registry_structure_fails_closed_before_findings
test_registry_csv_errors_fail_closed_in_process
test_ineffective_data_registry_cannot_shadow_populated_config
test_pointer_gap_does_not_skip_stale_hold_rule
test_exact_count_rejects_unexpected_other_rule
test_registry_rejects_unknown_sources_and_rules
test_indented_body_checkbox_cannot_impersonate_task_row
test_implicit_registry_and_decisions_symlinks_fail_closed
test_historical_checkout_fixture_reverses_clean_to_one_and_back
test_bootstrap_surfaces_gap_in_detect_only_local_phase
test_bootstrap_surfaces_structural_failure_without_aborting
test_bootstrap_surfaces_csv_structural_failures
