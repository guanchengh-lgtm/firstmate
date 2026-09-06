#!/usr/bin/env bash
set -euo pipefail
phase_root=$PWD
phase_fixture="$phase_root/.no-mistakes/test-phase/cli-rehearsal"
phase_evidence=/Users/AI/.no-mistakes/evidence/01M1VRWMEZJGZ0328RGDY94JYC
mkdir -p "$phase_fixture/seed/data" "$phase_fixture/home/state/task.inbox/handled" "$phase_fixture/home/config" "$phase_fixture/empty-home"
export GIT_AUTHOR_NAME='Record fixture' GIT_AUTHOR_EMAIL=record@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FM_HOME="$phase_fixture/home" FM_ROOT_OVERRIDE="$phase_root"
export FM_DATA_OVERRIDE="$FM_HOME/data" FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
export FM_RECORD_SETTLE_SECONDS=2 FM_RECORD_PUSH_TIMEOUT=5
rec() { env HOME="$phase_fixture/empty-home" "$phase_root/bin/fm-record.sh" "$@"; }
step() { printf '\n$ %s\n' "$*"; }
step 'gitleaks version; git lfs version'
gitleaks version
git lfs version
step 'Create an old-layout local origin and clone it into the scratch home.'
git init -q -b main "$phase_fixture/seed"
printf 'Preserved seed history.\n' > "$phase_fixture/seed/data/seed.md"
git -C "$phase_fixture/seed" add data/seed.md
git -C "$phase_fixture/seed" commit -qm seed
seed_head=$(git -C "$phase_fixture/seed" rev-parse HEAD)
git clone -q --bare "$phase_fixture/seed" "$phase_fixture/origin.git"
git clone -q "file://$phase_fixture/origin.git" "$FM_HOME/data"
step 'fm-record.sh setup --code-root <this worktree>'
rec setup --code-root "$phase_root"
mv "$FM_HOME/data/data/seed.md" "$FM_HOME/data/seed.md"
rmdir "$FM_HOME/data/data"
printf '# Captain\nPreserve the task notes.\n' > "$FM_HOME/data/captain.md"
printf 'working: collect evidence\n' > "$FM_HOME/state/task.status"
printf 'kind=ship\nmode=local-only\n' > "$FM_HOME/state/task.meta"
printf 'A handled task instruction.\n' > "$FM_HOME/state/task.inbox/handled/001.msg"
printf 'A runtime lock must stay local.\n' > "$FM_HOME/state/task.inbox/.seq.lock"
mkdir -p "$FM_HOME/data/raw" "$FM_HOME/data/.obsidian"
printf 'private workspace layout\n' > "$FM_HOME/data/.obsidian/workspace-mobile.json"
printf 'Fixture binary payload.\000\001\002\003\n' > "$FM_HOME/data/raw/sample.png"
ln -s captain.md "$FM_HOME/data/context.md"
step 'fm-record.sh checkpoint --reason stow'
rec checkpoint --reason stow
[ "$(git --git-dir="$phase_fixture/origin.git" rev-parse main)" = "$seed_head" ]
git -C "$FM_HOME/data" merge-base --is-ancestor "$seed_head" HEAD
printf 'The checkpoint kept the old remote tip as an ancestor and did not push.\n'
step 'git ls-tree -r --name-only HEAD'
git -C "$FM_HOME/data" ls-tree -r --name-only HEAD
step 'git show HEAD:.record-state/task.inbox/handled/001.msg'
git -C "$FM_HOME/data" show HEAD:.record-state/task.inbox/handled/001.msg
step 'fm-record.sh tick'
rec tick
step 'Clone the local origin at another path, reinstall local hooks, and compare LFS bytes.'
mkdir -p "$phase_fixture/restored/state" "$phase_fixture/restored/config"
git clone -q "file://$phase_fixture/origin.git" "$phase_fixture/restored/data"
env HOME="$phase_fixture/empty-home" FM_HOME="$phase_fixture/restored" FM_DATA_OVERRIDE="$phase_fixture/restored/data" FM_STATE_OVERRIDE="$phase_fixture/restored/state" FM_CONFIG_OVERRIDE="$phase_fixture/restored/config" "$phase_root/bin/fm-record.sh" setup --code-root "$phase_root"
env HOME="$phase_fixture/empty-home" git -C "$phase_fixture/restored/data" lfs pull
cmp "$FM_HOME/data/raw/sample.png" "$phase_fixture/restored/data/raw/sample.png"
[ -e "$phase_fixture/restored/data/context.md" ]
[ ! -e "$phase_fixture/restored/data/.obsidian/workspace-mobile.json" ]
[ ! -e "$phase_fixture/restored/data/.record-state/task.inbox/.seq.lock" ]
printf 'LFS source and restored SHA-256:\n'
shasum -a 256 "$FM_HOME/data/raw/sample.png" "$phase_fixture/restored/data/raw/sample.png"
printf 'The relative link resolves. Workspace state and the runtime lock are absent.\n'
step 'Run three quiet ticks and compare the commit and mirror file.'
quiet_head=$(git -C "$FM_HOME/data" rev-parse HEAD)
quiet_stamp=$(stat -f '%i %m %c' "$FM_HOME/data/.record-state/task.status")
for attempt in 1 2 3; do rec tick; done
[ "$(git -C "$FM_HOME/data" rev-parse HEAD)" = "$quiet_head" ]
[ "$(stat -f '%i %m %c' "$FM_HOME/data/.record-state/task.status")" = "$quiet_stamp" ]
printf 'Quiet ticks kept the same commit and mirror inode/timestamps.\n'
step 'Reject a synthetic credential through tick and the installed manual-commit hook.'
printf '%s%s\n' ghp _0123456789abcdefghijklmnopqrstuvwxyzAB > "$FM_HOME/data/rejected.md"
status=0
rec tick || status=$?
[ "$status" -eq 5 ]
printf 'tick exit=%s; HEAD and remote unchanged.\n' "$status"
[ "$(git -C "$FM_HOME/data" rev-parse HEAD)" = "$quiet_head" ]
[ "$(git --git-dir="$phase_fixture/origin.git" rev-parse main)" = "$quiet_head" ]
git -C "$FM_HOME/data" add rejected.md
status=0
env HOME="$phase_fixture/empty-home" git -C "$FM_HOME/data" commit -qm rejected || status=$?
[ "$status" -ne 0 ]
printf 'manual git commit exit=%s; no credential bytes reached Git history.\n' "$status"
git -C "$FM_HOME/data" restore --staged rejected.md
rm "$FM_HOME/data/rejected.md"
step 'Temporarily make the local origin unavailable, then tick a changed note.'
printf 'An offline edit remains recoverable.\n' >> "$FM_HOME/data/captain.md"
mv "$phase_fixture/origin.git" "$phase_fixture/origin.offline.git"
status=0
rec tick || status=$?
[ "$status" -eq 6 ]
local_head=$(git -C "$FM_HOME/data" rev-parse HEAD)
[ "$local_head" != "$quiet_head" ]
printf 'tick exit=%s; the complete new local commit remains present.\n' "$status"
sleep 2
step 'fm-record.sh health'
cp "$FM_HOME/data/.git/record-health" "$phase_fixture/health-before"
rec health
cmp "$phase_fixture/health-before" "$FM_HOME/data/.git/record-health"
printf 'Health was read-only. It retained the last push and reported current pending age.\n'
mv "$phase_fixture/origin.offline.git" "$phase_fixture/origin.git"
step 'fm-record.sh tick after restoring the origin, without another edit'
rec tick
[ "$(git --git-dir="$phase_fixture/origin.git" rev-parse main)" = "$local_head" ]
step 'Create a clean manual commit, then read health before another tick.'
printf 'Manual progress.\n' > "$FM_HOME/data/manual.md"
git -C "$FM_HOME/data" add manual.md
env HOME="$phase_fixture/empty-home" git -C "$FM_HOME/data" commit -qm 'Record manual progress'
sleep 2
rec health
step 'Advance the origin independently from the restored clone.'
printf 'Independent device progress.\n' > "$phase_fixture/restored/data/device.md"
git -C "$phase_fixture/restored/data" add device.md
env HOME="$phase_fixture/empty-home" FM_HOME="$phase_fixture/restored" FM_DATA_OVERRIDE="$phase_fixture/restored/data" FM_STATE_OVERRIDE="$phase_fixture/restored/state" FM_CONFIG_OVERRIDE="$phase_fixture/restored/config" git -C "$phase_fixture/restored/data" commit -qm 'Record other device progress'
# The restored clone started at quiet_head. Bring it forward only through a normal merge.
git -C "$phase_fixture/restored/data" fetch -q origin
env HOME="$phase_fixture/empty-home" git -C "$phase_fixture/restored/data" -c core.hooksPath=/dev/null merge -q --no-edit origin/main
env HOME="$phase_fixture/empty-home" git -C "$phase_fixture/restored/data" push -q origin main
remote_head=$(git --git-dir="$phase_fixture/origin.git" rev-parse main)
local_head=$(git -C "$FM_HOME/data" rev-parse HEAD)
step 'fm-record.sh tick with two different histories'
status=0
rec tick || status=$?
[ "$status" -eq 7 ]
[ "$(git --git-dir="$phase_fixture/origin.git" rev-parse main)" = "$remote_head" ]
[ "$(git -C "$FM_HOME/data" rev-parse HEAD)" = "$local_head" ]
printf 'tick exit=%s; both local and remote histories remain unchanged.\n' "$status"
step 'fm-record.sh checkpoint --reason stow after another local edit'
printf 'Local work after divergence.\n' >> "$FM_HOME/data/manual.md"
rec checkpoint --reason stow
rec health
printf '\nThe scratch rehearsal completed with no live-home or scheduler operation.\n'
