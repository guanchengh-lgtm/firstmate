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
# changed test files on the ship against `breakage:` records in
# `no-mistakes axi logs --step test --run <id> --full` and prints exactly one
# line when the counts differ:
#   BREAKAGE: <n> changed test file(s), <m> red record(s) - run <id>
# It prints nothing when the counts match or when the run, diff, or log is
# unreadable, and it never changes the exit code. bin/fm-brief.sh's verifier
# DoD owns the instruction the test step records; this check only sees the
# durable `tested[]` prefix. Not a merge refusal.
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

# tests/** plus common project test globs. Direct-PR / local-only have no
# test step; callers skip those modes before listing.
fm_pr_check_is_test_path() {
  case "$1" in
    tests/*|test/*|*/tests/*|*/test/*|*/__tests__/*) return 0 ;;
    *.test.*|*.spec.*|*_test.*|*/test_*) return 0 ;;
  esac
  return 1
}

fm_pr_check_diff_base() {  # <worktree>
  local wt=$1 ref
  ref=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || true
  if [ -n "$ref" ]; then
    printf '%s' "$ref"
    return 0
  fi
  for ref in origin/main origin/master main master; do
    if git -C "$wt" rev-parse --verify -q "$ref" >/dev/null 2>&1; then
      printf '%s' "$ref"
      return 0
    fi
  done
  return 1
}

# Newest run id for PR URL $1. Prefers axi status in the meta worktree/project
# when that run's pr field matches, else the global sqlite PR-URL index.
fm_pr_check_run_id_for_pr() {  # <pr-url> <meta-file>
  local url dir timeout out id pr db esc row
  url=$(fm_vt_canon_url "$1")
  [ -n "$url" ] || return 1
  dir=$(fm_vt_meta_runs_dir "$2") || dir=
  timeout=$(fm_nm_remote_timeout)
  if [ -n "$dir" ] && command -v no-mistakes >/dev/null 2>&1; then
    out=$(fm_nm_run_checked "$dir" "$timeout" axi status) || out=
    id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
    pr=$(fm_vt_canon_url "$(fm_nm_strip_quotes "$(fm_nm_field "$out" pr)")")
    if [ -n "$id" ] && [ "$pr" = "$url" ]; then
      printf '%s' "$id"
      return 0
    fi
  fi
  command -v sqlite3 >/dev/null 2>&1 || return 1
  db=${NO_MISTAKES_HOME:-$HOME/.no-mistakes}/state.sqlite
  [ -f "$db" ] && [ ! -L "$db" ] || return 1
  esc=${url//\'/\'\'}
  row=$(sqlite3 -readonly "$db" \
    "select id from runs where pr_url is not null and pr_url != '' and rtrim(pr_url, '/') = '$esc' order by updated_at desc, rowid desc limit 1;" \
    2>/dev/null) || return 1
  row=$(fm_nm_trim "$row")
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# Advisory only. Always returns 0. Prints at most one BREAKAGE line.
# Optional $3 is a forge head SHA already read by the caller; HEAD is the
# fallback when that object is missing from the worktree.
fm_pr_check_breakage_advisory() {  # <meta-file> <pr-url> [pr-head]
  local meta=$1 url=$2 head=${3:-} kind mode dir timeout run_id base logs n m f list
  kind=$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2- || true)
  case "$kind" in
    scout|secondmate) return 0 ;;
  esac
  mode=$(grep '^mode=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ "$mode" = no-mistakes ] || return 0
  url=$(fm_vt_canon_url "$url")
  [ -n "$url" ] || return 0
  dir=$(fm_vt_meta_runs_dir "$meta") || return 0
  run_id=$(fm_pr_check_run_id_for_pr "$url" "$meta") || return 0
  [ -n "$run_id" ] || return 0
  base=$(fm_pr_check_diff_base "$dir") || return 0
  head=$(fm_nm_trim "$head")
  if ! fm_pr_head_valid "$head" || ! git -C "$dir" cat-file -e "${head}^{commit}" 2>/dev/null; then
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 0
  fi
  list=$(git -C "$dir" diff --name-only --diff-filter=ACMR "${base}...${head}" 2>/dev/null) || return 0
  n=0
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    fm_pr_check_is_test_path "$f" || continue
    n=$((n + 1))
  done <<EOF
$list
EOF
  timeout=$(fm_nm_remote_timeout)
  logs=$(fm_nm_run_checked "$dir" "$timeout" axi logs --step test --run "$run_id" --full) || return 0
  m=$(printf '%s\n' "$logs" | grep -o 'breakage:' | wc -l | tr -d ' ') || m=0
  case "$m" in
    ''|*[!0-9]*) m=0 ;;
  esac
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
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi
fm_pr_check_breakage_advisory "$META" "$URL" "$PR_HEAD" || true

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

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

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
