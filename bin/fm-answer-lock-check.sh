#!/usr/bin/env bash
# Check that Map 2 ticket closes agree with dated lock files, and that a
# ticket does not stay OPEN after an Answer pick.
#
# Usage: fm-answer-lock-check.sh [--claude]
#          [--tickets-dir <dir>] [--decisions-dir <dir>]
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#
# Matcher mode (no --claude): findings exit 1, structural failures exit 2,
# clean exit 0. --claude is Stop mode: Stop-hook JSON on stdin, empty stdin
# is inert exit 0, findings print the refusal banner and exit 2.
#
# Gather is only data/wf-map2-v2/tickets/*.md under FM_HOME (or
# --tickets-dir). Never walk all of data/. Never include
# data/wf-map2-loops/. Later maps opt in by adding a path to this header's
# gather list; wf-map2-loops stays grandfathered. Only ordinary *.md files
# in that directory are scanned, not nested paths or symlinks.
#
# Default rules:
#   R-close-no-lock     status: starts with CLOSED, the file has ## Answer,
#                       and there is no Lock `data/decisions/<name>.md`
#                       token inside ## Answer, or that pointer is not an
#                       ordinary file under FM_HOME. Bare data/decisions/
#                       mentions and tokens outside ## Answer are ignored.
#                       Ship tickets with no ## Answer are exempt.
#   R-close-undated     status: CLOSED with no YYYY-MM-DD token on that
#                       line. Dated means that token on the status line and
#                       in the lock filename; the two dates are not matched.
#   R-pick-still-open   ## Answer whose first bold span is a pick (starts
#                       with A-Z, optional ".", then end or whitespace:
#                       **A.**, **D.**, **A**, **A. No ship.**) and
#                       status: is OPEN.
#   R-lock-still-open   a CLOSED ticket's ordinary pointed-to lock has no
#                       **Pick:** line, or the open-lock reader reports it.
#                       Every ticket is scanned. The reader runs once when
#                       needed and scans only pointed locks with **Pick:**.
#
# Exact-count regression requires both --expect-rule and --expect-count and
# exits 0 only when that rule count and the total finding count both equal
# the expected count. --expect-count 0, empty --rules, and unknown rule ids
# are structural.
#
# Stop refusal names only two escapes: point the ticket at the real lock,
# or revert status: to OPEN. It never invites inventing a lock file.
#
# LIMITS: an answer that produced no write is invisible. Same-turn is not
# same-instant. Pick text and pointer identity are not judged. Map-level
# locks without a ticket are outside the gather. Non-Stop writes and
# payloads with no guard run stay inert.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
OPEN_LOCK_READER="$SCRIPT_DIR/fm-stow-open-lock-check.sh"
GATHER_REL="data/wf-map2-v2/tickets"

claude_mode=0
tickets_dir=
decisions_dir=
expect_rule=
expect_count=
rules="R-close-no-lock,R-close-undated,R-pick-still-open,R-lock-still-open"

usage() {
  sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
}

structural() {
  printf 'structural: %s\n' "$*" >&2
  exit 2
}

KNOWN_RULES='R-close-no-lock R-close-undated R-pick-still-open R-lock-still-open'

is_known_rule() {
  local want=$1 r
  for r in $KNOWN_RULES; do
    [ "$r" = "$want" ] && return 0
  done
  return 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude)
      claude_mode=1
      shift
      ;;
    --tickets-dir)
      [ "$#" -ge 2 ] || structural "--tickets-dir requires a path"
      tickets_dir=$2
      shift 2
      ;;
    --decisions-dir)
      [ "$#" -ge 2 ] || structural "--decisions-dir requires a path"
      decisions_dir=$2
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

if [ "$claude_mode" -eq 1 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
fi

command -v jq >/dev/null 2>&1 || structural "jq not found"

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

rule_wanted() {
  local want=$1 r
  for r in "${selected[@]+"${selected[@]}"}"; do
    [ "$r" = "$want" ] && return 0
  done
  return 1
}

if [ -z "$tickets_dir" ]; then
  tickets_dir="$DATA/wf-map2-v2/tickets"
fi
if [ -z "$decisions_dir" ]; then
  decisions_dir="$DATA/decisions"
fi

if [ ! -e "$tickets_dir" ]; then
  exit 0
fi
[ -d "$tickets_dir" ] && [ ! -L "$tickets_dir" ] \
  || structural "tickets path is not a regular directory: $tickets_dir"

ordinary_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

parse_ticket() {
  local file=$1 line body='' bold='' status_seen=0 in_answer=0 answer_done=0 body_started=0
  parsed_status_line=
  parsed_answered=0
  parsed_pointer=
  parsed_first_bold_pick=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$status_seen" -eq 0 ] && [[ $line == status:* ]]; then
      parsed_status_line=${line%$'\r'}
      status_seen=1
    fi
    if [ "$answer_done" -eq 0 ] \
      && [[ $line =~ ^##[[:blank:]]+Answer([[:blank:]]|$) ]]; then
      parsed_answered=1
      in_answer=1
      continue
    fi
    [ "$in_answer" -eq 1 ] || continue
    if [[ $line =~ ^##[[:blank:]] ]]; then
      in_answer=0
      answer_done=1
      continue
    fi
    if [ "$body_started" -eq 1 ]; then
      body+=$'\n'
    fi
    body+=$line
    body_started=1
  done < "$file"
  if [[ $body =~ Lock\ \`(data/decisions/[A-Za-z0-9._-]+\.md)\` ]]; then
    parsed_pointer=${BASH_REMATCH[1]}
  fi
  if [[ $body =~ \*\*([^*]+)\*\* ]]; then
    bold=${BASH_REMATCH[1]}
    bold=${bold#"${bold%%[![:space:]]*}"}
    bold=${bold%"${bold##*[![:space:]]}"}
    if [[ $bold =~ ^[A-Z](\.([[:space:]].*)?)?$ ]]; then
      parsed_first_bold_pick=1
    fi
  fi
}

lock_has_pick() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'**Pick:**'*) return 0 ;;
    esac
  done < "$1"
  return 1
}

ticket_rel() {
  printf '%s/%s' "$GATHER_REL" "${1##*/}"
}

lock_listed_open() {
  local pointer=$1 open_file
  while IFS= read -r open_file; do
    [ "$open_file" = "$pointer" ] && return 0
  done <<< "$open_files"
  return 1
}

load_open_json() {
  local reader_json
  [ -x "$OPEN_LOCK_READER" ] || structural "missing open-lock reader $OPEN_LOCK_READER"
  reader_json=$("$OPEN_LOCK_READER" --list-open --decisions-dir "$decisions_dir" "$@") \
    || structural "open-lock reader failed"
  open_files=$(printf '%s' "$reader_json" | jq -r \
    'if type == "array" then .[].file else error("not an array") end') \
    || structural "open-lock reader did not return a JSON array"
}

findings=()
pending_indexes=()
pending_pointers=()
pending_rels=()
reader_args=()
reader_names=' '
shopt -s nullglob
tickets=( "$tickets_dir"/*.md )
shopt -u nullglob

for file in "${tickets[@]+"${tickets[@]}"}"; do
  ordinary_file "$file" || continue
  rel=$(ticket_rel "$file")
  parse_ticket "$file"
  status_line=$parsed_status_line
  rest=${status_line#status:}
  rest=${rest#"${rest%%[![:space:]]*}"}
  closed=0
  open=0
  dated=0
  case "$rest" in
    CLOSED*) closed=1 ;;
    OPEN*) open=1 ;;
  esac
  if [[ $status_line =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    dated=1
  fi
  answered=$parsed_answered
  pointer=$parsed_pointer
  lock_path=
  lock_ok=0
  if [ -n "$pointer" ]; then
    lock_path="$decisions_dir/${pointer##*/}"
    if ordinary_file "$lock_path"; then
      lock_ok=1
    fi
  fi

  if rule_wanted R-close-no-lock && [ "$closed" -eq 1 ] && [ "$answered" -eq 1 ] \
    && [ "$lock_ok" -eq 0 ]; then
    findings+=("R-close-no-lock-missing: $rel has ## Answer but no ordinary lock file")
  fi
  if rule_wanted R-close-undated && [ "$closed" -eq 1 ] && [ "$dated" -eq 0 ]; then
    findings+=("R-close-undated-status: $rel status: CLOSED has no YYYY-MM-DD token")
  fi
  if rule_wanted R-pick-still-open && [ "$open" -eq 1 ] && [ "$answered" -eq 1 ] \
    && [ "$parsed_first_bold_pick" -eq 1 ]; then
    findings+=("R-pick-still-open-status: $rel has a pick in ## Answer while status: is OPEN")
  fi
  if rule_wanted R-lock-still-open && [ "$closed" -eq 1 ] && [ "$lock_ok" -eq 1 ]; then
    if ! lock_has_pick "$lock_path"; then
      findings+=("R-lock-still-open-file: $rel lock $pointer has no **Pick:** or is still open")
    else
      pending_indexes+=("${#findings[@]}")
      pending_pointers+=("$pointer")
      pending_rels+=("$rel")
      findings+=("")
      reader_name=${pointer##*/}
      case "$reader_names" in
        *" $reader_name "*) ;;
        *)
          reader_names+="$reader_name "
          reader_args+=(--file "$reader_name")
          ;;
      esac
    fi
  fi
done

if [ "${#pending_indexes[@]}" -gt 0 ]; then
  open_files=
  load_open_json "${reader_args[@]}"
  for ((pending=0; pending < ${#pending_indexes[@]}; pending++)); do
    index=${pending_indexes[$pending]}
    pointer=${pending_pointers[$pending]}
    rel=${pending_rels[$pending]}
    if lock_listed_open "$pointer"; then
      findings[index]="R-lock-still-open-file: $rel lock $pointer has no **Pick:** or is still open"
    else
      unset 'findings[index]'
    fi
  done
fi

print_banner() {
  local rule line
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  ANSWER-TIME LOCK REFUSED\n'
    for line in "${findings[@]+"${findings[@]}"}"; do
      printf '●  %s\n' "$line"
    done
    printf '●  Point the ticket at the real lock, or revert status: to OPEN.\n'
    printf '●%s\n' "$rule"
  } >&2
}

if [ -n "$expect_rule" ]; then
  prefix="${expect_rule}-"
  selected_count=0
  total=0
  for line in "${findings[@]+"${findings[@]}"}"; do
    total=$((total + 1))
    case "$line" in
      "$prefix"*) selected_count=$((selected_count + 1)) ;;
    esac
  done
  if [ "$selected_count" -ne "$expect_count" ] || [ "$total" -ne "$expect_count" ]; then
    printf 'regression: expected %s finding(s) and %s total, observed %s and %s total\n' \
      "$expect_count" "$expect_count" "$selected_count" "$total" >&2
    for line in "${findings[@]+"${findings[@]}"}"; do
      printf '%s\n' "$line" >&2
    done
    exit 1
  fi
  exit 0
fi

if [ "${#findings[@]}" -gt 0 ]; then
  if [ "$claude_mode" -eq 1 ]; then
    print_banner
    exit 2
  fi
  printf '%s\n' "${findings[@]}"
  exit 1
fi
exit 0
