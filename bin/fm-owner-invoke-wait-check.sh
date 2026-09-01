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
# --ov supplies the completed pre-publication OV record for a production ship spawn.
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
# Default --input rules:
#   R-held-locked-next      a held ticket is a map_next target or its until
#                           date has passed, and it has no worker meta
#   R-ov-missing            spawn --input with task: no distinct OV worker;
#                           stored --brief without --ov: review worker gone
#                           with no data/<ov>/report.md (live worker without
#                           report is in-progress and passes); --brief --ov
#                           requires the report before spawn
# Default hook/payload rules: R-held-locked-next only. Hook mode does not
# gather session ships and does not arm owner-invoke nodes.
# Default --brief rules: R-ov-missing,R-skill-unloaded on durable OV records
# (state/<ship>.meta ov=/ov_harness=, data/<ov>/report.md, data/<ov>/skills,
# live endpoint). Explicit --ov requires a completed report. No brief-body parse.
#
# plan-eng-review requires a separate OV worker. The builder's own plan note
# is not OV.
# Hook-mode held gather calls tasks-axi ready --include-held once. It reads
# only the first id field and the final hold_until field from each held row;
# quoted commas or escaped newlines in intermediate fields cannot alter them.
# It never calls tasks-axi show for individual held tickets.
#
# At spawn, fm-spawn.sh runs the distinct-worker R-ov-missing check first for
# every explicit --ov, then requires the OV report and retains
# R-skill-unloaded for every ship role.
# fm-spawn.sh writes ov_harness=
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
# LIMITS: A real captain hold is invisible.
# Empty or {TASK} task fields skip ship rules (spawn-harness stubs).
# Builder self-review is not OV. A non-Claude review worker (grok, codex,
# pi, kimi, opencode, muse) fires no PostToolUse hook, so its skills record
# is never written; brief or explicit R-skill-unloaded evaluation runs only
# when durable ov_harness is claude or claude*, and skips for any other harness
# or a missing/unreadable ov_harness on older records - a disclosed gap, not a
# refusal.
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

INPUT_RULES='R-held-locked-next,R-ov-missing'
HOOK_RULES='R-held-locked-next'
BRIEF_RULES='R-ov-missing,R-skill-unloaded'
KNOWN_RULES='R-held-locked-next R-ov-missing R-skill-unloaded'

usage() {
  sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'
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
  elif [ "$HOOK_MODE" -eq 1 ]; then
    rules=$HOOK_RULES
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
for r in "${selected[@]+"${selected[@]}"}"; do
  case "$r" in
    R-held-locked-next) run_held=1 ;;
    R-ov-missing) run_ov=1 ;;
    R-skill-unloaded) run_skill=1 ;;
  esac
done

today=$(date +%F)

read_skill_lines() {  # <path> -> JSON array
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] || { printf '%s\n' '[]'; return 0; }
  jq -R -s -c '
    [ split("\n")[]
      | gsub("^[[:space:]]+"; "")
      | gsub("[[:space:]]+$"; "")
      | select(length > 0)
    ]
  ' "$path"
}

evaluate_turn() {  # <json-file>
  local json=$1
  jq -c \
    --argjson run_held "$run_held" \
    --argjson run_ov "$run_ov" \
    --argjson run_skill "$run_skill" \
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

backend=
if [ -f "$CONFIG/backlog-backend" ]; then
  backend=$(sed -n '1{s/[[:space:]]//g;p;}' "$CONFIG/backlog-backend" 2>/dev/null || true)
fi

gather_held() {
  local backlog="$DATA/backlog.md" output id until rows=
  [ -f "$backlog" ] && [ ! -L "$backlog" ] || return 0
  [ "$backend" != manual ] || return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  output=$(tasks-axi ready --file "$backlog" --include-held 2>/dev/null) || return 0
  while IFS=$'\t' read -r id until; do
    [ -n "$id" ] || continue
    rows+="$id"$'\t'"$until"$'\n'
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
  held_json=$(printf '%s' "$rows" | jq -R -s -c '
    [ split("\n")[]
      | select(length > 0)
      | split("\t")
      | {id: .[0], hold_until: .[1]}
    ]
  ')
}

gather_meta() {
  local meta id next owned_rows='' map_rows=''
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ -n "$id" ] || continue
    owned_rows+="$id"$'\n'
    next=$(sed -n 's/^map_next=//p' "$meta" 2>/dev/null | tail -1)
    [ -n "$next" ] || continue
    map_rows+="$next"$'\n'
  done
  owned_json=$(printf '%s' "$owned_rows" | jq -R -s -c \
    '[split("\n")[] | select(length > 0)]')
  map_json=$(printf '%s' "$map_rows" | jq -R -s -c \
    '[split("\n")[] | select(length > 0)]')
}

gather_held || true
gather_meta || true

turn="$TMP_DIR/turn.json"
[ -n "$held_json" ] || held_json='[]'
[ -n "$map_json" ] || map_json='[]'
[ -n "$owned_json" ] || owned_json='[]'
[ -n "$ships_json" ] || ships_json='[]'
jq -n \
  --argjson held "$held_json" \
  --argjson map_next "$map_json" \
  --argjson owned "$owned_json" \
  --argjson ships "$ships_json" \
  '{
    held: $held,
    map_next: $map_next,
    owned_meta: $owned,
    ships: $ships
  }' > "$turn" || exit 0

findings=$(evaluate_turn "$turn") || exit 0
count=$(jq 'length' <<<"$findings")
[ "$count" -gt 0 ] || exit 0
first=$(jq -r '.[0]' <<<"$findings")
hook_refuse "$first"
