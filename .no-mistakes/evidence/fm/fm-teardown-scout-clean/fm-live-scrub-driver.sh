#!/usr/bin/env bash
# Drive a real scout teardown against a real Treehouse pool in a lab home.
# Args: <fm-root-with-bin> <label> [--nested-under-claude-for-ship]
set -u
FMROOT=$1; LABEL=$2; KIND=${3:-scout}; FORCE=${4:-}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$PWD/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TREEHOUSE_ROOT="$LAB/treehouse"
P="$LAB/projects/demo"
git init -q -b main "$P"; printf 'hello\n' > "$P/README.md"
git -C "$P" add README.md; git -C "$P" -c user.email=t@t -c user.name=t commit -q -m init
git init -q -b main "$LAB/nested-src"; printf 'payload\n' > "$LAB/nested-src/payload.txt"
git -C "$LAB/nested-src" add .; git -C "$LAB/nested-src" -c user.email=t@t -c user.name=t commit -q -m p
WT=$(cd "$P" && treehouse get --lease 2>/dev/null)
echo "== [$LABEL] leased slot: $WT"
git clone -q "$LAB/nested-src" "$WT/scratch-clone"
printf "ignored-cache/\n" >> "$P/.git/info/exclude"; mkdir -p "$WT/ignored-cache"; printf "keep-me\n" > "$WT/ignored-cache/blob"; printf "scratch\n" > "$WT/scratch.txt"
git -C "$WT" -c user.email=t@t -c user.name=t checkout -q -b fm/scout-1
echo "== [$LABEL] slot status before teardown:"; git -C "$WT" status --porcelain --untracked-files=all
cat > "$LAB/state/scout-1.meta" <<M
window=firstmate:fm-scout-1
endpoint_task_id=scout-1
worktree=$WT
project=$P
kind=$KIND
mode=local-only
spawn_gen=live-scout-1
decisions_reviewed=1
M
mkdir -p "$LAB/data/scout-1"; printf 'Scout report.\n' > "$LAB/data/scout-1/report.md"
echo "== [$LABEL] running: fm-teardown.sh scout-1 $FORCE"
( cd "$FMROOT" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_BACKEND=tmux bin/fm-teardown.sh scout-1 $FORCE ); echo "== [$LABEL] teardown exit=$?"
echo "== [$LABEL] slot status after return (empty = clean):"; git -C "$WT" status --porcelain --untracked-files=all
echo "== [$LABEL] ignored file after return: $(cat "$WT/ignored-cache/blob" 2>&1)"; echo "== [$LABEL] treehouse status:"; (cd "$P" && treehouse status 2>&1)
echo "== [$LABEL] next treehouse get picks:"; (cd "$P" && treehouse get --lease 2>&1 | tail -2)
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
chmod -R u+w "$LAB"; rm -rf "$LAB"
