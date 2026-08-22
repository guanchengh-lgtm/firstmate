#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. --method and
# --method=<merge|squash|rebase> are translated to the matching gh shorthand
# because gh does not accept --method. Extra args must not include --repo or -R
# because the repository comes only from the URL.
# A no-mistakes ship is refused unless validation truth is readable
# (bin/fm-validation-truth-lib.sh), independently of the recording step.
# After recording, this helper re-reads the forge rollup, refuses a red or
# pending rollup, and merges via `gh pr merge` with --match-head-commit
# <forge head> so GitHub enforces expectedHeadOid (gh-axi drops that flag).
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

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
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

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
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
fm_require_validation_truth "$META" "$ID" "$URL" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

fm_vt_require_merge_pin "$URL" "$ID" || exit 1

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

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
