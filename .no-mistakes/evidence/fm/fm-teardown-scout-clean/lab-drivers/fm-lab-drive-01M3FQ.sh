#!/usr/bin/env bash
# drive.sh <logfile-basename> <command string>: run a command in the lab primary pane, append transcript to evidence log.
LAB=$(cat /tmp/fm-lab-path-01M3FQ)
EV=/Users/AI/.no-mistakes/evidence/01M3FQ7YEV9KJY0WP6MH7ZCDBQ
log="$EV/$1"; shift
mkdir -p "$LAB/steps"
n=$(date +%s%N)
step="$LAB/steps/$n.sh"
printf '%s\n' "$*" > "$step"
marker="__DONE_${n}__"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
start=$(cat "$log" 2>/dev/null | wc -l)
T send-keys -t primary:0 -l "{ printf '\$ %s\n' \"\$(cat $step)\"; bash $step; echo \"[exit \$?]\"; } >> '$log' 2>&1; echo $marker"
T send-keys -t primary:0 Enter
for i in $(seq 1 ${DRIVE_TIMEOUT:-300}); do
  if T capture-pane -p -t primary:0 -S -50 | grep -q "^$marker"; then break; fi
  sleep 1
done
tail -n +$((start+1)) "$log"
