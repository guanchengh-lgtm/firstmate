#!/usr/bin/env bash
# Detect live map fog under a `## Not yet specified` section.
#
# Usage: fm-map-fog-check.sh [--strict] [--expect-rule <rule-id> --expect-count <count>]
#          [map-file ...]
#
# Each map file must be an ordinary readable file. Relative paths resolve from
# FM_HOME. With no map-file arguments, every ordinary `map.md` under
# $FM_HOME/data is checked. An empty data tree or no map files is silent
# success.
#
# Fog is live when a bullet is `[open]` or lacks a valid status token.
# `[parked YYYY-MM-DD]` is not live. `[closed <pointer>]` is not live when the
# first path token resolves to an existing ordinary file under FM_HOME.
# `- none` as the only effective bullet is clean. A missing
# `## Not yet specified` section is a structural failure, exit 2, never a pass.
# Backtick paths ending in `map.md` named by a checked map are followed once.
#
# Default detect-only mode prints ordinary findings as
# "MAP_FOG: <map><TAB><finding text>" and exits 0.
# --strict exits 1 when any live fog remains. Structural failures always exit 2.
# This script never writes `[parked]` or `[closed]` tokens.
#
# Residual: unwritten fog, fog in the wrong section, closed-pointer honesty,
# and ships that never pass --map are not visible here. No completeness claim.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

strict=0
expect_rule=
expect_count=
MAP_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)
      strict=1
      shift
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
      sed -n '2,24p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    --)
      shift
      MAP_ARGS+=("$@")
      break
      ;;
    -*)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
    *)
      MAP_ARGS+=("$1")
      shift
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
  R-MAP-FOG-LIVE)
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

fatal() {
  echo "MAP_FOG: registry invalid - $*" >&2
  exit 2
}

report_finding() {
  printf 'MAP_FOG: %s\t%s\n' "$1" "$2" >> "$FINDINGS"
}

trim_space() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

is_ordinary_file() {
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ]
}

resolve_map() {
  local raw=$1
  case "$raw" in
    /*) printf '%s' "$raw" ;;
    *) printf '%s' "$FM_HOME/$raw" ;;
  esac
}

display_map() {
  local abs=$1 prefix
  prefix="$FM_HOME/"
  case "$abs" in
    "$prefix"*) printf '%s' "${abs#"$prefix"}" ;;
    *) printf '%s' "$abs" ;;
  esac
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-map-fog.XXXXXX") || exit 2
# shellcheck disable=SC2329 # Invoked by trap handlers below.
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM
SEEN="$TMP_DIR/seen"
FINDINGS="$TMP_DIR/findings"
QUEUE="$TMP_DIR/queue"
: > "$SEEN"
: > "$FINDINGS"
: > "$QUEUE"

NEXT="$TMP_DIR/next"
: > "$NEXT"

enqueue() {
  local abs=$1
  grep -Fxq -- "$abs" "$SEEN" && return 0
  printf '%s\n' "$abs" >> "$SEEN"
  printf '%s\n' "$abs" >> "$NEXT"
}

if [ "${#MAP_ARGS[@]}" -gt 0 ]; then
  for raw in "${MAP_ARGS[@]}"; do
    abs=$(resolve_map "$raw")
    is_ordinary_file "$abs" || fatal "map is not a readable ordinary file: $raw"
    enqueue "$abs"
  done
else
  if [ -d "$DATA" ] && [ ! -L "$DATA" ]; then
    while IFS= read -r found; do
      [ -n "$found" ] || continue
      is_ordinary_file "$found" || continue
      enqueue "$found"
    done < <(find "$DATA" -name map.md -type f 2>/dev/null || true)
  fi
fi

[ -s "$NEXT" ] || exit 0

closed_pointer_ok() {
  local pointer=$1 token path
  token=$(trim_space "$pointer")
  token=${token%%[[:space:]]*}
  [ -n "$token" ] || return 1
  case "$token" in
    /*) path=$token ;;
    *) path="$FM_HOME/$token" ;;
  esac
  is_ordinary_file "$path"
}

check_map() {
  local abs=$1 display bullets_file section_rc bullet token rest live_here=0
  display=$(display_map "$abs")
  bullets_file="$TMP_DIR/bullets"
  set +e
  awk '
    /^##[[:space:]]+Not yet specified[[:space:]]*$/ { in_sec=1; found=1; next }
    in_sec && /^##[[:space:]]/ { in_sec=0 }
    in_sec && /^-[[:space:]]/ { print }
    END { if (!found) exit 2 }
  ' "$abs" > "$bullets_file"
  section_rc=$?
  set -e
  [ "$section_rc" -ne 2 ] || fatal "$display is missing a ## Not yet specified section"
  [ "$section_rc" -eq 0 ] || fatal "$display could not be parsed"

  if [ ! -s "$bullets_file" ]; then
    report_finding "$display" "## Not yet specified has no bullets (use - none when empty)"
    return 0
  fi

  live_here=0
  while IFS= read -r bullet || [ -n "$bullet" ]; do
    [ -n "$bullet" ] || continue
    rest=${bullet#- }
    rest=$(trim_space "$rest")
    case "$rest" in
      none|none.)
        continue
        ;;
      \[open\]*)
        live_here=1
        report_finding "$display" "live unspecified item: $bullet"
        continue
        ;;
      \[parked\ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]*)
        continue
        ;;
      \[closed\ *)
        token=${rest#\[closed }
        token=${token%%]*}
        if closed_pointer_ok "$token"; then
          continue
        fi
        live_here=1
        report_finding "$display" "closed pointer does not resolve: $token"
        continue
        ;;
      *)
        live_here=1
        report_finding "$display" "live unspecified item: $bullet"
        ;;
    esac
  done < "$bullets_file"

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      /*) : ;;
      *) ref="$FM_HOME/$ref" ;;
    esac
    is_ordinary_file "$ref" || continue
    enqueue "$ref"
  done < <(awk '
    {
      while (match($0, /`[^`]+map\.md`/)) {
        path = substr($0, RSTART + 1, RLENGTH - 2)
        print path
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
  ' "$abs")
  : "$live_here"
}

while [ -s "$NEXT" ]; do
  cat "$NEXT" > "$QUEUE"
  : > "$NEXT"
  while IFS= read -r abs || [ -n "$abs" ]; do
    [ -n "$abs" ] || continue
    check_map "$abs"
  done < "$QUEUE"
done

finding_count=0
if [ -s "$FINDINGS" ]; then
  finding_count=$(wc -l < "$FINDINGS" | tr -d ' ')
  cat "$FINDINGS"
fi

if [ -n "$expect_rule" ]; then
  [ "$finding_count" -eq "$expect_count" ] || {
    echo "error: expected $expect_count $expect_rule finding(s), got $finding_count" >&2
    exit 1
  }
  exit 0
fi

if [ "$finding_count" -gt 0 ] && [ "$strict" -eq 1 ]; then
  exit 1
fi
exit 0
