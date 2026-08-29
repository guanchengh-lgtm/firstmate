#!/usr/bin/env bash
# Refuse ending a turn or starting a ship when this seat already owns the
# next act and does not start it.
#
# Usage: fm-owner-invoke-wait-check.sh --input <turn.json>
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#        fm-owner-invoke-wait-check.sh --brief <ship-brief.md> [--ov <task-id>]
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#        fm-owner-invoke-wait-check.sh [--claude] [--pretool]
#
# --ov supplies the pre-publication OV record for a production ship spawn.
# Without it, --brief reads ov= and durable ov_harness= from state/<ship>.meta.
# --input and --brief are required in CLI modes. A missing or empty file,
# claims that are not a JSON object, unknown rule ids, empty --rules, and
# --expect-count 0 are structural failures, exit 2. Findings exit 1. Clean
# exit 0.
# Hook/payload mode (no --input/--brief) reads the turn-end or PreToolUse
# payload on stdin. Empty stdin is inert exit 0 so a missing hook payload
# cannot wedge the session. Findings in hook mode print a refusal banner
# and exit 2. PreToolUse has no remaining owner-invoke rule and is inert.
#
# Default --input / payload rules:
#   R-held-locked-next      a held ticket is a map_next target or its until
#                           date has passed, and it has no worker meta
#   R-ov-missing            spawn --input with task: no distinct OV worker;
#                           hook/stored-brief ladder: review worker gone with
#                           no data/<ov>/report.md (live worker without report
#                           is in-progress and passes); --brief --ov requires
#                           the report before spawn
#   R-owner-node-open       a harness <command-name> token from the header
#                           node table opened a node, a later real captain
#                           turn arrived, and no ordinary file matching any
#                           of that token's artifact_glob rows has mtime at
#                           or after the trigger. Does not refuse on the
#                           trigger turn. Does not hunt free English. Does
#                           not warn without blocking. --input reads
#                           turn.owner_nodes.
# Default --brief rules: R-ov-missing,R-skill-unloaded on durable OV records
# (state/<ship>.meta ov=/ov_harness=, data/<ov>/report.md, data/<ov>/skills,
# live endpoint). Explicit --ov requires a completed report. No brief-body parse.
#
# Owner-invoke node rows (header-owned; not a skill picker; not a home file).
# Each row is token<TAB>artifact_glob relative to FM_HOME or FM_ROOT, with
# no .. and no absolute path:
#   recurring-defect	docs/verification/**/*claims.json
#   grill-with-docs	data/decisions/*.md
#   wayfinder	data/**/map.md
#   vision	VISION.md
# Duplicate tokens OR-merge: any matching glob clears the node. ** in a glob
# is recursive. FM_OWNER_INVOKE_NODES_REGISTRY overrides this table for tests
# only. The header table fires with no home file. A present malformed
# override is structural. The trigger is a non-meta user record containing
# <command-name>/token</command-name> or <command-name>token</command-name>.
# The transcript record is the arm; this helper does not write a second
# state file. A later captain turn is is_captain_turn after that record.
# Same-turn Stop is clean. Blocking, not advisory. Artifact credit needs
# trigger timestamp or state/.lock mtime; without either, leftover files
# do not clear the node.
# plan-eng-review requires a separate OV worker. The builder's own plan note
# is not OV. Split transcript windows stay as gather holes.
#
# Production gather (hook mode, non-PreToolUse): every state/*.meta with
# kind=ship whose session= equals the current state/.lock contents (ships
# this session started). Prior-session ships fall out when a new lock pid is
# written. No second session-ships list. Does not match cwd to worktree=.
# For each gathered ship with ov=<ov>, Stop ladder in this order:
#   a. data/<ov>/report.md non-empty -> PASS. No liveness or skill check in
#      this branch.
#   b. else if <ov>.meta exists and its agent is alive -> PASS
#      (review in progress; never refuse merely for a missing report)
#   c. else refuse: review worker gone with no report
# Alive means the harness agent, not bare pane presence: agent_alive=alive
# passes; dead|missing fails; only unknown (zellij/orca/unreadable) falls
# back to target_exists so unverified backends do not wedge. A shell husk
# after the agent exits is not in-progress.
# A gathered ship with no ov= passes at turn-end; spawn-time R-ov-missing is
# the empty-ov start gate. Spawn-time brief evaluation requires the OV report
# and retains R-skill-unloaded. fm-spawn.sh writes session= and ov_harness=
# (from the OV worker's harness= at ship spawn) and exports FM_TASK_ID/FM_HOME; Claude
# PostToolUse Skill (crewmate settings.local.json absolute $FM_ROOT path, plus
# tracked settings.json) runs bin/fm-skill-load-record.sh to append normalized
# loads (strip gstack-, lowercase) into data/<id>/skills. Matcher is exact
# element plan-eng-review.
#
# Exact-count regression requires both --expect-rule and --expect-count and
# exits 0 only when that rule count and the total finding count both equal
# the expected count. There is no "the fixture must fail" inversion.
#
# LIMITS: Split transcripts can hide a load. A real captain hold is
# invisible.
# Empty or {TASK} task fields skip ship rules (spawn-harness stubs).
# Builder self-review is not OV. In-flight ships already started without ov=
# are not re-refused at turn end. A non-Claude review worker (grok, codex,
# pi, kimi, opencode, muse) fires no PostToolUse hook, so its skills record
# is never written; brief or explicit R-skill-unloaded evaluation runs only
# when durable ov_harness is claude or claude*, and skips for any other harness
# or a missing/unreadable ov_harness on older records - a disclosed gap, not a
# refusal.
# R-owner-node-open sees only harness command-name records, not slash text
# and not Skill tool loads. Non-Claude primaries emit no command-name
# record (disclosed gap). Assistant or isMeta text that quotes the tag does
# not arm a node. A glob that matches any this-trigger-or-later file,
# including an unrelated data/decisions/*.md, can clear grill-with-docs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

input=
brief=
brief_ov_arg=
brief_ov_arg_set=0
expect_rule=
expect_count=
rules=
rules_set=0
CLAUDE_MODE=0
PRETOOL_MODE=0
HOOK_MODE=0

INPUT_RULES='R-held-locked-next,R-ov-missing,R-owner-node-open'
BRIEF_RULES='R-ov-missing,R-skill-unloaded'
KNOWN_RULES='R-held-locked-next R-ov-missing R-skill-unloaded R-owner-node-open'
# Header-owned default node table. Home file is not consulted.
# FM_OWNER_INVOKE_NODES_REGISTRY is a test override only.
DEFAULT_OWNER_INVOKE_NODES=$'recurring-defect\tdocs/verification/**/*claims.json\ngrill-with-docs\tdata/decisions/*.md\nwayfinder\tdata/**/map.md\nvision\tVISION.md'

usage() {
  sed -n '2,106p' "$0" | sed 's/^# \{0,1\}//'
}

structural() {
  printf 'structural: %s\n' "$*" >&2
  exit 2
}

is_known_rule() {
  local want=$1 r
  for r in $KNOWN_RULES; do
    [ "$r" = "$want" ] && return 0
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      [ "$#" -ge 2 ] || structural "--input requires a path"
      input=$2
      shift 2
      ;;
    --brief)
      [ "$#" -ge 2 ] || structural "--brief requires a path"
      brief=$2
      shift 2
      ;;
    --ov)
      [ "$#" -ge 2 ] || structural "--ov requires a task id"
      brief_ov_arg=$2
      brief_ov_arg_set=1
      shift 2
      ;;
    --expect-rule)
      [ "$#" -ge 2 ] || structural "--expect-rule requires a rule id"
      expect_rule=$2
      shift 2
      ;;
    --expect-count)
      [ "$#" -ge 2 ] || structural "--expect-count requires a count"
      expect_count=$2
      shift 2
      ;;
    --rules)
      [ "$#" -ge 2 ] || structural "--rules requires a value"
      rules=$2
      rules_set=1
      shift 2
      ;;
    --claude) CLAUDE_MODE=1; shift ;;
    --pretool) PRETOOL_MODE=1; shift ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      structural "unknown argument: $1"
      ;;
  esac
done

if [ -n "$input" ] && [ -n "$brief" ]; then
  structural "--input and --brief cannot be combined"
fi

if [ "$brief_ov_arg_set" -eq 1 ]; then
  [ -n "$brief" ] || structural "--ov requires --brief"
  [ -n "$brief_ov_arg" ] || structural "--ov requires a non-empty task id"
fi

if [ -z "$input" ] && [ -z "$brief" ]; then
  HOOK_MODE=1
fi

if [ "$rules_set" -eq 0 ]; then
  if [ -n "$brief" ]; then
    rules=$BRIEF_RULES
  else
    rules=$INPUT_RULES
  fi
fi

command -v jq >/dev/null 2>&1 || {
  if [ "$HOOK_MODE" -eq 1 ]; then
    exit 0
  fi
  structural "jq not found"
}

[ -n "$rules" ] || structural "empty --rules"
selected=()
IFS=',' read -r -a selected <<< "$rules" || true
cleaned=()
for r in "${selected[@]+"${selected[@]}"}"; do
  r=${r#"${r%%[![:space:]]*}"}
  r=${r%"${r##*[![:space:]]}"}
  [ -n "$r" ] || continue
  is_known_rule "$r" || structural "unknown rule id: $r"
  cleaned+=("$r")
done
[ "${#cleaned[@]}" -gt 0 ] || structural "empty --rules"
selected=("${cleaned[@]}")

if [ -n "$expect_rule" ] || [ -n "$expect_count" ]; then
  [ -n "$expect_rule" ] && [ -n "$expect_count" ] \
    || structural "regression mode needs both --expect-rule and --expect-count"
  case "$expect_count" in
    ''|*[!0-9]*|0) structural "expect-count must be > 0" ;;
  esac
  is_known_rule "$expect_rule" || structural "unknown expect-rule $expect_rule"
  found_selected=0
  for r in "${selected[@]+"${selected[@]}"}"; do
    if [ "$r" = "$expect_rule" ]; then
      found_selected=1
      break
    fi
  done
  [ "$found_selected" -eq 1 ] \
    || structural "--expect-rule $expect_rule is not in the selected rule set"
fi

run_held=0
run_ov=0
run_skill=0
run_node=0
for r in "${selected[@]+"${selected[@]}"}"; do
  case "$r" in
    R-held-locked-next) run_held=1 ;;
    R-ov-missing) run_ov=1 ;;
    R-skill-unloaded) run_skill=1 ;;
    R-owner-node-open) run_node=1 ;;
  esac
done

today=$(date +%F)

read_skill_lines() {  # <path> -> JSON array
  local path=$1 json='[]' line
  [ -f "$path" ] && [ ! -L "$path" ] || { printf '%s\n' '[]'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    json=$(jq -n -c --arg s "$line" --argjson acc "$json" '$acc + [$s]')
  done < "$path"
  printf '%s\n' "$json"
}

path_mtime() {
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null || true
  else
    stat -c %Y "$1" 2>/dev/null || true
  fi
}

evaluate_turn() {  # <json-file>
  local json=$1
  jq -c \
    --argjson run_held "$run_held" \
    --argjson run_ov "$run_ov" \
    --argjson run_skill "$run_skill" \
    --argjson run_node "$run_node" \
    --arg today "$today" '
    def trim:
      gsub("^[[:space:]]+"; "") | gsub("[[:space:]]+$"; "");
    def date_cleared($today):
      (.hold_until // "") as $u
      | ($u | type) == "string"
        and ($u | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
        and ($u <= $today);
    def as_str($v):
      if ($v | type) == "string" then $v else "" end;
    def as_arr($v):
      if ($v | type) == "array" then $v else [] end;

    . as $t
    | (as_arr($t.held)) as $held
    | (as_arr($t.map_next) | map(select(type == "string" and . != ""))) as $map_next
    | (as_arr($t.owned_meta) | map(select(type == "string" and . != ""))) as $owned
    | (as_arr($t.ships)) as $ships
    | (as_arr($t.owner_nodes)) as $nodes
    | [
        if $run_held == 1 then
          ($held[]? | select(type == "object") | . as $h
            | as_str($h.id) as $id
            | select($id != "")
            | select(($owned | index($id)) == null)
            | select(
                ($h | date_cleared($today))
                or (($map_next | index($id)) != null)
              )
            | "R-held-locked-next-unowned: \($id) is a locked next act still held without a worker"
          )
        else empty end,
        if $run_ov == 1 then
          ($ships[]? | select(type == "object") | . as $s
            | as_str($s.id) as $id
            | as_str($s.ov) as $ov
            | (as_str($s.task) | trim) as $task
            | select($id != "")
            | select(($s | has("task") | not) or ($task != "" and $task != "{TASK}"))
            | if $ov == "" then
                if ($s | has("task")) then
                  "R-ov-missing-none: \($id) started with no separate OV worker"
                else empty end
              elif $ov == $id then
                "R-ov-missing-self: \($id) named itself as OV; builder self-review is not OV"
              elif ($s | has("task")) and (($s | has("ov_report")) | not) then
                if (($owned | index($ov)) == null) then
                  "R-ov-missing-worker: \($id) OV \($ov) has no spawned worker"
                else empty end
              elif ($s | has("ov_report")) then
                if $s.ov_report == true then
                  empty
                elif $s.ov_report_required == true then
                  "R-ov-missing-report: \($id) OV \($ov) report is required before ship spawn"
                elif $s.ov_alive == true then
                  empty
                else
                  "R-ov-missing-report: \($id) review worker gone with no report"
                end
              else empty end
          )
        else empty end,
        if $run_skill == 1 then
          ($ships[]? | select(type == "object") | . as $s
            | as_str($s.id) as $id
            | (as_str($s.task) | trim) as $task
            | (as_str($s.ov_harness) | ascii_downcase) as $ov_harness
            | select($id != "")
            | select(($s | has("task") | not) or ($task != "" and $task != "{TASK}"))
            | select(($s | has("ov_report")) and ($s.ov_report == true))
            | select(($ov_harness == "claude") or ($ov_harness | startswith("claude")))
            | (if ($s.skills | type) == "array" then $s.skills else [] end) as $sk
            | select(($sk | map(ascii_downcase) | index("plan-eng-review")) == null)
            | "R-skill-unloaded-plan-eng-review: \($id) instructions never loaded plan-eng-review"
          )
        else empty end,
        if $run_node == 1 then
          ($nodes[]? | select(type == "object") | . as $n
            | as_str($n.token) as $tok
            | select($tok != "")
            | select($n.later_captain == true)
            | select($n.artifact != true)
            | "R-owner-node-open-waiting: /\($tok) node still open after the next captain message with no matching artifact"
          )
        else empty end
      ]
  ' "$json"
}

report_findings() {  # <findings-json-array>
  local findings=$1
  if [ -n "$expect_rule" ]; then
    prefix="${expect_rule}-"
    counts=$(jq -n --argjson findings "$findings" --arg prefix "$prefix" \
      '{selected: ([ $findings[] | select(startswith($prefix))] | length), total: ($findings | length)}')
    selected_count=$(jq '.selected' <<<"$counts")
    total=$(jq '.total' <<<"$counts")
    if [ "$selected_count" -ne "$expect_count" ] || [ "$total" -ne "$expect_count" ]; then
      printf 'regression: expected %s finding(s) and %s total, observed %s and %s total\n' \
        "$expect_count" "$expect_count" "$selected_count" "$total" >&2
      jq -r '.[]' <<<"$findings" >&2
      exit 1
    fi
    exit 0
  fi
  count=$(jq 'length' <<<"$findings")
  if [ "$count" -gt 0 ]; then
    jq -r '.[]' <<<"$findings"
    exit 1
  fi
  exit 0
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# Agent-alive first; pane presence only when agent state is unknown.
ov_endpoint_alive() {  # <ov-meta-path>
  local meta=$1 backend target agent_state
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  type fm_backend_of_meta >/dev/null 2>&1 || return 1
  type fm_backend_target_of_meta >/dev/null 2>&1 || return 1
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  if type fm_backend_agent_alive >/dev/null 2>&1; then
    agent_state=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || true)
    case "$agent_state" in
      alive) return 0 ;;
      dead) return 1 ;;
    esac
  fi
  if type fm_backend_target_exists >/dev/null 2>&1 \
    && fm_backend_target_exists "$backend" "$target" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

hook_refuse() {  # <finding>
  local finding=$1 reason escaped rule
  reason="Start that act now. A yes-ask or omission is not done."
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  if [ "$PRETOOL_MODE" -eq 1 ]; then
    escaped=$(json_escape "[owner-invoke-wait] $finding $reason")
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' \
      "$escaped" >&2
    [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  else
    {
      printf '●%s\n' "$rule"
      printf '●  OWNER-OWNED NEXT ACT WAS NOT STARTED\n'
      printf '●  %s\n' "$finding"
      printf '●  %s\n' "$reason"
      printf '●%s\n' "$rule"
    } >&2
  fi
  exit 2
}

if [ -n "$brief" ]; then
  [ -n "$brief" ] || structural "missing brief --brief"
  [ -e "$brief" ] || structural "missing brief $brief"
  [ -f "$brief" ] && [ ! -L "$brief" ] || structural "brief path is not a regular file: $brief"
  [ -s "$brief" ] || structural "empty brief $brief"
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-owner-invoke-wait.XXXXXX") || structural "could not create temp dir"
  # shellcheck disable=SC2329 # Invoked by trap handlers below.
  cleanup() { rm -rf -- "$TMP_DIR"; }
  trap cleanup EXIT HUP INT TERM
  brief_dir=$(CDPATH='' cd -- "$(dirname -- "$brief")" && pwd -P) || structural "brief directory unreadable"
  brief_id=$(basename "$brief_dir")
  turn="$TMP_DIR/turn.json"
  brief_ov="$brief_ov_arg"
  brief_meta="$STATE/$brief_id.meta"
  if [ -z "$brief_ov" ] && [ -f "$brief_meta" ] && [ ! -L "$brief_meta" ]; then
    brief_ov=$(sed -n 's/^ov=//p' "$brief_meta" 2>/dev/null | tail -1)
  fi
  brief_ov_report=false
  brief_ov_report_required=false
  brief_ov_alive=false
  brief_skills='[]'
  brief_ov_harness=""
  if [ "$brief_ov_arg_set" -eq 1 ] && [ -f "$STATE/$brief_ov.meta" ] \
    && [ ! -L "$STATE/$brief_ov.meta" ]; then
    brief_ov_harness=$(sed -n 's/^harness=//p' "$STATE/$brief_ov.meta" 2>/dev/null | tail -1)
  elif [ -f "$brief_meta" ] && [ ! -L "$brief_meta" ]; then
    brief_ov_harness=$(sed -n 's/^ov_harness=//p' "$brief_meta" 2>/dev/null | tail -1)
  fi
  if [ -n "$brief_ov" ]; then
    if [ -f "$DATA/$brief_ov/report.md" ] && [ ! -L "$DATA/$brief_ov/report.md" ] \
      && [ -s "$DATA/$brief_ov/report.md" ]; then
      brief_ov_report=true
      brief_skills=$(read_skill_lines "$DATA/$brief_ov/skills")
    elif [ -f "$STATE/$brief_ov.meta" ] && [ ! -L "$STATE/$brief_ov.meta" ]; then
      # shellcheck source=bin/fm-backend.sh
      . "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || true
      if ov_endpoint_alive "$STATE/$brief_ov.meta"; then
        brief_ov_alive=true
      fi
    fi
  fi
  [ "$brief_ov_arg_set" -eq 0 ] || brief_ov_report_required=true
  if [ -n "$brief_ov" ]; then
    jq -n --arg id "$brief_id" --arg ov "$brief_ov" --arg ov_harness "$brief_ov_harness" \
      --argjson skills "$brief_skills" \
      --argjson ov_report "$brief_ov_report" --argjson ov_report_required "$brief_ov_report_required" \
      --argjson ov_alive "$brief_ov_alive" \
      '{ships:[{id:$id, ov:$ov, ov_harness:$ov_harness, skills:$skills, ov_report:$ov_report, ov_report_required:$ov_report_required, ov_alive:$ov_alive}], owned_meta:[]}' > "$turn" \
      || structural "could not encode brief records"
  else
    printf '%s\n' '{"ships":[],"owned_meta":[]}' > "$turn"
  fi
  findings=$(evaluate_turn "$turn") || structural "could not evaluate brief"
  report_findings "$findings"
fi

if [ -n "$input" ]; then
  [ -e "$input" ] || structural "missing claims $input"
  [ -f "$input" ] && [ ! -L "$input" ] || structural "claims path is not a regular file: $input"
  [ -s "$input" ] || structural "empty claims $input"
  jq -e 'type == "object"' "$input" >/dev/null \
    || structural "turn JSON root must be an object"
  findings=$(evaluate_turn "$input") || structural "could not evaluate turn"
  report_findings "$findings"
fi

# --- hook / payload mode -----------------------------------------------------
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Match only real primary homes. Child task worktrees remain inert.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

if [ "$PRETOOL_MODE" -eq 1 ]; then
  exit 0
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-owner-invoke-wait.XXXXXX") || exit 0
# shellcheck disable=SC2329 # Invoked by trap handlers below.
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

held_json='[]'
map_json='[]'
owned_json='[]'
ships_json='[]'
owner_nodes_json='[]'

backend=
if [ -f "$CONFIG/backlog-backend" ]; then
  backend=$(sed -n '1{s/[[:space:]]//g;p;}' "$CONFIG/backlog-backend" 2>/dev/null || true)
fi

gather_held() {
  local backlog="$DATA/backlog.md" output id until
  [ -f "$backlog" ] && [ ! -L "$backlog" ] || return 0
  [ "$backend" != manual ] || return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  output=$(tasks-axi ready --file "$backlog" --include-held 2>/dev/null) || return 0
  while IFS=$'\t' read -r id until; do
    [ -n "$id" ] || continue
    held_json=$(jq -n -c --arg id "$id" --arg until "$until" \
      --argjson acc "$held_json" \
      '$acc + [{id:$id, hold_until:$until}]')
  done < <(printf '%s\n' "$output" | awk '
    /^held\[[0-9]+\]/ { in_held = 1; next }
    in_held && /^[[:space:]]/ {
      row = $0
      sub(/^[[:space:]]*/, "", row)
      id = row
      sub(/,.*/, "", id)
      until = row
      sub(/^.*,/, "", until)
      sub(/^[[:space:]]*/, "", until)
      sub(/[[:space:]]*$/, "", until)
      if (id != "") print id "\t" until
    }
    in_held && /^[^[:space:]]/ { exit }
  ')
}

gather_meta() {
  local meta id next owned='[]' maps='[]'
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    [ -n "$id" ] || continue
    owned=$(jq -n -c --arg id "$id" --argjson acc "$owned" '$acc + [$id]')
    next=$(sed -n 's/^map_next=//p' "$meta" 2>/dev/null | tail -1)
    [ -n "$next" ] || continue
    maps=$(jq -n -c --arg id "$next" --argjson acc "$maps" '$acc + [$id]')
  done
  owned_json=$owned
  map_json=$maps
}

gather_ships() {
  local session_id meta id kind ov ov_harness ship_session skills_json ov_report ov_alive ship
  local ships='[]'
  session_id=
  if [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ]; then
    session_id=$(tr -d '[:space:]' < "$STATE/.lock" 2>/dev/null || true)
  fi
  [ -n "$session_id" ] || {
    ships_json='[]'
    return 0
  }
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || true
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta")
    id=${id%.meta}
    [ -n "$id" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | tail -1)
    [ "$kind" = ship ] || continue
    ship_session=$(sed -n 's/^session=//p' "$meta" 2>/dev/null | tail -1)
    [ -n "$ship_session" ] || continue
    [ "$ship_session" = "$session_id" ] || continue
    ov=$(sed -n 's/^ov=//p' "$meta" 2>/dev/null | tail -1)
    ov_harness=$(sed -n 's/^ov_harness=//p' "$meta" 2>/dev/null | tail -1)
    skills_json='[]'
    ov_report=false
    ov_alive=false
    if [ -n "$ov" ]; then
      if [ -f "$DATA/$ov/report.md" ] && [ ! -L "$DATA/$ov/report.md" ] \
        && [ -s "$DATA/$ov/report.md" ]; then
        ov_report=true
        skills_json=$(read_skill_lines "$DATA/$ov/skills")
      elif [ -f "$STATE/$ov.meta" ] && [ ! -L "$STATE/$ov.meta" ] \
        && ov_endpoint_alive "$STATE/$ov.meta"; then
        ov_alive=true
      fi
    fi
    ship=$(jq -n -c --arg id "$id" --arg ov "$ov" --arg ov_harness "$ov_harness" \
      --argjson skills "$skills_json" \
      --argjson ov_report "$ov_report" --argjson ov_alive "$ov_alive" \
      '{id:$id, ov:$ov, ov_harness:$ov_harness, skills:$skills, ov_report:$ov_report, ov_alive:$ov_alive}')
    ships=$(jq -n -c --argjson ship "$ship" --argjson acc "$ships" '$acc + [$ship]')
  done
  ships_json=$ships
}

gather_owner_nodes() {
  local line_no=0 tabs token glob rows='[]' line trimmed lock_mtime py extracted transcript
  local registry_file=
  owner_nodes_json='[]'
  [ "$run_node" -eq 1 ] || return 0
  if [ -n "${FM_OWNER_INVOKE_NODES_REGISTRY:-}" ]; then
    registry_file=$FM_OWNER_INVOKE_NODES_REGISTRY
    [ -e "$registry_file" ] || structural "owner-invoke nodes registry is missing: $registry_file"
    [ -f "$registry_file" ] && [ ! -L "$registry_file" ] && [ -r "$registry_file" ] \
      || structural "owner-invoke nodes registry is not a readable ordinary file: $registry_file"
    [ -s "$registry_file" ] || structural "empty owner-invoke nodes registry $registry_file"
  else
    registry_file=$TMP_DIR/default-owner-invoke-nodes.tsv
    printf '%s\n' "$DEFAULT_OWNER_INVOKE_NODES" > "$registry_file" \
      || structural "could not write default owner-invoke nodes table"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    case "$trimmed" in ''|\#*) continue ;; esac
    tabs=$(awk -F '\t' '{ print NF - 1 }' <<< "$line")
    [ "$tabs" -eq 1 ] || structural "owner-invoke nodes registry line $line_no must contain exactly two tab-separated fields"
    token=${line%%$'\t'*}
    glob=${line#*$'\t'}
    [ -n "$token" ] && [ -n "$glob" ] || structural "owner-invoke nodes registry line $line_no has an empty field"
    [ "$token" = "$(printf '%s' "$token" | tr -d '[:space:]')" ] \
      || structural "owner-invoke nodes registry line $line_no token has whitespace"
    case "$token" in
      *[!A-Za-z0-9_-]*) structural "owner-invoke nodes registry line $line_no has an unsafe token: $token" ;;
    esac
    case "$glob" in
      /*|../*|*/../*|*/..|.. ) structural "owner-invoke nodes registry line $line_no has an unsafe glob: $glob" ;;
    esac
    rows=$(jq -n -c --arg token "$token" --arg glob "$glob" --argjson acc "$rows" \
      '$acc + [{token: ($token | ascii_downcase), glob: $glob}]')
  done < "$registry_file"
  [ "$(jq 'length' <<<"$rows")" -gt 0 ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  transcript=$(printf '%s' "$PAYLOAD" | jq -r '(.transcript_path // .transcriptPath // empty)' 2>/dev/null) || return 0
  [ -n "$transcript" ] || return 0
  [ -f "$transcript" ] && [ ! -L "$transcript" ] && [ -r "$transcript" ] || return 0
  lock_mtime=
  if [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ]; then
    lock_mtime=$(path_mtime "$STATE/.lock")
  fi
  py="$TMP_DIR/owner-nodes.py"
  cat > "$py" <<'PY'
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

rows = json.loads(sys.argv[1])
transcript = sys.argv[2]
home = sys.argv[3]
root = sys.argv[4]
lock_raw = sys.argv[5]
token_set = {row["token"] for row in rows if row.get("token")}
globs = {}
for row in rows:
    tok = row.get("token") or ""
    pattern = row.get("glob") or ""
    if not tok or not pattern:
        continue
    globs.setdefault(tok, []).append(pattern)
tag_re = re.compile(
    r"<command-name>\s*/?([A-Za-z][A-Za-z0-9_-]*)\s*</command-name>",
    re.IGNORECASE,
)

def message(record):
    if not isinstance(record, dict):
        return None
    if isinstance(record.get("message"), dict):
        return record["message"]
    return record

def role_of(record, msg):
    if isinstance(msg, dict):
        role = str(msg.get("role") or "")
        if role:
            return role
    if isinstance(record, dict):
        return str(record.get("type") or record.get("role") or "")
    return ""

def texts_of(content):
    if isinstance(content, str):
        return [content] if content.strip() else []
    if not isinstance(content, list):
        return []
    out = []
    for part in content:
        if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str):
            if part["text"].strip():
                out.append(part["text"])
    return out

def is_tool_result_only(content):
    if not isinstance(content, list) or not content:
        return False
    for part in content:
        if not isinstance(part, dict):
            return False
        typ = str(part.get("type") or "")
        if typ not in ("tool_result", "toolResult"):
            return False
    return True

def is_synthetic_user_text(text):
    t = text.lstrip()
    if t.startswith("<task-notification"):
        return True
    if t.startswith("<local-command-stdout"):
        return True
    if t.startswith("[Request interrupted by user"):
        return True
    if "FIRSTMATE_OP:" in text or "turn-end-guard" in text:
        return True
    return False

def is_captain_turn(record, content):
    if isinstance(record, dict) and record.get("isMeta") is True:
        return False
    if is_tool_result_only(content):
        return False
    text_blob = "\n".join(texts_of(content))
    if not text_blob.strip():
        return False
    if is_synthetic_user_text(text_blob):
        return False
    return True

def parse_ts(record, msg):
    raw = None
    if isinstance(record, dict):
        raw = record.get("timestamp") or record.get("ts")
    if raw is None and isinstance(msg, dict):
        raw = msg.get("timestamp") or msg.get("ts")
    if isinstance(raw, (int, float)):
        value = float(raw)
        if value > 1e12:
            value = value / 1000.0
        return value
    if isinstance(raw, str) and raw.strip():
        text = raw.strip()
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            return datetime.fromisoformat(text).timestamp()
        except ValueError:
            return None
    return None

def ordinary_nonempty(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    if not os.path.isfile(path) or os.path.islink(path) or st.st_size <= 0:
        return False
    return True

def artifact_hit(patterns, since):
    if not patterns or since is None:
        return False
    if isinstance(patterns, str):
        patterns = [patterns]
    for pattern in patterns:
        if not pattern:
            continue
        for base in (home, root):
            full = os.path.join(base, pattern)
            for path in glob.glob(full, recursive=True):
                if not ordinary_nonempty(path):
                    continue
                try:
                    if os.path.getmtime(path) >= since:
                        return True
                except OSError:
                    continue
    return False

lock_mtime = None
if lock_raw:
    try:
        lock_mtime = float(lock_raw)
    except ValueError:
        lock_mtime = None

opens = {}
seq = 0
try:
    with open(transcript, encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw)
            except json.JSONDecodeError:
                continue
            seq += 1
            msg = message(record)
            role = role_of(record, msg)
            content = msg.get("content") if isinstance(msg, dict) else None
            blob = "\n".join(texts_of(content))
            ts = parse_ts(record, msg)
            if role in ("user", "human") and not (
                isinstance(record, dict) and record.get("isMeta") is True
            ):
                found = []
                for match in tag_re.finditer(blob):
                    tok = match.group(1).strip().lstrip("/").lower()
                    if tok in token_set and tok not in found:
                        found.append(tok)
                if found:
                    for tok in found:
                        opens[tok] = {"seq": seq, "ts": ts}
            if role in ("user", "human") and is_captain_turn(record, content):
                for tok, info in opens.items():
                    if seq > info["seq"]:
                        info["later"] = True
except OSError:
    print("[]")
    raise SystemExit(0)

out = []
for tok, info in opens.items():
    since = info.get("ts")
    if since is None:
        since = lock_mtime
    out.append({
        "token": tok,
        "later_captain": bool(info.get("later")),
        "artifact": artifact_hit(globs.get(tok, []), since),
    })
print(json.dumps(out))
PY
  extracted=$(python3 "$py" "$rows" "$transcript" "$FM_HOME" "$FM_ROOT" "${lock_mtime:-}" 2>/dev/null) || {
    owner_nodes_json='[]'
    return 0
  }
  jq -e 'type == "array"' <<<"$extracted" >/dev/null 2>&1 || {
    owner_nodes_json='[]'
    return 0
  }
  owner_nodes_json=$extracted
}

gather_held || true
gather_meta || true
gather_ships || true
gather_owner_nodes

turn="$TMP_DIR/turn.json"
[ -n "$held_json" ] || held_json='[]'
[ -n "$map_json" ] || map_json='[]'
[ -n "$owned_json" ] || owned_json='[]'
[ -n "$ships_json" ] || ships_json='[]'
[ -n "$owner_nodes_json" ] || owner_nodes_json='[]'
jq -n \
  --argjson held "$held_json" \
  --argjson map_next "$map_json" \
  --argjson owned "$owned_json" \
  --argjson ships "$ships_json" \
  --argjson nodes "$owner_nodes_json" \
  '{
    held: $held,
    map_next: $map_next,
    owned_meta: $owned,
    ships: $ships,
    owner_nodes: $nodes
  }' > "$turn" || exit 0

findings=$(evaluate_turn "$turn") || exit 0
count=$(jq 'length' <<<"$findings")
[ "$count" -gt 0 ] || exit 0
first=$(jq -r '.[0]' <<<"$findings")
hook_refuse "$first"
