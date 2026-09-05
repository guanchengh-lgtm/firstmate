#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode, yolo posture, and launch role are firstmate's
# decision at intake, so the tools refuse to guess: the spawn and a scout
# promotion require the delivery flags, ship spawns also require --role, they
# validate against a closed set, and the spawn additionally refuses to launch
# when the file it is about to encode records a different mode or Role. Scout
# spawns carry no delivery posture at all. A scout promotion records
# role=builder and the builder sibling markers so a later ship respawn can pass
# --role from metadata; it does not parse brief prose. The registry keeps only
# the captain's standing posture, for the mechanical consumers and for one
# advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>] [<role>] [<surface>]
  local home=$1 id=$2 mode=${3:-} role surface=${5:-}
  if [ "$#" -ge 4 ]; then
    role=$4
  elif [ -n "$mode" ]; then
    role=builder
  else
    role=
  fi
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
    [ -z "$role" ] || printf 'Role: %s\n' "$role"
  } > "$home/data/$id/brief.md"
  # Machine-owned markers are the launch gate; brief prose is human-facing only.
  if [ -n "$mode" ]; then
    printf '%s\n' "$mode" > "$home/data/$id/mode"
  else
    rm -f "$home/data/$id/mode"
  fi
  if [ -n "$role" ]; then
    printf '%s\n' "$role" > "$home/data/$id/role"
  else
    rm -f "$home/data/$id/role"
  fi
  if [ -n "$surface" ]; then
    printf '%s\n' "$surface" > "$home/data/$id/surface"
  else
    rm -f "$home/data/$id/surface"
  fi
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown surface|--mode no-mistakes --yolo off --role builder --surface nope|must be one of internal-only, product, mixed, uncertain
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
missing --role|--mode no-mistakes --yolo off|ship spawns require --role
unknown role|--mode no-mistakes --yolo off --role maybe|must be builder or verifier
verifier on direct-PR|--mode direct-PR --yolo off --role verifier --surface internal-only|--role verifier is legal only with --mode no-mistakes
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode, yolo, and role before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --surface internal-only)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --surface should exit non-zero"
  assert_contains "$out" "--surface applies only to ship spawns" "scout spawn did not refuse --surface"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off --role builder)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-surface-a3 "$home" --secondmate --surface=internal-only)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying --surface should exit non-zero"
  assert_contains "$out" "--surface applies only to ship spawns" "secondmate spawn did not refuse --surface"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --role builder)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --role should exit non-zero"
  assert_contains "$out" "--role applies only to ship spawns" "scout spawn did not refuse --role"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-role-a4 "$home" --secondmate --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying --role should exit non-zero"
  assert_contains "$out" "--role applies only to ship spawns" "secondmate spawn did not refuse --role"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off --role builder --surface internal-only)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the task mode marker says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR builder internal-only
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off --role builder --surface internal-only)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the mode marker existed warns once and continues.
  write_brief "$home" delivery-legacy-b3 "" builder
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off --role builder)
  assert_contains "$out" "records no delivery mode" "a legacy brief did not warn about its missing mode marker"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# --role is the launch gate: missing flag, missing role marker, missing verifier
# file, and role mismatch all refuse before metadata. A verifier spawn must not
# encode brief.md. Brief prose never satisfies or poisons the machine markers.
test_spawn_role_gate_selects_the_role_file() {
  local rec home proj fakebin out status
  rec=$(make_home role-gate)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  write_brief "$home" role-missing-line-c1 no-mistakes ""
  out=$(run_spawn "$home" "$fakebin" role-missing-line-c1 "$proj" claude --mode no-mistakes --yolo off --role builder)
  status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn with no role marker should exit non-zero"
  assert_contains "$out" "records no role" "missing role marker did not refuse"
  assert_absent "$home/state/role-missing-line-c1.meta" "missing role marker spawn wrote task metadata"

  write_brief "$home" role-builder-only-c2 no-mistakes
  out=$(run_spawn "$home" "$fakebin" role-builder-only-c2 "$proj" claude --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "--role verifier against builder-only brief.md should exit non-zero"
  assert_contains "$out" "no verifier brief at" "verifier spawn did not name the missing verifier-brief.md"
  assert_contains "$out" "verifier-brief.md" "verifier spawn did not select verifier-brief.md"
  assert_not_contains "$out" "encode the builder brief" "missing verifier file was reported as a builder-encode"
  assert_absent "$home/state/role-builder-only-c2.meta" "verifier spawn against builder-only brief wrote task metadata"

  write_brief "$home" role-mismatch-c3 no-mistakes
  mkdir -p "$home/data/role-mismatch-c3"
  printf 'Role: builder\nDelivery contract: mode=no-mistakes\n' > "$home/data/role-mismatch-c3/verifier-brief.md"
  printf '%s\n' builder > "$home/data/role-mismatch-c3/verifier-role"
  out=$(run_spawn "$home" "$fakebin" role-mismatch-c3 "$proj" claude --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "role marker mismatch on verifier-role should exit non-zero"
  assert_contains "$out" "role mismatch for role-mismatch-c3" "role mismatch refusal did not name the task"
  assert_contains "$out" "the task role marker says builder but this spawn passed --role verifier" \
    "role mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/role-mismatch-c3.meta" "mismatched role spawn wrote task metadata"

  write_brief "$home" role-agree-c4 no-mistakes
  out=$(run_spawn "$home" "$fakebin" role-agree-c4 "$proj" claude --mode no-mistakes --yolo off --role builder)
  assert_not_contains "$out" "role mismatch" "an agreeing builder role was reported as a mismatch"
  assert_not_contains "$out" "no verifier brief" "a builder spawn looked for verifier-brief.md"

  # Task-body Role:/Delivery contract: prose must not poison agreeing machine markers.
  mkdir -p "$home/data/role-task-body-c5"
  cat > "$home/data/role-task-body-c5/brief.md" <<'EOF'
You are a crewmate.

# Task
Acceptance includes a line Role: admin for the RBAC matrix.
Also document Role: builder in the ACL table.
Delivery contract: mode=direct-PR is the wrong posture here.

# Definition of done
Delivery contract: mode=no-mistakes
Role: builder
EOF
  printf '%s\n' builder > "$home/data/role-task-body-c5/role"
  printf '%s\n' no-mistakes > "$home/data/role-task-body-c5/mode"
  out=$(run_spawn "$home" "$fakebin" role-task-body-c5 "$proj" claude --mode no-mistakes --yolo off --role builder)
  assert_not_contains "$out" "role mismatch" "task-body Role: text poisoned an agreeing role marker"
  assert_not_contains "$out" "delivery mismatch" "task-body Delivery contract: text poisoned an agreeing mode marker"
  assert_not_contains "$out" "records no role" "task-body Role: hid the role marker"

  # Brief prose alone never satisfies the role gate without the machine marker.
  mkdir -p "$home/data/role-task-only-c6"
  cat > "$home/data/role-task-only-c6/brief.md" <<'EOF'
You are a crewmate.

# Task
Role: builder

# Definition of done
Delivery contract: mode=no-mistakes
Role: builder
EOF
  printf '%s\n' no-mistakes > "$home/data/role-task-only-c6/mode"
  rm -f "$home/data/role-task-only-c6/role"
  out=$(run_spawn "$home" "$fakebin" role-task-only-c6 "$proj" claude --mode no-mistakes --yolo off --role builder)
  status=$?
  [ "$status" -ne 0 ] || fail "brief prose Role: lines must not satisfy the role gate without a role marker"
  assert_contains "$out" "records no role" "brief prose Role: builder was accepted without a role marker"
  assert_absent "$home/state/role-task-only-c6.meta" "prose-only Role: spawn wrote task metadata"

  # Recovery-style progress append after the scaffold DoD must not overwrite markers.
  mkdir -p "$home/data/role-progress-append-c7"
  cat > "$home/data/role-progress-append-c7/brief.md" <<'EOF'
You are a crewmate.

# Task
Body text about the feature.

# Definition of done
Delivery contract: mode=no-mistakes
Role: builder
Implement the feature and stop.

## Progress so far
Delivery contract: mode=direct-PR looked worse after investigation.
Role: verifier
EOF
  printf '%s\n' builder > "$home/data/role-progress-append-c7/role"
  printf '%s\n' no-mistakes > "$home/data/role-progress-append-c7/mode"
  out=$(run_spawn "$home" "$fakebin" role-progress-append-c7 "$proj" claude --mode no-mistakes --yolo off --role builder)
  assert_not_contains "$out" "role mismatch" \
    "progress-append Role: verifier poisoned the machine role marker"
  assert_not_contains "$out" "delivery mismatch" \
    "progress-append Delivery contract: mode=direct-PR poisoned the machine mode marker"
  assert_not_contains "$out" "records no role" \
    "progress-append hid the machine role marker"

  pass "fm-spawn: --role selects the role file and refuses a missing or mismatched role marker"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0 extra surface
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    extra=()
    surface=
    if [ "$mode" = direct-PR ]; then
      extra=(--surface internal-only)
      surface=internal-only
    fi
    write_brief "$home" "delivery-dev-$n" "$mode" builder "$surface"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude \
      --mode "$mode" --yolo off --role builder ${extra[@]+"${extra[@]}"})
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

test_promote_help_owns_the_workflow_without_runtime_state() {
  local isolated home out status
  isolated="$TMP_ROOT/promote-help"
  home="$TMP_ROOT/promote-help-home"
  mkdir -p "$isolated/bin"
  cp "$PROMOTE" "$isolated/bin/fm-promote.sh"

  out=$(FM_ROOT_OVERRIDE="$isolated" FM_HOME="$home" \
    "$isolated/bin/fm-promote.sh" --help 2>&1)
  status=$?
  expect_code 0 "$status" "promotion help should work without runtime dependencies"
  assert_contains "$out" "existing scout in place" \
    "promotion help did not preserve the no-duplicate-task workflow"
  assert_contains "$out" "Inventory its scratch state" \
    "promotion help did not require the scratch-state inventory"
  assert_contains "$out" "clean default-branch base" \
    "promotion help did not require a clean base"
  assert_contains "$out" "carry over only intended fix changes" \
    "promotion help did not bound carried changes"
  assert_contains "$out" "leave scratch commits and debug edits behind" \
    "promotion help did not exclude scratch work"
  assert_contains "$out" "reproduced bug into the regression test" \
    "promotion help did not preserve regression-test guidance"
  [ ! -e "$home" ] || fail "promotion help created runtime state"
  pass "fm-promote: help owns the promotion workflow without runtime state"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record, including
# role=builder and the builder sibling markers a later ship respawn will read.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"
  assert_absent "$home/data/promote-d1/role" "refused promotion wrote a role marker"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing approval posture"
  assert_absent "$home/data/promote-d1/role" "yolo-less promotion wrote a role marker"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"
  assert_absent "$home/data/promote-d1/role" "refused policy promotion wrote a role marker"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on --surface internal-only 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'surface=internal-only' "$meta" "promotion did not record the classified surface"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided approval posture"
  assert_grep 'role=builder' "$meta" "promotion did not record role=builder for a later ship respawn"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  assert_contains "$out" "role=builder" "promotion hint did not name the recorded builder role"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  [ "$(grep -c '^surface=' "$meta")" = 1 ] || fail "promotion left more than one surface= line in the task record"
  [ "$(grep -c '^role=' "$meta")" = 1 ] || fail "promotion left more than one role= line in the task record"
  grep -qx builder "$home/data/promote-d1/role" \
    || fail "promotion did not write the builder role marker"
  grep -qx 'direct-PR' "$home/data/promote-d1/mode" \
    || fail "promotion did not write the matching mode marker"
  grep -qx 'internal-only' "$home/data/promote-d1/surface" \
    || fail "promotion did not write the matching surface marker"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

# Brief prose is not a role source: a scout brief that mentions Role: verifier
# still promotes to builder, and a later ship spawn can pass that recorded role.
test_promote_records_builder_from_the_role_marker_not_brief_prose() {
  local rec home proj fakebin meta out status
  rec=$(make_home promote-role)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  meta="$home/state/promote-role-c1.meta"
  mkdir -p "$home/data/promote-role-c1" "$home/state"
  printf 'window=fm-promote-role-c1\nkind=scout\nworktree=/tmp/wt\nrole=verifier\n' > "$meta"
  cat > "$home/data/promote-role-c1/brief.md" <<'EOF'
You are a crewmate.

# Task
Role: verifier
Delivery contract: mode=no-mistakes
Accept a Role: verifier line in the task body without treating it as the launch role.

# Definition of done
The deliverable is a report.
EOF
  rm -f "$home/data/promote-role-c1/role" "$home/data/promote-role-c1/mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" promote-role-c1 --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion with Role: verifier in the scout brief should succeed"
  assert_grep 'role=builder' "$meta" "promotion trusted leftover meta role= or brief prose instead of recording builder"
  assert_no_grep 'role=verifier' "$meta" "promotion kept a leftover role=verifier line"
  grep -qx builder "$home/data/promote-role-c1/role" \
    || fail "promotion did not overwrite toward the builder role marker"
  grep -qx 'no-mistakes' "$home/data/promote-role-c1/mode" \
    || fail "promotion did not write the no-mistakes mode marker"

  out=$(run_spawn "$home" "$fakebin" promote-role-c1 "$proj" claude \
    --mode no-mistakes --yolo off --role builder)
  assert_not_contains "$out" "records no role" \
    "ship respawn after promote refused a missing role marker"
  assert_not_contains "$out" "role mismatch" \
    "ship respawn after promote treated brief prose as the role marker"

  printf 'Role: verifier\n' > "$home/data/promote-role-c1/verifier-brief.md"
  out=$(run_spawn "$home" "$fakebin" promote-role-c1 "$proj" claude \
    --mode no-mistakes --yolo off --role verifier)
  status=$?
  [ "$status" -ne 0 ] || fail "verifier respawn after promote should exit non-zero"
  assert_contains "$out" "records no role" \
    "promote wrote a verifier-role marker or let --role verifier use the builder marker"
  assert_grep 'role=builder' "$meta" "a refused verifier respawn changed the promoted role record"
  pass "fm-promote: records builder via the role marker and ignores brief prose"
}

test_promote_refuses_a_symlinked_task_record() {
  local home meta target original out status leftover
  home="$TMP_ROOT/promote-symlink/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-sym.meta"
  target="$TMP_ROOT/promote-symlink/foreign-task-record"
  original="$TMP_ROOT/promote-symlink/foreign-task-record.expected"
  printf '%s\n' 'window=fm-promote-sym' 'kind=scout' 'worktree=/tmp/wt' > "$target"
  cp "$target" "$original"
  ln -s "$target" "$meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-sym --mode direct-PR --yolo on --surface internal-only 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion through a symlink record should refuse"
  assert_contains "$out" "task record" "promotion did not identify the unpublished task record"
  [ -L "$meta" ] || fail "promotion replaced or removed the symlink record"
  cmp -s "$target" "$original" \
    || fail "promotion rewrote the symlink target in place"
  assert_absent "$home/data/promote-sym/ship-instructions.md" \
    "refused promotion published ship instructions"
  leftover=$(find "$home/state" -maxdepth 1 -name '.*.meta.promote.*' -print 2>/dev/null || true)
  [ -z "$leftover" ] || fail "promotion left a staging file after a refused publish: $leftover"
  pass "fm-promote: a symlinked task record is refused and its target is left untouched"
}

test_promotion_delivers_the_real_definition_of_done() {
  local home meta out sendroot payload mode id brief_dod delivered_dod extra
  home="$TMP_ROOT/promote-dod/home"
  sendroot="$TMP_ROOT/promote-dod/sendroot"
  mkdir -p "$home/state" "$sendroot/bin"
  cat > "$sendroot/bin/fm-send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$2" > "$FM_TEST_CAPTURE"
STUB
  chmod +x "$sendroot/bin/fm-send.sh"

  for mode in no-mistakes direct-PR local-only; do
    extra=()
    if [ "$mode" = direct-PR ]; then
      extra=(--surface internal-only)
    fi
    id="promote-dod-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    meta="$home/state/$id.meta"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PROMOTE" "$id" --mode "$mode" --yolo off ${extra[@]+"${extra[@]}"} 2>&1) \
      || fail "$mode: promotion should succeed"

    payload="$TMP_ROOT/promote-dod/payload-$id"
    ( cd "$sendroot" \
      && FM_TEST_CAPTURE="$payload" \
         eval "$(printf '%s\n' "$out" | sed -n 's/^next: //p' | grep 'fm-send\.sh')" ) \
      || fail "$mode: promotion's delivery command did not run"
    assert_present "$payload" "$mode: promotion delivered no message to the worker"

    grep -qx "Delivery contract: mode=$mode" "$payload" \
      || fail "$mode: promoted worker did not receive the machine-readable delivery contract"
    assert_grep "# Definition of done" "$payload" \
      "$mode: promoted worker did not receive a Definition of done"
    assert_grep "pwd -P" "$payload" \
      "$mode: promoted worker was not told to verify its physical worktree"
    assert_grep "git rev-parse --show-toplevel" "$payload" \
      "$mode: promoted worker was not told to verify its repository root"
    assert_grep "If either does not resolve to the worktree you were launched in, stop and escalate to firstmate" "$payload" \
      "$mode: promoted worker was not told to stop for any wrong worktree"
    assert_grep "git checkout -b fm/$id" "$payload" \
      "$mode: promoted worker was not told to leave the scratch base for its ship branch"

    FM_HOME="$home" "$BRIEF" "$id" fixture-project --mode "$mode" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1 \
      || fail "$mode: ordinary ship brief generation should succeed"
    brief_dod="$TMP_ROOT/promote-dod/brief-dod-$id"
    delivered_dod="$TMP_ROOT/promote-dod/delivered-dod-$id"
    awk '/^# Definition of done$/ { emit=1 } emit' "$home/data/$id/brief.md" > "$brief_dod"
    awk '/^# Definition of done$/ { emit=1 } emit' "$payload" > "$delivered_dod"
    cmp -s "$brief_dod" "$delivered_dod" \
      || fail "$mode: promotion and ordinary brief generation delivered different Definitions of done"
  done

  payload="$TMP_ROOT/promote-dod/payload-promote-dod-no-mistakes"
  assert_grep "ask-user findings are never the verifier's to answer: escalate to firstmate" "$payload" \
    "promoted no-mistakes worker did not receive the ask-user escalation rule"
  assert_grep "NEVER pass \`--yes\` (or \`-y\`)" "$payload" \
    "promoted no-mistakes worker did not receive the --yes prohibition"
  assert_grep "It is banned fleet-wide" "$payload" \
    "promoted no-mistakes worker did not receive the fleet-wide ban wording"

  payload="$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr"
  assert_grep "supersede the scout delivery rules and report-based Definition of done" "$payload" \
    "promoted worker retained the scout delivery contract"
  assert_grep "status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule" "$payload" \
    "promoted worker lost the scout protocols and safety rules that still apply"

  assert_grep "Do NOT run /no-mistakes" "$payload" \
    "promoted direct-PR worker lost its no-pipeline contract"
  assert_grep "Do NOT push, do NOT open a PR, do NOT merge" "$TMP_ROOT/promote-dod/payload-promote-dod-local-only" \
    "promoted local-only worker lost its no-remote contract"
  assert_no_grep "no-mistakes axi respond" "$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr" \
    "promoted direct-PR worker received the pipeline gate contract"
  pass "fm-promote: a promoted worker receives the same mode-specific delivery contract a briefed one does"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err rec proj fakebin
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"

  out=$(FM_HOME="$home" "$PROJECT_MODE" never-registered 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "an unregistered project did not stay no-mistakes off (got '$out')"
  rec=$(make_home absent-reg)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  rm -f "$home/data/projects.md"
  out=$(FM_HOME="$home" "$PROJECT_MODE" anyproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "an absent registry did not stay no-mistakes off (got '$out')"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_direct_pr_requires_internal_only_surface() {
  local rec home proj fakebin out status
  rec=$(make_home surface-gate)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  write_brief "$home" surf-product-s1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" surf-product-s1 "$proj" claude --mode direct-PR --yolo off --role builder --surface product)
  status=$?
  [ "$status" -ne 0 ] || fail "product + direct-PR spawn should exit non-zero"
  assert_contains "$out" "refused for product work" "product + direct-PR spawn did not name the refused surface"
  assert_absent "$home/state/surf-product-s1.meta" "product + direct-PR spawn wrote task metadata"

  write_brief "$home" surf-mixed-s2 no-mistakes
  out=$(run_spawn "$home" "$fakebin" surf-mixed-s2 "$proj" claude --mode direct-PR --yolo off --role builder --surface=mixed)
  status=$?
  [ "$status" -ne 0 ] || fail "mixed + direct-PR spawn should exit non-zero"
  assert_contains "$out" "refused for mixed work" "mixed + direct-PR spawn did not name the refused surface"

  write_brief "$home" surf-uncertain-s3 no-mistakes
  out=$(run_spawn "$home" "$fakebin" surf-uncertain-s3 "$proj" claude --mode direct-PR --yolo off --role builder --surface uncertain)
  status=$?
  [ "$status" -ne 0 ] || fail "uncertain + direct-PR spawn should exit non-zero"
  assert_contains "$out" "refused for uncertain work" "uncertain + direct-PR spawn did not name the refused surface"

  write_brief "$home" surf-omitted-s4 no-mistakes
  out=$(run_spawn "$home" "$fakebin" surf-omitted-s4 "$proj" claude --mode direct-PR --yolo off --role builder)
  status=$?
  [ "$status" -ne 0 ] || fail "direct-PR spawn without --surface should exit non-zero"
  assert_contains "$out" "requires --surface internal-only" "omitted surface spawn did not fail closed"
  assert_absent "$home/state/surf-omitted-s4.meta" "direct-PR spawn without --surface wrote task metadata"

  write_brief "$home" surf-internal-s5 direct-PR builder internal-only
  out=$(run_spawn "$home" "$fakebin" surf-internal-s5 "$proj" claude --mode direct-PR --yolo off --role builder --surface internal-only)
  assert_not_contains "$out" "refused for" "internal-only + direct-PR was refused"
  assert_not_contains "$out" "requires --surface internal-only" "internal-only + direct-PR was treated as omitted"

  write_brief "$home" surf-nm-product-s6 no-mistakes builder product
  out=$(run_spawn "$home" "$fakebin" surf-nm-product-s6 "$proj" claude --mode no-mistakes --yolo off --role builder --surface product)
  assert_not_contains "$out" "refused for" "product + no-mistakes spawn was refused"
  assert_not_contains "$out" "requires --surface" "product + no-mistakes required a surface it already had"

  write_brief "$home" surf-marker-missing-s7 direct-PR
  out=$(run_spawn "$home" "$fakebin" surf-marker-missing-s7 "$proj" claude --mode direct-PR --yolo off --role builder --surface internal-only)
  status=$?
  [ "$status" -ne 0 ] || fail "direct-PR spawn without a surface marker should exit non-zero"
  assert_contains "$out" "requires exactly one regular surface marker" \
    "direct-PR spawn did not refuse its missing surface marker"

  write_brief "$home" surf-marker-mismatch-s8 direct-PR builder product
  out=$(run_spawn "$home" "$fakebin" surf-marker-mismatch-s8 "$proj" claude --mode direct-PR --yolo off --role builder --surface internal-only)
  status=$?
  [ "$status" -ne 0 ] || fail "direct-PR spawn with a mismatched surface marker should exit non-zero"
  assert_contains "$out" "surface marker says surface=product" \
    "direct-PR spawn did not refuse its mismatched surface marker"

  write_brief "$home" surf-marker-duplicate-s9 direct-PR builder internal-only
  printf 'internal-only\n' >> "$home/data/surf-marker-duplicate-s9/surface"
  out=$(run_spawn "$home" "$fakebin" surf-marker-duplicate-s9 "$proj" claude --mode direct-PR --yolo off --role builder --surface internal-only)
  status=$?
  [ "$status" -ne 0 ] || fail "direct-PR spawn with duplicate surface classifications should exit non-zero"
  assert_contains "$out" "contains 2 classifications" \
    "direct-PR spawn did not refuse its duplicate surface classifications"

  write_brief "$home" surf-marker-unrecorded-s10 no-mistakes builder product
  out=$(run_spawn "$home" "$fakebin" surf-marker-unrecorded-s10 "$proj" claude --mode no-mistakes --yolo off --role builder)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn omitting a recorded surface should exit non-zero"
  assert_contains "$out" "exists but the spawn request records no surface" \
    "spawn did not refuse an omitted recorded surface"

  write_surface_scout_meta() {
    local id=$1
    mkdir -p "$home/state" "$home/data/$id"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
    rm -f "$home/data/$id/mode" "$home/data/$id/role" "$home/data/$id/surface"
  }

  write_surface_scout_meta surf-promote-product-p1
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-product-p1 \
    --mode direct-PR --yolo off --surface product 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "product + direct-PR promotion should exit non-zero"
  assert_contains "$out" "refused for product work" "product + direct-PR promote did not name the refused surface"
  assert_grep 'kind=scout' "$home/state/surf-promote-product-p1.meta" \
    "refused product promotion still changed the task record"

  write_surface_scout_meta surf-promote-omitted-p2
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-omitted-p2 \
    --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct-PR promotion without --surface should exit non-zero"
  assert_contains "$out" "requires --surface internal-only" "omitted surface promote did not fail closed"

  write_surface_scout_meta surf-promote-mixed-p3
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-mixed-p3 \
    --mode direct-PR --yolo off --surface mixed 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mixed + direct-PR promotion should exit non-zero"
  assert_contains "$out" "refused for mixed work" "mixed + direct-PR promote did not name the refused surface"

  write_surface_scout_meta surf-promote-uncertain-p4
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-uncertain-p4 \
    --mode direct-PR --yolo off --surface=uncertain 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "uncertain + direct-PR promotion should exit non-zero"
  assert_contains "$out" "refused for uncertain work" \
    "uncertain + direct-PR promote did not name the refused surface"

  write_surface_scout_meta surf-promote-invalid-p5
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-invalid-p5 \
    --mode no-mistakes --yolo off --surface=invalid 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "invalid promotion surface should exit non-zero"
  assert_contains "$out" "must be one of internal-only, product, mixed, uncertain" \
    "invalid promotion surface did not fail closed"

  write_surface_scout_meta surf-promote-internal-p6
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-internal-p6 \
    --mode direct-PR --yolo off --surface=internal-only 2>&1)
  status=$?
  expect_code 0 "$status" "internal-only + direct-PR promotion should succeed"
  assert_grep 'surface=internal-only' "$home/state/surf-promote-internal-p6.meta" \
    "internal-only + direct-PR promotion did not record its surface"
  assert_grep 'internal-only' "$home/data/surf-promote-internal-p6/surface" \
    "internal-only + direct-PR promotion did not write its surface marker"

  write_surface_scout_meta surf-promote-local-p7
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-local-p7 \
    --mode local-only --yolo off --surface product 2>&1)
  status=$?
  expect_code 0 "$status" "product + local-only promotion should succeed"
  assert_grep 'mode=local-only' "$home/state/surf-promote-local-p7.meta" \
    "product + local-only promotion did not record its mode"
  assert_grep 'surface=product' "$home/state/surf-promote-local-p7.meta" \
    "product + local-only promotion did not record its surface"
  assert_grep 'product' "$home/data/surf-promote-local-p7/surface" \
    "product + local-only promotion did not write its surface marker"

  write_surface_scout_meta surf-promote-nm-p8
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" surf-promote-nm-p8 \
    --mode no-mistakes --yolo off --surface product 2>&1)
  status=$?
  expect_code 0 "$status" "product + no-mistakes promotion should succeed"
  assert_grep 'kind=ship' "$home/state/surf-promote-nm-p8.meta" \
    "product + no-mistakes promotion did not flip the task to ship"

  pass "fm-spawn/fm-promote: surface matrices enforce direct-PR and preserve allowed classifications"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_role_gate_selects_the_role_file
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_help_owns_the_workflow_without_runtime_state
test_promote_requires_and_records_the_delivery_contract
test_promote_records_builder_from_the_role_marker_not_brief_prose
test_promote_refuses_a_symlinked_task_record
test_promotion_delivers_the_real_definition_of_done
test_project_mode_maps_the_conditional_policy
test_direct_pr_requires_internal_only_surface
echo "# all fm-task-delivery tests passed"
