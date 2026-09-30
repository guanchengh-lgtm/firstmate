#!/usr/bin/env bash
# Builds race-probe-{base,head}.sh from the test file at each revision.
set -eu
W=$1 EV=$2
for pair in "base:65c75b0dab02f2bd6c293cf21a20f712dfac16bd" "head:93ae5875dd9f4206eed3a1b43370763b86c55c1e"; do
  name=${pair%%:*} rev=${pair#*:}
  out="$EV/race-probe-$name.sh"
  git -C "$W" show "${rev}:tests/fm-remote-reply.test.sh" > "$out.full"
  cut=$(grep -n '^pass "later generations cannot invalidate an unacknowledged ingested result"' "$out.full" | cut -d: -f1)
  head -n "$cut" "$out.full" \
    | sed -e 's#^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib.sh"#. "'"$W"'/tests/lib.sh"#' \
          -e 's#^ROOT=.*#ROOT='"$W"'#' > "$out"
  cat >> "$out" <<'EOF'

# ---- injected race (probe only) -------------------------------------------
# The listener is gone, but the FIRST ownership sample still reads "live": the
# window in which a listener has adopted the previous registration and is about
# to exit as superseded. Later samples tell the truth.
stop_reply_listener || fail "probe: listener did not stop"
RACE_FLAG="$TMP_ROOT/race-first-sample-done"
eval "real_$(declare -f reply_owner)"
reply_owner() {
  if [ ! -e "$RACE_FLAG" ]; then : > "$RACE_FLAG"; printf 'live\n'; return 0; fi
  real_reply_owner
}
printf 'working [key=race-probe]: injected race generation\n' >> "$REMOTE/state/parent-replies.status"
T0=$(date +%s)
if await_reply_result "$PARENT/state/procevent-inbox/$SID.4.result"; then
  echo "PROBE-RESULT: captured after $(( $(date +%s) - T0 ))s"
  exit 0
else
  echo "PROBE-RESULT: NOT captured after $(( $(date +%s) - T0 ))s"
  exit 1
fi
EOF
  rm -f "$out.full"
  chmod +x "$out"
done
