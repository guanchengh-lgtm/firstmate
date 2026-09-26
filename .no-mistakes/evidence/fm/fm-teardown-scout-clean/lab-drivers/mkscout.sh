#!/usr/bin/env bash
# mkscout.sh <id>: scaffold a scout brief, spawn it into the demo pool, and do the scout's scratch work in its copy.
set -e
id=$1
bin/fm-brief.sh "$id" demo --scout >/dev/null
python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("{TASK}","Lab scout: clone a repository and run git init inside the copy, then write a report.",1)
s=s.replace("{FIRSTMATE_SPEC}","Clone the lab nested-src repository into scratch-clone/, run git init in scratch-init/, and write the report.",1)
open(p,"w").write(s)
PY
bin/fm-spawn.sh "$id" "$FM_HOME/projects/demo" --scout --harness "sh -c 'exec sleep 86400'" 2>&1 | grep -v '^●'
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$id.meta")
echo "== scout $id copy: $WT"
# The scout's own scratch work inside its copy:
( cd "$WT"
  git clone -q "$FM_HOME/nested-src" scratch-clone
  git init -q scratch-init
  git -C scratch-init -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip
  echo scratch > scratch.txt
  mkdir -p cache && echo keep-me > cache/blob
  echo "== copy status after scout work (untracked):"
  git status --porcelain --untracked-files=all
  echo "== ignored:"
  git status --porcelain --ignored | grep '^!!' )
printf '# Scout report\nPlanted nested repositories in the copy.\n' > "$FM_HOME/data/$id/report.md"
bin/fm-captain-hold.sh complete "$id" --none
