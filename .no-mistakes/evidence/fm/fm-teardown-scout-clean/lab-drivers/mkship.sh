#!/usr/bin/env bash
# mkship.sh <id> <nested-subpath>: scaffold a local-only ship brief, spawn it, and put a nested clone at <nested-subpath> in its copy.
set -e
id=$1 sub=$2
bin/fm-brief.sh "$id" demo --mode local-only >/dev/null
python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("{TASK}","Lab ship: exercise teardown of a copy that holds a nested repository.",1)
s=s.replace("{FIRSTMATE_SPEC}","Clone a repository inside the copy; make no commits.",1)
open(p,"w").write(s)
PY
grep -n '{' "$FM_HOME/data/$id/brief.md" | grep -E '\{[A-Z_]+\}' || true
bin/fm-spawn.sh "$id" "$FM_HOME/projects/demo" --mode local-only --yolo off --harness "sh -c 'exec sleep 86400'" 2>&1 | grep -v '^●'
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$id.meta")
echo "== ship $id copy: $WT (branch $(git -C "$WT" branch --show-current))"
mkdir -p "$WT/$(dirname "$sub")"
git clone -q "$FM_HOME/nested-src" "$WT/$sub"
echo "== copy status (untracked, all):"
git -C "$WT" status --porcelain --untracked-files=all
