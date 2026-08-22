#!/usr/bin/env bash
# Behavioral coverage for the spec compile-check Stop adapter.
# Fixture transcripts, public exit codes, and manufactured breakage of one
# asserted tag. Does not assert adapter or matcher source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-spec-compile-stop-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-spec-compile-stop-check)
fm_git_identity fmtest fmtest@example.invalid

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

write_green_home() {
  local home=$1
  mkdir -p "$home/data/wf-map2-loops/tickets" "$home/data/synth"
  write_ticket "$home/data/wf-map2-loops/tickets" D1 "CLOSED 2026-08-20"
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  write_keep "$home/data/synth/report.md" "Node contract: bounded job, defined input"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "D8 is the lock." \
    "XG-keep \"Node contract\"."
  printf '%s\n' "$home"
}

write_transcript() {
  local file=$1
  shift
  : > "$file"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$file"
  done
}

write_tool_line() {
  local name=$1 path=$2
  printf '{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"%s","input":{"file_path":"%s"}}]}}' "$name" "$path"
}

tool_result_line() {
  local body=${1:-ok}
  python3 -c 'import json,sys; print(json.dumps({"type":"message","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":sys.argv[1]}]}}))' "$body"
}

meta_user_line() {
  local text=$1
  python3 -c 'import json,sys; print(json.dumps({"type":"user","isMeta":True,"message":{"role":"user","content":[{"type":"text","text":sys.argv[1]}]}}))' "$text"
}

user_text_line() {
  local text=$1
  python3 -c 'import json,sys; print(json.dumps({"type":"message","message":{"role":"user","content":[{"type":"text","text":sys.argv[1]}]}}))' "$text"
}

bash_tool_line() {
  local cmd=$1
  python3 -c 'import json,sys; print(json.dumps({"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":sys.argv[1]}}]}}))' "$cmd"
}

run_adapter() {
  local payload=$1
  shift
  printf '%s' "$payload" | env -u FM_HOME -u FM_ROOT_OVERRIDE "$ADAPTER" "$@" 2>&1
}

install_guard_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-spec-compile-stop-check.sh" "$dir/bin/fm-spec-compile-stop-check.sh"
  cp "$ROOT/bin/fm-spec-compile-check.sh" "$dir/bin/fm-spec-compile-check.sh"
  cp "$ROOT/bin/fm-keep-rows.py" "$dir/bin/fm-keep-rows.py"
  cp "$ROOT/bin/fm-reduce-check.sh" "$dir/bin/fm-reduce-check.sh"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-spec-compile-stop-check.sh" \
    "$dir/bin/fm-spec-compile-check.sh" "$dir/bin/fm-reduce-check.sh"
}

run_guard() {
  local dir=$1 payload=$2
  printf '%s' "$payload" | env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

test_write_renames_d8_and_refuses() {
  local home spec transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/rename-d8")
  spec="$home/data/wf-map2-loops/spec.md"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "DX is the lock." \
    "XG-keep \"Node contract\"."
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "renaming D8 in the spec must refuse"
  assert_contains "$out" "R-ticket-lock-missing: D8" "D8 rename did not name missing D8"
  pass "spec compile stop: Write that renames D8 exits 2"
}

test_write_then_tool_result_still_refuses() {
  local home spec transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/write-tool-result")
  spec="$home/data/wf-map2-loops/spec.md"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "DX is the lock." \
    "XG-keep \"Node contract\"."
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    "$(write_tool_line Write "$spec")" \
    "$(tool_result_line "Wrote contents")" \
    "$(meta_user_line "Skill reference says keep going.")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "Write followed by tool_result/isMeta must still refuse"
  assert_contains "$out" "R-ticket-lock-missing: D8" "tool_result after Write cleared the this-turn window"
  pass "spec compile stop: Write then tool_result/isMeta still exits 2"
}

test_write_then_stop_hook_feedback_still_refuses() {
  local home spec transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/write-stop-feedback")
  spec="$home/data/wf-map2-loops/spec.md"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "DX is the lock." \
    "XG-keep \"Node contract\"."
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    "$(write_tool_line Write "$spec")" \
    "$(tool_result_line "Wrote contents")" \
    "$(user_text_line "<task-notification><summary>Stop hook feedback</summary><detail>R-ticket-lock-missing: D8</detail></task-notification>")" \
    "$(user_text_line "<task-notification><summary>background agent finished</summary></task-notification>")" \
    "$(user_text_line "[Request interrupted by user for tool use]")" \
    "$(user_text_line "<local-command-stdout>ok</local-command-stdout>")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "Write followed by Stop-hook feedback must still refuse"
  assert_contains "$out" "R-ticket-lock-missing: D8" "Stop-hook feedback after Write cleared the this-turn window"
  pass "spec compile stop: Write then Stop-hook feedback still exits 2"
}

test_bash_sed_closed_ticket_without_tag_refuses() {
  local home ticket transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/bash-d9")
  ticket="$home/data/wf-map2-loops/tickets/D9-new.md"
  write_ticket "$home/data/wf-map2-loops/tickets" D9 "CLOSED 2026-08-20"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(bash_tool_line "sed -i 's/OPEN/CLOSED/' $ticket")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "Bash sed -i closing D9 without a spec tag must refuse"
  assert_contains "$out" "R-ticket-lock-missing: D9" "D9 bash write did not name missing D9"
  pass "spec compile stop: Bash sed -i of a closed untagged ticket exits 2"
}

test_no_write_this_turn_is_inert_while_spec_red() {
  local home spec transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/red-no-write")
  spec="$home/data/wf-map2-loops/spec.md"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    "$(write_tool_line Read "$spec")" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"spec is still red"}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "no write this turn must stay inert even if the spec is red"
  [ -z "$out" ] || fail "no-write inert Stop produced output: $out"
  pass "spec compile stop: no write this turn is inert while spec is red"
}

test_child_worktree_write_checks_that_tree() {
  local operating wt spec transcript payload out rc
  operating=$(write_green_home "$TMP_ROOT/operating-green")
  wt="$TMP_ROOT/child-red"
  write_green_home "$wt" >/dev/null
  spec="$wt/data/wf-map2-loops/spec.md"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  transcript="$wt/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | env FM_HOME="$operating" "$ADAPTER" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "child-tree write must check that tree"
  assert_contains "$out" "R-ticket-lock-missing: D8" "child-tree write did not see missing D8"
  [ -f "$operating/data/wf-map2-loops/spec.md" ] || fail "operating spec vanished"
  grep -q 'D8 is the lock' "$operating/data/wf-map2-loops/spec.md" \
    || fail "operating spec lost its D8 tag"
  pass "spec compile stop: child worktree write checks that tree, not FM_HOME"
}

test_pi_payload_without_transcript_is_inert() {
  local out rc
  set +e
  out=$(run_adapter '{"stop_hook_active":false}')
  rc=$?
  set -e
  expect_code 0 "$rc" "Pi-shaped payload without a transcript must stay inert"
  [ -z "$out" ] || fail "Pi-shaped payload produced output: $out"
  pass "spec compile stop: Pi payload without transcript exits 0"
}

test_manufactured_breakage_of_d8_tag() {
  local home spec transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/break-d8")
  spec="$home/data/wf-map2-loops/spec.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "green fixture must start clean"
  [ -z "$out" ] || fail "green fixture produced output: $out"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "deleting the D8 tag must go red"
  assert_contains "$out" "R-ticket-lock-missing: D8" "deleted D8 tag did not go red"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "D8 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "restoring the D8 tag must go green"
  [ -z "$out" ] || fail "restored D8 tag produced output: $out"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "deleting the D8 tag again must go red"
  assert_contains "$out" "R-ticket-lock-missing: D8" "second D8 delete did not go red"
  pass "spec compile stop: manufactured breakage of the D8 tag"
}

write_reduce_lock() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

test_decision_write_without_expected_reports_is_inert() {
  local home lock transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/decision-inert")
  lock="$home/data/decisions/lock.md"
  write_reduce_lock "$lock" "# lock" "no declaration here"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$lock")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "decision write without expected-reports must stay inert"
  [ -z "$out" ] || fail "inert decision write produced output: $out"
  pass "spec compile stop: decision write without expected-reports is inert"
}

test_decision_write_missing_report_refuses() {
  local home lock transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/decision-missing")
  write_keep "$home/data/ov-a/report.md" "Node contract: bounded job"
  lock="$home/data/decisions/lock.md"
  write_reduce_lock "$lock" \
    "expected-reports: ov-a, ov-b" \
    "Cite \`data/ov-a/report.md\`." \
    "Cite \`data/ov-b/report.md\`."
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$lock")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "decision write with a missing expected report must refuse"
  assert_contains "$out" "R-reduce-missing:" "missing expected report did not fire"
  assert_contains "$out" "decision-missing/data/ov-b/report.md" \
    "missing ov-b was not named from the written home"
  pass "spec compile stop: decision write with missing expected report exits 2"
}

test_child_home_not_fm_home_for_reduce() {
  local operating wt lock transcript payload out rc
  operating=$(write_green_home "$TMP_ROOT/reduce-operating")
  write_keep "$operating/data/ov-a/report.md" "Node contract: bounded job"
  write_keep "$operating/data/ov-b/report.md" "Merge counts expected inputs"
  wt="$TMP_ROOT/reduce-child"
  write_green_home "$wt" >/dev/null
  lock="$wt/data/decisions/lock.md"
  write_reduce_lock "$lock" \
    "expected-reports: ov-a, ov-b" \
    "Cite \`data/ov-a/report.md\`." \
    "Cite \`data/ov-b/report.md\`."
  transcript="$wt/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$lock")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | env FM_HOME="$operating" "$ADAPTER" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "child-tree reduce must check that tree, not FM_HOME"
  assert_contains "$out" "R-reduce-missing:" "child-tree reduce did not fire missing"
  assert_contains "$out" "reduce-child/data/ov-a/report.md" \
    "child-tree reduce resolved ids against FM_HOME"
  assert_not_contains "$out" "reduce-operating/data/ov-a/report.md" \
    "child-tree reduce named the operating home path"
  pass "spec compile stop: reduce ids resolve under the written path home, not FM_HOME"
}

test_failed_declared_reduce_is_clean() {
  local home lock transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/reduce-failed")
  write_keep "$home/data/ov-a/report.md" "Node contract: bounded job"
  lock="$home/data/decisions/lock.md"
  write_reduce_lock "$lock" \
    "expected-reports: ov-a, ov-b(failed: scout died after dispatch)" \
    "Cite \`data/ov-a/report.md\`."
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$lock")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "failed-declared member must not refuse Stop"
  pass "spec compile stop: declared failed expected report stays clean"
}

test_child_worktree_guard_seat_before_scope() {
  local base wt spec transcript payload out rc
  base="$TMP_ROOT/child-base"
  wt="$TMP_ROOT/child-wt"
  fm_git_worktree "$base" "$wt" fm/compile-child
  install_guard_fixture "$wt"
  write_green_home "$wt" >/dev/null
  spec="$wt/data/wf-map2-loops/spec.md"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "DX is the lock." \
    "XG-keep \"Node contract\"."
  transcript="$wt/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_guard "$wt" "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "child worktree Stop with a red spec write must refuse"
  assert_contains "$out" "R-ticket-lock-missing: D8" "guard seat did not name missing D8"
  pass "spec compile stop: guard seat before primary-scope refuses a child write"
}

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

test_write_renames_d8_and_refuses
test_write_then_tool_result_still_refuses
test_write_then_stop_hook_feedback_still_refuses
test_bash_sed_closed_ticket_without_tag_refuses
test_no_write_this_turn_is_inert_while_spec_red
test_child_worktree_write_checks_that_tree
test_pi_payload_without_transcript_is_inert
test_manufactured_breakage_of_d8_tag
test_decision_write_without_expected_reports_is_inert
test_decision_write_missing_report_refuses
test_child_home_not_fm_home_for_reduce
test_failed_declared_reduce_is_clean
test_child_worktree_guard_seat_before_scope

echo "# all fm-spec-compile-stop-check tests passed"
