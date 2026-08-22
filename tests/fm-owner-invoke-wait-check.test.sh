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
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":true,"ov_alive":false,"skills":["plan-eng-review"]}],
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
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":true,"ov_alive":false,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn" --expect-rule R-skill-unloaded --expect-count 1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "unloaded plan-eng-review exact-count exited $rc: $out"
  turn="$TMP_ROOT/skills-before-report.json"
  write_turn "$turn" '{
    "ships": [{"id":"spec-compile-check","ov":"spec-compile-check-ov","ov_report":false,"ov_alive":true,"skills":[]}],
    "owned_meta": []
  }'
  set +e
  out=$(run_check --input "$turn" --rules R-skill-unloaded)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "skills gate before report exited $rc: $out"
  [ -z "$out" ] || fail "skills gate before report printed findings: $out"
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
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'session=4242' \
    "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
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
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' > "$home/state/spec-compile-check.meta"
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
  printf '%s\n' 'kind=ship' 'ov=spec-compile-check-ov' 'session=6161' \
    "worktree=$ship_wt" > "$home/state/spec-compile-check.meta"
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

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_historical_yes_ask_fires_exact_count
test_historical_fog_pin_fires_exact_count
test_historical_ship_omission_fires_exact_count
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
test_skill_load_record_appends_normalized_token
test_brief_reads_ov_worker_report_and_skills

echo "# all fm-owner-invoke-wait-check tests passed"
