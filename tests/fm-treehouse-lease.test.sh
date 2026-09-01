#!/usr/bin/env bash
# Real Treehouse regression for immutable task lease identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v treehouse >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  printf '%s\n' "# SKIP: real Treehouse lease regression needs treehouse and node"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-treehouse-lease)
PROJECT="$TMP_ROOT/project"
POOL="$TMP_ROOT/pool"
B_PATH=
B_ID=
B_PID=

lease_field() {  # <json> <field>
  node -e '
    const value = JSON.parse(process.argv[1]);
    const field = value[process.argv[2]];
    if (typeof field !== "string" || field.length === 0) process.exit(1);
    process.stdout.write(field);
  ' "$1" "$2"
}

cleanup() {
  local status=$?
  if [ -n "$B_PATH" ] && [ -n "$B_ID" ]; then
    ( cd "$PROJECT" && treehouse return --root "$POOL" --force \
      --if-lease-id "$B_ID" --if-lease-holder task-b "$B_PATH" ) >/dev/null 2>&1 || true
  fi
  if [ -n "$B_PID" ]; then
    kill "$B_PID" 2>/dev/null || true
    wait "$B_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
  return "$status"
}
trap cleanup EXIT INT TERM

git init -q "$PROJECT"
git -C "$PROJECT" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m baseline

A_JSON=$(cd "$PROJECT" && treehouse get --root "$POOL" --lease --json --lease-holder task-a) \
  || fail "real-treehouse-lease: task A acquisition failed"
A_PATH=$(lease_field "$A_JSON" path) || fail "real-treehouse-lease: task A path was invalid"
A_ID=$(lease_field "$A_JSON" lease_id) || fail "real-treehouse-lease: task A lease ID was invalid"
A_HOLDER=$(lease_field "$A_JSON" lease_holder) || fail "real-treehouse-lease: task A holder was invalid"
[ "$A_HOLDER" = task-a ] || fail "real-treehouse-lease: task A holder was '$A_HOLDER'"

( cd "$PROJECT" && treehouse return --root "$POOL" --force \
  --if-lease-id "$A_ID" --if-lease-holder task-a "$A_PATH" ) >/dev/null \
  || fail "real-treehouse-lease: exact task A release failed"

B_JSON=$(cd "$PROJECT" && treehouse get --root "$POOL" --lease --json --lease-holder task-b) \
  || fail "real-treehouse-lease: task B reacquisition failed"
B_PATH=$(lease_field "$B_JSON" path) || fail "real-treehouse-lease: task B path was invalid"
B_ID=$(lease_field "$B_JSON" lease_id) || fail "real-treehouse-lease: task B lease ID was invalid"
B_HOLDER=$(lease_field "$B_JSON" lease_holder) || fail "real-treehouse-lease: task B holder was invalid"
[ "$B_HOLDER" = task-b ] || fail "real-treehouse-lease: task B holder was '$B_HOLDER'"
[ "$B_PATH" = "$A_PATH" ] || fail "real-treehouse-lease: fixture did not reuse the same pool path"
[ "$B_ID" != "$A_ID" ] || fail "real-treehouse-lease: reacquisition reused the old lease ID"

printf '%s\n' 'task B content' > "$B_PATH/task-b-sentinel"
( cd "$B_PATH" && exec sleep 60 ) &
B_PID=$!
sleep 0.2
kill -0 "$B_PID" 2>/dev/null || fail "real-treehouse-lease: task B sentinel process did not start"

set +e
STALE_OUT=$(cd "$PROJECT" && treehouse return --root "$POOL" --force \
  --if-lease-id "$A_ID" --if-lease-holder task-a "$A_PATH" 2>&1)
STALE_RC=$?
set -e
[ "$STALE_RC" -ne 0 ] || fail "real-treehouse-lease: stale task A lease released task B"
assert_contains "$STALE_OUT" "lease precondition failed" \
  "real-treehouse-lease: stale release did not report the lease mismatch"
[ "$(cat "$B_PATH/task-b-sentinel")" = 'task B content' ] \
  || fail "real-treehouse-lease: stale release reset task B content"
kill -0 "$B_PID" 2>/dev/null || fail "real-treehouse-lease: stale release terminated task B"

STATUS_JSON=$(cd "$PROJECT" && treehouse status --root "$POOL" --json) \
  || fail "real-treehouse-lease: status after stale refusal failed"
node -e '
  const value = JSON.parse(process.argv[1]);
  const rows = Array.isArray(value) ? value : value.worktrees;
  if (!Array.isArray(rows)) process.exit(1);
  const row = rows.find((item) => item.path === process.argv[2]);
  if (!row || row.lease_id !== process.argv[3] || row.lease_holder !== "task-b") process.exit(1);
  if (row.leased !== true && row.status !== "leased") process.exit(1);
' "$STATUS_JSON" "$B_PATH" "$B_ID" \
  || fail "real-treehouse-lease: stale refusal changed task B lease state"

pass "real Treehouse refuses a stale lease ID and preserves the reacquired task"
