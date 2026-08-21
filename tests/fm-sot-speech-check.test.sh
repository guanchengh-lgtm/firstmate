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

write_registry() {
  local home=$1
  mkdir -p "$home/data"
  printf 'F1 is locked in this fixture.\n' > "$home/data/spec.md"
  printf '%s\t%s\n' 'data/spec.md' 'F1|Map 2 spec' > "$home/data/sot-speech.tsv"
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

test_absent_registry_is_inert() {
  local home out rc
  home=$(make_primary_home "$TMP_ROOT/absent")
  set +e
  out=$(run_check "$home" '{"transcript_path":"/tmp/missing.jsonl"}')
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "absent registry exited $rc"
  [ -z "$out" ] || fail "absent registry should be silent, got: $out"
  pass "sot-speech: absent registry is inert"
}

test_claim_without_read_is_refused() {
  local home transcript payload out rc
  home=$(make_primary_home "$TMP_ROOT/refuse")
  write_registry "$home"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"F1 is the locked north star."}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_check "$home" "$payload")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "claim without read exited $rc"
  assert_contains "$out" 'open data/spec.md' "refusal did not name the file to open"
  pass "sot-speech: content claim without a session open is refused"
}

test_read_evidence_allows_claim() {
  local home transcript payload out rc abs
  home=$(make_primary_home "$TMP_ROOT/read")
  write_registry "$home"
  abs="$home/data/spec.md"
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
  write_registry "$home"
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
  mkdir -p "$home/data"
  printf 'only-one-field\n' > "$home/data/sot-speech.tsv"
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
  pass "sot-speech: malformed registry is a structural failure"
}

test_pretool_askuser_is_refused() {
  local home transcript payload out rc
  home=$(make_primary_home "$TMP_ROOT/pretool")
  write_registry "$home"
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

test_absent_registry_is_inert
test_claim_without_read_is_refused
test_read_evidence_allows_claim
test_declared_unread_allows_naming
test_malformed_registry_is_structural
test_pretool_askuser_is_refused

echo "# all fm-sot-speech-check tests passed"
