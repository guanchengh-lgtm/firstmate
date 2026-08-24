#!/usr/bin/env bash
# Check completed multi-task programs for durable standing source-of-truth pointers.
#
# Usage: fm-sot-pointer-check.sh [--strict] [--registry <path>]
#          [--expect-rule <rule-id> --expect-count <count>]
#
# Registry lookup uses the first effective ordinary registry when --registry is
# absent: $FM_HOME/data/sot-programs.tsv, then $FM_HOME/config/sot-programs.tsv.
# An empty or comment-only data file therefore cannot shadow populated config.
#
# Each non-comment row is tab-separated:
#   program_id <TAB> needle_regex <TAB> source_task_id,source_task_id,...
#     [<TAB> superseded_hold_id,superseded_hold_id,...]
#
# A row is enforced only after every source task has one authoritative task row
# and every source row is checked Done in data/done-archive.md or data/backlog.md.
# The ERE needle is matched against data/captain.md and regular files directly
# under data/decisions/. R-SOT-POINTER reports when completed sources lack that
# pointer. When the optional fourth field is present, R-SOT-SUPERSEDED-HOLD also
# reports each named captain hold that is not validly bound to the later
# authority. The binding must be a revalidated `fm-captain-hold.sh state`
# supersession whose exact decision file matches the pointer and whose exact
# shipped task is one of the row's source task ids.
#
# Registry syntax, duplicate identities, ERE syntax, task identity, hold shape,
# and readable input surfaces are structural requirements. Any structural
# failure prints one SOT_GAP registry-invalid line and exits 2 before findings
# are printed. Findings exit 1 only under --strict. Default detect-only mode
# prints findings and exits 0 so session-start can surface them without blocking.
# An absent implicit registry or an empty registry remains silent success.
#
# Exact regression mode requires both --expect-rule and --expect-count. It exits
# 0 only when that rule count and the total finding count both equal the expected
# count, so an unexpected second rule cannot hide behind a matching selected
# count. It exits 1 on a count mismatch and retains structural exit 2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

strict=0
registry=
expect_rule=
expect_count=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)
      strict=1
      shift
      ;;
    --registry)
      [ "$#" -ge 2 ] || {
        echo "error: --registry requires a path" >&2
        exit 2
      }
      registry=$2
      shift 2
      ;;
    --expect-rule)
      [ "$#" -ge 2 ] || {
        echo "error: --expect-rule requires a rule id" >&2
        exit 2
      }
      expect_rule=$2
      shift 2
      ;;
    --expect-count)
      [ "$#" -ge 2 ] || {
        echo "error: --expect-count requires a count" >&2
        exit 2
      }
      expect_count=$2
      shift 2
      ;;
    --help|-h)
      sed -n '2,34p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$expect_rule" in
  '')
    [ -z "$expect_count" ] || {
      echo "error: --expect-count requires --expect-rule" >&2
      exit 2
    }
    ;;
  R-SOT-POINTER|R-SOT-SUPERSEDED-HOLD)
    case "$expect_count" in
      ''|*[!0-9]*)
        echo "error: --expect-rule requires a non-negative integer --expect-count" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "error: unknown rule id: $expect_rule" >&2
    exit 2
    ;;
esac

registry_has_rows() {  # <path>
  awk '
    {
      row = $0
      sub(/^[[:space:]]*/, "", row)
      if (row != "" && row !~ /^#/) found = 1
    }
    END { exit !found }
  ' "$1"
}

if [ -z "$registry" ]; then
  data_registry="$DATA/sot-programs.tsv"
  config_registry="$CONFIG/sot-programs.tsv"
  for candidate in "$data_registry" "$config_registry"; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    if [ ! -f "$candidate" ] || [ -L "$candidate" ] || [ ! -r "$candidate" ]; then
      registry=$candidate
      break
    fi
    if registry_has_rows "$candidate"; then
      registry=$candidate
      break
    fi
  done
  [ -n "$registry" ] || exit 0
fi

if [ ! -f "$registry" ] || [ -L "$registry" ]; then
  printf 'SOT_GAP: registry invalid - path is not a regular non-symlink file: %s\n' "$registry"
  exit 2
fi
[ -r "$registry" ] || {
  printf 'SOT_GAP: registry invalid - path is not readable: %s\n' "$registry"
  exit 2
}
[ -s "$registry" ] || exit 0

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-sot-pointer-check.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM
normalized="$tmp_dir/registry.tsv"
seen_programs="$tmp_dir/seen-programs"
seen_holds="$tmp_dir/seen-holds"
findings="$tmp_dir/findings.tsv"
pointer_blob="$tmp_dir/pointers"
: > "$normalized"
: > "$seen_programs"
: > "$seen_holds"
: > "$findings"
: > "$pointer_blob"

trim_space() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

fatal_registry() {
  printf 'SOT_GAP: registry invalid - %s\n' "$*"
  exit 2
}

validate_slug() {
  local label=$1 value=$2 line_no=$3
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fatal_registry "line $line_no has invalid $label: $value" ;;
  esac
}

validate_regex() {
  local regex=$1 line_no=$2 rc
  set +e
  printf '' | grep -E -- "$regex" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -le 1 ] || fatal_registry "line $line_no has invalid ERE: $regex"
}

validate_csv() {
  local label=$1 csv=$2 line_no=$3 value trimmed seen=''
  local -a values
  case "$csv" in
    ''|,*|*,|*,,*) fatal_registry "line $line_no has malformed $label list: $csv" ;;
  esac
  IFS=, read -r -a values <<< "$csv"
  [ "${#values[@]}" -gt 0 ] || fatal_registry "line $line_no has empty $label"
  for value in "${values[@]}"; do
    trimmed=$(trim_space "$value")
    [ "$trimmed" = "$value" ] || fatal_registry "line $line_no has whitespace around $label: $value"
    validate_slug "$label" "$trimmed" "$line_no"
    case ",$seen," in
      *",$trimmed,"*) fatal_registry "line $line_no repeats $label: $trimmed" ;;
    esac
    seen="${seen}${seen:+,}$trimmed"
  done
  VALIDATED_CSV=$seen
}

line_no=0
while IFS= read -r row || [ -n "$row" ]; do
  line_no=$((line_no + 1))
  trimmed_row=$(trim_space "$row")
  case "$trimmed_row" in
    ''|\#*) continue ;;
  esac

  tab_count=$(awk -F '\t' '{ print NF - 1 }' <<< "$row")
  case "$tab_count" in
    2|3) : ;;
    *) fatal_registry "line $line_no must contain exactly 3 or 4 tab-separated fields" ;;
  esac

  program_id=${row%%$'\t'*}
  remainder=${row#*$'\t'}
  needle_regex=${remainder%%$'\t'*}
  remainder=${remainder#*$'\t'}
  if [ "$tab_count" -eq 3 ]; then
    source_task_ids=${remainder%%$'\t'*}
    superseded_hold_ids=${remainder#*$'\t'}
  else
    source_task_ids=$remainder
    superseded_hold_ids=
  fi

  program_id=$(trim_space "$program_id")
  needle_regex=$(trim_space "$needle_regex")
  source_task_ids=$(trim_space "$source_task_ids")
  superseded_hold_ids=$(trim_space "$superseded_hold_ids")
  validate_slug program_id "$program_id" "$line_no"
  [ -n "$needle_regex" ] || fatal_registry "line $line_no has an empty needle_regex"
  validate_regex "$needle_regex" "$line_no"
  validate_csv source_task_id "$source_task_ids" "$line_no"
  source_task_ids=$VALIDATED_CSV
  if [ "$tab_count" -eq 3 ]; then
    [ -n "$superseded_hold_ids" ] \
      || fatal_registry "line $line_no has an empty superseded_hold_id field"
    validate_csv superseded_hold_id "$superseded_hold_ids" "$line_no"
    superseded_hold_ids=$VALIDATED_CSV
  fi

  grep -Fxq -- "$program_id" "$seen_programs" \
    && fatal_registry "line $line_no repeats program_id: $program_id"
  printf '%s\n' "$program_id" >> "$seen_programs"
  if [ -n "$superseded_hold_ids" ]; then
    IFS=, read -r -a hold_ids <<< "$superseded_hold_ids"
    for hold_id in "${hold_ids[@]}"; do
      grep -Fxq -- "$hold_id" "$seen_holds" \
        && fatal_registry "line $line_no repeats superseded_hold_id across programs: $hold_id"
      printf '%s\n' "$hold_id" >> "$seen_holds"
    done
  fi
  printf '%s\t%s\t%s\t%s\n' \
    "$program_id" "$needle_regex" "$source_task_ids" "$superseded_hold_ids" >> "$normalized"
done < "$registry"

[ -s "$normalized" ] || exit 0
[ -d "$DATA" ] && [ ! -L "$DATA" ] \
  || fatal_registry "data directory is absent or a symlink: $DATA"

task_files=()
for task_file in "$DATA/done-archive.md" "$DATA/backlog.md"; do
  if [ -e "$task_file" ] || [ -L "$task_file" ]; then
    [ -f "$task_file" ] && [ ! -L "$task_file" ] && [ -r "$task_file" ] \
      || fatal_registry "task source is not a readable regular non-symlink file: $task_file"
    task_files+=("$task_file")
  fi
done
[ "${#task_files[@]}" -gt 0 ] \
  || fatal_registry "neither data/done-archive.md nor data/backlog.md is readable"

if [ -e "$DATA/captain.md" ]; then
  [ -f "$DATA/captain.md" ] && [ ! -L "$DATA/captain.md" ] && [ -r "$DATA/captain.md" ] \
    || fatal_registry "pointer source is not a readable regular non-symlink file: $DATA/captain.md"
  cat "$DATA/captain.md" >> "$pointer_blob"
  printf '\n' >> "$pointer_blob"
fi
if [ -e "$DATA/decisions" ]; then
  [ -d "$DATA/decisions" ] && [ ! -L "$DATA/decisions" ] && [ -r "$DATA/decisions" ] \
    || fatal_registry "pointer source is not a readable non-symlink directory: $DATA/decisions"
  shopt -s nullglob dotglob
  for decision_file in "$DATA/decisions"/*; do
    [ -e "$decision_file" ] || [ -L "$decision_file" ] || continue
    [ -f "$decision_file" ] && [ ! -L "$decision_file" ] && [ -r "$decision_file" ] \
      || fatal_registry "decision source is not a readable regular non-symlink file: $decision_file"
    cat "$decision_file" >> "$pointer_blob"
    printf '\n' >> "$pointer_blob"
  done
  shopt -u nullglob dotglob
fi

task_rows() {
  local task_id=$1 task_file
  for task_file in "${task_files[@]}"; do
    awk -v task_id="$task_id" \
      '$0 ~ /^- \[x\] / || $0 ~ /^- \[ \] / {
         id = ($0 ~ /^- \[x\] / ? $3 : $4)
         if (id == task_id) print FILENAME "\t" $0
       }' "$task_file"
  done
}

task_row_count() {
  task_rows "$1" | awk 'END { print NR + 0 }'
}

task_is_done() {
  local task_id=$1
  task_rows "$task_id" | awk -F '\t' '
    {
      row = $0
      sub(/^[^\t]*\t/, "", row)
      if (row ~ /^- \[x\] /) done = 1
    }
    END { exit !done }
  '
}

hold_state() {
  local hold_id=$1 output rc
  set +e
  output=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-captain-hold.sh" state "$hold_id" --binding 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fatal_registry "durable state for $hold_id is invalid: $output"
  IFS=$'\t' read -r HOLD_STATE HOLD_DECISION_PATH HOLD_SHIPPED_TASK extra <<< "$output"
  [ -n "$HOLD_STATE" ] && [ -z "${extra:-}" ] \
    || fatal_registry "durable state for $hold_id returned malformed binding data"
  case "$HOLD_STATE" in
    open|resolved)
      [ "$HOLD_DECISION_PATH" = - ] && [ "$HOLD_SHIPPED_TASK" = - ] \
        || fatal_registry "durable state for $hold_id returned unexpected binding data"
      ;;
    superseded)
      [ "$HOLD_DECISION_PATH" != - ] && [ "$HOLD_SHIPPED_TASK" != - ] \
        || fatal_registry "durable state for $hold_id omitted supersession binding data"
      ;;
    *) fatal_registry "durable state for $hold_id is unknown: $HOLD_STATE" ;;
  esac
}

while IFS=$'\t' read -r program_id needle_regex source_task_ids superseded_hold_ids; do
  IFS=, read -r -a source_ids <<< "$source_task_ids"
  for source_id in "${source_ids[@]}"; do
    count=$(task_row_count "$source_id")
    [ "$count" -eq 1 ] \
      || fatal_registry "source_task_id $source_id has $count authoritative task rows"
  done
  if [ -n "$superseded_hold_ids" ]; then
    IFS=, read -r -a hold_ids <<< "$superseded_hold_ids"
    for hold_id in "${hold_ids[@]}"; do
      count=$(task_row_count "$hold_id")
      [ "$count" -eq 1 ] \
        || fatal_registry "superseded_hold_id $hold_id has $count authoritative task rows"
      hold_state "$hold_id"
    done
  fi
done < "$normalized"

all_sources_done() {
  local source_csv=$1 source_id
  local -a source_ids
  IFS=, read -r -a source_ids <<< "$source_csv"
  for source_id in ${source_ids[@]+"${source_ids[@]}"}; do
    task_is_done "$source_id" || return 1
  done
}

add_finding() {
  printf '%s\t%s\n' "$1" "$2" >> "$findings"
}

while IFS=$'\t' read -r program_id needle_regex source_task_ids superseded_hold_ids; do
  all_sources_done "$source_task_ids" || continue
  if ! grep -E -q -- "$needle_regex" "$pointer_blob"; then
    add_finding R-SOT-POINTER \
      "SOT_GAP: $program_id - sources Done but no standing pointer matching /$needle_regex/ in captain.md|decisions/"
  fi
  [ -n "$superseded_hold_ids" ] || continue
  IFS=, read -r -a hold_ids <<< "$superseded_hold_ids"
  for hold_id in "${hold_ids[@]}"; do
    hold_state "$hold_id"
    if [ "$HOLD_STATE" != superseded ]; then
      add_finding R-SOT-SUPERSEDED-HOLD \
        "SOT_GAP: $program_id - captain hold $hold_id is $HOLD_STATE, not bound to the later authority"
      continue
    fi
    case ",$source_task_ids," in
      *",$HOLD_SHIPPED_TASK,"*) : ;;
      *)
        add_finding R-SOT-SUPERSEDED-HOLD \
          "SOT_GAP: $program_id - captain hold $hold_id binds unrelated shipped task $HOLD_SHIPPED_TASK"
        continue
        ;;
    esac
    if ! grep -E -q -- "$needle_regex" "$FM_HOME/$HOLD_DECISION_PATH"; then
      add_finding R-SOT-SUPERSEDED-HOLD \
        "SOT_GAP: $program_id - captain hold $hold_id binds decision $HOLD_DECISION_PATH without /$needle_regex/"
    fi
  done
done < "$normalized"

if [ -s "$findings" ]; then
  cut -f2- "$findings"
fi

if [ -n "$expect_rule" ]; then
  observed=$(awk -F '\t' -v rule="$expect_rule" '$1 == rule { count++ } END { print count + 0 }' "$findings")
  observed_total=$(awk 'END { print NR + 0 }' "$findings")
  if [ "$observed" -ne "$expect_count" ] || [ "$observed_total" -ne "$expect_count" ]; then
    printf 'SOT_EXPECTATION: %s expected %s finding(s) and %s total, observed %s and %s total\n' \
      "$expect_rule" "$expect_count" "$expect_count" "$observed" "$observed_total" >&2
    exit 1
  fi
  exit 0
fi

if [ "$strict" -eq 1 ] && [ -s "$findings" ]; then
  exit 1
fi
exit 0
