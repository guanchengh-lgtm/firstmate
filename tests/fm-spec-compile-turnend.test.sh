#!/usr/bin/env bash
# Behavioral coverage for the spec compile-check Stop adapter.
# Exercises this-turn write detection, home derivation from the written path,
# child-worktree Stop, and manufactured breakage of one asserted tag.
# Does not assert adapter or matcher source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-spec-compile-turnend.sh"
TMP_ROOT=$(fm_test_tmproot fm-spec-compile-turnend)
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

write_red_home() {
  local home=$1
  mkdir -p "$home/data/wf-map2-loops/tickets" "$home/data/synth"
  write_ticket "$home/data/wf-map2-loops/tickets" D1 "CLOSED 2026-08-20"
  write_ticket "$home/data/wf-map2-loops/tickets" D8 "CLOSED 2026-08-20"
  write_keep "$home/data/synth/report.md" "Node contract: bounded job, defined input"
  write_spec "$home/data/wf-map2-loops/spec.md" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  printf '%s\n' "$home"
}

write_green_home() {
  local home=$1
  write_red_home "$home" >/dev/null
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

run_adapter() {
  local payload=$1
  printf '%s' "$payload" | env -u FM_HOME -u FM_ROOT_OVERRIDE "$ADAPTER" 2>&1
}

install_guard_fixture() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-spec-compile-turnend.sh" "$dir/bin/fm-spec-compile-turnend.sh"
  cp "$ROOT/bin/fm-spec-compile-check.sh" "$dir/bin/fm-spec-compile-check.sh"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-spec-compile-turnend.sh" \
    "$dir/bin/fm-spec-compile-check.sh"
}

run_guard() {
  local dir=$1 payload=$2
  printf '%s' "$payload" | env -u FM_HOME -u FM_ROOT_OVERRIDE bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

test_child_worktree_write_missing_d8_is_refused() {
  local base wt spec transcript payload out rc
  base="$TMP_ROOT/child-base"
  wt="$TMP_ROOT/child-wt"
  fm_git_worktree "$base" "$wt" fm/compile-child
  install_guard_fixture "$wt"
  write_red_home "$wt" >/dev/null
  spec="$wt/data/wf-map2-loops/spec.md"
  transcript="$wt/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_guard "$wt" "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "child worktree Stop with a red spec write must refuse"
  assert_contains "$out" "R-ticket-lock-missing: D8" "refusal did not name missing D8"
  write_transcript "$transcript" "$(write_tool_line Read "$spec")"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_guard "$wt" "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "child worktree Stop with no write must stay inert while spec is red"
  [ -z "$out" ] || fail "child worktree no-write Stop produced output: $out"
  pass "spec compile turnend: child worktree write of red spec exits 2"
}

test_no_write_this_turn_is_inert_while_spec_red() {
  local home transcript payload out rc
  home=$(write_red_home "$TMP_ROOT/red-no-write")
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    "$(write_tool_line Read "$home/data/wf-map2-loops/spec.md")" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"spec is still red"}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "no write this turn must stay inert even if the spec is red"
  [ -z "$out" ] || fail "no-write inert Stop produced output: $out"
  pass "spec compile turnend: no write this turn is inert while spec is red"
}

test_worktree_write_does_not_check_operating_home() {
  local operating wt spec transcript payload out rc
  operating=$(write_red_home "$TMP_ROOT/operating-red")
  wt="$TMP_ROOT/written-green"
  write_green_home "$wt" >/dev/null
  spec="$wt/data/wf-map2-loops/spec.md"
  transcript="$wt/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Edit "$spec")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | env FM_HOME="$operating" "$ADAPTER" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "worktree-local write must not check a red operating home"
  [ -z "$out" ] || fail "worktree-local green write produced output: $out"
  pass "spec compile turnend: written tree is checked, not FM_HOME"
}

test_unset_fm_home_still_uses_written_path() {
  local home spec transcript payload out rc
  home=$(write_red_home "$TMP_ROOT/no-fm-home")
  spec="$home/data/wf-map2-loops/spec.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "unset FM_HOME must still refuse from the written path"
  assert_contains "$out" "R-ticket-lock-missing: D8" "written-path refuse did not name missing D8"
  pass "spec compile turnend: unset FM_HOME still finds the written home"
}

test_absent_map2_tree_without_write_is_inert() {
  local home transcript payload out rc
  home="$TMP_ROOT/no-map2"
  mkdir -p "$home"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" \
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"idle turn"}]}}'
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 0 "$rc" "absent Map 2 tree with no write must stay inert"
  [ -z "$out" ] || fail "absent Map 2 tree produced output: $out"
  pass "spec compile turnend: absent Map 2 tree with no write exits 0"
}

test_manufactured_breakage_of_d8_tag() {
  local home spec transcript payload out rc
  home=$(write_red_home "$TMP_ROOT/break-d8")
  spec="$home/data/wf-map2-loops/spec.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "fixture missing D8 must start red"
  assert_contains "$out" "R-ticket-lock-missing: D8" "red fixture did not name D8"
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
  expect_code 0 "$rc" "adding the D8 tag must go green"
  [ -z "$out" ] || fail "green D8 tag produced output: $out"
  write_spec "$spec" \
    "# Spec" \
    "Cite \`data/synth/report.md\`." \
    "D1 is the lock." \
    "XG-keep \"Node contract\"."
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "deleting the D8 tag must go red again"
  assert_contains "$out" "R-ticket-lock-missing: D8" "deleted D8 tag did not go red"
  pass "spec compile turnend: manufactured breakage of the D8 tag"
}

test_stop_hook_active_still_refuses_a_red_write() {
  local home spec transcript payload out rc
  home=$(write_red_home "$TMP_ROOT/active-stop")
  spec="$home/data/wf-map2-loops/spec.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$spec")"
  payload=$(printf '{"stop_hook_active":true,"transcript_path":"%s"}' "$transcript")
  install_guard_fixture "$home"
  set +e
  out=$(run_guard "$home" "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "stop_hook_active must not allow a red compile write"
  assert_contains "$out" "R-ticket-lock-missing: D8" "active-stop refuse did not name missing D8"
  pass "spec compile turnend: stop_hook_active still refuses a red write"
}

test_keep_source_write_is_a_compile_event() {
  local home report transcript payload out rc
  home=$(write_green_home "$TMP_ROOT/keep-write")
  write_keep "$home/data/synth/report.md" \
    "Node contract: bounded job, defined input" \
    "Dormant skills (~100 words until match) as a tool-layer shape"
  report="$home/data/synth/report.md"
  transcript="$home/transcript.jsonl"
  write_transcript "$transcript" "$(write_tool_line Write "$report")"
  payload=$(printf '{"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(run_adapter "$payload")
  rc=$?
  set -e
  expect_code 2 "$rc" "writing a cited keep-source must run the matcher"
  assert_contains "$out" "R-keep-lock-missing:" "keep-source write did not report a keep finding"
  pass "spec compile turnend: cited keep-source write is a compile event"
}

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

test_child_worktree_write_missing_d8_is_refused
test_no_write_this_turn_is_inert_while_spec_red
test_worktree_write_does_not_check_operating_home
test_unset_fm_home_still_uses_written_path
test_absent_map2_tree_without_write_is_inert
test_manufactured_breakage_of_d8_tag
test_stop_hook_active_still_refuses_a_red_write
test_keep_source_write_is_a_compile_event

echo "# all fm-spec-compile-turnend tests passed"
