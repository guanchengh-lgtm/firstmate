#!/usr/bin/env bash
# Manufactured breakage: one line per subject, red then restored green.
set -u
ROOT=/Users/AI/.no-mistakes/worktrees/edb446952c22/01M2CV541BEPXKMFSNBJDAMH09
EV=/Users/AI/.no-mistakes/evidence/01M2CV541BEPXKMFSNBJDAMH09
cd "$ROOT" || exit 9
one() {
  local test=$1 subject=$2 line=$3 from=$4 to=$5 tag=$6
  echo "===== breakage $tag: $subject:$line '$from' -> '$to'"
  sed -i '' "${line}s|${from}|${to}|" "$subject"
  git diff --stat -- "$subject"
  bash "tests/$test" > "$EV/red-$tag.log" 2>&1; rc=$?
  echo "red run exit=$rc"; grep -m3 'not ok' "$EV/red-$tag.log"
  git checkout -- "$subject"
  p=$(git status --porcelain); echo "porcelain after restore: [${p}]"
  bash "tests/$test" > "$EV/green-$tag.log" 2>&1; rc=$?
  echo "green run exit=$rc"; grep -c 'not ok' "$EV/green-$tag.log"; tail -1 "$EV/green-$tag.log"
}
one fm-nightly-archive.test.sh bin/fm-nightly.sh 1142 '-eq 11 ' '-eq 99 ' archive
one fm-maintain.test.sh bin/fm-maintain.py 1287 'if not os.path.isfile' 'if os.path.isfile' maintain
one fm-nightly.test.sh bin/fm-nightly.sh 867 'signal-term' 'bound-hit' nightly
one fm-record.test.sh bin/fm-record.sh 1594 '= remote-branch-missing ]' '= remote-branch-missingX ]' record
one fm-session-start.test.sh bin/fm-session-start.sh 1276 'nightly-digest.json" ]' 'nightly-digest.jsonx" ]' session
echo "FINAL porcelain: [$(git status --porcelain)]"
