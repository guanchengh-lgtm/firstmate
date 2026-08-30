#!/usr/bin/env bash
set -u

ROOT=${1:?repository root required}
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-hook-evidence.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
HOME_DIR="$FIXTURE/home"

mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state" "$FIXTURE/fakebin"
git init -q "$HOME_DIR"
git -C "$HOME_DIR" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
: > "$HOME_DIR/state/task.meta"
for script in fm-claude-stop-autoarm.sh fm-lock.sh fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh fm-session-lock-lib.sh fm-cursor-lib.sh fm-hook-host-lib.sh; do
  cp "$ROOT/bin/$script" "$HOME_DIR/bin/"
done
ln -s /bin/bash "$FIXTURE/fakebin/claude"
FAKE_CLAUDE="$FIXTURE/fakebin/claude"

cat > "$HOME_DIR/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf '%s\n' 'stale: evidence task needs attention'
SH

cat > "$HOME_DIR/foreign-hook.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-background
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
status=0
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null 2>&1 || status=$?
printf 'foreign Stop exit=%s epoch=%s\n' "$status" "$(test -e "$FM_HOME/state/.claude-autoarm-epoch" && printf present || printf absent)"
SH

cat > "$HOME_DIR/holder-hook.sh" <<'SH'
#!/usr/bin/env bash
export CLAUDE_CODE_SESSION_ID=session-holder
export CLAUDE_PID=$$
export CLAUDE_CODE_CHILD_SESSION=1
"$FM_HOME/bin/fm-lock.sh"
printf '%s\n' 'foreign Stop hook:'
"$FM_CLAUDE" "$FM_HOME/foreign-hook.sh"
printf '%s\n' 'owner Stop hook:'
status=0
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null 2>&1 || status=$?
printf 'owner Stop exit=%s epoch=%s\n' "$status" "$(sed -n 's/^.*outcome=\([a-z-]*\).*$/\1/p' "$FM_HOME/state/.claude-autoarm-epoch")"
SH

chmod +x "$HOME_DIR/bin/fm-claude-stop-autoarm.sh" "$HOME_DIR/bin/fm-lock.sh" "$HOME_DIR/bin/fm-watch-arm.sh"
chmod +x "$HOME_DIR/foreign-hook.sh" "$HOME_DIR/holder-hook.sh"

FM_HOME="$HOME_DIR" FM_CLAUDE="$FAKE_CLAUDE" "$FAKE_CLAUDE" "$HOME_DIR/holder-hook.sh"
