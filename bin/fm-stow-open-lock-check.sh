#!/usr/bin/env bash
# Check that a stow receipt does not claim reset-safe while a lock file still
# marks a pick open, and that a Bearings snapshot lists those still-open picks.
#
# Usage: fm-stow-open-lock-check.sh --input <receipt.json|txt>
#          [--decisions-dir <dir>] [--snapshot <snapshot.json>]
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#        fm-stow-open-lock-check.sh --list-open [--decisions-dir <dir>]
#          [--file <name.md>]...
#
# This is the promoted stow-reset-safe checker taxonomy (exit 0/1/2, exact-count
# regression) extended to data/decisions/*.md open-pick markers.
#
# --input is required except for --list-open and --help. A missing or empty
# receipt, missing or empty --snapshot when that path is supplied, unknown
# rule ids, empty --rules, and --expect-count 0 are structural failures, exit 2.
# Findings exit 1. Clean exit 0.
#
# Default rules:
#   R-stow-open-lock            receipt reset_safe=true omits an open lock pick
#   R-bearings-lists-open-locks snapshot decisions_open omits an open lock pick
#                               (skipped unless --snapshot is passed, unless
#                               that rule is the --expect-rule)
#
# --list-open prints the JSON array of open lock-file picks and is the single
# reader used by fm-fleet-snapshot.sh. An absent decisions directory is an
# empty list, not a pass over missing receipt input.
#
# Open-pick markers are Q-items whose bold span has no locked answer, and
# lines whose lead-in is Still open. Exact-count regression requires both
# --expect-rule and --expect-count and exits 0 only when that rule count and
# the total finding count both equal the expected count.
#
# LIMITS: a pick never written to any decision file cannot be seen. Other
# prose that merely mentions "still open" is invisible. This checker does
# not scrape transcripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

input=
decisions_dir=
snapshot=
list_open=0
expect_rule=
expect_count=
rules="R-stow-open-lock,R-bearings-lists-open-locks"
decision_files=()

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

structural() {
  printf 'structural: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input)
      [ "$#" -ge 2 ] || structural "--input requires a path"
      input=$2
      shift 2
      ;;
    --decisions-dir)
      [ "$#" -ge 2 ] || structural "--decisions-dir requires a path"
      decisions_dir=$2
      shift 2
      ;;
    --snapshot)
      [ "$#" -ge 2 ] || structural "--snapshot requires a path"
      snapshot=$2
      shift 2
      ;;
    --list-open)
      list_open=1
      shift
      ;;
    --file)
      [ "$#" -ge 2 ] || structural "--file requires a decision file name"
      case "$2" in
        */*|''|.|..|*[!A-Za-z0-9._-]*) structural "unsafe --file name: $2" ;;
        *.md) decision_files+=("$2") ;;
        *) structural "--file must name a .md file: $2" ;;
      esac
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
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      structural "unknown argument: $1"
      ;;
  esac
done

[ "$list_open" -eq 1 ] || [ "${#decision_files[@]}" -eq 0 ] \
  || structural "--file requires --list-open"

command -v jq >/dev/null 2>&1 || structural "jq not found"

[ -n "$rules" ] || structural "empty --rules"
selected=()
IFS=',' read -r -a selected <<< "$rules" || true
cleaned=()
for r in "${selected[@]+"${selected[@]}"}"; do
  r=${r#"${r%%[![:space:]]*}"}
  r=${r%"${r##*[![:space:]]}"}
  [ -n "$r" ] || continue
  case "$r" in
    R-stow-open-lock|R-bearings-lists-open-locks) cleaned+=("$r") ;;
    *) structural "unknown rule id: $r" ;;
  esac
done
[ "${#cleaned[@]}" -gt 0 ] || structural "empty --rules"
selected=("${cleaned[@]}")

if [ -n "$expect_rule" ] || [ -n "$expect_count" ]; then
  [ -n "$expect_rule" ] && [ -n "$expect_count" ] \
    || structural "regression mode needs both --expect-rule and --expect-count"
  case "$expect_count" in
    ''|*[!0-9]*|0) structural "expect-count must be > 0" ;;
  esac
  case "$expect_rule" in
    R-stow-open-lock|R-bearings-lists-open-locks) ;;
    *) structural "unknown expect-rule $expect_rule" ;;
  esac
fi

if [ -z "$decisions_dir" ]; then
  decisions_dir="$DATA/decisions"
fi

# Print TSV: id, key, summary, file. One row per open pick.
list_open_tsv() {
  local dir=$1 file base stem rel lineno line key bold_rest after bold ans label summary
  local -a files
  shift
  [ -e "$dir" ] || return 0
  [ -d "$dir" ] && [ ! -L "$dir" ] || structural "decisions path is not a regular directory: $dir"
  if [ "$#" -gt 0 ]; then
    files=()
    for file in "$@"; do
      files+=("$dir/$file")
    done
  else
    shopt -s nullglob
    files=( "$dir"/*.md )
    shopt -u nullglob
  fi
  for file in "${files[@]}"; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    base=${file##*/}
    stem=${base%.md}
    rel="data/decisions/$base"
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      line=${line%$'\r'}
      if [[ $line =~ ^[-*][[:space:]]+\*\*(Q[0-9]+)([^*]*)\*\*(.*)$ ]]; then
        key=${BASH_REMATCH[1]}
        bold_rest=${BASH_REMATCH[2]}
        after=${BASH_REMATCH[3]}
        bold="${key}${bold_rest}"
        ans=
        if [[ $bold =~ =[[:space:]]*([^[:space:]].*)$ ]]; then
          ans=${BASH_REMATCH[1]}
          if [[ ! $ans =~ ^[Ss]till[[:space:]].*[Oo]pen ]]; then
            continue
          fi
        fi
        label=${bold_rest#"${bold_rest%%[![:space:]]*}"}
        label=${label%"${label##*[![:space:]]}"}
        [ -n "$label" ] || label=$key
        summary="${label}${after}"
        summary=${summary#"${summary%%[![:space:]]*}"}
        summary=${summary%"${summary##*[![:space:]]}"}
        [ -n "$summary" ] || summary="$key still open"
        summary=${summary:0:160}
        summary=${summary//$'\t'/ }
        printf '%s\t%s\t%s\t%s\n' "$stem/$key" "$key" "$summary" "$rel"
        continue
      fi
      if [[ $line =~ ^(#[[:space:]]+)?([-*][[:space:]]+)?(\*\*[[:space:]]*)?[Ss]till[[:space:]]+open ]]; then
        key="L${lineno}"
        if [[ $line =~ \(([A-Za-z0-9._-]+)\) ]]; then
          key=${BASH_REMATCH[1]}
        fi
        summary=${line:0:160}
        summary=${summary//$'\t'/ }
        printf '%s\t%s\t%s\t%s\n' "$stem/$key" "$key" "$summary" "$rel"
      fi
    done < "$file"
  done
}

tsv_to_json() {
  jq -R -s -c '
    [ split("\n")[]
      | select(length > 0)
      | split("\t")
      | select(length >= 4)
      | {id:.[0], key:.[1], verb:"lock-open", summary:.[2], source:"decision-lock", file:.[3]}
    ]
  '
}

picks_json=$(list_open_tsv "$decisions_dir" "${decision_files[@]+"${decision_files[@]}"}" | tsv_to_json) \
  || structural "could not list open lock-file picks"

if [ "$list_open" -eq 1 ]; then
  printf '%s\n' "$picks_json" | jq .
  exit 0
fi

[ -n "$input" ] || structural "missing receipt --input"
[ -e "$input" ] || structural "missing receipt $input"
[ -f "$input" ] && [ ! -L "$input" ] || structural "receipt is not a regular file: $input"
[ -s "$input" ] || structural "empty receipt $input"

load_receipt_json() {
  local path=$1
  case "$path" in
    *.json)
      jq -e 'type == "object"' "$path" >/dev/null \
        || structural "receipt JSON root must be an object"
      jq -c '.' "$path"
      ;;
    *)
      local text lower
      text=$(cat "$path")
      lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
      case "$lower" in
        *stow*|*reset*) ;;
        *) structural "prose receipt has no stow/reset language" ;;
      esac
      local reset_safe=false
      case "$lower" in
        *'not safe to reset'*) reset_safe=false ;;
        *'safe to reset'*) reset_safe=true ;;
      esac
      jq -n --argjson reset_safe "$reset_safe" --arg text "$text" '
        {
          reset_safe:$reset_safe,
          remaining_session_picks:[
            $text | scan("(?i)(?:still open|review pick is still open|open:)[: \\t]+([^\\n]+)") | .[0]
          ],
          source:"prose"
        }
      '
      ;;
  esac
}

receipt_json=$(load_receipt_json "$input") || exit 2
jq -e 'has("reset_safe")' >/dev/null <<<"$receipt_json" \
  || structural "receipt missing reset_safe"
reset_type=$(jq -r '.reset_safe | type' <<<"$receipt_json")
[ "$reset_type" = "boolean" ] || structural "reset_safe must be boolean"
reset_safe=$(jq -r '.reset_safe' <<<"$receipt_json")
remaining_json=$(jq -c '.remaining_session_picks // []' <<<"$receipt_json")
jq -e 'type == "array"' >/dev/null <<<"$remaining_json" \
  || structural "remaining_session_picks must be a list"

snapshot_rows='null'
rule_wanted() {
  local want=$1 r
  for r in "${selected[@]}"; do
    [ "$r" = "$want" ] && return 0
  done
  return 1
}

if rule_wanted R-bearings-lists-open-locks; then
  if [ -z "$snapshot" ]; then
    if [ "$expect_rule" = "R-bearings-lists-open-locks" ]; then
      structural "R-bearings-lists-open-locks requires --snapshot"
    fi
  else
    [ -e "$snapshot" ] || structural "missing snapshot $snapshot"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || structural "snapshot is not a regular file: $snapshot"
    [ -s "$snapshot" ] || structural "empty snapshot $snapshot"
    jq -e 'type == "object"' "$snapshot" >/dev/null \
      || structural "snapshot JSON root must be an object"
    jq -e 'has("decisions_open")' "$snapshot" >/dev/null \
      || structural "snapshot missing decisions_open"
    jq -e '.decisions_open | type == "array"' "$snapshot" >/dev/null \
      || structural "snapshot decisions_open must be a list"
    snapshot_rows=$(jq -c '.decisions_open' "$snapshot")
  fi
elif [ -n "$snapshot" ]; then
  [ -e "$snapshot" ] || structural "missing snapshot $snapshot"
  [ -s "$snapshot" ] || structural "empty snapshot $snapshot"
  snapshot_rows=$(jq -c '.decisions_open' "$snapshot")
fi

run_stow=0
run_bearings=0
rule_wanted R-stow-open-lock && run_stow=1
rule_wanted R-bearings-lists-open-locks && [ "$snapshot_rows" != "null" ] && run_bearings=1

findings=$(jq -n \
  --argjson picks "$picks_json" \
  --argjson remaining "$remaining_json" \
  --argjson snapshot_rows "$snapshot_rows" \
  --argjson reset_safe "$reset_safe" \
  --argjson run_stow "$run_stow" \
  --argjson run_bearings "$run_bearings" '
  def norm: tostring | gsub("\\s+"; " ") | ascii_downcase;
  def listed($pick):
    ([ $pick.id, $pick.key ] | map(norm)) as $tokens
    | any($remaining[];
        (norm) as $item
        | ($item != "") and (($tokens | index($item)) != null));
  def snap_lists($pick):
    ($pick.id | norm) as $pid
    | any($snapshot_rows[];
        ((.verb // "") | tostring) == "lock-open"
        and (
          ((.id // "") | tostring | norm) as $id
          | ($id == $pid) or ($id | endswith("/" + $pid))
        ));
  [ if $run_stow == 1 and $reset_safe then
      $picks[]
      | select(listed(.) | not)
      | "R-stow-open-lock-unlisted: reset_safe is true while \(.file) marks \(.key) open and the receipt does not list that pick"
    else empty end,
    if $run_bearings == 1 then
      $picks[]
      | select(snap_lists(.) | not)
      | "R-bearings-lists-open-locks-omitted: snapshot decisions_open omits lock-file pick \(.id)"
    else empty end
  ]
')

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
