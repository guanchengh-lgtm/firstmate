#!/usr/bin/env bash
# Behavioral coverage for the answer-time lock refuse-hook.
# Exercises public CLI exit codes, exact-count regression, the three
# clothes, gather bounds, and Stop banner escapes. Does not assert
# checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-answer-lock-check.sh"
FIX="$ROOT/tests/fixtures/fm-answer-lock-check"
TMP_ROOT=$(fm_test_tmproot fm-answer-lock-check)

run_check() {
  "$CHECK" "$@" 2>&1
}

materialize() {  # <home> <clothes>
  local home=$1
  local clothes=$2
  local src="$FIX/$clothes"
  local f base
  mkdir -p "$home/data/wf-map2-v2/tickets" "$home/data/decisions"
  if [ -d "$src/tickets" ]; then
    for f in "$src/tickets"/*.fixture; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .fixture)
      cp "$f" "$home/data/wf-map2-v2/tickets/${base}.md"
    done
  fi
  if [ -d "$src/decisions" ]; then
    for f in "$src/decisions"/*.fixture; do
      [ -f "$f" ] || continue
      base=$(basename "$f" .fixture)
      cp "$f" "$home/data/decisions/${base}.md"
    done
  fi
}

write_ticket() {  # <path> <body>
  local path=$1
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$2" > "$path"
}

write_lock() {  # <path> <body>
  local path=$1
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$2" > "$path"
}

test_missing_tickets_dir_is_inert() {
  local home out rc
  home="$TMP_ROOT/no-tickets"
  mkdir -p "$home/data"
  set +e
  out=$(FM_HOME="$home" run_check)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing tickets dir exited $rc: $out"
  [ -z "$out" ] || fail "missing tickets dir printed: $out"
  pass "answer-lock: missing tickets dir is inert"
}

test_expect_count_zero_and_empty_rules_are_structural() {
  local home out rc
  home="$TMP_ROOT/structural"
  materialize "$home" clothes-pick-still-open
  set +e
  out=$(FM_HOME="$home" run_check --expect-rule R-pick-still-open --expect-count 0)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(FM_HOME="$home" run_check --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  set +e
  out=$(FM_HOME="$home" run_check --expect-rule NOT-A-RULE --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unknown expect-rule exited $rc"
  pass "answer-lock: expect-count 0, empty rules, unknown rule exit 2"
}

test_clothes_pick_still_open_fires_exact_count() {
  local home out rc
  home="$TMP_ROOT/clothes-pick-still-open"
  materialize "$home" clothes-pick-still-open
  set +e
  out=$(FM_HOME="$home" run_check \
    --rules R-pick-still-open \
    --expect-rule R-pick-still-open --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "pick-still-open exact-count exited $rc: $out"
  set +e
  out=$(FM_HOME="$home" run_check --rules R-pick-still-open)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "pick-still-open gate exited $rc"
  assert_contains "$out" "R-pick-still-open-status" \
    "pick-still-open did not report the rule"
  assert_contains "$out" "N18-arbitration.md" \
    "pick-still-open did not name the ticket"
  pass "answer-lock: clothes pick-still-open fires exact count 1"
}

test_clothes_close_no_lock_ship_ticket_is_exempt() {
  local home out rc
  home="$TMP_ROOT/clothes-close-no-lock"
  materialize "$home" clothes-close-no-lock
  set +e
  out=$(FM_HOME="$home" run_check --rules R-close-no-lock)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "S2 ship ticket R-close-no-lock exited $rc: $out"
  [ -z "$out" ] || fail "S2 ship ticket printed R-close-no-lock: $out"
  pass "answer-lock: clothes close-no-lock ship ticket without ## Answer is exempt"
}

test_clothes_close_undated_fires_exact_count() {
  local home out rc
  home="$TMP_ROOT/clothes-close-undated"
  materialize "$home" clothes-close-undated
  set +e
  out=$(FM_HOME="$home" run_check \
    --rules R-close-undated \
    --expect-rule R-close-undated --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "close-undated exact-count exited $rc: $out"
  set +e
  out=$(FM_HOME="$home" run_check --rules R-close-undated)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "close-undated gate exited $rc"
  assert_contains "$out" "R-close-undated-status" \
    "close-undated did not report the rule"
  assert_contains "$out" "N12-diamond-reduce.md" \
    "close-undated did not name the ticket"
  pass "answer-lock: clothes close-undated fires exact count 1"
}

test_answered_close_without_lock_fires() {
  local home out rc
  home="$TMP_ROOT/answered-no-lock"
  mkdir -p "$home/data/wf-map2-v2/tickets"
  write_ticket "$home/data/wf-map2-v2/tickets/closed-answered.md" \
    "$(printf '%s\n' 'status: CLOSED 2026-08-22' '' '## Answer' '**A.** no pointer')"
  set +e
  out=$(FM_HOME="$home" run_check \
    --rules R-close-no-lock \
    --expect-rule R-close-no-lock --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "answered close-no-lock exact-count exited $rc: $out"
  set +e
  out=$(FM_HOME="$home" run_check --rules R-close-no-lock)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "answered close-no-lock gate exited $rc"
  assert_contains "$out" "R-close-no-lock-missing" \
    "answered close without lock did not report the rule"
  pass "answer-lock: CLOSED with ## Answer and no lock file fires R-close-no-lock"
}

test_lock_still_open_uses_list_open_reader() {
  local home out rc
  home="$TMP_ROOT/lock-still-open"
  mkdir -p "$home/data/wf-map2-v2/tickets" "$home/data/decisions"
  # shellcheck disable=SC2016 # Backticks are literal Markdown lock tokens.
  write_ticket "$home/data/wf-map2-v2/tickets/closed-open-lock.md" \
    "$(printf '%s\n' 'status: CLOSED 2026-08-22' '' '## Answer' \
      '**A.** Lock `data/decisions/still-open-2026-08-22.md`.')"
  write_lock "$home/data/decisions/still-open-2026-08-22.md" \
    "$(printf '%s\n' '# still open' '**Pick:** A. locked.' '- **Q1 Left.** Still open.')"
  set +e
  out=$(FM_HOME="$home" run_check \
    --rules R-lock-still-open \
    --expect-rule R-lock-still-open --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "lock-still-open exact-count exited $rc: $out"
  set +e
  out=$(FM_HOME="$home" run_check --rules R-lock-still-open)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "lock-still-open gate exited $rc"
  assert_contains "$out" "R-lock-still-open-file" \
    "list-open still-open lock did not report the rule"
  pass "answer-lock: R-lock-still-open fires from --list-open, not a second regex"
}

test_lock_without_pick_fires() {
  local home out rc
  home="$TMP_ROOT/lock-no-pick"
  mkdir -p "$home/data/wf-map2-v2/tickets" "$home/data/decisions"
  # shellcheck disable=SC2016 # Backticks are literal Markdown lock tokens.
  write_ticket "$home/data/wf-map2-v2/tickets/closed-no-pick.md" \
    "$(printf '%s\n' 'status: CLOSED 2026-08-22' '' '## Answer' \
      '**A.** Lock `data/decisions/no-pick-2026-08-22.md`.')"
  write_lock "$home/data/decisions/no-pick-2026-08-22.md" \
    "$(printf '%s\n' '# no pick line' 'Some prose only.')"
  set +e
  out=$(FM_HOME="$home" run_check --rules R-lock-still-open)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "no-pick lock gate exited $rc: $out"
  assert_contains "$out" "R-lock-still-open-file" \
    "lock without **Pick:** did not report the rule"
  pass "answer-lock: pointed-to lock with no **Pick:** line fires R-lock-still-open"
}

test_gather_skips_loops_and_other_data() {
  local home out rc
  home="$TMP_ROOT/gather-bounds"
  mkdir -p "$home/data/wf-map2-v2/tickets" \
    "$home/data/wf-map2-loops/tickets" \
    "$home/data/wf-other/tickets" \
    "$home/data/decisions"
  # shellcheck disable=SC2016 # Backticks are literal Markdown lock tokens.
  write_ticket "$home/data/wf-map2-v2/tickets/clean.md" \
    "$(printf '%s\n' 'status: CLOSED 2026-08-22' '' '## Answer' \
      '**A.** Lock `data/decisions/clean-2026-08-22.md`.')"
  write_lock "$home/data/decisions/clean-2026-08-22.md" \
    "$(printf '%s\n' '**Pick:** A. clean.')"
  write_ticket "$home/data/wf-map2-loops/tickets/D1-item.md" \
    "$(printf '%s\n' 'status: CLOSED' '' '## Answer' '**A.** no lock')"
  write_ticket "$home/data/wf-other/tickets/other.md" \
    "$(printf '%s\n' 'status: OPEN' '' '## Answer' '**A.** stray')"
  set +e
  out=$(FM_HOME="$home" run_check)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "gather bounds exited $rc: $out"
  [ -z "$out" ] || fail "gather walked outside v2 tickets: $out"
  pass "answer-lock: gather is v2 tickets only; loops and other data/ are skipped"
}

test_clean_closed_dated_lock_is_silent() {
  local home out rc
  home="$TMP_ROOT/clean"
  mkdir -p "$home/data/wf-map2-v2/tickets" "$home/data/decisions"
  # shellcheck disable=SC2016 # Backticks are literal Markdown lock tokens.
  write_ticket "$home/data/wf-map2-v2/tickets/clean.md" \
    "$(printf '%s\n' 'status: CLOSED 2026-08-22' '' '## Answer' \
      '**A.** Lock `data/decisions/clean-2026-08-22.md`.')"
  write_lock "$home/data/decisions/clean-2026-08-22.md" \
    "$(printf '%s\n' '**Pick:** A. clean.')"
  set +e
  out=$(FM_HOME="$home" run_check)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "clean ticket exited $rc: $out"
  [ -z "$out" ] || fail "clean ticket printed findings: $out"
  pass "answer-lock: dated CLOSED with ## Answer and **Pick:** lock is clean"
}

test_lock_token_only_inside_answer_ignores_prose_paths() {
  local home out rc
  home="$TMP_ROOT/lock-token-answer-only"
  mkdir -p "$home/data/wf-map2-v2/tickets" "$home/data/decisions"
  write_lock "$home/data/decisions/real-lock-2026-08-22.md" \
    "$(printf '%s\n' '**Pick:** A. real.')"
  write_lock "$home/data/decisions/prose-only-2026-08-22.md" \
    "$(printf '%s\n' '# prose only' 'No pick line.')"
  # shellcheck disable=SC2016 # Backticks are literal Markdown lock tokens.
  write_ticket "$home/data/wf-map2-v2/tickets/prose-before-lock.md" \
    "$(printf '%s\n' 'status: CLOSED 2026-08-22' '' \
      '## Question' \
      'See data/decisions/prose-only-2026-08-22.md in the trail.' '' \
      '## Answer' \
      '**A.** Lock `data/decisions/real-lock-2026-08-22.md`.' \
      'Also mentions data/decisions/prose-only-2026-08-22.md.')"
  set +e
  out=$(FM_HOME="$home" run_check)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "valid Answer Lock with prose path exited $rc: $out"
  [ -z "$out" ] || fail "valid Answer Lock with prose path printed: $out"
  write_ticket "$home/data/wf-map2-v2/tickets/closed-prose-only.md" \
    "$(printf '%s\n' 'status: CLOSED 2026-08-22' '' \
      '## Question' \
      'Mentions data/decisions/real-lock-2026-08-22.md only in prose.' '' \
      '## Answer' \
      '**A.** No Lock token here, only prose data/decisions/real-lock-2026-08-22.md.')"
  set +e
  out=$(FM_HOME="$home" run_check --rules R-close-no-lock)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "prose path without Answer Lock exited $rc: $out"
  assert_contains "$out" "R-close-no-lock-missing" \
    "prose path without Answer Lock did not report R-close-no-lock"
  assert_contains "$out" "closed-prose-only.md" \
    "prose path without Answer Lock did not name the ticket"
  pass "answer-lock: only Answer Lock token counts; bare/prose paths ignored"
}

test_s1_style_pick_phrase_still_open_fires() {
  local home out rc
  home="$TMP_ROOT/s1-style-pick"
  mkdir -p "$home/data/wf-map2-v2/tickets" "$home/data/decisions"
  # shellcheck disable=SC2016 # Backticks are literal Markdown lock tokens.
  write_ticket "$home/data/wf-map2-v2/tickets/s1-style-open.md" \
    "$(printf '%s\n' 'status: OPEN' '' '## Answer' \
      '**A. No ship.** Cursor is not a worker. Lock `data/decisions/s1-style-2026-08-22.md`.')"
  write_lock "$home/data/decisions/s1-style-2026-08-22.md" \
    "$(printf '%s\n' '**Pick:** A. No ship.')"
  set +e
  out=$(FM_HOME="$home" run_check \
    --rules R-pick-still-open \
    --expect-rule R-pick-still-open --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "S1-style pick exact-count exited $rc: $out"
  set +e
  out=$(FM_HOME="$home" run_check --rules R-pick-still-open)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "S1-style pick gate exited $rc: $out"
  assert_contains "$out" "R-pick-still-open-status" \
    "S1-style **A. No ship.** did not report the rule"
  assert_contains "$out" "s1-style-open.md" \
    "S1-style pick did not name the ticket"
  pass "answer-lock: S1-style **A. No ship.** pick fires R-pick-still-open"
}

test_claude_stop_banner_has_only_two_escapes() {
  local home out rc
  home="$TMP_ROOT/stop-banner"
  materialize "$home" clothes-pick-still-open
  set +e
  out=$(printf '%s' '{"stop_hook_active":false}' | FM_HOME="$home" "$CHECK" --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--claude findings exited $rc: $out"
  assert_contains "$out" "ANSWER-TIME LOCK REFUSED" "Stop banner title missing"
  assert_contains "$out" "Point the ticket at the real lock, or revert status: to OPEN." \
    "Stop banner did not name the two escapes"
  assert_not_contains "$out" "write a lock" "Stop banner told the seat to write a lock"
  assert_not_contains "$out" "Write a lock" "Stop banner told the seat to write a lock"
  set +e
  out=$(printf '' | FM_HOME="$home" "$CHECK" --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "empty --claude payload exited $rc: $out"
  pass "answer-lock: --claude Stop banner names two escapes and never says write a lock"
}

test_help_names_gather_and_escapes() {
  local out rc
  set +e
  out=$(run_check --help)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "--help exited $rc"
  assert_contains "$out" "data/wf-map2-v2/tickets" "help did not name the gather"
  assert_contains "$out" "data/wf-map2-loops" "help did not name the grandfathered loops path"
  assert_contains "$out" "point the ticket at the real lock" "help did not name the lock escape"
  assert_contains "$out" "revert status: to OPEN" "help did not name the OPEN escape"
  assert_not_contains "$out" "write a lock" "help told the seat to write a lock"
  pass "answer-lock: --help owns gather, loops exclusion, and the two escapes"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_tickets_dir_is_inert
test_expect_count_zero_and_empty_rules_are_structural
test_clothes_pick_still_open_fires_exact_count
test_clothes_close_no_lock_ship_ticket_is_exempt
test_clothes_close_undated_fires_exact_count
test_answered_close_without_lock_fires
test_lock_still_open_uses_list_open_reader
test_lock_without_pick_fires
test_gather_skips_loops_and_other_data
test_clean_closed_dated_lock_is_silent
test_lock_token_only_inside_answer_ignores_prose_paths
test_s1_style_pick_phrase_still_open_fires
test_claude_stop_banner_has_only_two_escapes
test_help_names_gather_and_escapes

echo "# all fm-answer-lock-check tests passed"
