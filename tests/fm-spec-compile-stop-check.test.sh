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
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-spec-compile-stop-check.sh" \
    "$dir/bin/fm-spec-compile-check.sh"
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
test_bash_sed_closed_ticket_without_tag_refuses
test_no_write_this_turn_is_inert_while_spec_red
test_child_worktree_write_checks_that_tree
test_pi_payload_without_transcript_is_inert
test_manufactured_breakage_of_d8_tag
test_child_worktree_guard_seat_before_scope

echo "# all fm-spec-compile-stop-check tests passed"
