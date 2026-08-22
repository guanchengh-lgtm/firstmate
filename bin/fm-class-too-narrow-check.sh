#!/usr/bin/env bash
# Check that a class claims file states a property, names two or more
# instances in different clothes, and is not named as one command or
# situation while those instances are a broader mechanism.
#
# Usage: fm-class-too-narrow-check.sh --input <claims.json>
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#
# --input is required except for --help. A missing or empty claims file,
# claims that are not a JSON object, unknown rule ids, empty --rules, and
# --expect-count 0 are structural failures, exit 2. Findings exit 1. Clean
# exit 0.
#
# Default rules:
#   R-property            claims.shape is a non-empty property phrase
#   R-two-clothes         claims.instances names two or more distinct clothes
#   R-broader-than-shape  a slash-command or ISO date in shape (or named_as /
#                         class_id / class) is missing from at least one instance
#
# Exact-count regression requires both --expect-rule and --expect-count and
# exits 0 only when that rule count and the total finding count both equal
# the expected count. There is no "the fixture must fail" inversion.
#
# LIMITS: English "broader than" cannot be 100%. This checker sees a slash-
# command or ISO date binder in the named shape that an instance does not
# share. It cannot see a class whose instance strings stay inside the named
# clothes while the true mechanism is still broader, and it cannot judge
# paraphrase.
set -euo pipefail

input=
expect_rule=
expect_count=
rules="R-property,R-two-clothes,R-broader-than-shape"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

structural() {
  printf 'structural: %s\n' "$*" >&2
  exit 2
}

KNOWN_RULES='R-property R-two-clothes R-broader-than-shape'

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

[ -n "$input" ] || structural "missing claims --input"
[ -e "$input" ] || structural "missing claims $input"
[ -f "$input" ] && [ ! -L "$input" ] || structural "claims path is not a regular file: $input"
[ -s "$input" ] || structural "empty claims $input"

jq -e 'type == "object"' "$input" >/dev/null \
  || structural "claims JSON root must be an object"

shape_type=$(jq -r '.shape | type' "$input")
case "$shape_type" in
  null) ;;
  string) ;;
  *) structural "claims.shape must be a string when present" ;;
esac

instances_type=$(jq -r '.instances | type' "$input")
case "$instances_type" in
  null) ;;
  array)
    jq -e '.instances | all(type == "string")' "$input" >/dev/null \
      || structural "claims.instances must be an array of strings"
    ;;
  *) structural "claims.instances must be an array when present" ;;
esac

for field in named_as class_id class; do
  field_type=$(jq -r --arg f "$field" '.[$f] | type' "$input")
  case "$field_type" in
    null|string) ;;
    *) structural "claims.$field must be a string when present" ;;
  esac
done

run_property=0
run_clothes=0
run_broader=0
for r in "${selected[@]+"${selected[@]}"}"; do
  case "$r" in
    R-property) run_property=1 ;;
    R-two-clothes) run_clothes=1 ;;
    R-broader-than-shape) run_broader=1 ;;
  esac
done

findings=$(jq -c \
  --argjson run_property "$run_property" \
  --argjson run_clothes "$run_clothes" \
  --argjson run_broader "$run_broader" '
  def trim:
    gsub("^[[:space:]]+"; "") | gsub("[[:space:]]+$"; "");
  def norm:
    ascii_downcase | gsub("[[:space:]]+"; " ") | trim;
  def strip_dates:
    gsub("20[0-9]{2}-[0-9]{2}-[0-9]{2}"; "");
  def word_has($tok):
    ($tok | ascii_downcase) as $k
    | test("(^|[^a-z0-9])" + $k + "([^a-z0-9]|$)"; "i");
  def slash_cmds:
    [scan("/[A-Za-z][A-Za-z0-9_-]*") | ltrimstr("/") | ascii_downcase];
  def dates_in:
    [scan("20[0-9]{2}-[0-9]{2}-[0-9]{2}")];
  def ident_binders:
    select(type == "string")
    | trim
    | select(test("^[A-Za-z][A-Za-z0-9_-]*$"))
    | ascii_downcase;
  def binders_from($text):
    if ($text | type) != "string" then
      []
    else
      (
        [($text | slash_cmds)[] | {kind: "command", token: .}]
        + [($text | dates_in)[] | {kind: "situation", token: .}]
      )
    end;
  def extra_ident:
    [(.named_as, .class_id, .class) | ident_binders | {kind: "command", token: .}];
  def extra_first_segment:
    [
      (.named_as, .class_id, .class)
      | ident_binders
      | select(contains("-"))
      | split("-")[0]
      | select(length > 0)
      | {kind: "command", token: .}
    ];
  def all_binders:
    (
      binders_from(.shape // "")
      + binders_from(.named_as // "")
      + binders_from(.class_id // "")
      + binders_from(.class // "")
      + extra_ident
      + extra_first_segment
    )
    | unique_by(.kind + "\t" + .token);

  . as $claims
  | (if ($claims.shape | type) == "string" then $claims.shape | trim else "" end) as $shape
  | (if ($claims.instances | type) == "array" then $claims.instances else [] end) as $instances
  | (all_binders) as $binders
  | [
      if $run_property == 1 then
        if $shape == "" then
          "R-property-missing: claims file has no property in shape"
        elif ($shape | test("[[:space:]]") | not) then
          "R-property-not-a-property: shape is a single token, not a property"
        else empty end
      else empty end,
      if $run_clothes == 1 then
        if ($instances | map(trim) | map(select(. != "")) | length) < 2 then
          "R-two-clothes-few: claims file names fewer than two instances"
        elif (
          $instances
          | map(strip_dates | norm)
          | map(select(. != ""))
          | unique
          | length
        ) < 2 then
          "R-two-clothes-same: after stripping dates, instances are not different clothes"
        else empty end
      else empty end,
      if $run_broader == 1 and ($binders | length) > 0 then
        range(0; $instances | length) as $i
        | $instances[$i]
        | select(type == "string")
        | . as $inst
        | select(
            any($binders[]; . as $b | ($inst | word_has($b.token)))
            | not
          )
        | "R-broader-than-shape-escaped: instance \($i + 1) does not share shape token(s): \($binders | map(.token) | unique | join(", "))"
      else empty end
    ]
' "$input") || structural "could not evaluate claims"

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
