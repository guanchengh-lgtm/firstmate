#!/usr/bin/env bash
# Behavioral coverage for the owner-invoke-wait refuse-hook.
# Exercises public CLI exit codes, exact-count regression, and reconstructed
# 2026-08-22 turns. Does not assert checker source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-owner-invoke-wait-check.sh"
FIXTURES="$ROOT/tests/fixtures/fm-owner-invoke-wait-check"
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
  out=$(run_check --input "$empty" --expect-rule R-held-locked-next --expect-count 0)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "expect-count 0 exited $rc"
  assert_contains "$out" "expect-count must be > 0" "zero count was not structural"
  set +e
  out=$(run_check --input "$FIXTURES/historical-ship-without-ov.json" --rules '')
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "empty --rules exited $rc"
  pass "owner-invoke-wait: missing and empty input, expect-count 0, empty rules exit 2"
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
  out=$(run_check --input "$turn" --rules R-skill-unloaded \
    --expect-rule R-skill-unloaded --expect-count 1)
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
    --input "$FIXTURES/historical-ship-without-ov.json" \
    --expect-rule R-held-locked-next --expect-count 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "unrelated held exact-count exited $rc: $out"
  assert_contains "$out" "regression:" "unrelated-rule miss was not a count mismatch"
  pass "owner-invoke-wait: unrelated rule fire is not exact-count success"
}

make_primary_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
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

test_scaled_rows_keep_verdict_and_cost_bounded() {
  local small scaled small_out scaled_out start small_ms scaled_ms rc home count brief
  small=$(make_primary_home "$TMP_ROOT/scale-small")
  scaled=$(make_primary_home "$TMP_ROOT/scale-large")
  for home in "$small" "$scaled"; do
    mkdir -p "$home/data/scale-ship" "$home/data/scale-review"
    printf '# Task\nscale ship\n' > "$home/data/scale-ship/brief.md"
    printf '%s\n' 'kind=ship' 'ov=scale-review' 'ov_harness=claude' \
      > "$home/state/scale-ship.meta"
    printf 'review complete\n' > "$home/data/scale-review/report.md"
  done
  printf '%s\n' plan-eng-review skill-one skill-two > "$small/data/scale-review/skills"
  count=1
  : > "$scaled/data/scale-review/skills"
  while [ "$count" -le 200 ]; do
    if [ "$count" -eq 1 ]; then
      printf '%s\n' plan-eng-review >> "$scaled/data/scale-review/skills"
    else
      printf 'skill-%s\n' "$count" >> "$scaled/data/scale-review/skills"
    fi
    count=$((count + 1))
  done

  brief="$small/data/scale-ship/brief.md"
  start=$(fm_test_monotonic_ms)
  set +e
  small_out=$(FM_HOME="$small" FM_ROOT_OVERRIDE="$small" \
    FM_STATE_OVERRIDE="$small/state" FM_DATA_OVERRIDE="$small/data" \
    "$CHECK" --brief "$brief" --rules R-skill-unloaded 2>&1)
  rc=$?
  set -e
  small_ms=$(($(fm_test_monotonic_ms) - start))
  [ "$rc" -eq 0 ] || fail "small scaled-fixture oracle exited $rc: $small_out"

  brief="$scaled/data/scale-ship/brief.md"
  start=$(fm_test_monotonic_ms)
  set +e
  scaled_out=$(FM_HOME="$scaled" FM_ROOT_OVERRIDE="$scaled" \
    FM_STATE_OVERRIDE="$scaled/state" FM_DATA_OVERRIDE="$scaled/data" \
    "$CHECK" --brief "$brief" --rules R-skill-unloaded 2>&1)
  rc=$?
  set -e
  scaled_ms=$(($(fm_test_monotonic_ms) - start))
  [ "$rc" -eq 0 ] || fail "large scaled-fixture oracle exited $rc: $scaled_out"
  [ "$small_out" = "$scaled_out" ] || fail "scaled row fixture changed owner-invoke verdict"
  fm_test_assert_scale_bound "$small_ms" "$scaled_ms" "owner-invoke-wait"
  pass "owner-invoke-wait: 200 skill rows preserve spawn-gate verdict with bounded scaling"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

test_missing_and_empty_input_are_structural
test_historical_ship_omission_fires_exact_count
test_held_locked_next_and_date_cleared
test_placeholder_and_stub_briefs_are_clean
test_builder_self_review_is_not_ov
test_distinct_ov_worker_is_clean
test_ov_report_and_skill_records
test_unrelated_rule_does_not_satisfy_exact_count
test_hook_does_not_rerefuse_inflight_ship_without_ov
test_skill_load_record_appends_normalized_token
test_crewmate_settings_carry_skill_recorder
test_brief_reads_ov_worker_report_and_skills
test_scaled_rows_keep_verdict_and_cost_bounded

echo "# all fm-owner-invoke-wait-check tests passed"
