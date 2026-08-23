#!/usr/bin/env bash
# Behavioral coverage for the SoT-speech refuse-hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-sot-speech-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-sot-speech-check)
fm_git_identity fmtest fmtest@example.invalid

make_primary_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

write_lock() {
  local home=$1
  mkdir -p "$home/data/decisions"
  printf '%s\n' \
    'F1 is locked in this fixture.' \
    'AMENDED: 0DTE walls are in scope. A pointer in captain.md is not the lock.' \
    'speech-claim: F1|Map 2 spec|0DTE|north star' \
    > "$home/data/decisions/example-product-lock.md"
}

write_transcript() {
  local file=$1
  shift
  : > "$file"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
}

run_check() {
  local home=$1 payload=$2
  shift 2
  printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" "$@" 2>&1
}

test_absent_locks_are_inert() {
  local home out rc
  home=$(make_primary_home "$TMP_ROOT/absent")
  set +e
  out=$(run_check "$home" '{"transcript_path":"/tmp/missing.jsonl"}')
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "absent locks exited $rc"
  [ -z "$out" ] || fail "absent locks should be silent, got: $out"
  pass "sot-speech: absent speech-claim locks are inert"
}

test_claim_without_read_is_refused() {
  local home transcript payload out rc
  home=$(make_primary_home "$TMP_ROOT/refuse")
  write_lock "$home"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"F1 is the locked north star."}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "claim without read exited $rc"
  assert_contains "$out" 'open data/decisions/example-product-lock.md' "refusal did not name the file to open"
  pass "sot-speech: content claim without a session open is refused"
}

test_read_evidence_allows_claim() {
  local home transcript payload out rc abs
  home=$(make_primary_home "$TMP_ROOT/read")
  write_lock "$home"
  abs="$home/data/decisions/example-product-lock.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    "$(printf '{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s"}}]}}' "$abs")" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"F1 is the locked north star."}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "read evidence exited $rc with: $out"
  [ -z "$out" ] || fail "read evidence should be silent, got: $out"
  pass "sot-speech: same-session Read of the owning file allows the claim"
}

test_declared_unread_allows_naming() {
  local home transcript payload out rc
  home=$(make_primary_home "$TMP_ROOT/unread")
  write_lock "$home"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"I have not opened the Map 2 spec this session."}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "declared unread exited $rc with: $out"
  pass "sot-speech: declared-unread statement is not refused"
}

test_malformed_registry_is_structural() {
  local home transcript payload out rc
  home=$(make_primary_home "$TMP_ROOT/badreg")
  mkdir -p "$home/data/decisions"
  printf '%s\n' 'speech-claim:' > "$home/data/decisions/empty-claim.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed registry exited $rc"
  assert_contains "$out" 'registry invalid' "structural failure did not name the registry"
  pass "sot-speech: empty speech-claim ERE is a structural failure"
}

test_pretool_askuser_is_refused() {
  local home transcript payload out rc
  home=$(make_primary_home "$TMP_ROOT/pretool")
  write_lock "$home"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"planning"}]}}'
  payload=$(printf '{"transcript_path":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Does F1 still hold?"}]}}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload" --pretool --claude)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "pretool claim exited $rc with: $out"
  assert_contains "$out" 'permissionDecision":"deny' "pretool refusal was not a deny object"
  pass "sot-speech: AskUserQuestion PreToolUse denies an unread content claim"
}

test_decision_lock_claim_without_read_is_refused() {
  local home transcript payload out rc
  home=$(make_primary_home "$TMP_ROOT/lock-refuse")
  write_lock "$home"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The north star still says 0DTE is deferred."}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "decision-lock claim without read exited $rc"
  assert_contains "$out" 'open data/decisions/example-product-lock.md' \
    "refusal did not name the decision lock"
  pass "sot-speech: decision-lock content claim without a session open is refused"
}

test_decision_lock_read_allows_claim() {
  local home transcript payload out rc abs
  home=$(make_primary_home "$TMP_ROOT/lock-read")
  write_lock "$home"
  abs="$home/data/decisions/example-product-lock.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    "$(printf '{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"%s"}}]}}' "$abs")" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The north star still says 0DTE is deferred."}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "decision-lock Read exited $rc with: $out"
  [ -z "$out" ] || fail "decision-lock Read should be silent, got: $out"
  pass "sot-speech: same-session Read of the decision lock allows the claim"
}

test_session_start_digest_does_not_credit_decision_lock() {
  local home transcript payload out rc digest
  home=$(make_primary_home "$TMP_ROOT/ss-lock")
  write_lock "$home"
  mkdir -p "$home/data"
  printf 'Gamma north star pointer; last AMENDED in a decisions file.\n' \
    > "$home/data/captain.md"
  transcript="$home/transcript.jsonl"
  digest=$(printf '%s\n' \
    'SESSION START - fixture' \
    '================================================================================' \
    'CONTEXT' \
    '================================================================================' \
    '' \
    'data/captain.md' \
    '--------------------------------------------------------------------------------' \
    'Gamma north star pointer; last AMENDED in a decisions file.' \
    '' \
    'data/projects.md' \
    '--------------------------------------------------------------------------------' \
    'ABSENT')
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"bin/fm-session-start.sh"}}]}}' \
    "$(printf '{"type":"message","message":{"role":"user","content":[{"type":"tool_result","content":%s}]}}' "$(printf '%s' "$digest" | jq -Rs .)")" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"The north star still says 0DTE is deferred."}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "digest-printed captain.md credited a decision lock: $out"
  assert_contains "$out" 'open data/decisions/example-product-lock.md' \
    "digest credit of captain.md should not satisfy the lock row"
  pass "sot-speech: session-start digest does not credit a data/decisions lock"
}

test_absent_locks_are_inert
test_claim_without_read_is_refused
test_read_evidence_allows_claim
test_declared_unread_allows_naming
test_malformed_registry_is_structural
test_pretool_askuser_is_refused
test_decision_lock_claim_without_read_is_refused
test_decision_lock_read_allows_claim
test_session_start_digest_does_not_credit_decision_lock

echo "# all fm-sot-speech-check tests passed"
