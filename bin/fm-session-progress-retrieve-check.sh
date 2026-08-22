#!/usr/bin/env bash
# Check that a session-start or Bearings retrieve surface includes the
# prior-session fold bar: live jobs, open picks, and captain lock words.
#
# Usage: fm-session-progress-retrieve-check.sh
#          --prior-log <jsonl> --retrieve <file>
#          [--home <dir>]
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#
# This is a refuse-hook plus retrieve path. It does not write a progress file.
# It runs bin/fm-prior-session-fold.sh on --prior-log (old session talk on disk)
# and requires --retrieve to contain each extracted bar item.
# Session-start and Bearings are the retrieve surfaces.
# Captain picks written to data/decisions/ at answer time stay that store.
#
# --prior-log and --retrieve are required. Missing, empty, or non-regular
# inputs, unknown rule ids, empty --rules, --expect-count 0, and a prior log
# that does not yield a parsed fold are structural failures, exit 2.
# Findings exit 1. Clean exit 0.
#
# Default rules:
#   R-retrieve-omitted   retrieve omits a live job, open pick, or captain
#                        lock-word the fold already extracted
#
# Exact-count regression requires both --expect-rule and --expect-count and
# exits 0 only when that rule count and the total finding count both equal
# the expected count.
#
# LIMITS: asides outside that bar are not covered.
# Unverified pick context is not in the bar.
# A pick never written to talk or a decision file cannot be seen.
# This checker does not scrape transcripts itself; it uses the fold.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
FOLD="$SCRIPT_DIR/fm-prior-session-fold.sh"

prior_log=
retrieve=
home_arg=
expect_rule=
expect_count=
rules="R-retrieve-omitted"

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
}

structural() {
  printf 'structural: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prior-log)
      [ "$#" -ge 2 ] || structural "--prior-log requires a path"
      prior_log=$2
      shift 2
      ;;
    --retrieve)
      [ "$#" -ge 2 ] || structural "--retrieve requires a path"
      retrieve=$2
      shift 2
      ;;
    --home)
      [ "$#" -ge 2 ] || structural "--home requires a path"
      home_arg=$2
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
[ -x "$FOLD" ] || structural "missing fold helper $FOLD"

[ -n "$rules" ] || structural "empty --rules"
selected=()
IFS=',' read -r -a selected <<< "$rules" || true
cleaned=()
for r in "${selected[@]+"${selected[@]}"}"; do
  r=${r#"${r%%[![:space:]]*}"}
  r=${r%"${r##*[![:space:]]}"}
  [ -n "$r" ] || continue
  case "$r" in
    R-retrieve-omitted) cleaned+=("$r") ;;
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
    R-retrieve-omitted) ;;
    *) structural "unknown expect-rule $expect_rule" ;;
  esac
fi

[ -n "$prior_log" ] || structural "missing prior-log --prior-log"
[ -e "$prior_log" ] || structural "missing prior-log $prior_log"
[ -f "$prior_log" ] && [ ! -L "$prior_log" ] || structural "prior-log is not a regular file: $prior_log"
[ -s "$prior_log" ] || structural "empty prior-log $prior_log"

[ -n "$retrieve" ] || structural "missing retrieve --retrieve"
[ -e "$retrieve" ] || structural "missing retrieve $retrieve"
[ -f "$retrieve" ] && [ ! -L "$retrieve" ] || structural "retrieve is not a regular file: $retrieve"
[ -s "$retrieve" ] || structural "empty retrieve $retrieve"

fold_home=$home_arg
cleanup_home=
fold_out=
bar_items=
findings=
# shellcheck disable=SC2329 # Invoked by trap handlers below.
cleanup() {
  [ -n "$fold_out" ] && rm -f "$fold_out"
  [ -n "$bar_items" ] && rm -f "$bar_items"
  [ -n "$findings" ] && rm -f "$findings"
  [ -n "$cleanup_home" ] && rm -rf "$cleanup_home"
}
trap cleanup EXIT HUP INT TERM

if [ -z "$fold_home" ]; then
  fold_home=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-progress-retrieve.XXXXXX") \
    || structural "could not create a fold home"
  cleanup_home=$fold_home
  mkdir -p "$fold_home/config" "$fold_home/data" "$fold_home/state"
  printf '7500\n' > "$fold_home/config/startup-memory-budget"
fi

[ -d "$fold_home" ] && [ ! -L "$fold_home" ] \
  || structural "home is not a regular directory: $fold_home"

fold_out=$(mktemp "${TMPDIR:-/tmp}/fm-session-progress-fold.XXXXXX") \
  || structural "could not create fold output"

set +e
FM_HOME="$fold_home" FM_PRIOR_SESSION_LOG="$prior_log" "$FOLD" > "$fold_out" 2>/dev/null
set -e
[ -s "$fold_out" ] || structural "prior log produced no fold output"

if ! grep -Fq 'fold-status: parsed within bound.' "$fold_out"; then
  structural "prior log did not yield a parsed fold"
fi

bar_items=$(mktemp "${TMPDIR:-/tmp}/fm-session-progress-bar.XXXXXX") \
  || structural "could not create bar-item list"

awk '
  /^LIVE JOBS$/ { sec=1; next }
  /^OPEN PICKS$/ { sec=1; next }
  /^UNVERIFIED PICK CONTEXT$/ { sec=0; next }
  /^CAPTAIN LOCK WORDS$/ { sec=1; next }
  /^fold-status:/ { sec=0; next }
  /^INCOMPLETE:/ { sec=0; next }
  /^source:/ { next }
  /^scope:/ { next }
  /^=+$/ { next }
  /^PRIOR SESSION$/ { next }
  sec==1 && $0=="(none found)" { next }
  sec==1 && $0 ~ /^- / { print substr($0, 3) }
' "$fold_out" > "$bar_items"

findings=$(mktemp "${TMPDIR:-/tmp}/fm-session-progress-findings.XXXXXX") \
  || structural "could not create findings list"
: > "$findings"

rule_wanted() {
  local want=$1 r
  for r in "${selected[@]}"; do
    [ "$r" = "$want" ] && return 0
  done
  return 1
}

if rule_wanted R-retrieve-omitted; then
  while IFS= read -r item || [ -n "${item:-}" ]; do
    [ -n "$item" ] || continue
    if ! grep -Fq -- "$item" "$retrieve"; then
      printf 'R-retrieve-omitted-bar-item: retrieve omits bar item: %s\n' "$item" >> "$findings"
    fi
  done < "$bar_items"
fi

findings_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' < "$findings") \
  || structural "could not encode findings"

if [ -n "$expect_rule" ]; then
  prefix="${expect_rule}-"
  counts=$(jq -n --argjson findings "$findings_json" --arg prefix "$prefix" \
    '{selected: ([ $findings[] | select(startswith($prefix))] | length), total: ($findings | length)}')
  selected_count=$(jq '.selected' <<<"$counts")
  total=$(jq '.total' <<<"$counts")
  if [ "$selected_count" -ne "$expect_count" ] || [ "$total" -ne "$expect_count" ]; then
    printf 'regression: expected %s finding(s) and %s total, observed %s and %s total\n' \
      "$expect_count" "$expect_count" "$selected_count" "$total" >&2
    jq -r '.[]' <<<"$findings_json" >&2
    exit 1
  fi
  exit 0
fi

count=$(jq 'length' <<<"$findings_json")
if [ "$count" -gt 0 ]; then
  jq -r '.[]' <<<"$findings_json"
  exit 1
fi
exit 0
