#!/usr/bin/env bash
# Behavioral coverage for the diamond-reduce matcher.
# Exercises public CLI exit codes, declared N, failed-scout escape, and
# manufactured citation breakage. Does not assert checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-reduce-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-reduce-check)

run_check() {
  env -u FM_HOME -u FM_ROOT_OVERRIDE "$CHECK" "$@" 2>&1
}

write_keep() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' "# Report" "" "### Keep" "" "| Idea | From | Why |" "|---|---|---|"
    local idea
    for idea in "$@"; do
      printf '| %s | src | why |\n' "$idea"
    done
  } > "$path"
}

write_cited() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

three_home() {
  local home=$1
  mkdir -p "$home/data/ov-a" "$home/data/ov-b" "$home/data/ov-c" "$home/data/decisions"
  write_keep "$home/data/ov-a/report.md" "Node contract: bounded job"
  write_keep "$home/data/ov-b/report.md" "Merge counts expected inputs"
  write_keep "$home/data/ov-c/report.md" "Grounded versus ungrounded"
  write_cited "$home/data/decisions/lock.md" \
    "expected-reports: ov-a, ov-b, ov-c" \
    "Cite \`data/ov-a/report.md\`." \
    "Cite \`data/ov-b/report.md\`." \
    "Cite \`data/ov-c/report.md\`."
  printf '%s\n' "$home"
}

test_missing_expect_and_cited_by_are_structural() {
  local home out rc empty
  home=$(three_home "$TMP_ROOT/struct")
  empty="$TMP_ROOT/empty.md"
  : > "$empty"
  set +e
  out=$(run_check)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "no flags exited $rc"
  assert_contains "$out" "missing --cited-by" "no flags did not name --cited-by"
  set +e
  out=$(run_check --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing --expect exited $rc"
  assert_contains "$out" "missing --expect" "missing --expect did not say missing"
  set +e
  out=$(run_check --expect "$home/data/ov-a/report.md")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing --cited-by exited $rc"
  assert_contains "$out" "missing --cited-by" "missing --cited-by did not say missing"
  set +e
  out=$(run_check --expect "$home/data/ov-a/report.md" --cited-by "$TMP_ROOT/no-such.md")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing cited-by file exited $rc"
  assert_contains "$out" "missing cited-by" "missing cited-by file did not say missing"
  pass "reduce-check: missing --expect, missing --cited-by, missing cited-by file exit 2"
}

test_n3_all_present_and_cited_is_clean() {
  local home out rc keep
  home=$(three_home "$TMP_ROOT/n3")
  keep="$TMP_ROOT/n3.keep"
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md" \
    --keep-list "$keep")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "N=3 green exited $rc: $out"
  assert_contains "$out" "id: ov-a" "keep-list omitted ov-a"
  assert_contains "$out" "keep: Node contract: bounded job" "keep-list omitted ov-a keep row"
  assert_contains "$out" "id: ov-b" "keep-list omitted ov-b"
  assert_contains "$out" "keep: Merge counts expected inputs" "keep-list omitted ov-b keep row"
  assert_contains "$out" "id: ov-c" "keep-list omitted ov-c"
  assert_grep "id: ov-a" "$keep" "keep-list file omitted ov-a"
  assert_grep "keep: Grounded versus ungrounded" "$keep" "keep-list file omitted ov-c keep row"
  pass "reduce-check: N=3 all present and cited exits 0 and writes keep-list"
}

test_one_missing_is_a_finding() {
  local home out rc
  home=$(three_home "$TMP_ROOT/missing")
  rm -f "$home/data/ov-b/report.md"
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing report exited $rc: $out"
  assert_contains "$out" "R-reduce-missing: $home/data/ov-b/report.md" "missing report did not name ov-b"
  assert_not_contains "$out" "R-reduce-missing: $home/data/ov-a/report.md" "present ov-a was marked missing"
  pass "reduce-check: one missing report exits 1 naming it"
}

test_empty_report_is_missing() {
  local home out rc
  home=$(three_home "$TMP_ROOT/empty-report")
  : > "$home/data/ov-a/report.md"
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "empty report exited $rc: $out"
  assert_contains "$out" "R-reduce-missing: $home/data/ov-a/report.md" "empty report was not missing"
  pass "reduce-check: empty report is R-reduce-missing"
}

test_one_uncited_is_a_finding() {
  local home out rc
  home=$(three_home "$TMP_ROOT/uncited")
  write_cited "$home/data/decisions/lock.md" \
    "expected-reports: ov-a, ov-b, ov-c" \
    "Cite \`data/ov-a/report.md\`." \
    "Cite \`data/ov-c/report.md\`."
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "uncited report exited $rc: $out"
  assert_contains "$out" "R-reduce-uncited: $home/data/ov-b/report.md" "uncited report did not name ov-b"
  pass "reduce-check: one present but uncited report exits 1 naming it"
}

test_declared_failed_is_not_a_finding() {
  local home out rc
  home=$(three_home "$TMP_ROOT/failed")
  rm -f "$home/data/ov-c/report.md"
  write_cited "$home/data/decisions/lock.md" \
    "expected-reports: ov-a, ov-b, ov-c(failed: scout died after dispatch)" \
    "Cite \`data/ov-a/report.md\`." \
    "Cite \`data/ov-b/report.md\`."
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "declared failed exited $rc: $out"
  assert_contains "$out" "R-reduce-failed-declared: ov-c: scout died after dispatch" \
    "failed member was not listed"
  assert_not_contains "$out" "R-reduce-missing: $home/data/ov-c/report.md" \
    "failed member was treated as missing"
  pass "reduce-check: declared failed member exits 0 and is listed"
}

test_manufactured_citation_breakage() {
  local home out rc
  home=$(three_home "$TMP_ROOT/break")
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "green fixture exited $rc: $out"
  write_cited "$home/data/decisions/lock.md" \
    "expected-reports: ov-a, ov-b, ov-c" \
    "Cite \`data/ov-a/report.md\`." \
    "Cite \`data/ov-c/report.md\`."
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "deleted citation exited $rc: $out"
  assert_contains "$out" "R-reduce-uncited: $home/data/ov-b/report.md" \
    "deleted citation did not go red"
  write_cited "$home/data/decisions/lock.md" \
    "expected-reports: ov-a, ov-b, ov-c" \
    "Cite \`data/ov-a/report.md\`." \
    "Cite \`data/ov-b/report.md\`." \
    "Cite \`data/ov-c/report.md\`."
  set +e
  out=$(run_check \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "restored citation exited $rc: $out"
  pass "reduce-check: manufactured breakage of one citation"
}

test_fm_home_is_not_an_implicit_home() {
  local home decoy out rc
  home=$(three_home "$TMP_ROOT/no-fm-home")
  decoy="$TMP_ROOT/decoy-home"
  mkdir -p "$decoy/data"
  set +e
  out=$(env FM_HOME="$decoy" "$CHECK" \
    --expect "$home/data/ov-a/report.md" \
    --expect "$home/data/ov-b/report.md" \
    --expect "$home/data/ov-c/report.md" \
    --cited-by "$home/data/decisions/lock.md" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "FM_HOME decoy exited $rc: $out"
  pass "reduce-check: FM_HOME is not an implicit input home"
}

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

test_missing_expect_and_cited_by_are_structural
test_n3_all_present_and_cited_is_clean
test_one_missing_is_a_finding
test_empty_report_is_missing
test_one_uncited_is_a_finding
test_declared_failed_is_not_a_finding
test_manufactured_citation_breakage
test_fm_home_is_not_an_implicit_home

echo "# all fm-reduce-check tests passed"
