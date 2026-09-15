#!/usr/bin/env bash
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-record-live2.XXXXXX")
export GIT_AUTHOR_NAME=live GIT_AUTHOR_EMAIL=live@example.invalid GIT_COMMITTER_NAME=live GIT_COMMITTER_EMAIL=live@example.invalid
export FM_RECORD_SETTLE_SECONDS=0 FM_RECORD_LOCK_WAIT_SECONDS=1 FM_RECORD_PUSH_TIMEOUT=5
mkhome() { local n=$1; mkdir -p "$LAB/$n/home/data" "$LAB/$n/home/state" "$LAB/$n/home/config"; git init -q --bare --initial-branch=main "$LAB/$n/origin.git"; }
rec() { local home=$1; shift; HOME="$LAB/empty" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-record.sh" "$@" 2>&1; echo "[exit=$?]"; }
step() { printf '\n### %s\n' "$*"; }
mkdir -p "$LAB/empty"
step "S5 E-attest (fake gitleaks wrapper logs outgoing scans)"
mkhome a; H=$LAB/a/home
rec "$H" setup --init --origin "file://$LAB/a/origin.git" --code-root "$ROOT" >/dev/null
echo seed > "$H/data/user.md"; rec "$H" tick | head -1
FAKE=$LAB/fakegl; mkdir -p "$FAKE"; REALGL=$(command -v gitleaks)
cat > "$FAKE/gitleaks" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in */outgoing.scan.*) echo "outgoing-scan: \$a" >> "$LAB/gl.log";; esac; done
exec "$REALGL" "\$@"
EOF
chmod +x "$FAKE/gitleaks"
echo manual > "$H/data/manual.md"; git -C "$H/data" add manual.md; git -C "$H/data" commit -q --no-verify -m manual
MANUAL=$(git -C "$H/data" rev-parse HEAD)
echo "--- manual sha in ledger before tick: $(grep -c "$MANUAL" "$H/data/.git/record-attested")"
: > "$LAB/gl.log"; PATH="$FAKE:$PATH" rec "$H" tick | head -1
echo "--- outgoing scans during tick (manual commit only): $(wc -l < "$LAB/gl.log" | tr -d ' ')"; sed 's|/private/var/[^ ]*/data/|<data>/|' "$LAB/gl.log"
echo "--- manual sha in ledger after tick: $(grep -c "$MANUAL" "$H/data/.git/record-attested")"
echo more >> "$H/data/user.md"; : > "$LAB/gl.log"; PATH="$FAKE:$PATH" rec "$H" tick | head -1
echo "--- outgoing scans on the following tick (owner commit never rescanned): $(wc -l < "$LAB/gl.log" | tr -d ' ')"
echo "--- ledger lines vs commits reachable from HEAD: $(wc -l < "$H/data/.git/record-attested" | tr -d ' ') / $(git -C "$H/data" rev-list --count HEAD)"
step "S11 E-prereq: setup succeeds with gitleaks and git-lfs only (plus base utils), restic absent"
FB=$LAB/fakebin; mkdir -p "$FB"; for t in gitleaks git-lfs git jq python3 bash sh mktemp date awk sed grep cut tr mv rm mkdir cp ln find sort head tail wc cat env dirname basename readlink realpath uname stat chmod touch sleep printf shasum sha256sum id hostname ls comm uniq xargs test expr tee od dd diff cmp; do p=$(command -v $t 2>/dev/null) && ln -sf "$p" "$FB/$t"; done
mkhome q; Q=$LAB/q/home
PATH="$FB" rec "$Q" setup --init --origin "file://$LAB/q/origin.git" --code-root "$ROOT"
echo "--- restic: $(PATH=$FB command -v restic || echo absent); rclone: $(PATH=$FB command -v rclone || echo absent); gitleaks: $(PATH=$FB command -v gitleaks)"
step "S12 foreign index.lock excludes a --required checkpoint with exit 9; HEAD unchanged"
BEFORE=$(git -C "$H/data" rev-parse HEAD)
printf 'foreign lock\n' > "$H/data/.git/index.lock"; echo x >> "$H/data/user.md"
rec "$H" checkpoint --reason teardown --required | head -1
echo "--- HEAD unchanged: $([ "$BEFORE" = "$(git -C "$H/data" rev-parse HEAD)" ] && echo yes || echo no); lock content: $(cat "$H/data/.git/index.lock")"
rm -f "$H/data/.git/index.lock"; rec "$H" checkpoint --reason teardown --required | head -1
step "S14 E-classify: push_once classes from a fake git on PATH"
FG=$LAB/fakegit; mkdir -p "$FG"; REALGIT=$(command -v git)
cat > "$FG/git" <<EOF
#!/usr/bin/env bash
if [ -f "$LAB/push-mode" ]; then for a in "\$@"; do if [ "\$a" = push ]; then case "\$(cat "$LAB/push-mode")" in
  nff) echo ' ! [rejected]        main -> main (non-fast-forward)' >&2; exit 1;;
  fetchfirst) echo ' ! [rejected]        main -> main (fetch first)' >&2; exit 1;;
  auth) echo 'fatal: Authentication failed for origin' >&2; exit 128;;
  lfs) echo 'batch response: LFS: upload failed' >&2; exit 2;;
  other) echo 'fatal: unable to access: Could not resolve host' >&2; exit 128;;
  hang) sleep 30;; esac; fi; done; fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$FG/git"
for m in nff fetchfirst auth lfs other hang; do echo "$m" > "$LAB/push-mode"; echo "c $m" >> "$H/data/user.md"; printf '%s -> ' "$m"; FM_RECORD_PUSH_TIMEOUT=2 PATH="$FG:$PATH" rec "$H" tick | head -1; done; rm -f "$LAB/push-mode"
rm -rf "$LAB"
