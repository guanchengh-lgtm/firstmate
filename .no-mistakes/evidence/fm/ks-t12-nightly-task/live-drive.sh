#!/usr/bin/env bash
# Live drive of bin/fm-nightly.sh and bin/fm-maintain.py on an isolated fixture home.
set -u
ROOT=/Users/AI/.no-mistakes/worktrees/edb446952c22/01M2CV541BEPXKMFSNBJDAMH09
EV=/Users/AI/.no-mistakes/evidence/01M2CV541BEPXKMFSNBJDAMH09
T=$(mktemp -d /tmp/fm-nightly-live.XXXXXX)
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export FM_RECORD_SETTLE_SECONDS=0 FM_RECORD_LOCK_WAIT_SECONDS=1 FM_RECORD_PUSH_TIMEOUT=5 NIGHTLY_TICK_RETRY_SECONDS=0
NOW=2026-09-13T03:00:00Z
home=$T/home; origin=$T/origin.git; trans=$T/trans; repo=$T/repo
mkdir -p $home/data $home/state $home/config $T/empty $repo
git init --quiet --bare --initial-branch=main $origin
rec() { HOME=$T/empty FM_HOME=$home FM_ROOT_OVERRIDE=$ROOT FM_DATA_OVERRIDE=$home/data FM_STATE_OVERRIDE=$home/state FM_CONFIG_OVERRIDE=$home/config $ROOT/bin/fm-record.sh "$@"; }
nightly() { HOME=${NHOME:-$T/empty} FM_ROOT_OVERRIDE=$ROOT $ROOT/bin/fm-nightly.sh "$@"; }
step() { printf '\n===== %s =====\n' "$*"; }

step "setup Record home"
rec setup --init --origin file://$origin --code-root $ROOT
cat > $home/data/backlog.md <<'MD'
# backlog
- [ ] t1 - migrate the index later
- [x] t2 - done task
MD
mkdir -p $home/data/t1 $home/data/decisions
printf '# brief\nold brief\n' > $home/data/t1/brief.md
printf '{"launched_at":"2026-08-01T00:00:00Z"}\n' > $home/data/t1/launch.json
printf '# captain\n- the sky is blue\n- decided on 2026-01-02 to use restic\n' > $home/data/captain.md
printf '# d1\n' > $home/data/decisions/d1.md
rec tick; echo "tick rc=$?"
mkdir -p $trans/.claude/projects/demo $trans/.codex/sessions $trans/.pi/agent/sessions $trans/.grok/sessions "$trans/.cursor/projects/p1/agent-transcripts"
printf 'transcript one\n' > "$trans/.claude/projects/demo/my file.txt"
printf 'codex\n' > $trans/.codex/sessions/s.jsonl
printf '[fixture]\ntype = local\n' > $T/rclone.conf
printf 'real-password\n' > $T/pw
{ printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s\n' $repo; printf 'NIGHTLY_RCLONE_CONFIG=%s\n' $T/rclone.conf; printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s\n' $T/pw; printf 'NIGHTLY_ARCHIVE_HOST=livehost\n'; } > $home/config/nightly.env
RCLONE_CONFIG=$T/rclone.conf RESTIC_PASSWORD_COMMAND="cat $T/pw" restic -r rclone:fixture:$repo init
cat $home/config/nightly.env

step "S1 dry-run on the fixture home"
NHOME=$trans nightly run --fm-home $home --dry-run --now $NOW; echo "rc=$?"

step "S1b dry-run record-only"
git clone --quiet file://$origin $T/clone-dry
nightly run --record-only --record $T/clone-dry --dry-run --now $NOW; echo "rc=$?"

step "S2 full night run (real restic over rclone local)"
NHOME=$trans nightly run --fm-home $home --now $NOW; echo "rc=$?"
echo "--- stages.tsv"; cat $home/data/.git/nightly/stages.tsv
echo "--- last-attempt"; cat $home/data/.git/nightly/last-attempt
echo "--- last-complete"; cat $home/data/.git/nightly/last-complete
echo "--- archive.json"; cat $home/data/.git/nightly/archive.json
echo "--- origin log"; git --git-dir=$origin log --format='%h %s' | head -5
echo "--- views landed"; git --git-dir=$origin ls-tree -r --name-only HEAD | grep wiki/views
echo "--- receipt"; cat $home/data/wiki/views/maintenance/*.md
echo "--- digest json"; cat $home/data/wiki/views/nightly-digest.json
echo "--- real restic snapshots"; RCLONE_CONFIG=$T/rclone.conf RESTIC_PASSWORD_COMMAND="cat $T/pw" restic -r rclone:fixture:$repo snapshots

step "S3 status"
nightly status --fm-home $home; echo "rc=$?"

step "S4 digest lines (maintenance executable)"
python3 -B $ROOT/bin/fm-maintain.py digest --record $home/data --now 2026-09-13T09:00:00Z --max-lines 8 --line-chars 200; echo "rc=$?"

step "S5 restore into empty target, then refuse non-empty"
nightly restore --fm-home $home --target $T/restore; echo "rc=$?"
find $T/restore -type f | sed "s#$T##"
cmp "$trans/.claude/projects/demo/my file.txt" "$(find $T/restore -name 'my file.txt' -type f | head -1)" && echo "restored bytes equal"
nightly restore --fm-home $home --target $T/restore; echo "rc=$? (expect 2 non-empty target)"

step "S6 record-only run on a cloud clone"
git clone --quiet file://$origin $T/clone
printf -- '- [ ] t3 - new pending row without hold\n' >> $T/clone/backlog.md
git -C $T/clone commit --quiet -am 'add t3'; git -C $T/clone push --quiet origin HEAD
nightly run --record-only --record $T/clone --now 2026-09-14T03:00:00Z; echo "rc=$?"
cat $T/clone/.git/nightly/stages.tsv
git --git-dir=$origin log --format='%h %s' | head -3

step "S7a busy lock exits 3"
mkdir -p $home/data/.git/nightly
( NHOME=$trans nightly run --fm-home $home --now 2026-09-15T03:00:00Z >/dev/null 2>&1 & ) ; sleep 0.5
NHOME=$trans nightly run --fm-home $home --now 2026-09-15T03:00:00Z; echo "rc=$? (expect 3)"
sleep 8

step "S7b lint guard: missing backlog.md exits 2; deferral finding exits 1; rollout status"
mkdir -p $T/norec; git init --quiet $T/norec
python3 -B $ROOT/bin/fm-maintain.py lint --record $T/norec --now $NOW; echo "rc=$? (expect 2)"
python3 -B $ROOT/bin/fm-maintain.py lint --record $home/data --now $NOW; echo "rc=$? (expect 1)"
python3 -B $ROOT/bin/fm-maintain.py rollout status --record $home/data; echo "rc=$?"

step "S7c report-then-enforce transition and stow-gate"
R=$T/enf; mkdir -p $R; git init --quiet -b main $R
printf '# backlog\n- [ ] a - fine row\n' > $R/backlog.md; git -C $R add . ; git -C $R commit --quiet -m init
python3 -B $ROOT/bin/fm-maintain.py rollout init --record $R --now $NOW
python3 -B $ROOT/bin/fm-maintain.py lint --record $R --now $NOW --format json > $T/clean.json; echo "clean lint rc=$?"
for d in 01 02 03 04 05 06 07; do python3 -B $ROOT/bin/fm-maintain.py rollout advance --record $R --now 2026-09-${d}T03:00:00Z --lint-json $T/clean.json --scheduled-date 2026-09-$d | tail -1; done
python3 -B $ROOT/bin/fm-maintain.py rollout status --record $R
printf -- '- [ ] b - pending with no hold\n' >> $R/backlog.md
python3 -B $ROOT/bin/fm-maintain.py stow-gate --record $R --now $NOW; echo "stow-gate rc=$? (expect 1 in enforce)"
rm $R/backlog.md
python3 -B $ROOT/bin/fm-maintain.py stow-gate --record $R --now $NOW; echo "stow-gate rc=$? (no backlog.md)"

step "S8 install renders plist to a private path (no bootstrap)"
mkdir -p $T/code && cp -R $ROOT/bin $T/code/bin && git init --quiet -b main $T/code && git -C $T/code add bin && git -C $T/code commit --quiet -m code
FM_NIGHTLY_PLIST=$T/nightly.plist FM_NIGHTLY_LOG_DIR=$T/logs nightly install --fm-home $home --hour 3 --minute 0 --code-root $T/code; echo "rc=$?"
cat $T/nightly.plist
plutil -lint $T/nightly.plist

step "S9 wrong restic password: archive fails, Record stages still run, exit 1"
printf 'wrong\n' > $T/pw
NHOME=$trans nightly run --fm-home $home --now 2026-09-16T03:00:00Z; echo "rc=$? (expect 1)"
cat $home/data/.git/nightly/stages.tsv
grep -c 'stderr' $home/data/.git/nightly/stages.tsv || true
grep -n 'wrong password\|Fatal' $home/data/.git/nightly/stages.tsv $home/data/.git/nightly/archive.json || echo "no raw restic stderr in Record files"
echo "TMP=$T"
