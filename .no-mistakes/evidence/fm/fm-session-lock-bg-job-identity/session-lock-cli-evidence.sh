#!/usr/bin/env bash
set -u

ROOT=${1:?repository root required}
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-lock-evidence.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/home/bin" "$FIXTURE/home/state" "$FIXTURE/fakebin"
cp "$ROOT/bin/fm-lock.sh" "$FIXTURE/home/bin/"
cp "$ROOT/bin/fm-session-lock-lib.sh" "$FIXTURE/home/bin/"
cp "$ROOT/bin/fm-cursor-lib.sh" "$FIXTURE/home/bin/"
cp "$ROOT/bin/fm-wake-lib.sh" "$FIXTURE/home/bin/"
ln -s /bin/bash "$FIXTURE/fakebin/claude"
FAKE_CLAUDE="$FIXTURE/fakebin/claude"

cat > "$FIXTURE/home/same.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-holder
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' 'same-session reacquire:'
"$FM_HOME/bin/fm-lock.sh"
printf 'persisted lock=%s session=%s\n' "$(cat "$FM_HOME/state/.lock")" "$(cat "$FM_HOME/state/.lock.session")"
SH

cat > "$FIXTURE/home/foreign.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-background
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' 'background-session acquire:'
status=0
"$FM_HOME/bin/fm-lock.sh" 2>&1 || status=$?
printf 'exit=%s persisted lock=%s session=%s\n' "$status" "$(cat "$FM_HOME/state/.lock")" "$(cat "$FM_HOME/state/.lock.session")"
SH

cat > "$FIXTURE/home/holder.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-holder
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' 'holder acquire:'
"$FM_HOME/bin/fm-lock.sh"
printf 'persisted lock=%s session=%s\n' "$(cat "$FM_HOME/state/.lock")" "$(cat "$FM_HOME/state/.lock.session")"
"$FM_CLAUDE" "$FM_HOME/same.sh"
"$FM_CLAUDE" "$FM_HOME/foreign.sh"
SH

cat > "$FIXTURE/home/takeover.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-current
export CLAUDE_PID=9999999
export CLAUDE_CODE_CHILD_SESSION=1
printf '%s\n' 'stale-holder takeover:'
"$FM_HOME/bin/fm-lock.sh"
printf 'persisted lock=%s session=%s\n' "$(cat "$FM_HOME/state/.lock")" "$(cat "$FM_HOME/state/.lock.session")"
SH

chmod +x "$FIXTURE/home/holder.sh" "$FIXTURE/home/same.sh" "$FIXTURE/home/foreign.sh" "$FIXTURE/home/takeover.sh"

FM_HOME="$FIXTURE/home" FM_CLAUDE="$FAKE_CLAUDE" "$FAKE_CLAUDE" "$FIXTURE/home/holder.sh"
printf '9999999\n' > "$FIXTURE/home/state/.lock"
printf 'session-dead\n' > "$FIXTURE/home/state/.lock.session"
FM_HOME="$FIXTURE/home" "$FAKE_CLAUDE" "$FIXTURE/home/takeover.sh"
