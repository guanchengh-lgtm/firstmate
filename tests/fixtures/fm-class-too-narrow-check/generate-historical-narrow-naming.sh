#!/usr/bin/env bash
# Derive the class-too-narrow historical fixture from the 2026-08-22 PR 29
# naming still on disk.
#
# Usage: generate-historical-narrow-naming.sh --output <claims.json>
#          [--source <claims.json>] [--force]
#
# Default --source is docs/verification/stow-open-lock-recurring-defect-claims.json,
# the PR 29 claims that named the class as /stow while a 2026-08-18 instance is
# session-resume clothes. The generator copies only shape and instances, asserts
# those historical markers, then requires the checker to fire
# R-broader-than-shape exactly once before the file is kept.
#
# Exit 0 on write. Exit 2 on any assertion, CLI, or checker failure.
# There is no exit-1 path.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(CDPATH='' cd -- "$script_dir/../../.." && pwd)
default_source="$root/docs/verification/stow-open-lock-recurring-defect-claims.json"
checker="$root/bin/fm-class-too-narrow-check.sh"
source_path=$default_source
output=
force=0

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fixture generator: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || die "--output requires a path"
      output=$2
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || die "--source requires a path"
      source_path=$2
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$output" ] || die "--output is required"
command -v jq >/dev/null 2>&1 || die "jq not found"
[ -x "$checker" ] || die "checker is not executable: $checker"
[ -f "$source_path" ] && [ ! -L "$source_path" ] \
  || die "source is not a regular file: $source_path"
[ -s "$source_path" ] || die "source is empty: $source_path"
jq -e 'type == "object"' "$source_path" >/dev/null \
  || die "source JSON root must be an object"

jq -e '.shape | type == "string" and test("/stow")' "$source_path" >/dev/null \
  || die "source shape must name the /stow command (2026-08-22 narrow naming)"
jq -e '.instances | type == "array" and length >= 2' "$source_path" >/dev/null \
  || die "source must name two or more instances"
jq -e '[.instances[] | select(type == "string" and test("2026-08-18") and (test("(?i)stow") | not))] | length >= 1' \
  "$source_path" >/dev/null \
  || die "source must keep a 2026-08-18 instance that does not mention stow"
jq -e '[.instances[] | select(type == "string" and test("(?i)stow"))] | length >= 1' \
  "$source_path" >/dev/null \
  || die "source must keep a stow-clothed instance"

derived=$(jq -c '{shape, instances}' "$source_path") \
  || die "could not extract shape and instances"
jq -e '(.shape | type == "string") and (.instances | type == "array" and length >= 2)' \
  >/dev/null <<<"$derived" \
  || die "extracted claims lost shape or instances"

if [ -e "$output" ] && [ "$force" -ne 1 ]; then
  die "output already exists: $output"
fi

out_dir=$(dirname -- "$output")
mkdir -p "$out_dir"
tmp=$(mktemp "$out_dir/.class-too-narrow-XXXXXX")
trap 'rm -f "$tmp"' EXIT HUP INT TERM
printf '%s\n' "$derived" | jq '.' > "$tmp"

"$checker" --input "$tmp" --expect-rule R-broader-than-shape --expect-count 1 \
  || die "derived fixture did not fire R-broader-than-shape exactly once"

mv "$tmp" "$output"
trap - EXIT HUP INT TERM
exit 0
