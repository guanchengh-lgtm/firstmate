#!/usr/bin/env bash
# Behavioral coverage for the spec compile-check.
# Exercises public CLI exit codes, exact-count regression, explicit home
# versus path inputs, and refusal spans. Does not assert checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-spec-compile-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-spec-compile-check)

run_check() {
  "$CHECK" "$@" 2>&1
}

write_ticket() {
  local dir=$1 id=$2 status=$3
  mkdir -p "$dir"
  printf '%s\n' "# ${id}" "status: ${status}" "" "## Answer" "locked." > "${dir}/${id}-item.md"
}

write_keep() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' "# Synthesis" "" "### Keep" "" "| Idea | From | Why |" "|---|---|---|"
    local idea
    for idea in "$@"; do
      printf '| %s | src | why |\n' "$idea"
    done
  } > "$path"
}

write_spec() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

clean_home() {
  local home=$1
  mkdir -p "$home/data/wf-map2-loops/tickets" "$home/data/synth"
  write_ticket "$home/data/wf-map2-loops/tickets" D1 "CLOSED 2026-08-20"
  write_keep "$home/data/synth/report.md" "Node contract: bounded job, defined input"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  printf '%s\n' "$home"
}

test_missing_and_empty_input_are_structural() {
  local out rc empty home decoy
  empty="$TMP_ROOT/empty.md"
  : > "$empty"
  set +e
  out=$(run_check)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing --home/--spec exited $rc"
  assert_contains "$out" "missing --home or --spec" "missing flags did not name the required input"
  set +e
  out=$(run_check --spec "$TMP_ROOT/no-such.md" --tickets "$TMP_ROOT/no-tickets" --keep-source "$empty")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing spec file exited $rc"
  assert_contains "$out" "missing spec" "missing spec file did not say missing"
  home=$(clean_home "$TMP_ROOT/empty-spec-home")
  : > "$home/data/wf-map2-loops/spec.md"
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty spec exited $rc"
  assert_contains "$out" "empty spec" "empty spec was not structural"
  decoy=$(clean_home "$TMP_ROOT/decoy-home")
  write_ticket "$decoy/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  set +e
  out=$(run_check --home "$decoy" --expect-rule R-ticket-lock --expect-count 0)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(run_check --home "$decoy" --expect-rule R-ticket-lock --expect-count 00)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 00 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "leading-zero zero count was not structural"
  set +e
  out=$(run_check --home "$decoy" --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  set +e
  out=$(run_check --home "$decoy" --spec "$decoy/data/wf-map2-loops/spec.md")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--home with --spec exited $rc"
  assert_contains "$out" "cannot be combined" "--home with --spec was not refused"
  pass "spec compile-check: missing and empty input, expect-count 0, empty rules exit 2"
}

test_empty_tickets_and_keep_sources_are_structural() {
  local home out rc tickets keep
  home=$(clean_home "$TMP_ROOT/no-closed")
  write_ticket "$home/data/wf-map2-loops/tickets" D1 "OPEN"
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "open-only tickets exited $rc: $out"
  assert_contains "$out" "empty ticket input" "open-only tickets were not empty ticket input"
  home=$(clean_home "$TMP_ROOT/no-keep-cite")
  write_spec "$home/data/wf-map2-loops/spec.md" "# Spec" "D1 is the lock."
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "uncited keep sources exited $rc: $out"
  assert_contains "$out" "empty keep-row input" "uncited keep sources were not empty keep-row input"
  home=$(clean_home "$TMP_ROOT/missing-cited")
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock."
  rm -f "$home/data/synth/report.md"
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing cited report exited $rc: $out"
  assert_contains "$out" "missing keep source" "missing cited report was not structural"
  tickets="$TMP_ROOT/direct-tickets"
  keep="$TMP_ROOT/direct-keep.md"
  write_ticket "$tickets" D1 "CLOSED 2026-08-20"
  write_keep "$keep" "Node contract: bounded job"
  set +e
  out=$(run_check --spec "$TMP_ROOT/direct-spec.md" --tickets "$tickets")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "direct paths without --keep-source exited $rc"
  assert_contains "$out" "empty keep-row input" "direct paths without keep-source were not empty keep-row input"
  pass "spec compile-check: empty tickets, uncited keep, missing cited report exit 2"
}

test_clean_home_and_direct_paths_are_clean() {
  local home out rc spec tickets keep
  home=$(clean_home "$TMP_ROOT/clean-home")
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "clean --home exited $rc: $out"
  [ -z "$out" ] || fail "clean --home printed findings: $out"
  spec="$TMP_ROOT/direct/spec.md"
  tickets="$TMP_ROOT/direct/tickets"
  keep="$TMP_ROOT/direct/keep.md"
  write_ticket "$tickets" D1 "CLOSED 2026-08-20"
  write_keep "$keep" "Node contract: bounded job, defined input"
  write_spec "$spec" "# Spec" "D1 is the lock." "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --spec "$spec" --tickets "$tickets" --keep-source "$keep")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "clean direct paths exited $rc: $out"
  [ -z "$out" ] || fail "clean direct paths printed findings: $out"
  pass "spec compile-check: clean --home and direct paths exit 0"
}

test_missing_ticket_id_fires_exact_count() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/missing-d8")
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --home "$home" --expect-rule R-ticket-lock --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing D8 exact-count exited $rc: $out"
  set +e
  out=$(run_check --home "$home" --rules R-ticket-lock)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing D8 gate exited $rc: $out"
  assert_contains "$out" "R-ticket-lock-missing: D8" "missing D8 did not report R-ticket-lock-missing"
  assert_not_contains "$out" "R-keep-lock-missing" "ticket-only rule printed a keep finding"
  pass "spec compile-check: missing closed ticket id fires exact count 1"
}

test_missing_keep_row_fires_exact_count() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/missing-keep")
  write_keep "$home/data/synth/report.md" \
    "Node contract: bounded job, defined input" \
    "Dormant skills (~100 words until match) as a tool-layer shape"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --home "$home" --expect-rule R-keep-lock --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing keep-row exact-count exited $rc: $out"
  set +e
  out=$(run_check --home "$home" --rules R-keep-lock)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing keep-row gate exited $rc: $out"
  assert_contains "$out" "R-keep-lock-missing: Dormant skills (~100 words until match) as a tool-layer shape" \
    "missing keep-row did not report R-keep-lock-missing"
  pass "spec compile-check: missing keep-row title fires exact count 1"
}

test_section_ten_index_is_not_a_tag() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/section-ten")
  write_keep "$home/data/synth/report.md" \
    "Dormant skills (~100 words until match) as a tool-layer shape"
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "" \
    "## 10. Judge fixes carried" \
    "" \
    "| Fix | Source restored | Where it is now |" \
    "|---|---|---|" \
    "| F1 | D8 Answer | missing body |" \
    "| F7 | Dormant skills (~100 words until match) as a tool-layer shape | missing body |"
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "section 10 only exited $rc: $out"
  assert_contains "$out" "R-ticket-lock-missing: D8" "section 10 listing did not miss D8"
  assert_contains "$out" "R-keep-lock-missing:" "section 10 listing did not miss the keep-row"
  pass "spec compile-check: section 10 location index is not a tag"
}

test_explicit_refusal_is_clean() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/refused")
  write_keep "$home/data/synth/report.md" \
    "Outer hill-climbing loop: traces from ships"
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "" \
    "## 10. Judge fixes carried" \
    "" \
    "Explicit refusals: D8. Outer hill-climbing loop is refused." \
    "" \
    "---" \
    "" \
    "## Appendix"
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "explicit refusal exited $rc: $out"
  [ -z "$out" ] || fail "explicit refusal printed findings: $out"
  pass "spec compile-check: explicit refusal of a ticket id and keep-row is clean"
}

test_open_ticket_and_word_boundary_are_not_false_locks() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/boundary")
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "OPEN"
  write_ticket "$home/data/wf-map2-loops/tickets" D10 "CLOSED 2026-08-20"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "D10 is also locked." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "open D8 plus D10 exited $rc: $out"
  [ -z "$out" ] || fail "open D8 plus D10 printed findings: $out"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --home "$home" --rules R-ticket-lock)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "D10 missing while D1 present exited $rc: $out"
  assert_contains "$out" "R-ticket-lock-missing: D10" "D1 mention did not fail to cover D10"
  pass "spec compile-check: open tickets ignored; D1 is not D10"
}

test_env_home_is_not_scanned() {
  local home decoy out rc spec tickets keep
  home=$(clean_home "$TMP_ROOT/real-home")
  decoy=$(clean_home "$TMP_ROOT/wrong-home")
  write_ticket "$decoy/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  spec="$home/data/wf-map2-loops/spec.md"
  tickets="$home/data/wf-map2-loops/tickets"
  keep="$home/data/synth/report.md"
  set +e
  out=$(
    FM_HOME="$decoy" FM_ROOT="$decoy" FM_DATA_OVERRIDE="$decoy/data" \
      run_check --spec "$spec" --tickets "$tickets" --keep-source "$keep"
  )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "decoy FM_HOME with direct paths exited $rc: $out"
  [ -z "$out" ] || fail "decoy FM_HOME leaked into direct paths: $out"
  set +e
  out=$(
    FM_HOME="$decoy" run_check --home "$home"
  )
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "explicit --home ignored because FM_HOME was set: $rc $out"
  [ -z "$out" ] || fail "explicit --home scanned FM_HOME: $out"
  pass "spec compile-check: FM_HOME is not an implicit input"
}

test_duplicate_ticket_files_do_not_double_findings() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/dup-d8")
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  printf '%s\n' "# D8" "status: CLOSED 2026-08-20" "" "## Answer" "also." \
    > "$home/data/wf-map2-loops/tickets/D8-other.md"
  set +e
  out=$(run_check --home "$home" --expect-rule R-ticket-lock --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "duplicate D8 files exact-count exited $rc: $out"
  pass "spec compile-check: two closed files for one id count as one finding"
}

test_closed_research_ticket_is_required() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/r1-missing")
  write_ticket "$home/data/wf-map2-loops/tickets" R1 "CLOSED 2026-08-20"
  set +e
  out=$(run_check --home "$home" --expect-rule R-ticket-lock --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing R1 exact-count exited $rc: $out"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "R1 is the research lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "R1 tagged spec exited $rc: $out"
  [ -z "$out" ] || fail "R1 tagged spec printed findings: $out"
  pass "spec compile-check: closed R ticket id is required and a body tag is clean"
}

test_quoted_prefix_and_unrelated_rule_count() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/quoted-prefix")
  write_keep "$home/data/synth/report.md" \
    "Dormant skills (~100 words until match) as a tool-layer shape, not a 203-role staff"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Dormant skills (~100 words until match)\"."
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "quoted prefix keep-row exited $rc: $out"
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  set +e
  out=$(run_check --home "$home" --expect-rule R-keep-lock --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "unrelated ticket finding hid behind keep exact-count, exit $rc: $out"
  assert_contains "$out" "regression:" "unrelated rule did not fail exact-count"
  pass "spec compile-check: quoted keep prefix is a tag; extra rule breaks exact-count"
}

test_placeholder_citation_is_skipped() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/placeholder-cite")
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/<id>/report.md\` and \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "placeholder plus real citation exited $rc: $out"
  [ -z "$out" ] || fail "placeholder plus real citation printed findings: $out"
  pass "spec compile-check: placeholder citation with a real report is clean"
}

test_multiline_quoted_better_prefix_is_a_tag() {
  local home out rc
  home=$(clean_home "$TMP_ROOT/better-prefix")
  write_keep "$home/data/synth/report.md" \
    "\"Better\" is chosen outside the graph, by people, from real failures"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "SP2-keep \"'Better' is" \
    "chosen outside the graph\"."
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "multiline quoted Better prefix exited $rc: $out"
  [ -z "$out" ] || fail "multiline quoted Better prefix printed findings: $out"
  pass "spec compile-check: multiline quoted Better prefix with inner single quotes is a tag"
}

test_explicit_keep_source_ignores_cited_reports() {
  local home out rc explicit
  home=$(clean_home "$TMP_ROOT/explicit-keep")
  write_keep "$home/data/synth/report.md" \
    "Node contract: bounded job, defined input" \
    "Outer hill-climbing loop: traces from ships"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_check --home "$home")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "cited extra keep-row exited $rc: $out"
  assert_contains "$out" "R-keep-lock-missing: Outer hill-climbing loop" \
    "cited extra keep-row did not report R-keep-lock-missing"
  explicit="$TMP_ROOT/explicit-only.md"
  write_keep "$explicit" "Node contract: bounded job, defined input"
  set +e
  out=$(run_check --home "$home" --keep-source "$explicit")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--home plus explicit --keep-source exited $rc: $out"
  [ -z "$out" ] || fail "--home plus explicit --keep-source printed findings: $out"
  pass "spec compile-check: explicit --keep-source ignores cited reports"
}

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_empty_tickets_and_keep_sources_are_structural
test_clean_home_and_direct_paths_are_clean
test_missing_ticket_id_fires_exact_count
test_missing_keep_row_fires_exact_count
test_section_ten_index_is_not_a_tag
test_explicit_refusal_is_clean
test_open_ticket_and_word_boundary_are_not_false_locks
test_env_home_is_not_scanned
test_duplicate_ticket_files_do_not_double_findings
test_closed_research_ticket_is_required
test_quoted_prefix_and_unrelated_rule_count
test_placeholder_citation_is_skipped
test_multiline_quoted_better_prefix_is_a_tag
test_explicit_keep_source_ignores_cited_reports

echo "# all fm-spec-compile-check tests passed"
