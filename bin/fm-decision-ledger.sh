#!/usr/bin/env bash
# fm-decision-ledger.sh - render captain-facing decisions from tasks-axi state.
#
# Usage:
#   fm-decision-ledger.sh render [--home <FM_HOME>] [--out <path>] [--recent <count>]
#
# The default home is FM_HOME when set, otherwise the tracked Firstmate root.
# The default output is <home>/data/decision-ledger.md.
# Open captain decisions have owner captain and other work has owner eng.
# A note line `owner=eng|cos|captain` overrides that derived owner.
# A note line `acceptance-test=<text>` supplies the acceptance-test column.
# A ship item is decision-backed when its note contains `decision=<provenance>`.
# Open rows are unbounded and --recent bounds the combined decided/shipped tail.
# This command reads backlog state only through compatible tasks-axi list/show calls.
# It never reads or writes data/product-ideas.md and writes only the selected output.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

fail() {
  printf 'fm-decision-ledger: %s\n' "$*" >&2
  exit 1
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

decode_scalar() {  # <tasks-axi scalar>
  local value=$1
  case "$value" in
    \"*\")
      value=${value#\"}
      value=${value%\"}
      ;;
  esac
  value=${value//\\n/$'\n'}
  value=${value//\\r/}
  value=${value//\\\"/\"}
  value=${value//\\\\/$'\\'}
  printf '%s' "$value"
}

note_token() {  # <decoded-body> <key>
  local body=$1 key=$2 line value=''
  while IFS= read -r line; do
    line=${line%$'\r'}
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done <<< "$body"
  printf '%s' "$value"
}

trim() {  # <value>
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

markdown_cell() {  # <value>
  local value=$1
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  value=${value//$'\t'/ }
  value=${value//|/\\|}
  printf '%s' "$value"
}

artifact_field() {  # <tasks-axi links scalar>
  local links part value result=''
  links=$(decode_scalar "$1")
  case "$links" in none|'-'|'') printf '%s' '-'; return 0 ;; esac
  while IFS= read -r part; do
    case "$part" in
      pr:*) value=${part#pr:} ;;
      report:*) value=${part#report:} ;;
      doc:*) value=${part#doc:} ;;
      *) continue ;;
    esac
    case "$value" in
      https://*) ;;
      *://*) continue ;;
      /*|../*|*/../*|*/..|'') continue ;;
      *) ;;
    esac
    result="${result}${result:+<br>}${value}"
  done < <(printf '%s\n' "$links" | tr ',' '\n')
  [ -n "$result" ] || result=-
  printf '%s' "$result"
}

title_without_artifacts() {  # <title> <artifact-field>
  local title=$1 artifacts=$2 artifact
  title=$(decode_scalar "$title")
  if [ "$artifacts" != - ]; then
    while IFS= read -r artifact; do
      title=${title//"$artifact"/}
    done < <(printf '%s\n' "$artifacts" | sed 's/<br>/\n/g')
  fi
  trim "$title"
}

tasks_axi() {
  (cd "$HOME_PATH" && tasks-axi "$@")
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help) usage; exit 0 ;;
  render) shift ;;
  *) usage >&2; exit 2 ;;
esac

HOME_PATH=${FM_HOME:-$FM_ROOT}
OUT_PATH=''
RECENT_LIMIT=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      shift
      [ "$#" -gt 0 ] || fail "--home requires a path"
      HOME_PATH=$1
      ;;
    --out)
      shift
      [ "$#" -gt 0 ] || fail "--out requires a path"
      OUT_PATH=$1
      ;;
    --recent)
      shift
      [ "$#" -gt 0 ] || fail "--recent requires a count"
      RECENT_LIMIT=$1
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

case "$RECENT_LIMIT" in ''|*[!0-9]*) fail "--recent must be a non-negative integer" ;; esac
[ -d "$HOME_PATH" ] || fail "home does not exist: $HOME_PATH"
HOME_PATH=$(cd "$HOME_PATH" && pwd -P)
BACKLOG_PATH="$HOME_PATH/data/backlog.md"
[ -f "$HOME_PATH/.tasks.toml" ] || fail "tasks-axi config is absent: $HOME_PATH/.tasks.toml"
[ -f "$BACKLOG_PATH" ] || fail "backlog is absent: $BACKLOG_PATH"

if [ -z "$OUT_PATH" ]; then
  OUT_PATH="$HOME_PATH/data/decision-ledger.md"
fi
OUT_DIR=$(dirname "$OUT_PATH")
OUT_NAME=$(basename "$OUT_PATH")
[ -d "$OUT_DIR" ] || fail "output directory does not exist: $OUT_DIR"
OUT_PATH="$(cd "$OUT_DIR" && pwd -P)/$OUT_NAME"
[ ! -L "$OUT_PATH" ] || fail "output must not be a symbolic link"
[ ! "$OUT_PATH" -ef "$BACKLOG_PATH" ] || fail "output must not overwrite backlog state"
if [ -e "$HOME_PATH/data/product-ideas.md" ]; then
  [ ! "$OUT_PATH" -ef "$HOME_PATH/data/product-ideas.md" ] || fail "output must not be data/product-ideas.md"
else
  [ "$OUT_PATH" != "$HOME_PATH/data/product-ideas.md" ] || fail "output must not be data/product-ideas.md"
fi

fm_tasks_axi_compatible || fail "compatible tasks-axi is required"

LIST_OUTPUT=$(tasks_axi list --file "$BACKLOG_PATH" --fields created --limit 1000000) \
  || fail "cannot read backlog through tasks-axi"
printf '%s\n' "$LIST_OUTPUT" | grep '^tasks\[[0-9][0-9]*\]{' >/dev/null \
  || printf '%s\n' "$LIST_OUTPUT" | grep '^tasks: 0 tasks in this backlog$' >/dev/null \
  || fail "tasks-axi returned an unsupported list shape"

OPEN_ROWS=()
RECENT_ROWS=()
while IFS= read -r id; do
  [ -n "$id" ] || continue
  SHOW=$(tasks_axi show "$id" --full) || fail "cannot read backlog item through tasks-axi: $id"
  state=$(show_field "$SHOW" state)
  kind=$(show_field "$SHOW" kind)
  held=$(show_field "$SHOW" held)
  hold_kind=$(show_field "$SHOW" hold_kind)
  body=$(decode_scalar "$(show_field "$SHOW" body)")
  provenance=$(note_token "$body" decision)

  admitted=0
  if [ "$kind" = captain ]; then
    admitted=1
  elif [ "$state" != "done" ] && [ "$held" = yes ] && [ "$hold_kind" = captain ]; then
    admitted=1
  elif [ "$kind" = ship ] && { [ "$state" = queued ] || [ "$state" = in_flight ]; } && [ -n "$provenance" ]; then
    admitted=1
  fi
  [ "$admitted" -eq 1 ] || continue

  artifact=$(artifact_field "$(show_field "$SHOW" links)")
  if [ "$state" != "done" ] && { [ "$kind" = captain ] || { [ "$held" = yes ] && [ "$hold_kind" = captain ]; }; }; then
    status=open
    rank=0
  elif [ "$state" = "done" ] && [ "$artifact" != - ]; then
    status=shipped
    rank=2
  else
    status=decided
    rank=1
  fi

  owner=$(note_token "$body" owner)
  if [ -n "$owner" ]; then
    case "$owner" in eng|cos|captain) ;; *) fail "invalid owner override on $id: $owner" ;; esac
  elif [ "$status" = open ]; then
    owner=captain
  else
    owner=eng
  fi

  acceptance=$(note_token "$body" acceptance-test)
  [ -n "$acceptance" ] || acceptance=-
  decision=$(title_without_artifacts "$(show_field "$SHOW" title)" "$artifact")
  [ -n "$decision" ] || decision=$id
  if [ "$state" = "done" ]; then
    date=$(show_field "$SHOW" closed)
  else
    date=$(show_field "$SHOW" created)
  fi
  case "$date" in ''|'-') date=0000-00-00 ;; esac

  decision=$(markdown_cell "$decision")
  acceptance=$(markdown_cell "$acceptance")
  artifact=$(markdown_cell "$artifact")
  row="$rank"$'\t'"$date"$'\t'"$id"$'\t'"$decision"$'\t'"$owner"$'\t'"$status"$'\t'"$acceptance"$'\t'"$artifact"
  if [ "$status" = open ]; then
    OPEN_ROWS+=("$row")
  else
    RECENT_ROWS+=("$row")
  fi
done < <(printf '%s\n' "$LIST_OUTPUT" | sed -n 's/^  \([A-Za-z0-9._-][A-Za-z0-9._-]*\),.*/\1/p')

SELECTED_RECENT=''
if [ "$RECENT_LIMIT" -gt 0 ] && [ "${#RECENT_ROWS[@]}" -gt 0 ]; then
  SELECTED_RECENT=$(printf '%s\n' "${RECENT_ROWS[@]}" | LC_ALL=C sort -t $'\t' -k2,2r -k3,3 | head -n "$RECENT_LIMIT")
fi

ALL_ROWS=$(
  if [ "${#OPEN_ROWS[@]}" -gt 0 ]; then printf '%s\n' "${OPEN_ROWS[@]}"; fi
  if [ -n "$SELECTED_RECENT" ]; then printf '%s\n' "$SELECTED_RECENT"; fi
)

render_table() {
  local row_decision row_owner row_status row_acceptance row_artifact
  printf '%s\n' '| Decision | Owner | Status | Acceptance test | PR / artifact |'
  printf '%s\n' '| --- | --- | --- | --- | --- |'
  [ -n "$ALL_ROWS" ] || return 0
  while IFS=$'\t' read -r _ _ _ row_decision row_owner row_status row_acceptance row_artifact; do
    printf '| %s | %s | %s | %s | %s |\n' \
      "$row_decision" "$row_owner" "$row_status" "$row_acceptance" "$row_artifact"
  done < <(printf '%s\n' "$ALL_ROWS" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2r -k3,3)
}

render_table > "$OUT_PATH"
