#!/usr/bin/env bash
# Full-test stress: N concurrent copies of the base test and N of the changed test.
set -u
W=$1 EV=$2 N=$3
for pair in "base:65c75b0dab02f2bd6c293cf21a20f712dfac16bd" "head:93ae5875dd9f4206eed3a1b43370763b86c55c1e"; do
  name=${pair%%:*} rev=${pair#*:}
  git -C "$W" show "${rev}:tests/fm-remote-reply.test.sh" \
    | sed -e 's#^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib.sh"#. "'"$W"'/tests/lib.sh"#' \
          -e 's#^ROOT=.*#ROOT='"$W"'#' > "$EV/full-$name.sh"
  chmod +x "$EV/full-$name.sh"
done
for i in $(seq 1 "$N"); do
  for name in base head; do
    ( s=$(date +%s); bash "$EV/full-$name.sh" > "$EV/stress-$name-$i.log" 2>&1; rc=$?
      echo "exit=$rc elapsed=$(( $(date +%s) - s ))s" >> "$EV/stress-$name-$i.log" ) &
  done
done
wait
