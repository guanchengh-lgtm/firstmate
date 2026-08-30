#!/usr/bin/env bash
# Merge a task's PR after recording validated PR metadata through
# bin/fm-pr-check.sh, so teardown can verify landed work.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An upstream
# sync instead requires --merge and refuses every explicit squash or rebase
# form before recording merge state. A checked-out branch with the literal
# prefix fm/merge-upstream is a sync, so fm/merge-upstreamish also matches. If
# the recorded worktree is absent or is not a repository, the branch check
# falls back to the forge headRefName. A merge at HEAD is also a sync when its
# second parent is reachable from the already-local
# ${FM_UPSTREAM_REF:-upstream/main}; an absent ref makes this signal unknown,
# never fetches, and does not abort. The branch signal alone is sufficient.
# This helper cannot prevent a squash through the GitHub UI or another command.
# --method and --method=<merge|squash|rebase> are translated to the matching gh
# shorthand because gh does not accept --method. Extra args must not include
# --repo or -R in any form, including a bundled short-option cluster such as
# -yR, because the repository comes only from the URL.
# A no-mistakes ship is refused unless validation truth is readable
# (bin/fm-validation-truth-lib.sh), independently of the recording step.
# After recording, this helper re-reads the forge rollup, refuses a red or
# pending rollup, and merges via `gh pr merge` with --match-head-commit
# <forge head> so GitHub enforces expectedHeadOid (gh-axi drops that flag).
#
# Invariant: this merge path is GitHub-only by standing captain decision at the
# upstream merge (2026-08-24). bin/fm-pr-lib.sh still parses GitLab merge
# request URLs so the watcher can follow them, but the validation-truth second
# proof (fm_require_validation_truth + fm_vt_require_merge_pin) exists only for
# GitHub, so restoring a GitLab merge arm must first give GitLab an equivalent
# proof rather than silently exempting it from this invariant.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-validation-truth-lib.sh
. "$SCRIPT_DIR/fm-validation-truth-lib.sh"
# Role partition: merging is MAIN-owned; the Pi supervision branch reports the
# green PR and never merges (contract: bin/fm-lease-lib.sh; no-op in homes
# without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "PR merge (fm-pr-merge)"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

caller_merge_method() {
  local arg method='' expect_value=0
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
      case "$arg" in
        merge|squash|rebase) method=$arg ;;
      esac
      expect_value=0
      continue
    fi
    case "$arg" in
      --merge) method=merge ;;
      --squash) method=squash ;;
      --rebase) method=rebase ;;
      --method) expect_value=1 ;;
      --method=merge|--method=squash|--method=rebase) method=${arg#--method=} ;;
    esac
  done
  printf '%s\n' "$method"
}

reject_upstream_sync_methods() {
  local arg expect_value=0
  for arg in "$@"; do
    if [ "$expect_value" -eq 1 ]; then
      [ "$arg" = merge ] || {
        echo "error: upstream-sync PRs require merge method merge" >&2
        return 1
      }
      expect_value=0
      continue
    fi
    case "$arg" in
      --squash|--squash=*|--rebase|--rebase=*|--method=squash|--method=rebase)
        echo "error: upstream-sync PRs require merge method merge" >&2
        return 1
        ;;
      --method) expect_value=1 ;;
      --method=*)
        [ "$arg" = --method=merge ] || {
          echo "error: upstream-sync PRs require merge method merge" >&2
          return 1
        }
        ;;
      --*) ;;
      -*s*|-*r*)
        echo "error: upstream-sync PRs require merge method merge" >&2
        return 1
        ;;
    esac
  done
  [ "$expect_value" -eq 0 ] || {
    echo "error: upstream-sync PRs require merge method merge" >&2
    return 1
  }
}

head_has_upstream_parent() {
  local wt=$1 upstream_ref upstream_commit second_parent
  upstream_ref=${FM_UPSTREAM_REF:-upstream/main}
  if ! upstream_commit=$(git -C "$wt" rev-parse --verify --quiet "$upstream_ref^{commit}" 2>/dev/null); then
    return 1
  fi
  if ! second_parent=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^2' 2>/dev/null); then
    return 1
  fi
  git -C "$wt" merge-base --is-ancestor "$second_parent" "$upstream_commit" 2>/dev/null
}

is_upstream_sync_pr() {
  local wt=$1 branch
  branch=
  if [ -n "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    if ! branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null); then
      branch=
    fi
    case "$branch" in
      fm/merge-upstream*) return 0 ;;
    esac
    head_has_upstream_parent "$wt" && return 0
  else
    if ! branch=$(gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null); then
      branch=
    fi
    case "$branch" in
      fm/merge-upstream*) return 0 ;;
    esac
  fi
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
      --*) ;;
      # A single-dash argument is a short-option cluster, which gh expands one
      # character at a time, so -yR carries --repo exactly as a bare -R does.
      -*R*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
UPSTREAM_SYNC=0
if is_upstream_sync_pr "$WT"; then
  UPSTREAM_SYNC=1
  reject_upstream_sync_methods "$@" || exit 1
fi

merge_args=()
if [ "$UPSTREAM_SYNC" -eq 1 ]; then
  RESOLVED_MERGE_METHOD=merge
  if ! caller_has_merge_method "$@"; then
    merge_args=(--merge)
  fi
else
  RESOLVED_MERGE_METHOD=$(caller_merge_method "$@")
  if ! caller_has_merge_method "$@"; then
    merge_args=(--squash)
    RESOLVED_MERGE_METHOD=squash
  fi
fi

fm_require_validation_truth "$META" "$ID" "$URL" || exit 1

if [ -n "$RESOLVED_MERGE_METHOD" ]; then
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" "$RESOLVED_MERGE_METHOD"
else
  "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
fi
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

fm_vt_require_merge_pin "$URL" "$ID" || exit 1

# Translate gh-axi-style --method into gh shorthands, then pin the head.
gh_args=()
set -- "${merge_args[@]+"${merge_args[@]}"}" "$@"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method=merge|--method=squash|--method=rebase)
      gh_args+=("--${1#--method=}")
      ;;
    --method)
      shift
      case "${1:-}" in
        merge|squash|rebase) gh_args+=("--$1") ;;
        *)
          echo "error: --method must be merge, squash, or rebase" >&2
          exit 1
          ;;
      esac
      ;;
    --match-head-commit|--match-head-commit=*)
      echo "error: extra merge arguments must not override the head pin" >&2
      exit 1
      ;;
    *)
      gh_args+=("$1")
      ;;
  esac
  shift
done

gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${gh_args[@]+"${gh_args[@]}"}" --match-head-commit "$FM_VT_FORGE_HEAD"
