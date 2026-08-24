#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# A no-mistakes ship is refused unless validation truth is readable
# (bin/fm-validation-truth-lib.sh). The PR URL is passed so a builder id
# can prove a -nm run keyed by that URL before pr= is recorded.
# After that proof succeeds, an advisory manufactured-breakage check counts
# changed test files on the ship against per-file `breakage:` tested[] records
# in `no-mistakes axi logs --step test --run <id> --full` and prints exactly
# one line when a changed test file has no covering second-token entry:
#   BREAKAGE: <n> changed test file(s), <m> red record(s) - run <id>
# Test-file class (owned here): path matching (^|/)(tests?|spec|__tests__)/,
# or basename test_*.py, *_test.*, *.test.*, *.spec.*, *_spec.rb.
# m is files-with-a-red-record, not raw entry count. When axi is unreadable,
# m is ? and the run is <id|unknown>. Prints nothing only when n is 0 (or the
# run branch is not the task branch). Never changes the exit code.
# bin/fm-brief.sh's verifier DoD owns the instruction the test step records;
# this check only sees the durable tested[] prefix. Not a merge refusal.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-validation-truth-lib.sh
. "$SCRIPT_DIR/fm-validation-truth-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Path class owned by this script header. Direct-PR / local-only have no test
# step; those modes are skipped before listing.
fm_pr_check_is_test_path() {
  local p=$1 base
  base=${p##*/}
  case "$p" in
    tests/*|test/*|spec/*|__tests__/*|*/tests/*|*/test/*|*/spec/*|*/__tests__/*) return 0 ;;
  esac
  case "$base" in
    test_*.py|*_test.*|*.test.*|*.spec.*|*_spec.rb) return 0 ;;
  esac
  return 1
}

# Advisory only. Always returns 0. Prints at most one BREAKAGE line.
# Uses META from the caller scope (set before the PR_HEAD block returns).
breakage_advisory() {
  local meta=${META:-} kind mode WT timeout out run_id run_branch task_branch
  local DEFAULT mb list n m f logs line entry tok test_files covered_paths
  [ -n "$meta" ] && [ -f "$meta" ] || return 0
  kind=$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2- || true)
  case "$kind" in
    scout|secondmate) return 0 ;;
  esac
  mode=$(grep '^mode=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ "$mode" = no-mistakes ] || return 0
  WT=$(grep '^worktree=' "$meta" | tail -1 | cut -d= -f2- || true)
  WT=$(fm_nm_trim "$WT")
  [ -n "$WT" ] && [ -d "$WT" ] || return 0

  DEFAULT=$(default_branch "$WT") || return 0
  mb=$(git -C "$WT" merge-base "$DEFAULT" HEAD 2>/dev/null) || return 0
  list=$(git -C "$WT" diff --name-only --diff-filter=AM "${mb}..HEAD" 2>/dev/null) || return 0
  n=0
  test_files=
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    fm_pr_check_is_test_path "$f" || continue
    n=$((n + 1))
    test_files=${test_files}${f}$'\n'
  done <<EOF
$list
EOF
  [ "$n" -gt 0 ] || return 0

  timeout=$(fm_nm_remote_timeout)
  out=$(fm_nm_run "$WT" "$timeout" axi status)
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  task_branch=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || task_branch=
  if [ -n "$run_branch" ] && [ -n "$task_branch" ] && [ "$run_branch" != "$task_branch" ]; then
    return 0
  fi
  if [ -z "$out" ] || [ -z "$run_id" ]; then
    printf 'BREAKAGE: %s changed test file(s), ? red record(s) - run %s\n' \
      "$n" "${run_id:-unknown}"
    return 0
  fi

  logs=
  if ! logs=$(fm_nm_run_checked "$WT" "$timeout" axi logs --step test --run "$run_id" --full); then
    printf 'BREAKAGE: %s changed test file(s), ? red record(s) - run %s\n' "$n" "$run_id"
    return 0
  fi

  covered_paths=
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    entry=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*"[[:space:]]*//')
    tok=$(printf '%s\n' "$entry" | awk '{print $2}')
    [ -n "$tok" ] || continue
    covered_paths=${covered_paths}${tok}$'\n'
  done <<EOF
$(printf '%s\n' "$logs" | grep -E '^[[:space:]]*"[[:space:]]*breakage:' || true)
EOF

  m=0
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$covered_paths" | grep -Fxq -- "$f"; then
      m=$((m + 1))
    fi
  done <<EOF
$test_files
EOF
  [ "$n" -eq "$m" ] && return 0
  printf 'BREAKAGE: %s changed test file(s), %s red record(s) - run %s\n' "$n" "$m" "$run_id"
  return 0
}

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
fm_require_validation_truth "$META" "$ID" "$URL" || exit 1

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi
breakage_advisory || true

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
