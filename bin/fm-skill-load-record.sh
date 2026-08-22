#!/usr/bin/env bash
# Record a real Skill tool load into data/<task-id>/skills.
#
# Usage: fm-skill-load-record.sh [--claude]
#
# Claude PostToolUse matcher Skill. Inert exit 0 unless FM_TASK_ID and FM_HOME
# are both set and $FM_HOME/state/$FM_TASK_ID.meta exists as a regular file.
# Otherwise appends the normalized skill name to $FM_HOME/data/$FM_TASK_ID/skills,
# creating the file on first load. Normalization: lowercase and strip a leading
# gstack- prefix. Absent or empty skills file means never loaded for consumers.
# Does not parse free English. Non-Claude harnesses fire no PostToolUse hook.
set -euo pipefail

CLAUDE_MODE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude) CLAUDE_MODE=1; shift ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) exit 0 ;;
  esac
done

: "${CLAUDE_MODE:=0}"

task_id=${FM_TASK_ID:-}
home=${FM_HOME:-}
[ -n "$task_id" ] && [ -n "$home" ] || exit 0
case "$task_id" in
  *[!A-Za-z0-9._-]*|"") exit 0 ;;
esac

state="$home/state"
data="$home/data"
meta="$state/$task_id.meta"
[ -f "$meta" ] && [ ! -L "$meta" ] || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

skill=$(printf '%s' "$PAYLOAD" | jq -r '
  def pick:
    if type == "string" then .
    elif type != "object" then empty
    else
      (.skill // .skill_name // .name // .command // empty)
    end;
  (.tool_input // .toolInput // {}) | pick
' 2>/dev/null) || exit 0
skill=${skill#"${skill%%[![:space:]]*}"}
skill=${skill%"${skill##*[![:space:]]}"}
[ -n "$skill" ] || exit 0

# Basename only when a path-like skill id is supplied.
case "$skill" in
  */*) skill=${skill##*/} ;;
esac
skill=$(printf '%s' "$skill" | tr '[:upper:]' '[:lower:]')
case "$skill" in
  gstack-*) skill=${skill#gstack-} ;;
esac
[ -n "$skill" ] || exit 0

mkdir -p "$data/$task_id" 2>/dev/null || exit 0
skills_path="$data/$task_id/skills"
if [ -e "$skills_path" ] && { [ -L "$skills_path" ] || [ ! -f "$skills_path" ]; }; then
  exit 0
fi
if [ -f "$skills_path" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ "$line" = "$skill" ] && exit 0
  done < "$skills_path"
fi
printf '%s\n' "$skill" >> "$skills_path" 2>/dev/null || exit 0
exit 0
