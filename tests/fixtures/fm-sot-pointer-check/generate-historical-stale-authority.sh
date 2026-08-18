#!/usr/bin/env bash
# Derive the stale-authority regression fixture from the real Firstmate home
# records and a detached checkout of the later shipping commit.
#
# Usage: generate-historical-stale-authority.sh <fm-home> <project-repo> <output-dir>
#
# The source home must contain the 2026-08-15 look lock, its shipped task, and
# the older captain hold that remained open on 2026-08-19.
# The project repository must contain tradingview-tools commit 0d8bb3b, merged
# as PR #98. The generator clones that repository into a temporary directory and
# checks out the exact commit before deriving any fixture bytes.
# The generator first derives the valid later-authority binding, then preserves
# the extracted historical open row as the reversible mutation input.
# The output directory must not exist, so regeneration never overwrites evidence.
set -euo pipefail

[ "$#" -eq 3 ] || {
  sed -n '2,12p' "$0" | sed 's/^# \?//' >&2
  exit 2
}

fm_home=$1
project_repo=$2
output_dir=$3
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../../.." && pwd)
ship_commit=0d8bb3bb62ada54197185924bfc4ce1908432b1a
ship_task=tv-gamma-look-ship
hold_id=tv-gamma-impl-intake-decision-level-coincidence
decision_name=tv-gamma-look-lock-2026-08-15.md
pointer_regex='Chart flips from two walls to all ranked levels'

[ -d "$fm_home/data" ] || { echo "fixture generator: missing home data: $fm_home/data" >&2; exit 2; }
[ -d "$project_repo" ] || { echo "fixture generator: missing project repository: $project_repo" >&2; exit 2; }
[ ! -e "$output_dir" ] || { echo "fixture generator: output already exists: $output_dir" >&2; exit 2; }

parent_dir=$(dirname "$output_dir")
mkdir -p "$parent_dir"
stage=$(mktemp -d "$parent_dir/.historical-stale-authority.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

git clone --quiet --no-checkout "$project_repo" "$stage/project"
git -C "$stage/project" checkout --quiet --detach "$ship_commit"
[ "$(git -C "$stage/project" rev-parse HEAD)" = "$ship_commit" ] \
  || { echo "fixture generator: detached checkout resolved the wrong commit" >&2; exit 2; }
[ "$(git -C "$stage/project" log -1 --format=%s)" = 'feat(gamma): ship locked all-rank GEX level look (#98)' ] \
  || { echo "fixture generator: shipping commit subject changed" >&2; exit 2; }
grep -Fq 'test_two_wall_arrays_are_gone_so_no_reader_can_drop_ranks_two_and_three' \
  "$stage/project/tests/gamma/test_generate.py" \
  || { echo "fixture generator: checked-out ship no longer proves all ranked levels" >&2; exit 2; }

mkdir -p "$stage/home/data/decisions" "$stage/output"
cp "$repo_root/.tasks.toml" "$stage/home/.tasks.toml"

awk -v task_id="$ship_task" '
  $1 == "-" && $2 == "[x]" && $3 == task_id { print; count++ }
  END { if (count != 1) exit 2 }
' "$fm_home/data/done-archive.md" > "$stage/output/done-archive.fixture" \
  || { echo "fixture generator: expected exactly one shipped task row" >&2; exit 2; }

awk -v hold_id="$hold_id" '
  $1 == "-" && $2 == "[" && $3 == "]" && $4 == hold_id { print; count++ }
  END { if (count != 1) exit 2 }
' "$fm_home/data/backlog.md" > "$stage/output/open-hold.fixture" \
  || { echo "fixture generator: expected exactly one open superseded hold row" >&2; exit 2; }
grep -Fq '(kind: captain)' "$stage/output/open-hold.fixture" \
  || { echo "fixture generator: historical row is not a captain hold" >&2; exit 2; }
grep -Fq '(hold-kind: captain)' "$stage/output/open-hold.fixture" \
  || { echo "fixture generator: historical row lacks captain hold-kind" >&2; exit 2; }

decision_source="$fm_home/data/decisions/$decision_name"
[ -f "$decision_source" ] || { echo "fixture generator: missing historical decision: $decision_source" >&2; exit 2; }
[ "$(grep -F -c "$pointer_regex" "$decision_source")" -eq 1 ] \
  || { echo "fixture generator: decision must contain the pointer exactly once" >&2; exit 2; }
cp "$decision_source" "$stage/output/decision.fixture"
cp "$decision_source" "$stage/home/data/decisions/look-lock.md"

{
  printf '## In flight\n\n## Queued\n'
  cat "$stage/output/open-hold.fixture"
  printf '## Done\n'
  cat "$stage/output/done-archive.fixture"
} > "$stage/home/data/backlog.md"

FM_HOME="$stage/home" "$repo_root/bin/fm-decision-hold.sh" supersede \
  tv-gamma-impl-intake level-coincidence \
  --decision-file data/decisions/look-lock.md --shipped-task "$ship_task" >/dev/null
sed -E 's/\(done [0-9]{4}-[0-9]{2}-[0-9]{2}\)/\(done 2026-08-19\)/' \
  "$stage/home/data/backlog.md" > "$stage/output/backlog.fixture"

printf '%s\t%s\t%s\t%s\n' \
  gamma-look-ship-20260815 "$pointer_regex" "$ship_task" "$hold_id" \
  > "$stage/output/registry.fixture"

decision_sha=$(shasum -a 256 "$stage/output/decision.fixture" | awk '{print $1}')
backlog_sha=$(shasum -a 256 "$stage/output/backlog.fixture" | awk '{print $1}')
open_hold_sha=$(shasum -a 256 "$stage/output/open-hold.fixture" | awk '{print $1}')
archive_sha=$(shasum -a 256 "$stage/output/done-archive.fixture" | awk '{print $1}')
cat > "$stage/output/provenance.json" <<EOF
{
  "derived": true,
  "source_date": "2026-08-19",
  "project_commit": "$ship_commit",
  "project_pr": 98,
  "ship_task": "$ship_task",
  "superseded_hold": "$hold_id",
  "decision_file": "data/decisions/$decision_name",
  "sha256": {
    "decision.fixture": "$decision_sha",
    "backlog.fixture": "$backlog_sha",
    "open-hold.fixture": "$open_hold_sha",
    "done-archive.fixture": "$archive_sha"
  }
}
EOF

mv "$stage/output" "$output_dir"
printf 'generated: %s\n' "$output_dir"
