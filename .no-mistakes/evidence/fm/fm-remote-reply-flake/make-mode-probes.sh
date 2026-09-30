#!/usr/bin/env bash
# Builds mode-probe-{base,head}.sh: the test prefix (generations 1-3) plus a
# scenario chosen by PROBE_MODE = steady | killed | timeout.
set -eu
W=$1 EV=$2
for pair in "base:65c75b0dab02f2bd6c293cf21a20f712dfac16bd" "head:93ae5875dd9f4206eed3a1b43370763b86c55c1e"; do
  name=${pair%%:*} rev=${pair#*:}
  out="$EV/mode-probe-$name.sh"
  git -C "$W" show "${rev}:tests/fm-remote-reply.test.sh" > "$out.full"
  cut=$(grep -n '^pass "later generations cannot invalidate an unacknowledged ingested result"' "$out.full" | cut -d: -f1)
  head -n "$cut" "$out.full" \
    | sed -e 's#^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib.sh"#. "'"$W"'/tests/lib.sh"#' \
          -e 's#^ROOT=.*#ROOT='"$W"'#' > "$out"
  cat >> "$out" <<'EOF'

# ---- scenario probe (probe only) ------------------------------------------
stop_reply_listener || fail "probe: listener did not stop"
STARTS="$TMP_ROOT/starts"; : > "$STARTS"
eval "real_$(declare -f remote_env)"
remote_env() { case "${2:-}" in start) echo x >> "$STARTS" ;; esac; real_remote_env "$@"; }
CLAIM_PIDS="$TMP_ROOT/claim-pids"; : > "$CLAIM_PIDS"
( set +e; while :; do sed -n 2p "$CLAIMS/$SID.claim" 2>/dev/null >> "$CLAIM_PIDS"; sleep 0.25; done ) &
SAMPLER=$!
T0=$(date +%s)
case "${PROBE_MODE:?}" in
  steady)
    ( sleep 4; printf 'working [key=steady]: late line\n' >> "$REMOTE/state/parent-replies.status" ) &
    ;;
  killed)
    ( sleep 2.5; stop_reply_listener; sleep 3.5; printf 'working [key=killed]: late line\n' >> "$REMOTE/state/parent-replies.status" ) &
    ;;
  timeout)
    export FM_REMOTE_REPLY_FAIL_READ=1
    printf 'working [key=timeout]: never readable\n' >> "$REMOTE/state/parent-replies.status"
    ;;
esac
rc=0; await_reply_result "$PARENT/state/procevent-inbox/$SID.4.result" 2> "$TMP_ROOT/await.stderr" || rc=$?
kill "$SAMPLER" 2>/dev/null || true
echo "PROBE-MODE: $PROBE_MODE"
echo "PROBE-RC: $rc after $(( $(date +%s) - T0 ))s"
echo "PROBE-STARTS: $(wc -l < "$STARTS" | tr -d ' ')"
echo "PROBE-DISTINCT-CLAIM-PIDS: $(sort -u "$CLAIM_PIDS" | grep -c . || true)"
echo "PROBE-STDERR: $(cat "$TMP_ROOT/await.stderr")"
exit "$rc"
EOF
  rm -f "$out.full"
  chmod +x "$out"
done
