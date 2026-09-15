#!/usr/bin/env bash
# Live manual scenarios against bin/fm-record.sh and bin/fm-record-scan.sh.
set -u
ROOT=$1; E=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-record-live.XXXXXX")
export GIT_AUTHOR_NAME=live GIT_AUTHOR_EMAIL=live@example.invalid GIT_COMMITTER_NAME=live GIT_COMMITTER_EMAIL=live@example.invalid
export FM_RECORD_SETTLE_SECONDS=0 FM_RECORD_LOCK_WAIT_SECONDS=1 FM_RECORD_PUSH_TIMEOUT=5
mkhome() { local n=$1; mkdir -p "$LAB/$n/home/data" "$LAB/$n/home/state" "$LAB/$n/home/config" "$LAB/$n/logs"; git init -q --bare --initial-branch=main "$LAB/$n/origin.git"; }
rec() { local home=$1; shift; HOME="$LAB/empty" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-record.sh" "$@" 2>&1; echo "[exit=$?]"; }
step() { printf '\n### %s\n' "$*"; }
mkdir -p "$LAB/empty"

step "S1 setup --init, then tick commits and pushes"
mkhome a; H=$LAB/a/home
rec "$H" setup --init --origin "file://$LAB/a/origin.git" --code-root "$ROOT"
echo "hello" > "$H/data/user.md"
rec "$H" tick
step "S1b unchanged tick emits commit + pending"
rec "$H" tick
step "S1c health has exactly seven keys after pushed"
rec "$H" health
echo "--- raw health file:"; cat "$H/data/.git/record-health"

step "S2 crash window: fault-inject read-tree on second checkpoint, next checkpoint reconciles"
FAKE=$LAB/fakegit; mkdir -p "$FAKE"; REALGIT=$(command -v git)
cat > "$FAKE/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do if [ "\$a" = read-tree ] && [ -z "\${FM_LIVE_CRASHED:-}" ] && [ -f "$LAB/crash-armed" ]; then rm -f "$LAB/crash-armed"; exit 137; fi; done
exec "$REALGIT" "\$@"
EOF
chmod +x "$FAKE/git"
echo "second" > "$H/data/second.md"
touch "$LAB/crash-armed"
PATH="$FAKE:$PATH" rec "$H" checkpoint --reason stow
echo "--- after crash: HEAD=$(git -C "$H/data" rev-parse --short HEAD) diff --cached count=$(git -C "$H/data" diff --cached --name-only | wc -l | tr -d ' ')"
HEAD_BEFORE=$(git -C "$H/data" rev-parse HEAD)
step "S2b next checkpoint (no new bytes) reconciles: HEAD unchanged, unchanged state"
rec "$H" checkpoint --reason stow
echo "--- HEAD unchanged: $([ "$HEAD_BEFORE" = "$(git -C "$H/data" rev-parse HEAD)" ] && echo yes || echo no); diff --cached count=$(git -C "$H/data" diff --cached --name-only | wc -l | tr -d ' ')"

step "S3 adversarial: real user staging (not parent tree) refuses exit 8 index-recovery"
echo "staged by user" > "$H/data/staged.md"; git -C "$H/data" add staged.md
rec "$H" checkpoint --reason stow
git -C "$H/data" reset -q staged.md
step "S3b gate-2: reconcile with staged content reports local-changes exit 4, not index-recovery"
git -C "$H/data" add staged.md
rec "$H" reconcile
step "S3c verify stays read-only with staged content"
rec "$H" verify
echo "--- still staged: $(git -C "$H/data" diff --cached --name-only)"
git -C "$H/data" reset -q staged.md; rm -f "$H/data/staged.md"
rec "$H" tick >/dev/null

step "S4 root-commit crash window: first checkpoint crashes between commit and read-tree"
mkhome r; R=$LAB/r/home
rec "$R" setup --init --origin "file://$LAB/r/origin.git" --code-root "$ROOT"
echo "first" > "$R/data/first.md"
touch "$LAB/crash-armed"
PATH="$FAKE:$PATH" rec "$R" checkpoint --reason stow
echo "--- root HEAD parents: $(git -C "$R/data" rev-list --count HEAD) commit(s); diff --cached count=$(git -C "$R/data" diff --cached --name-only | wc -l | tr -d ' ')"
step "S4b next checkpoint reconciles the root crash"
rec "$R" checkpoint --reason stow
echo "--- commits=$(git -C "$R/data" rev-list --count HEAD) cached=$(git -C "$R/data" diff --cached --name-only | wc -l | tr -d ' ')"

step "S5 E-attest: manual --no-verify clean commit is the only SHA scanned on next tick"
FAKESCAN=$LAB/fakescan; mkdir -p "$FAKESCAN"
cat > "$FAKESCAN/fm-record-scan.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LAB/scan-calls.log"
exit 0
EOF
chmod +x "$FAKESCAN/fm-record-scan.sh"
echo "manual" > "$H/data/manual.md"; git -C "$H/data" add manual.md; git -C "$H/data" commit -q --no-verify -m "manual commit"
MANUAL=$(git -C "$H/data" rev-parse HEAD)
: > "$LAB/scan-calls.log"
echo "--- ledger contains manual sha before tick: $(grep -c "$MANUAL" "$H/data/.git/record-attested")"
PATH="$FAKESCAN:$PATH" rec "$H" tick
echo "--- scan calls:"; cat "$LAB/scan-calls.log"
echo "--- manual sha $MANUAL"
echo "--- ledger contains manual sha after tick: $(grep -c "$MANUAL" "$H/data/.git/record-attested")"
: > "$LAB/scan-calls.log"
echo "again" >> "$H/data/user.md"
PATH="$FAKESCAN:$PATH" rec "$H" tick
echo "--- scan calls on next tick (owner commit never rescanned as outgoing):"; cat "$LAB/scan-calls.log"

step "S6 E-attest adversarial: secret in manual --no-verify commit is caught by real scan on tick"
printf 'token=%s%s\n' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' > "$H/data/leak.md"; git -C "$H/data" add leak.md; git -C "$H/data" commit -q --no-verify -m "leak"
rec "$H" tick
git -C "$H/data" reset -q --hard HEAD~1

step "S7 push-pending then diverged health keys and failure_class"
mkhome p; P=$LAB/p/home
rec "$P" setup --init --origin "file://$LAB/p/origin.git" --code-root "$ROOT"
echo one > "$P/data/one.md"; rec "$P" tick >/dev/null
mv "$LAB/p/origin.git" "$LAB/p/origin.git.away"
echo two > "$P/data/two.md"; rec "$P" tick
rec "$P" health
echo "--- keys: $(cut -d= -f1 "$P/data/.git/record-health" | tr '\n' ' ')"
sleep 2
rec "$P" health | grep pending_age
mv "$LAB/p/origin.git.away" "$LAB/p/origin.git"
CL=$LAB/p/clone; git clone -q "file://$LAB/p/origin.git" "$CL"; echo other > "$CL/other.md"; git -C "$CL" add other.md; git -C "$CL" commit -q -m other; git -C "$CL" push -q origin main
rec "$P" tick
echo "--- health file after diverged (was offline first):"; cat "$P/data/.git/record-health"

step "S8 E-misnamed: zip renamed .bin and a .tgz each block alone through real gitleaks"
SC=$ROOT/bin/fm-record-scan.sh
mk1=$LAB/mis1; mk2=$LAB/mis2; mkdir -p "$mk1/src" "$mk2/src"
printf 'k=%s%s\n' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' > "$mk1/src/t.txt"
( cd "$mk1/src" && zip -q ../renamed.bin t.txt ); rm -r "$mk1/src"
cp -r "$mk1" "$LAB/mis2src"; printf 'k=%s%s\n' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' > "$mk2/src/t.txt"
( cd "$mk2" && tar -czf bundle.tgz -C src t.txt ); rm -r "$mk2/src"
echo "--- renamed.bin:"; "$SC" chain --dir "$mk1" 2>&1; echo "[exit=$?]"
echo "--- bundle.tgz:"; "$SC" chain --dir "$mk2" 2>&1; echo "[exit=$?]"
step "S8b scratch hit locator: token in notes.pdf names payload path, not sha"
mk3=$LAB/mis3; mkdir -p "$mk3/sub"; printf 'k=%s%s\n' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' > "$mk3/sub/notes.pdf"
"$SC" chain --dir "$mk3" 2>&1; echo "[exit=$?]"
step "S8c scratch location: inside the payload's git dir when payload is a repo, sibling otherwise; nothing left behind"
mk4=$LAB/repo4; mkdir -p "$mk4/wiki/views"; git -C "$mk4" init -q; echo clean > "$mk4/wiki/views/a.md"
"$SC" chain --dir "$mk4/wiki/views" 2>&1; echo "[exit=$?]"
echo "--- leftovers in repo4 work tree: $(find "$mk4" -name '*.scan.*' -not -path '*/.git/*' | wc -l | tr -d ' ')  ; in .git: $(find "$mk4/.git" -name '*.scan.*' | wc -l | tr -d ' ')"
echo "--- leftovers beside mis1: $(ls -d "$LAB"/mis1.scan.* 2>/dev/null | wc -l | tr -d ' ')"
step "S9 E-nested: zip in zip refuses with nested message"
mk5=$LAB/nest; mkdir -p "$mk5/w"; echo inner > "$mk5/w/inner.txt"; ( cd "$mk5/w" && zip -q inner.zip inner.txt && zip -q ../outer.zip inner.zip ); rm -r "$mk5/w"
"$SC" chain --dir "$mk5" 2>&1; echo "[exit=$?]"
step "S10 E-locator: ordinary bad path named; credential-shaped path redacted"
"$SC" chain --dir "$LAB/does-not-exist" 2>&1; echo "[exit=$?]"
mk6=$LAB/cred; mkdir -p "$mk6"; ln -s /nonexistent "$mk6/ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"
"$SC" chain --dir "$mk6" 2>&1; echo "[exit=$?]"
step "S11 E-prereq: setup with gitleaks and git-lfs only on PATH succeeds; restic absent"
FB=$LAB/fakebin; mkdir -p "$FB"; for t in gitleaks git-lfs git jq python3 bash mktemp date awk sed grep cut tr mv rm mkdir cp ln find sort head tail wc cat env dirname basename readlink realpath uname stat chmod touch flock sleep printf; do p=$(command -v $t 2>/dev/null) && ln -sf "$p" "$FB/$t"; done
mkhome q; Q=$LAB/q/home
PATH="$FB" rec "$Q" setup --init --origin "file://$LAB/q/origin.git" --code-root "$ROOT"
echo "--- restic on PATH: $(PATH=$FB command -v restic || echo none)"
step "S12 index.lock: foreign index.lock excludes the checkpoint"
touch "$H/data/.git/index.lock"; echo x >> "$H/data/user.md"
rec "$H" checkpoint --reason stow
rm -f "$H/data/.git/index.lock"
step "S13 line counts"
wc -l "$ROOT/bin/fm-record.sh" "$ROOT/bin/fm-record-scan.sh"
echo "python3 invocations in fm-record.sh: $(grep -c 'python3 -' "$ROOT/bin/fm-record.sh"); in scan: $(grep -c 'python3 -' "$ROOT/bin/fm-record-scan.sh")"
echo "restic/rclone in record scripts+tests: $(grep -ci 'restic\|rclone' "$ROOT/bin/fm-record.sh" "$ROOT/bin/fm-record-scan.sh" "$ROOT/tests/fm-record.test.sh" "$ROOT/tests/fm-record-scan.test.sh" | tr '\n' ' ')"
echo "record-publication refs: $(grep -rc 'record-publication\|recover_index_publication' "$ROOT/bin" "$ROOT/tests" "$ROOT/docs" | grep -v ':0' | tr '\n' ' ')"
rm -rf "$LAB"
