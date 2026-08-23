#!/usr/bin/env bash
# Behavioral coverage for the owner-invoke-wait refuse-hook.
# Exercises public CLI exit codes, exact-count regression, and reconstructed
# 2026-08-22 turns. Does not assert checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-owner-invoke-wait-check.sh"
FIXTURES="$ROOT/tests/fixtures/fm-owner-invoke-wait-check"
OWN_CLAIMS="$ROOT/docs/verification/owner-invoke-wait-claims.json"
NODE_CLAIMS="$ROOT/docs/verification/owner-node-open-claims.json"
TMP_ROOT=$(fm_test_tmproot fm-owner-invoke-wait-check)
fm_git_identity fmtest fmtest@example.invalid

run_check() {
  "$CHECK" "$@" 2>&1
}

write_turn() {
  local path=$1
  shift
  printf '%s\n' "$@" > "$path"
}

test_missing_and_empty_input_are_structural() {
  local out rc empty
  empty="$TMP_ROOT/empty.json"
  : > "$empty"
  set +e
  out=$(run_check)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "hook mode with empty stdin exited $rc"
  set +e
  out=$(run_check --input "$TMP_ROOT/no-such.json")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing file exited $rc"
  assert_contains "$out" "missing claims" "missing file did not say missing"
  set +e
  out=$(run_check --input "$empty")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty claims exited $rc"
  assert_contains "$out" "empty claims" "empty claims was not structural"
  set +e
  out=$(run_check --brief "$empty")
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty brief exited $rc"
  assert_contains "$out" "empty brief" "empty brief was not structural"
  set +e
  out=$(run_check --input "$empty" --expect-rule R-owner-invoke-wait --expect-count 0)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(run_check --input "$FIXTURES/historical-yes-ask.json" --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  pass "owner-invoke-wait: missing and empty input, expect-count 0, empty rules exit 2"
}

test_historical_yes_ask_fires_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-yes-ask.json" \
    --expect-rule R-owner-invoke-wait --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical yes-ask exact-count exited $rc: $out"
  set +e
  out=$(run_check --input "$FIXTURES/historical-yes-ask.json")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical yes-ask gate exited $rc: $out"
  assert_contains "$out" "R-owner-invoke-wait-yes-ask" \
    "historical yes-ask did not report owner-invoke wait"
  assert_contains "$out" "recurring-defect" \
    "historical yes-ask did not name /recurring-defect"
  pass "owner-invoke-wait: 2026-08-22 reconstructed yes-ask fires exact count 1"
}

test_historical_fog_pin_fires_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-fog-pin.json" \
    --expect-rule R-fog-pin-wait --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical fog-pin exact-count exited $rc: $out"
  pass "owner-invoke-wait: 2026-08-22 reconstructed fog pin fires exact count 1"
}

test_historical_ship_omission_fires_exact_count() {
  local out rc brief
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-ship-without-ov.json" \
    --expect-rule R-ov-missing --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical ship without OV exact-count exited $rc: $out"
  set +e
  out=$(run_check --input "$FIXTURES/historical-ship-without-ov.json")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical ship without OV gate exited $rc: $out"
  assert_contains "$out" "R-ov-missing-none" \
    "historical compile-check ship did not report missing OV"
  pass "owner-invoke-wait: 2026-08-22 compile-check with no OV fires exact count 1"
}

test_held_locked_next_and_date_cleared() {
  local out rc turn
  turn="$TMP_ROOT/held-map-next.json"
  write_turn "$turn" '{
    "held": [{"id":"map-s2","hold_kind":"captain","hold_reason":"waiting for captain go","hold_until":"-"}],
    "map_next": ["map-s2"],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-held-locked-next --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "held map_next exact-count exited $rc: $out"
  turn="$TMP_ROOT/held-owned.json"
  write_turn "$turn" '{
    "held": [{"id":"map-s2","hold_kind":"captain","hold_reason":"waiting for captain go","hold_until":"-"}],
    "map_next": ["map-s2"],
    "owned_meta": ["map-s2"],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "owned held map_next exited $rc: $out"
  [ -z "$out" ] || fail "owned held map_next printed findings: $out"
  turn="$TMP_ROOT/date-cleared.json"
  write_turn "$turn" '{
    "held": [{"id":"slice-old","hold_kind":"future","hold_reason":"wait","hold_until":"2020-01-01"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-held-locked-next --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "date-cleared hold exact-count exited $rc: $out"
  turn="$TMP_ROOT/future-hold.json"
  write_turn "$turn" '{
    "held": [{"id":"later","hold_kind":"future","hold_reason":"start later","hold_until":"2099-01-01"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "future hold exited $rc: $out"
  [ -z "$out" ] || fail "future hold printed findings: $out"
  turn="$TMP_ROOT/real-captain.json"
  write_turn "$turn" '{
    "held": [{"id":"merge-q","hold_kind":"captain","hold_reason":"captain decision pending","hold_until":"-"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "real captain hold exited $rc: $out"
  [ -z "$out" ] || fail "real captain hold printed findings: $out"
  turn="$TMP_ROOT/english-hold.json"
  write_turn "$turn" '{
    "held": [{"id":"slice-go","hold_kind":"captain","hold_reason":"waiting for captain go","hold_until":"-"}],
    "map_next": [],
    "owned_meta": [],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "English hold reason without map_next exited $rc: $out"
  [ -z "$out" ] || fail "English hold reason printed findings: $out"
  pass "owner-invoke-wait: held map_next, date-cleared, future, and real captain holds"
}

test_invoked_and_english_without_marker_are_clean() {
  local out rc turn
  turn="$TMP_ROOT/invoked.json"
  write_turn "$turn" '{
    "assistant_text": "OWNER_INVOKE_WAIT /recurring-defect",
    "invoked_skills": ["recurring-defect"],
    "held": [],
    "map_next": [],
    "owned_meta": [],
    "fog_live": false
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "invoked skill with marker exited $rc: $out"
  [ -z "$out" ] || fail "invoked skill printed findings: $out"
  turn="$TMP_ROOT/english.json"
  write_turn "$turn" '{
    "assistant_text": "Want me to run /recurring-defect?",
    "invoked_skills": [],
    "held": [],
    "map_next": [],
    "owned_meta": [],
    "fog_live": false
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "English yes-ask without marker exited $rc: $out"
  [ -z "$out" ] || fail "English yes-ask printed findings: $out"
  pass "owner-invoke-wait: invoked skill and English without marker are clean"
}

test_placeholder_and_stub_briefs_are_clean() {
  local out rc brief
  brief="$TMP_ROOT/placeholder.md"
  printf '# Task\n{TASK}\n\n# Setup\nfixture\n' > "$brief"
  set +e
  out=$(run_check --brief "$brief")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "placeholder brief exited $rc: $out"
  [ -z "$out" ] || fail "placeholder brief printed findings: $out"
  brief="$TMP_ROOT/no-task.md"
  printf 'brief for stub\n' > "$brief"
  set +e
  out=$(run_check --brief "$brief")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "no-task stub exited $rc: $out"
  pass "owner-invoke-wait: placeholder and no-task briefs are clean"
}

test_builder_self_review_is_not_ov() {
  local out rc turn
  turn="$TMP_ROOT/self-review.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"","task":"Start Spec compile-check.","skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check"]
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-ov-missing --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "builder self-review exact-count exited $rc: $out"
  turn="$TMP_ROOT/ov-self.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check","skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check"]
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "self OV id exited $rc: $out"
  assert_contains "$out" "R-ov-missing-self" "self OV id did not report self-review"
  pass "owner-invoke-wait: builder self-review is not OV"
}

test_distinct_ov_worker_is_clean() {
  local out rc turn
  turn="$TMP_ROOT/ov-ok.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","task":"Start Spec compile-check."}],
    "owned_meta": ["spec-compile-check", "spec-compile-check-ov"]
  }'
  set +e
  out=$(run_check --input "$turn" --rules R-ov-missing)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "distinct OV worker exited $rc: $out"
  [ -z "$out" ] || fail "distinct OV worker printed findings: $out"
  turn="$TMP_ROOT/ov-missing-worker.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","task":"Start Spec compile-check."}],
    "owned_meta": ["spec-compile-check"]
  }'
  set +e
  out=$(run_check --input "$turn" --rules R-ov-missing)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing OV worker exited $rc: $out"
  assert_contains "$out" "R-ov-missing-worker" "missing OV worker did not report unspawned OV"
  turn="$TMP_ROOT/ov-report-proves.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_harness":"claude","ov_report":true,"ov_alive":false,"skills":["plan-eng-review"]}],
    "owned_meta": ["spec-compile-check"]
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "report presence should prove OV without live worker exited $rc: $out"
  [ -z "$out" ] || fail "report presence printed findings: $out"
  pass "owner-invoke-wait: distinct spawned OV worker is required"
}

test_ov_report_and_skill_records() {
  local out rc turn
  turn="$TMP_ROOT/live-no-report.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":false,"ov_alive":true,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "live OV worker without report exited $rc: $out"
  [ -z "$out" ] || fail "live OV worker without report printed findings: $out"
  turn="$TMP_ROOT/gone-no-report.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":false,"ov_alive":false,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-ov-missing --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "gone OV worker without report exact-count exited $rc: $out"
  turn="$TMP_ROOT/no-skill.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_harness":"claude","ov_report":true,"ov_alive":false,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-skill-unloaded --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "unloaded plan-eng-review exact-count exited $rc: $out"
  turn="$TMP_ROOT/skills-before-report.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_harness":"claude","ov_report":false,"ov_alive":true,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn" --rules R-skill-unloaded)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "skills gate before report exited $rc: $out"
  [ -z "$out" ] || fail "skills gate before report printed findings: $out"
  turn="$TMP_ROOT/non-claude-no-skill.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_harness":"codex","ov_report":true,"ov_alive":false,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn" --rules R-skill-unloaded)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "non-Claude finished review without skills exited $rc: $out"
  [ -z "$out" ] || fail "non-Claude finished review without skills printed findings: $out"
  turn="$TMP_ROOT/missing-ov-harness-no-skill.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":true,"ov_alive":false,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn" --rules R-skill-unloaded)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "missing ov_harness skill gap exited $rc: $out"
  [ -z "$out" ] || fail "missing ov_harness skill gap printed findings: $out"
  pass "owner-invoke-wait: OV report ladder and report-gated skills own the wait"
}

test_unrelated_rule_does_not_satisfy_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-yes-ask.json" \
    --expect-rule R-held-locked-next --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "unrelated held exact-count exited $rc: $out"
  assert_contains "$out" "regression:" "unrelated-rule miss was not a count mismatch"
  pass "owner-invoke-wait: unrelated rule fire is not exact-count success"
}

test_own_claims_pass_class_too_narrow() {
  local out rc
  set +e
  out=$("$ROOT/bin/fm-class-too-narrow-check.sh" --input "$OWN_CLAIMS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "own claims exited $rc: $out"
  [ -z "$out" ] || fail "own claims printed findings: $out"
  pass "owner-invoke-wait: tracked claims pass class-too-narrow"
}

test_historical_owner_node_open_fires_exact_count() {
  local out rc
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-owner-node-open.json" \
    --expect-rule R-owner-node-open --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "historical owner-node-open exact-count exited $rc: $out"
  set +e
  out=$(run_check --input "$FIXTURES/historical-owner-node-open.json")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "historical owner-node-open gate exited $rc: $out"
  assert_contains "$out" "R-owner-node-open-waiting" \
    "historical owner-node-open did not report a waiting node"
  assert_contains "$out" "/wayfinder" \
    "historical owner-node-open did not name wayfinder"
  set +e
  out=$(run_check \
    --input "$FIXTURES/historical-owner-node-open.json" \
    --expect-rule R-owner-invoke-wait --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "owner-node-open must not count as OWNER_INVOKE_WAIT: $out"
  pass "owner-invoke-wait: 2026-08-23 reconstructed owner-node-open fires exact count 1"
}

test_owner_node_same_turn_and_artifact_are_clean() {
  local out rc turn
  turn="$TMP_ROOT/node-same-turn.json"
  write_turn "$turn" '{
    "owner_nodes": [{"token":"wayfinder","later_captain":false,"artifact":false}],
    "assistant_text": "",
    "held": [],
    "map_next": [],
    "owned_meta": [],
    "fog_live": false
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "same-turn owner node exited $rc: $out"
  [ -z "$out" ] || fail "same-turn owner node printed findings: $out"
  turn="$TMP_ROOT/node-artifact.json"
  write_turn "$turn" '{
    "owner_nodes": [{"token":"wayfinder","later_captain":true,"artifact":true}],
    "assistant_text": ""
  }'
  set +e
  out=$(run_check --input "$turn")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "owner node with artifact exited $rc: $out"
  [ -z "$out" ] || fail "owner node with artifact printed findings: $out"
  pass "owner-invoke-wait: same-turn Stop and matching artifact are clean"
}

test_owner_node_claims_pass_class_too_narrow() {
  local out rc
  set +e
  out=$("$ROOT/bin/fm-class-too-narrow-check.sh" --input "$NODE_CLAIMS")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "owner-node-open claims exited $rc: $out"
  [ -z "$out" ] || fail "owner-node-open claims printed findings: $out"
  pass "owner-invoke-wait: owner-node-open claims pass class-too-narrow"
}

make_primary_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

test_pretool_yes_ask_is_denied() {
  local home out rc payload
  home=$(make_primary_home "$TMP_ROOT/pretool")
  payload=$(printf '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"OWNER_INVOKE_WAIT /recurring-defect"}]}}')
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --pretool --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "pretool yes-ask exited $rc with: $out"
  assert_contains "$out" 'permissionDecision":"deny' "pretool refusal was not a deny object"
  pass "owner-invoke-wait: AskUserQuestion PreToolUse denies an owner-invoke yes-ask"
}

test_hook_gathers_session_ship_ov_ladder() {
  local home out rc payload transcript ship_wt
  home=$(make_primary_home "$TMP_ROOT/hook-ships")
  ship_wt="$home/ships/spec-compile-check"
  mkdir -p "$home/data/spec-compile-check" "$home/data/spec-compile-check-ov" "$ship_wt"
  printf '4242\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'ov_harness=claude' \
    'session=4242' "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
  # Torn-down OV worker: report present, meta gone, skills missing -> skill refuse.
  printf 'OV done\n' > "$home/data/spec-compile-check-ov/report.md"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "hook report-gated skill refuse exited $rc with: $out"
  assert_contains "$out" 'R-skill-unloaded-plan-eng-review' \
    "hook did not refuse unloaded plan-eng-review after OV report"
  printf '%s\n' 'plan-eng-review' > "$home/data/spec-compile-check-ov/skills"
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "hook torn-down OV with report+skill exited $rc with: $out"
  [ -z "$out" ] || fail "hook torn-down OV with report+skill printed: $out"
  rm -f "$home/data/spec-compile-check-ov/report.md" \
    "$home/data/spec-compile-check-ov/skills"
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "hook gone OV without report exited $rc with: $out"
  assert_contains "$out" 'R-ov-missing-report' \
    "hook did not refuse gone OV worker without report"
  pass "owner-invoke-wait: hook session gather runs OV report ladder"
}

test_hook_does_not_rerefuse_inflight_ship_without_ov() {
  local home out rc payload transcript ship_wt
  home=$(make_primary_home "$TMP_ROOT/hook-no-ov")
  ship_wt="$home/ships/legacy-ship"
  mkdir -p "$home/data/legacy-ship" "$ship_wt"
  printf '5151\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'session=5151' "worktree=$ship_wt" \
    > "$home/state/legacy-ship.meta"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "in-flight ship without ov exited $rc with: $out"
  [ -z "$out" ] || fail "in-flight ship without ov printed: $out"
  pass "owner-invoke-wait: turn-end does not re-refuse in-flight ships without ov="
}

test_prior_turn_tool_mention_is_not_invoke_credit() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-prior-turn")
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"echo wayfinder docs"}}]}}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"ok"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OWNER_INVOKE_WAIT /wayfinder"}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "prior-turn tool mention exited $rc with: $out"
  assert_contains "$out" 'R-owner-invoke-wait-yes-ask' \
    "prior-turn tool-input mention incorrectly credited an invoke"
  assert_contains "$out" 'wayfinder' "prior-turn miss did not name wayfinder"
  pass "owner-invoke-wait: prior-turn tool-input mention is not invoke credit"
}

test_same_turn_skill_tool_load_is_invoke_credit() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-skill-load")
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"wayfinder"}},{"type":"text","text":"OWNER_INVOKE_WAIT /wayfinder"}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "same-turn Skill load exited $rc with: $out"
  [ -z "$out" ] || fail "same-turn Skill load printed: $out"
  pass "owner-invoke-wait: same-turn Skill tool load credits the invoke"
}

test_brief_reads_ov_worker_report_and_skills() {
  local home out rc brief
  home=$(make_primary_home "$TMP_ROOT/brief-ov")
  mkdir -p "$home/data/spec-compile-check" "$home/data/spec-compile-check-ov"
  brief="$home/data/spec-compile-check/brief.md"
  printf '# Task\nfilled ship work\n' > "$brief"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'ov_harness=claude' \
    > "$home/state/spec-compile-check.meta"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --brief "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "brief gone OV without report exited $rc with: $out"
  assert_contains "$out" 'R-ov-missing-report' \
    "brief mode did not refuse gone OV without report"
  printf 'OV ok\n' > "$home/data/spec-compile-check-ov/report.md"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --brief "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "brief report without skill exited $rc with: $out"
  assert_contains "$out" 'R-skill-unloaded-plan-eng-review' \
    "brief mode did not gate skills on OV report"
  printf '%s\n' 'plan-eng-review' > "$home/data/spec-compile-check-ov/skills"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --brief "$brief" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "brief with OV report+skill exited $rc with: $out"
  [ -z "$out" ] || fail "brief with OV report+skill printed: $out"
  pass "owner-invoke-wait: brief mode reads OV worker report and skills"
}

test_tool_result_user_message_keeps_same_turn_invoke_credit() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-tool-result")
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"wayfinder"}}]}}
{"type":"message","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"1","content":"loaded"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"OWNER_INVOKE_WAIT /wayfinder"}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "tool_result same-turn Skill load exited $rc with: $out"
  [ -z "$out" ] || fail "tool_result same-turn Skill load printed: $out"
  pass "owner-invoke-wait: tool_result user message keeps same-turn invoke credit"
}

test_pretool_credits_transcript_skill_load() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/pretool-skill")
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"wayfinder"}}]}}
{"type":"message","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"1","content":"ok"}]}}
JSONL
  payload=$(printf '{"tool_name":"AskUserQuestion","transcript_path":"%s","tool_input":{"questions":[{"question":"OWNER_INVOKE_WAIT /wayfinder"}]}}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" --pretool --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "pretool with same-turn Skill load exited $rc with: $out"
  [ -z "$out" ] || fail "pretool with same-turn Skill load printed: $out"
  pass "owner-invoke-wait: PreToolUse credits transcript skill-load invokes"
}

test_hook_ignores_prior_session_ships() {
  local home out rc payload transcript ship_wt prior_wt
  home=$(make_primary_home "$TMP_ROOT/hook-other-ship")
  ship_wt="$home/ships/current-ship"
  prior_wt="$home/ships/prior-ship"
  mkdir -p "$home/data/current-ship" "$home/data/current-ov" \
    "$home/data/prior-ship" "$home/data/prior-ov" "$ship_wt" "$prior_wt"
  printf '9001\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'ov=prior-ov' 'session=111' "worktree=$prior_wt" \
    > "$home/state/prior-ship.meta"
  printf 'bad\n' > "$home/data/prior-ov/report.md"
  printf '%s\n' 'kind=ship' 'ov=current-ov' 'session=9001' "worktree=$ship_wt" \
    > "$home/state/current-ship.meta"
  printf 'OV ok\n' > "$home/data/current-ov/report.md"
  printf '%s\n' 'plan-eng-review' > "$home/data/current-ov/skills"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "prior-session ship wedged current session exited $rc with: $out"
  [ -z "$out" ] || fail "prior-session ship printed: $out"
  pass "owner-invoke-wait: hook scopes ship gather to this session only"
}

test_missing_skills_record_counts_as_unloaded() {
  local home out rc payload transcript ship_wt
  home=$(make_primary_home "$TMP_ROOT/hook-missing-skills")
  ship_wt="$home/ships/spec-compile-check"
  mkdir -p "$home/data/spec-compile-check" "$home/data/spec-compile-check-ov" "$ship_wt"
  printf '6161\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'ov_harness=claude' \
    'session=6161' "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
  printf 'OV done\n' > "$home/data/spec-compile-check-ov/report.md"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "missing skills record exited $rc with: $out"
  assert_contains "$out" 'R-skill-unloaded-plan-eng-review' \
    "missing skills record did not count as unloaded"
  pass "owner-invoke-wait: missing skills record counts as unloaded"
}

test_finished_non_claude_review_without_skills_passes() {
  local home out rc payload transcript ship_wt
  home=$(make_primary_home "$TMP_ROOT/hook-non-claude-ov")
  ship_wt="$home/ships/spec-compile-check"
  mkdir -p "$home/data/spec-compile-check" "$home/data/spec-compile-check-ov" "$ship_wt"
  printf '6262\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'ov_harness=codex' \
    'session=6262' "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
  printf 'OV done on codex\n' > "$home/data/spec-compile-check-ov/report.md"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "finished non-Claude OV without skills exited $rc with: $out"
  [ -z "$out" ] || fail "finished non-Claude OV without skills printed: $out"
  pass "owner-invoke-wait: finished non-Claude review without skills passes"
}

test_finished_claude_review_without_skills_refuses() {
  local home out rc payload transcript ship_wt
  home=$(make_primary_home "$TMP_ROOT/hook-claude-ov-no-skill")
  ship_wt="$home/ships/spec-compile-check"
  mkdir -p "$home/data/spec-compile-check" "$home/data/spec-compile-check-ov" "$ship_wt"
  printf '6363\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'ov_harness=claude' \
    'session=6363' "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
  printf 'OV done on claude\n' > "$home/data/spec-compile-check-ov/report.md"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "finished Claude OV without skills exited $rc with: $out"
  assert_contains "$out" 'R-skill-unloaded-plan-eng-review' \
    "finished Claude OV without skills did not refuse"
  pass "owner-invoke-wait: finished Claude review without skills refuses"
}

test_skill_load_record_appends_normalized_token() {
  local home out rc payload skills recorder
  home=$(make_primary_home "$TMP_ROOT/skill-load")
  recorder="$ROOT/bin/fm-skill-load-record.sh"
  [ -x "$recorder" ] || fail "fm-skill-load-record.sh missing"
  printf '%s\n' 'kind=scout' > "$home/state/ov-worker.meta"
  payload='{"tool_name":"Skill","tool_input":{"skill":"gstack-plan-eng-review"}}'
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_TASK_ID=ov-worker \
    "$recorder" --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "skill-load recorder exited $rc with: $out"
  skills="$home/data/ov-worker/skills"
  [ -f "$skills" ] || fail "skill-load recorder did not create skills file"
  assert_contains "$(cat "$skills")" 'plan-eng-review' \
    "skill-load recorder did not normalize gstack-plan-eng-review"
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_TASK_ID=ov-worker \
    "$recorder" --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "skill-load recorder re-append exited $rc with: $out"
  [ "$(wc -l < "$skills" | tr -d ' ')" = 1 ] \
    || fail "skill-load recorder duplicated an existing token"
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_TASK_ID=missing \
    "$recorder" --claude 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "skill-load recorder without meta exited $rc"
  [ ! -e "$home/data/missing/skills" ] \
    || fail "skill-load recorder wrote skills without task meta"
  pass "owner-invoke-wait: skill-load recorder appends normalized token"
}

# Fake tmux for OV liveness: pane present, foreground is a shell husk (dead)
# or a live harness agent. list-windows + pane_id keep target_exists true.
make_ov_liveness_tmux() {  # <dir> <window> <pane_current_command>
  local dir=$1 window=$2 comm=$3 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_id*) printf '%s\n' '%1'; exit 0 ;;
        *pane_tty*) exit 1 ;;
        *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;;
      esac
    done
    exit 0 ;;
  list-windows) printf '%s\n' '$window'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_hook_refuses_husk_ov_worker_without_report() {
  local home out rc payload transcript ship_wt fakebin base_path
  home=$(make_primary_home "$TMP_ROOT/hook-husk-ov")
  ship_wt="$home/ships/spec-compile-check"
  mkdir -p "$home/data/spec-compile-check" "$home/data/spec-compile-check-ov" "$ship_wt"
  printf '7171\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'session=7171' \
    "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
  # Pane still present as a bare shell; agent exited with no report.md.
  printf '%s\n' 'kind=scout' 'backend=tmux' 'window=firstmate:fm-ov-husk' \
    > "$home/state/spec-compile-check-ov.meta"
  fakebin=$(make_ov_liveness_tmux "$TMP_ROOT/husk-tmux" fm-ov-husk bash)
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | PATH="$fakebin:$base_path" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "husk OV without report exited $rc with: $out"
  assert_contains "$out" 'R-ov-missing-report' \
    "husk pane presence incorrectly treated dead OV as in-progress"
  pass "owner-invoke-wait: husk OV pane without report refuses"
}

test_hook_live_ov_agent_without_report_passes() {
  local home out rc payload transcript ship_wt fakebin base_path
  home=$(make_primary_home "$TMP_ROOT/hook-live-ov")
  ship_wt="$home/ships/spec-compile-check"
  mkdir -p "$home/data/spec-compile-check" "$home/data/spec-compile-check-ov" "$ship_wt"
  printf '7272\n' > "$home/state/.lock"
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'session=7272' \
    "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
  printf '%s\n' 'kind=scout' 'backend=tmux' 'window=firstmate:fm-ov-live' \
    > "$home/state/spec-compile-check-ov.meta"
  fakebin=$(make_ov_liveness_tmux "$TMP_ROOT/live-tmux" fm-ov-live claude)
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | PATH="$fakebin:$base_path" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "live OV agent without report exited $rc with: $out"
  [ -z "$out" ] || fail "live OV agent without report printed: $out"
  pass "owner-invoke-wait: live OV agent without report passes"
}

test_crewmate_settings_carry_skill_recorder() {
  local case_dir home proj wt fakebin id=ov-scout-skill out settings cmd skills
  case_dir="$TMP_ROOT/crewmate-skill-settings"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi opencode claude codex
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' claude > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-crewmate-skill"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Role: scout' "brief for $id" > "$home/data/$id/brief.md"
  printf '%s\n' scout > "$home/data/$id/role"
  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --scout 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "claude scout spawn should succeed: $out"
  settings="$wt/.claude/settings.local.json"
  [ -f "$settings" ] || fail "crewmate spawn did not write settings.local.json"
  jq -e '.hooks.PostToolUse[] | select(.matcher == "Skill")' "$settings" >/dev/null \
    || fail "crewmate settings lack PostToolUse matcher Skill"
  cmd=$(jq -r '.hooks.PostToolUse[] | select(.matcher == "Skill") | .hooks[0].command' "$settings")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "crewmate Skill recorder command empty"
  case "$cmd" in
    *"$ROOT/bin/fm-skill-load-record.sh"*) ;;
    *) fail "crewmate Skill recorder is not absolute FM_ROOT path: $cmd" ;;
  esac
  # Emitted config contract: running the wired command records a real load.
  printf '%s\n' 'kind=scout' > "$home/state/$id.meta"
  set +e
  out=$(printf '%s' '{"tool_name":"Skill","tool_input":{"skill":"plan-eng-review"}}' \
    | FM_HOME="$home" FM_TASK_ID="$id" sh -c "$cmd" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "crewmate Skill recorder command exited $rc with: $out"
  skills="$home/data/$id/skills"
  [ -f "$skills" ] || fail "crewmate Skill recorder did not write skills"
  assert_contains "$(cat "$skills")" 'plan-eng-review' \
    "crewmate Skill recorder did not append plan-eng-review"
  pass "owner-invoke-wait: crewmate settings wire Skill load recorder"
}

write_nodes_registry() {
  local home=$1
  mkdir -p "$home/data"
  printf '%s\t%s\n' 'wayfinder' 'data/*/map.md' > "$home/data/owner-invoke-nodes.tsv"
}

test_hook_owner_node_same_turn_is_clean() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-node-same")
  write_nodes_registry "$home"
  printf '9001\n' > "$home/state/.lock"
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"timestamp":"2026-08-23T10:00:00Z","type":"message","message":{"role":"user","content":[{"type":"text","text":"<command-name>/wayfinder</command-name>"}]}}
{"timestamp":"2026-08-23T10:00:01Z","type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Where is this map going?"}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "hook same-turn wayfinder node exited $rc with: $out"
  [ -z "$out" ] || fail "hook same-turn wayfinder node printed: $out"
  pass "owner-invoke-wait: hook does not refuse a wayfinder node on the trigger turn"
}

test_hook_owner_node_later_captain_without_artifact_refuses() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-node-later")
  write_nodes_registry "$home"
  printf '9002\n' > "$home/state/.lock"
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"timestamp":"2026-08-23T10:00:00Z","type":"message","message":{"role":"user","content":[{"type":"text","text":"<command-name>/wayfinder</command-name>"}]}}
{"timestamp":"2026-08-23T10:00:01Z","type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Where is this map going?"}]}}
{"timestamp":"2026-08-23T10:05:00Z","type":"message","message":{"role":"user","content":[{"type":"text","text":"keep going"}]}}
{"timestamp":"2026-08-23T10:05:01Z","type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Still mapping."}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "hook later captain without map exited $rc with: $out"
  assert_contains "$out" 'R-owner-node-open-waiting' \
    "hook later captain did not refuse an open wayfinder node"
  mkdir -p "$home/data/wf-map"
  printf 'map\n' > "$home/data/wf-map/map.md"
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "hook later captain with map.md exited $rc with: $out"
  [ -z "$out" ] || fail "hook later captain with map.md printed: $out"
  pass "owner-invoke-wait: hook refuses an open node after the next captain message"
}

test_hook_owner_node_ignores_slash_without_command_name() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-node-slash")
  write_nodes_registry "$home"
  printf '9003\n' > "$home/state/.lock"
  transcript="$home/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"timestamp":"2026-08-23T10:00:00Z","type":"message","message":{"role":"user","content":[{"type":"text","text":"/wayfinder please chart this"}]}}
{"timestamp":"2026-08-23T10:05:00Z","type":"message","message":{"role":"user","content":[{"type":"text","text":"keep going"}]}}
JSONL
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s","cwd":"%s"}' \
    "$transcript" "$home")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "hook slash without command-name exited $rc with: $out"
  [ -z "$out" ] || fail "hook slash without command-name printed: $out"
  pass "owner-invoke-wait: slash text without command-name does not arm a node"
}

test_hook_owner_node_malformed_registry_is_structural() {
  local home out rc payload transcript
  home=$(make_primary_home "$TMP_ROOT/hook-node-badreg")
  printf 'wayfinder only\n' > "$home/data/owner-invoke-nodes.tsv"
  printf '9004\n' > "$home/state/.lock"
  transcript="$home/transcript.jsonl"
  : > "$transcript"
  payload=$(printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$transcript")
  set +e
  out=$(printf '%s' "$payload" | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$CHECK" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "malformed owner-node registry exited $rc with: $out"
  assert_contains "$out" 'structural:' "malformed owner-node registry was not structural"
  pass "owner-invoke-wait: malformed owner-invoke nodes registry is structural"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_historical_yes_ask_fires_exact_count
test_historical_fog_pin_fires_exact_count
test_historical_ship_omission_fires_exact_count
test_historical_owner_node_open_fires_exact_count
test_owner_node_same_turn_and_artifact_are_clean
test_owner_node_claims_pass_class_too_narrow
test_held_locked_next_and_date_cleared
test_invoked_and_english_without_marker_are_clean
test_placeholder_and_stub_briefs_are_clean
test_builder_self_review_is_not_ov
test_distinct_ov_worker_is_clean
test_ov_report_and_skill_records
test_unrelated_rule_does_not_satisfy_exact_count
test_own_claims_pass_class_too_narrow
test_pretool_yes_ask_is_denied
test_hook_gathers_session_ship_ov_ladder
test_hook_does_not_rerefuse_inflight_ship_without_ov
test_prior_turn_tool_mention_is_not_invoke_credit
test_same_turn_skill_tool_load_is_invoke_credit
test_tool_result_user_message_keeps_same_turn_invoke_credit
test_pretool_credits_transcript_skill_load
test_hook_ignores_prior_session_ships
test_missing_skills_record_counts_as_unloaded
test_finished_non_claude_review_without_skills_passes
test_finished_claude_review_without_skills_refuses
test_skill_load_record_appends_normalized_token
test_hook_refuses_husk_ov_worker_without_report
test_hook_live_ov_agent_without_report_passes
test_crewmate_settings_carry_skill_recorder
test_brief_reads_ov_worker_report_and_skills
test_hook_owner_node_same_turn_is_clean
test_hook_owner_node_later_captain_without_artifact_refuses
test_hook_owner_node_ignores_slash_without_command_name
test_hook_owner_node_malformed_registry_is_structural

echo "# all fm-owner-invoke-wait-check tests passed"
