#!/usr/bin/env bash
set -u
export FM_TEST_SKIP_ORPHAN_REAP=1
EVIDENCE_SCRATCH="$PWD/.no-mistakes/teardown-evidence-fixtures"
mkdir -p "$EVIDENCE_SCRATCH"
export TMPDIR="$EVIDENCE_SCRATCH"
set -T
shopt -s extdebug
trap 'case "$BASH_COMMAND" in test_*) false ;; esac' DEBUG
source tests/fm-teardown.test.sh
trap - DEBUG
set +T
shopt -u extdebug
trap 'fm_test_cleanup; rmdir "$EVIDENCE_SCRATCH"' EXIT
set -e
for shape in no-mistakes direct-PR local-only scout; do
  printf '\nScenario: %s\n' "$shape"
  case_dir=$(make_case "record-success-$shape")
  git init --quiet "$case_dir"
  mode=$shape
  kind=ship
  if [ "$shape" = scout ]; then mode=no-mistakes; kind=scout; fi
  write_meta "$case_dir" "$mode" "$kind"
  mkdir -p "$case_dir/data/task-x1" "$case_dir/state/task-x1.inbox/handled"
  printf '# Findings\nThe fixture report is ready.\n' > "$case_dir/data/task-x1/report.md"
  printf 'done: fixture report complete\n' > "$case_dir/state/task-x1.status"
  printf 'Preserve the final inbox message.\n' > "$case_dir/state/task-x1.inbox/handled/001.msg"
  if [ "$kind" = scout ]; then
    FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$case_dir/data" \
      FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" \
      PATH="$case_dir/fakebin:$PATH" \
      "$ROOT/bin/fm-captain-hold.sh" complete task-x1 --none --no-ideas
  else
    wt_commit "$case_dir" "Capture fixture work"
    tip=$(git -C "$case_dir/wt" rev-parse HEAD)
    if [ "$mode" = local-only ]; then
      git -C "$case_dir/project" update-ref refs/heads/main "$tip"
    else
      git -C "$case_dir/wt" push -q origin fm/task-x1
      git -C "$case_dir/project" fetch -q origin
    fi
  fi
  setup_teardown_record "$case_dir"
  printf '$ bin/fm-teardown.sh task-x1\n'
  HOME="$case_dir/empty-home" FM_RECORD_SETTLE_SECONDS=0 run_teardown "$case_dir"
  assert_absent "$case_dir/state/task-x1.meta" 'teardown retained live metadata'
  assert_absent "$case_dir/state/task-x1.inbox" 'teardown retained live inbox'
  printf '$ git show HEAD:.record-state/task-x1.inbox/handled/001.msg\n'
  git -C "$case_dir/data" show HEAD:.record-state/task-x1.inbox/handled/001.msg
  printf '$ git show HEAD:.record-state/task-x1.meta\n'
  git -C "$case_dir/data" show HEAD:.record-state/task-x1.meta
  git -C "$case_dir/data" cat-file -e HEAD:task-x1/report.md
  [ -z "$(git --git-dir="$case_dir/record-origin.git" for-each-ref)" ] || fail 'teardown pushed the Record'
  printf 'Live metadata and inbox are removed. Their complete bytes remain in the local Record commit.\n'
  printf 'The report is committed. Record delivery remains local until the next tick.\n'
done
