#!/usr/bin/env bash
# Behavior tests for the bounded prior-session talk fold.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prior-session-fold)
FOLD="$ROOT/bin/fm-prior-session-fold.sh"
trap 'rm -rf "$TMP_ROOT"' EXIT

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf '%s\n' "$home"
}

run_fold() {
  local home=$1 log=$2
  FM_HOME="$home" FM_PRIOR_SESSION_LOG="$log" "$FOLD"
}

test_missing_log_is_loudly_incomplete() {
  local home out status=0
  home=$(new_home missing)
  out=$(run_fold "$home" "$home/missing.jsonl" 2>&1) || status=$?
  expect_code 2 "$status" "missing prior log must fail closed"
  assert_contains "$out" 'INCOMPLETE: prior session log is missing' \
    "missing prior log looked like a clean empty fold"
  assert_not_contains "$out" 'fold-status: parsed within bound' \
    "missing prior log claimed a parsed fold"
  pass "missing prior log is a loud incomplete fold"
}

test_pick_and_lock_words_appear_but_aside_does_not() {
  local home log out
  home=$(new_home selected)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: resume helper tests are running."}]}}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Pick one: path A, path B, or both paths?"}]}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Both paths, and keep rollout on hold."}]}}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Which lane should deploy next?"}]}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"The weather is pleasant today."}]}}' \
    '{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Skill reference says pick compact output."}]}}' \
    > "$log"

  out=$(run_fold "$home" "$log")
  assert_contains "$out" 'Underway: resume helper tests are running.' \
    "live job did not appear in fold"
  assert_contains "$out" 'Both paths, and keep rollout on hold.' \
    "captain pick answer did not appear in lock words"
  assert_contains "$out" 'Which lane should deploy next?' \
    "unanswered pick disappeared after an unrelated captain aside"
  assert_not_contains "$out" 'The weather is pleasant today.' \
    "unrelated captain aside leaked into fold"
  assert_not_contains "$out" 'Skill reference says pick compact output.' \
    "harness metadata leaked into captain lock words"
  assert_contains "$out" 'fold-status: parsed within bound.' \
    "valid bounded fixture did not report parsed status"
  pass "fold keeps live work and lock-changing captain words but drops asides"
}

test_terminal_update_removes_finished_live_job() {
  local home log out
  home=$(new_home terminal)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: obsolete job is running."}]}}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"done: obsolete job completed."}]}}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: current job is running."}]}}' \
    > "$log"

  out=$(run_fold "$home" "$log")
  assert_not_contains "$out" 'obsolete job is running.' \
    "terminal update left finished work classified as live"
  assert_contains "$out" 'current job is running.' \
    "later live job disappeared after terminal reconciliation"
  assert_not_contains "$out" 'INCOMPLETE: a later terminal update made the earlier live-job snapshot unsafe to reuse.' \
    "fresh live job after terminal clear still reported live-job uncertainty"
  assert_contains "$out" 'fold-status: parsed within bound.' \
    "finished-then-new live job did not report a clean parsed fold"
  pass "terminal updates remove finished jobs from live fold"
}

test_separate_live_updates_accumulate() {
  local home log out
  home=$(new_home live-accumulate)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: job alpha is running."}]}}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: job beta is running."}]}}' \
    > "$log"

  out=$(run_fold "$home" "$log")
  assert_contains "$out" 'job alpha is running.' \
    "later live update silently dropped earlier live job"
  assert_contains "$out" 'job beta is running.' \
    "latest live update disappeared"
  pass "separate live updates accumulate"
}

test_uncorrelated_terminal_update_discloses_live_job_uncertainty() {
  local home log out
  home=$(new_home terminal-uncertain)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: jobs alpha and beta are running."}]}}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"done: job alpha completed."}]}}' \
    > "$log"

  out=$(run_fold "$home" "$log")
  assert_not_contains "$out" 'jobs alpha and beta are running.' \
    "stale aggregate snapshot survived an uncorrelated terminal update"
  assert_contains "$out" 'INCOMPLETE: a later terminal update made the earlier live-job snapshot unsafe to reuse.' \
    "uncorrelated terminal update hid live-job uncertainty"
  pass "uncorrelated terminal update discloses live-job uncertainty"
}

test_pick_relative_answer_forms_resolve_only_latest_pick() {
  local home log out
  home=$(new_home answer-forms)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Which path should own storage?"}]}}' \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Which lane should ship first?"}]}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Let us do A."}]}}' \
    > "$log"

  out=$(run_fold "$home" "$log")
  assert_contains "$out" 'Let us do A.' \
    "common pick-relative answer did not become captain lock words"
  assert_contains "$out" 'Which path should own storage?' \
    "answer to latest pick incorrectly cleared an older open pick"
  assert_not_contains "$out" 'Which lane should ship first?' \
    "answered latest pick remained open"
  pass "pick-relative answer resolves only latest open pick"
}

test_ordinary_action_asides_do_not_change_locks() {
  local home log out
  home=$(new_home action-asides)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Please cancel dinner and pick apples."}]}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Approve invoice 42."}]}}' \
    > "$log"

  out=$(run_fold "$home" "$log")
  assert_not_contains "$out" 'Please cancel dinner and pick apples.' \
    "ordinary cancellation aside became lock words"
  assert_not_contains "$out" 'Approve invoice 42.' \
    "ordinary approval aside became lock words"
  pass "ordinary action asides do not become lock words"
}

test_polite_work_lock_commands_are_retained() {
  local home log out
  home=$(new_home polite-locks)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Please stop work on beta."}]}}' \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Please approve it."}]}}' \
    > "$log"

  out=$(run_fold "$home" "$log")
  assert_contains "$out" 'Please stop work on beta.' \
    "polite stop command disappeared"
  assert_contains "$out" 'Please approve it.' \
    "polite approval command disappeared"
  pass "polite work-lock commands remain captain lock words"
}

test_discovery_skips_current_and_reads_prior_claude_log() {
  local home sessions prior current out
  home=$(new_home discovered)
  home=$(cd "$home" && pwd -P)
  sessions="$home/sessions"
  prior="$sessions/prior.jsonl"
  current="$sessions/current.jsonl"
  mkdir -p "$sessions"
  printf '%s\n' \
    "{\"type\":\"assistant\",\"cwd\":\"$home\",\"message\":{\"role\":\"assistant\",\"content\":\"Choose which release lane should stay open?\"}}" \
    > "$prior"
  sleep 1
  printf '%s\n' \
    "{\"type\":\"user\",\"cwd\":\"$home\",\"message\":{\"role\":\"user\",\"content\":\"Current session aside must not appear.\"}}" \
    > "$current"

  out=$(FM_HOME="$home" FM_PRIOR_SESSION_DIRS="$sessions" "$FOLD")
  assert_contains "$out" "source: $prior" \
    "discovery did not select the prior Claude JSONL"
  assert_contains "$out" 'Choose which release lane should stay open?' \
    "prior Claude pick did not appear"
  assert_not_contains "$out" 'Current session aside must not appear.' \
    "discovery folded the current session instead of the prior session"
  pass "discovery excludes current JSONL and parses prior Claude schema"
}

test_discovery_finds_pi_treehouse_session_dir() {
  local home pi_root sessions prior current out encoded_leaf wrong_leaf
  home=$(new_home "treehouse.home")
  home=$(cd "$home" && pwd -P)
  mkdir -p "$TMP_ROOT/pi-agent"
  pi_root=$(cd "$TMP_ROOT/pi-agent" && pwd -P)
  # Match Pi session-manager encoding against the same realpath Node will use.
  home=$(node -e 'process.stdout.write(require("fs").realpathSync.native(process.argv[1]))' "$home")
  encoded_leaf="--${home#/}--"
  encoded_leaf=${encoded_leaf//\//-}
  wrong_leaf=$(printf '%s' "$encoded_leaf" | tr '.' '-')
  sessions="$pi_root/sessions/$encoded_leaf"
  prior="$sessions/prior.jsonl"
  current="$sessions/current.jsonl"
  mkdir -p "$sessions" "$pi_root/sessions/$wrong_leaf"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: pi treehouse prior job is running."}]}}' \
    > "$prior"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway: wrong alnum-encoded dir must not win."}]}}' \
    > "$pi_root/sessions/$wrong_leaf/decoy.jsonl"
  sleep 1
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Current pi session aside must not appear."}]}}' \
    > "$current"

  out=$(FM_HOME="$home" PI_CODING_AGENT_DIR="$pi_root" "$FOLD")
  assert_contains "$out" "source: $prior" \
    "Pi discovery missed the dotted treehouse session directory"
  assert_contains "$out" 'treehouse.home' \
    "Pi source path lost the dotted treehouse leaf encoding"
  assert_not_contains "$out" "sessions/$wrong_leaf/" \
    "Pi discovery used Claude-style alnum encoding that flattens dots"
  assert_contains "$out" 'pi treehouse prior job is running.' \
    "Pi prior live job did not appear without session-dir overrides"
  assert_not_contains "$out" 'wrong alnum-encoded dir must not win.' \
    "Pi discovery read the decoy alnum-encoded session directory"
  assert_not_contains "$out" 'Current pi session aside must not appear.' \
    "Pi discovery folded the current session instead of the prior session"
  assert_contains "$out" 'fold-status: parsed within bound.' \
    "Pi treehouse discovery did not report a clean parsed fold"
  pass "default Pi discovery finds dotted treehouse session dirs"
}

test_over_budget_fold_discloses_truncation() {
  local home log out bytes
  home=$(new_home truncated)
  log="$home/prior.jsonl"
  printf '%s\n' "{\"type\":\"session\",\"cwd\":\"$home\"}" > "$log"
  i=1
  while [ "$i" -le 20 ]; do
    printf '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Underway live job %s with a deliberately long status description that consumes bounded startup memory."}]}}\n' "$i" >> "$log"
    i=$((i + 1))
  done

  out=$(FM_HOME="$home" FM_PRIOR_SESSION_LOG="$log" FM_PRIOR_SESSION_TOKEN_CAP=180 "$FOLD")
  assert_contains "$out" 'INCOMPLETE:' \
    "over-budget fold did not disclose truncation"
  assert_contains "$out" 'truncated to fit remaining startup-memory budget' \
    "over-budget fold did not name the startup-memory bound"
  assert_not_contains "$out" 'fold-status: parsed within bound' \
    "truncated fold claimed a fully rendered result"
  bytes=$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d '[:space:]')
  [ "$bytes" -le 540 ] \
    || fail "180-token fold cap emitted $bytes bytes instead of at most 540"
  pass "over-budget fold truncates with disclosure"
}

test_parse_failure_exits_two_and_stays_incomplete() {
  local home log out status=0
  home=$(new_home parse-failure)
  log="$home/prior.jsonl"
  printf '%s\n' \
    "{\"type\":\"session\",\"cwd\":\"$home\"}" \
    '{not-json' \
    > "$log"

  out=$(run_fold "$home" "$log" 2>&1) || status=$?
  expect_code 2 "$status" "malformed JSONL must exit 2"
  assert_contains "$out" 'INCOMPLETE: prior session log parse failed at JSONL line 2.' \
    "parse failure did not print its incomplete diagnostic"
  assert_not_contains "$out" 'fold-status: parsed within bound' \
    "parse failure looked like a clean empty fold"
  pass "parse failure exits 2 and cannot fake an empty fold"
}

test_missing_log_is_loudly_incomplete
test_pick_and_lock_words_appear_but_aside_does_not
test_terminal_update_removes_finished_live_job
test_separate_live_updates_accumulate
test_uncorrelated_terminal_update_discloses_live_job_uncertainty
test_pick_relative_answer_forms_resolve_only_latest_pick
test_ordinary_action_asides_do_not_change_locks
test_polite_work_lock_commands_are_retained
test_discovery_skips_current_and_reads_prior_claude_log
test_discovery_finds_pi_treehouse_session_dir
test_over_budget_fold_discloses_truncation
test_parse_failure_exits_two_and_stays_incomplete

echo '# all fm-prior-session-fold tests passed'
