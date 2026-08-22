#!/usr/bin/env bash
# Refuse ending a turn, asking for a yes, or starting a ship when this seat
# already owns the next act and does not start it.
#
# Usage: fm-owner-invoke-wait-check.sh --input <turn.json>
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#        fm-owner-invoke-wait-check.sh --brief <ship-brief.md>
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#        fm-owner-invoke-wait-check.sh [--claude] [--pretool]
#
# --input and --brief are required in CLI modes. A missing or empty file,
# claims that are not a JSON object, unknown rule ids, empty --rules, and
# --expect-count 0 are structural failures, exit 2. Findings exit 1. Clean
# exit 0.
# Hook/payload mode (no --input/--brief) reads the turn-end or PreToolUse
# payload on stdin. Empty stdin is inert exit 0 so a missing hook payload
# cannot wedge the session. Findings in hook mode print a refusal banner
# and exit 2. PreToolUse denies AskUserQuestion yes-asks the same way
# bin/fm-sot-speech-check.sh does.
#
# Default --input / payload rules:
#   R-held-locked-next      a held ticket is a map_next target, its until
#                           date has passed, or its captain hold is an
#                           invented go, and it has no worker meta
#   R-owner-invoke-wait     captain-facing text names an owner-invoke skill
#                           and asks for a yes, and that skill was not invoked
#   R-fog-pin-wait          live fog plus a pin/when question
#   R-ov-missing            a filled ship start has no distinct OV worker
# Default --brief rule: R-ov-missing (filled Task, empty ov)
#
# Owner-invoke tokens (header-owned; not a skill picker):
#   recurring-defect, grill-with-docs, wayfinder, vision
# Name-and-wait freeze (never a yes-ask refuse): design-shotgun,
# office-hours, plan-ceo-review, plan-design-review, plan-eng-review.
# plan-eng-review requires a separate OV worker. The builder's own plan
# note is not OV. Starting a filled ship without ov= pointing at a
# distinct already-spawned worker is omission.
#
# Exact-count regression requires both --expect-rule and --expect-count and
# exits 0 only when that rule count and the total finding count both equal
# the expected count. There is no "the fixture must fail" inversion.
#
# LIMITS: English yes-ask cannot be 100%. A real captain hold is invisible.
# An empty Task section (spawn-harness stubs) and the unreplaced {TASK}
# placeholder are skipped. Builder self-review is not OV. This check
# proves a distinct ov= worker meta exists, not that the OV ran the
# skill. Name-and-wait skills stay askable. In-flight ships already
# started without ov= are not re-refused at turn end.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

input=
brief=
expect_rule=
expect_count=
rules=
rules_set=0
CLAUDE_MODE=0
PRETOOL_MODE=0
HOOK_MODE=0

INPUT_RULES='R-held-locked-next,R-owner-invoke-wait,R-fog-pin-wait,R-ov-missing'
BRIEF_RULES='R-ov-missing'
KNOWN_RULES='R-held-locked-next R-owner-invoke-wait R-fog-pin-wait R-ov-missing'

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
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
run_wait=0
run_fog=0
run_ov=0
for r in "${selected[@]+"${selected[@]}"}"; do
  case "$r" in
    R-held-locked-next) run_held=1 ;;
    R-owner-invoke-wait) run_wait=1 ;;
    R-fog-pin-wait) run_fog=1 ;;
    R-ov-missing) run_ov=1 ;;
  esac
done

today=$(date +%F)

task_section() {
  awk '
    /^# Task[[:space:]]*$/ { in_task = 1; next }
    in_task && /^# / { exit }
    in_task { print }
  ' "$1"
}

evaluate_turn() {  # <json-file>
  local json=$1
  jq -c \
    --argjson run_held "$run_held" \
    --argjson run_wait "$run_wait" \
    --argjson run_fog "$run_fog" \
    --argjson run_ov "$run_ov" \
    --arg today "$today" '
    def trim:
      gsub("^[[:space:]]+"; "") | gsub("[[:space:]]+$"; "");
    def yes_ask:
      test("should i|shall i|want me to|do you want|wait for (your )?yes|when (should|do i|to )|may i (run|start|invoke)|start it\\?|run it\\?"; "i");
    def named_token($tok):
      test("(^|[^A-Za-z0-9_-])[/$]?" + $tok + "([^A-Za-z0-9_-]|$)"; "i");
    def invented_go:
      test("waiting for (a )?(captain )?(go|yes)|when you want|awaiting (a )?go"; "i");
    def date_cleared($today):
      (.hold_until // "") as $u
      | ($u | type) == "string"
        and ($u | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
        and ($u <= $today);
    def tokens:
      ["recurring-defect", "grill-with-docs", "wayfinder", "vision"];
    def as_str($v):
      if ($v | type) == "string" then $v else "" end;
    def as_arr($v):
      if ($v | type) == "array" then $v else [] end;

    . as $t
    | (as_arr($t.held)) as $held
    | (as_arr($t.map_next) | map(select(type == "string" and . != ""))) as $map_next
    | (as_arr($t.owned_meta) | map(select(type == "string" and . != ""))) as $owned
    | (as_str($t.assistant_text) | trim) as $speech
    | (as_arr($t.invoked_skills) | map(ascii_downcase)) as $invoked
    | (if ($t.fog_live == true) then true else false end) as $fog
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
                or (
                  (as_str($h.hold_kind) == "captain")
                  and (as_str($h.hold_reason) | invented_go)
                )
              )
            | "R-held-locked-next-unowned: \($id) is a locked next act still held without a worker"
          )
        else empty end,
        if $run_wait == 1 and ($speech != "") and ($speech | yes_ask) then
          (tokens[] | . as $tok
            | select($speech | named_token($tok))
            | select(($invoked | index($tok)) == null)
            | "R-owner-invoke-wait-yes-ask: named /\($tok) and asked for a yes"
          )
        else empty end,
        if $run_fog == 1 and $fog and ($speech != "")
           and ($speech | test("pin.{0,80}fog|fog.{0,80}pin|next fog"; "i"))
           and ($speech | (yes_ask or test("\\bwhen\\b"; "i"))) then
          "R-fog-pin-wait-asked: asked when to pin live fog"
        else empty end,
        if $run_ov == 1 then
          ($ships[]? | select(type == "object") | . as $s
            | as_str($s.id) as $id
            | as_str($s.ov) as $ov
            | (as_str($s.task) | trim) as $task
            | select($id != "")
            | select($task != "" and $task != "{TASK}")
            | if $ov == "" then
                "R-ov-missing-none: \($id) started with no separate OV worker"
              elif $ov == $id then
                "R-ov-missing-self: \($id) named itself as OV; builder self-review is not OV"
              elif (($owned | index($ov)) == null) then
                "R-ov-missing-worker: \($id) OV \($ov) has no spawned worker"
              else empty end
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
  task_file="$TMP_DIR/task.md"
  task_section "$brief" > "$task_file"
  task_text=$(cat "$task_file")
  turn="$TMP_DIR/turn.json"
  jq -n --arg task "$task_text" '{ships:[{id:"brief", ov:"", task:$task}]}' > "$turn" \
    || structural "could not encode brief task"
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

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-owner-invoke-wait.XXXXXX") || exit 0
# shellcheck disable=SC2329 # Invoked by trap handlers below.
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

held_json='[]'
map_json='[]'
owned_json='[]'
speech=''
invoked_json='[]'
fog_live=false

backend=
if [ -f "$CONFIG/backlog-backend" ]; then
  backend=$(sed -n '1{s/[[:space:]]//g;p;}' "$CONFIG/backlog-backend" 2>/dev/null || true)
fi

gather_held() {
  local backlog="$DATA/backlog.md" output id kind reason until show
  [ -f "$backlog" ] && [ ! -L "$backlog" ] || return 0
  [ "$backend" != manual ] || return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  output=$(tasks-axi ready --file "$backlog" --include-held 2>/dev/null) || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    show=$(tasks-axi show --file "$backlog" "$id" 2>/dev/null) || continue
    kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | tail -1)
    reason=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: //p' | tail -1)
    until=$(printf '%s\n' "$show" | sed -n 's/^  hold_until: //p' | tail -1)
    held_json=$(jq -n -c --arg id "$id" --arg kind "$kind" --arg reason "$reason" --arg until "$until" \
      --argjson acc "$held_json" \
      '$acc + [{id:$id, hold_kind:$kind, hold_reason:$reason, hold_until:$until}]')
  done < <(printf '%s\n' "$output" | awk '
    /^held\[[0-9]+\]/ { in_held = 1; next }
    in_held && /^[[:space:]]/ {
      row = $0
      sub(/^[[:space:]]*/, "", row)
      split(row, fields, ",")
      if (fields[1] != "") print fields[1]
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

extract_speech() {
  local transcript py
  transcript=$(printf '%s' "$PAYLOAD" | jq -r '(.transcript_path // .transcriptPath // empty)' 2>/dev/null) || return 0
  [ -n "$transcript" ] || return 0
  [ -f "$transcript" ] && [ ! -L "$transcript" ] && [ -r "$transcript" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  py="$TMP_DIR/extract.py"
  cat > "$py" <<'PY'
import json
import re
import sys

tokens = ("recurring-defect", "grill-with-docs", "wayfinder", "vision")
path = sys.argv[1]
text = ""
invoked = []


def add_invoked(blob):
    blob = (blob or "").lower()
    for token in tokens:
        if re.search(r'(^|[^a-z0-9_-])[/$]?' + re.escape(token) + r'([^a-z0-9_-]|$)', blob):
            if token not in invoked:
                invoked.append(token)


def walk_tools(value):
    if isinstance(value, list):
        for item in value:
            walk_tools(item)
        return
    if not isinstance(value, dict):
        return
    kind = str(value.get("type") or "")
    name = str(value.get("name") or value.get("tool_name") or "")
    if kind in ("tool_use", "toolUse", "toolCall") or name:
        add_invoked(name)
        blob = json.dumps(value.get("input") or value.get("arguments") or {})
        add_invoked(blob)
    for item in value.values():
        if isinstance(item, (list, dict)):
            walk_tools(item)


def message(record):
    if not isinstance(record, dict):
        return None
    if isinstance(record.get("message"), dict):
        return record["message"]
    return record


def text_parts(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for part in content:
        if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str):
            parts.append(part["text"])
    return "\n".join(parts)


try:
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw)
            except json.JSONDecodeError:
                continue
            msg = message(record)
            role = ""
            content = None
            if isinstance(msg, dict):
                role = str(msg.get("role") or record.get("type") or "")
                content = msg.get("content")
            if role == "assistant":
                walk_tools(content)
                chunk = text_parts(content).strip()
                if chunk:
                    text = chunk
except OSError:
    print(json.dumps({"assistant_text": "", "invoked_skills": []}))
    raise SystemExit(0)

print(json.dumps({"assistant_text": text, "invoked_skills": invoked}))
PY
  extracted=$(python3 "$py" "$transcript" 2>/dev/null) || return 0
  speech=$(printf '%s' "$extracted" | jq -r '.assistant_text // empty')
  invoked_json=$(printf '%s' "$extracted" | jq -c '.invoked_skills // []')
}

if [ "$PRETOOL_MODE" -eq 1 ]; then
  tool=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // .toolName // empty' 2>/dev/null) || exit 0
  [ "$tool" = AskUserQuestion ] || exit 0
  speech=$(printf '%s' "$PAYLOAD" | jq -r '
    def strings:
      if type == "string" then .
      elif type == "array" then map(strings) | join("\n")
      elif type == "object" then [.[]] | map(strings) | join("\n")
      else empty end;
    (.tool_input // .toolInput // {}) | strings
  ' 2>/dev/null) || exit 0
else
  extract_speech || true
  gather_held || true
  gather_meta || true
  if [ -x "$SCRIPT_DIR/fm-map-fog-check.sh" ]; then
    fog_out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-map-fog-check.sh" 2>/dev/null || true)
    case "$fog_out" in
      *MAP_FOG*) fog_live=true ;;
    esac
  fi
fi

turn="$TMP_DIR/turn.json"
[ -n "$held_json" ] || held_json='[]'
[ -n "$map_json" ] || map_json='[]'
[ -n "$owned_json" ] || owned_json='[]'
[ -n "$invoked_json" ] || invoked_json='[]'
case "$fog_live" in true|false) ;; *) fog_live=false ;; esac
jq -n \
  --argjson held "$held_json" \
  --argjson map_next "$map_json" \
  --argjson owned "$owned_json" \
  --arg speech "$speech" \
  --argjson invoked "$invoked_json" \
  --argjson fog "$fog_live" \
  '{
    held: $held,
    map_next: $map_next,
    owned_meta: $owned,
    assistant_text: $speech,
    invoked_skills: $invoked,
    fog_live: $fog
  }' > "$turn" || exit 0

findings=$(evaluate_turn "$turn") || exit 0
count=$(jq 'length' <<<"$findings")
[ "$count" -gt 0 ] || exit 0
first=$(jq -r '.[0]' <<<"$findings")
hook_refuse "$first"
