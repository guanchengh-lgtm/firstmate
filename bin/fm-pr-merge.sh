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
# After that command returns, GitHub's live state is read back and accepted
# only when the pull request is merged or in the merge queue. A confirmed
# merge is published through bin/fm-merge-outcome-lib.sh.
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
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
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

# Whether the caller's own extra arguments asked for auto-merge, including the
# --flag=value spelling the forge's flag parser accepts. --disable-auto cancels
# the request, and gh exposes no short option that could bundle either flag.
caller_requested_auto_merge() {
  local arg requested=1
  for arg in "$@"; do
    case "$arg" in
      --auto) requested=0 ;;
      --auto=*)
        case "${arg#--auto=}" in
          [tT]|[tT][rR][uU][eE]|1) requested=0 ;;
          *) requested=1 ;;
        esac
        ;;
      --disable-auto) requested=1 ;;
    esac
  done
  return "$requested"
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

# Read one live GitHub pull request view after gh pr merge returns. gh supplies
# the queue-aware view; gh-axi remains the degradation path that can prove a
# landed merge without making gh a prerequisite for that read.
FM_PR_GITHUB_STATE=
FM_PR_GITHUB_MERGED=
FM_PR_GITHUB_QUEUED=
FM_PR_GITHUB_BASE=
FM_PR_GITHUB_QUEUE_OBSERVED=false
github_read_outcome_with_gh() {
  local fields line
  local total=0 named=0
  local state='' merged='' queued='' base=''

  # shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
  if ! fields=$(gh api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue baseRefName}}}' \
    -F "owner=$PR_OWNER" -F "repo=$PR_REPO" -F "number=$PR_NUMBER" \
    --jq '.data.repository.pullRequest | "state=" + (.state // ""), "merged=" + (.merged | tostring), "queued=" + (.isInMergeQueue | tostring), "base=" + (.baseRefName // "")' \
    2>/dev/null) || [ -z "$fields" ]; then
    return 1
  fi
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      state=*) state=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      queued=*) queued=${line#queued=} ;;
      base=*) base=${line#base=} ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  if [ "$named" -ne 4 ] || [ "$total" -ne 4 ] || [ -z "$state" ] \
    || { [ "$merged" != true ] && [ "$merged" != false ]; } \
    || { [ "$queued" != true ] && [ "$queued" != false ]; } \
    || [ -z "$base" ]; then
    return 1
  fi

  FM_PR_GITHUB_STATE=$state
  FM_PR_GITHUB_MERGED=$merged
  FM_PR_GITHUB_QUEUED=$queued
  FM_PR_GITHUB_BASE=$base
  FM_PR_GITHUB_QUEUE_OBSERVED=true
}

github_read_outcome_with_gh_axi() {
  local output state
  if ! output=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>/dev/null); then
    return 1
  fi
  if ! state=$(printf '%s\n' "$output" | awk '
    $1 == "state:" { count++; value=$2 }
    END { if (count == 1 && value != "") print value; else exit 1 }
  '); then
    return 1
  fi
  case "$state" in
    merged)
      FM_PR_GITHUB_STATE=MERGED
      FM_PR_GITHUB_MERGED=true
      FM_PR_GITHUB_QUEUED=false
      ;;
    *)
      FM_PR_GITHUB_STATE=$state
      FM_PR_GITHUB_MERGED=false
      FM_PR_GITHUB_QUEUED=unknown
      ;;
  esac
  FM_PR_GITHUB_BASE=
  FM_PR_GITHUB_QUEUE_OBSERVED=false
}

github_read_outcome() {
  if ! command -v gh >/dev/null 2>&1; then
    github_read_outcome_with_gh_axi && return 0
    echo "error: could not read the GitHub pull request outcome after the merge attempt; PR metadata and merge poll remain recorded" >&2
    return 1
  fi
  # Only a failed gh read falls back. A gh read that completes and reports the
  # pull request as neither merged nor queued is a concrete outcome, not a
  # missing one, so it keeps its own refusal. The gh-axi view cannot observe the
  # merge queue, so it can only turn this into a proved merge or into a refusal.
  github_read_outcome_with_gh && return 0
  if github_read_outcome_with_gh_axi && [ "$FM_PR_GITHUB_MERGED" = true ]; then
    return 0
  fi
  echo "error: could not read the GitHub pull request outcome after the merge attempt: the gh read failed and the gh-axi view could not prove the outcome either; PR metadata and merge poll remain recorded" >&2
  return 1
}

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Read the effective merge-queue method for the observed base branch. The four
# situations the refusal has to keep apart - no queue rule, a rules response
# that could not be read, several rules that disagree, and a rule whose method
# this script does not recognise - are reported as a status rather than folded
# into one failure, because each one means something different to the operator.
FM_PR_GITHUB_QUEUE_METHOD=
FM_PR_GITHUB_QUEUE_METHODS=
FM_PR_GITHUB_QUEUE_STATUS=unreadable
github_read_queue_method() {
  local methods line candidate method='' count=0 branch_path
  local unrecognised=false conflicting=false
  FM_PR_GITHUB_QUEUE_METHOD=
  FM_PR_GITHUB_QUEUE_METHODS=
  FM_PR_GITHUB_QUEUE_STATUS=unreadable
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$FM_PR_GITHUB_BASE" ] || return 0
  branch_path=$(github_urlencode_path_segment "$FM_PR_GITHUB_BASE")
  if ! methods=$(gh api \
    --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" \
    --jq '.[] | select(.type == "merge_queue") | "merge_method=" + (.parameters.merge_method // "")' \
    2>/dev/null); then
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      merge_method=*) candidate=${line#merge_method=} ;;
      *) return 0 ;;
    esac
    count=$((count + 1))
    case "$candidate" in
      MERGE|SQUASH|REBASE) ;;
      *) unrecognised=true ;;
    esac
    if [ -z "$FM_PR_GITHUB_QUEUE_METHODS" ] && [ "$count" -eq 1 ]; then
      FM_PR_GITHUB_QUEUE_METHODS=$candidate
    else
      case ",$FM_PR_GITHUB_QUEUE_METHODS," in
        *",$candidate,"*) ;;
        *)
          FM_PR_GITHUB_QUEUE_METHODS="$FM_PR_GITHUB_QUEUE_METHODS,$candidate"
          conflicting=true
          ;;
      esac
    fi
    method=$candidate
  done <<METHODS
$methods
METHODS
  if [ "$count" -eq 0 ]; then
    FM_PR_GITHUB_QUEUE_STATUS=none
  elif [ "$conflicting" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=conflicting
  elif [ "$unrecognised" = true ]; then
    FM_PR_GITHUB_QUEUE_STATUS=unrecognised
  else
    FM_PR_GITHUB_QUEUE_STATUS=single
    FM_PR_GITHUB_QUEUE_METHOD=$method
  fi
}

FM_PR_GITHUB_AUTO_REQUESTED=false
FM_PR_GITHUB_MERGE_ACCEPTED=false
FM_PR_GITHUB_CALLER_METHOD=

# The single gate every statement about what the forge accepted, armed, or
# reported has to pass. A merge command that failed accepted nothing, so no
# such statement may be made on its path, and routing them all through one
# predicate keeps a later one from being written without the gate.
github_merge_command_succeeded() {
  [ "$FM_PR_GITHUB_MERGE_ACCEPTED" = true ]
}

github_report_forge_output() {
  local output=$1 line
  github_merge_command_succeeded || return 0
  [ -n "$output" ] || return 0
  echo "error: the merge command's own output follows, quoted; it is the forge CLI's report, not this script's verdict:" >&2
  while IFS= read -r line; do
    printf 'error: > %s\n' "$line" >&2
  done <<OUTPUT
$output
OUTPUT
}

github_state_is_open() {
  case "$FM_PR_GITHUB_STATE" in
    [oO][pP][eE][nN]) return 0 ;;
    *) return 1 ;;
  esac
}

github_caller_method_is() {
  case "$FM_PR_GITHUB_CALLER_METHOD" in
    [mM][eE][rR][gG][eE]) [ "$1" = merge ] ;;
    [sS][qQ][uU][aA][sS][hH]) [ "$1" = squash ] ;;
    [rR][eE][bB][aA][sS][eE]) [ "$1" = rebase ] ;;
    *) return 1 ;;
  esac
}

github_report_queue_rules() {
  local queue_method methods_display
  github_read_queue_method
  case "$FM_PR_GITHUB_QUEUE_STATUS" in
    single)
      case "$FM_PR_GITHUB_QUEUE_METHOD" in
        MERGE) queue_method=merge ;;
        SQUASH) queue_method=squash ;;
        REBASE) queue_method=rebase ;;
      esac
      if github_merge_command_succeeded \
        && [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ] \
        && github_caller_method_is "$queue_method"; then
        printf 'error: this run refuses even though the request for %s was accepted with the exact flags base branch %s requires (--auto --%s): the pull request has still not entered the merge queue, so no landed or queued outcome is proven; re-check the pull request'"'"'s merge queue state before retrying\n' \
          "$URL" "$FM_PR_GITHUB_BASE" "$queue_method" >&2
      else
        printf 'error: base branch %s requires the merge queue; retry with: %s %s %s -- --auto --%s\n' \
          "$FM_PR_GITHUB_BASE" "$0" "$ID" "$URL" "$queue_method" >&2
      fi
      ;;
    conflicting)
      printf 'error: base branch %s has conflicting merge queue methods (%s); exact retry flags are ambiguous\n' \
        "$FM_PR_GITHUB_BASE" "${FM_PR_GITHUB_QUEUE_METHODS//,/, }" >&2
      ;;
    unrecognised)
      methods_display=${FM_PR_GITHUB_QUEUE_METHODS//,/, }
      [ -n "$methods_display" ] || methods_display='<none reported>'
      printf 'error: base branch %s requires the merge queue, but its configured merge method (%s) is not one this script recognises, so exact retry flags cannot be named\n' \
        "$FM_PR_GITHUB_BASE" "$methods_display" >&2
      ;;
    unreadable)
      printf 'error: the branch rules for base branch %s could not be read, so a merge queue requirement can be neither confirmed nor ruled out here\n' \
        "${FM_PR_GITHUB_BASE:-<unknown>}" >&2
      ;;
  esac
}

github_report_unmerged_outcome() {
  printf 'error: GitHub merge outcome was not successful: state=%s, merged=%s, isInMergeQueue=%s\n' \
    "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
  if ! github_state_is_open || [ "$FM_PR_GITHUB_MERGED" != false ] \
    || [ "$FM_PR_GITHUB_QUEUED" = true ]; then
    return 0
  fi
  if [ "$FM_PR_GITHUB_AUTO_REQUESTED" = true ]; then
    if github_merge_command_succeeded; then
      printf 'error: auto-merge was requested and armed for %s, but nothing is merged or in the merge queue yet, so this run refuses instead of reporting an unproved merge\n' \
        "$URL" >&2
    else
      printf 'error: auto-merge was requested for %s, but the merge command itself failed, so nothing was enabled, merged or queued\n' \
        "$URL" >&2
    fi
  fi
  if [ "$FM_PR_GITHUB_QUEUE_OBSERVED" != true ]; then
    printf 'error: the merge queue could not be observed for %s because the queue-aware read was unavailable, so a pull request already in the merge queue cannot be told apart from one that never entered it; re-check the pull request'"'"'s merge queue state before retrying\n' \
      "$URL" >&2
    return 0
  fi
  github_report_queue_rules
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

if caller_requested_auto_merge "${gh_args[@]+"${gh_args[@]}"}"; then
  FM_PR_GITHUB_AUTO_REQUESTED=true
fi
FM_PR_GITHUB_CALLER_METHOD=$(caller_merge_method "${gh_args[@]+"${gh_args[@]}"}")

merge_output=
if merge_output=$(gh pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
  "${gh_args[@]+"${gh_args[@]}"}" --match-head-commit "$FM_VT_FORGE_HEAD" 2>&1); then
  FM_PR_GITHUB_MERGE_ACCEPTED=true
else
  merge_status=$?
  [ -z "$merge_output" ] || printf '%s\n' "$merge_output" >&2
  if github_read_outcome; then
    if [ "$FM_PR_GITHUB_MERGED" != true ] && [ "$FM_PR_GITHUB_QUEUED" != true ]; then
      github_report_unmerged_outcome
    else
      printf 'actionable: the merge command for %s failed, but the pull request reads back as state=%s, merged=%s, isInMergeQueue=%s\n' \
        "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED" >&2
    fi
  fi
  exit "$merge_status"
fi

if ! github_read_outcome; then
  github_report_forge_output "$merge_output"
  exit 1
fi
if [ "$FM_PR_GITHUB_MERGED" = true ]; then
  printf 'verified: %s is merged (state=%s, merged=%s, isInMergeQueue=%s)\n' \
    "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
elif [ "$FM_PR_GITHUB_QUEUED" = true ]; then
  printf 'verified: %s is queued (state=%s, merged=%s, isInMergeQueue=%s)\n' \
    "$URL" "$FM_PR_GITHUB_STATE" "$FM_PR_GITHUB_MERGED" "$FM_PR_GITHUB_QUEUED"
  exit 0
else
  github_report_forge_output "$merge_output"
  github_report_unmerged_outcome
  exit 1
fi

outcome_rc=0
fm_merge_outcome_report "$FM_HOME" "$STATE" "$ID" "$URL" self || outcome_rc=$?
case "$outcome_rc" in
  0) ;;
  3)
    printf 'actionable: merged %s but could not report it upward: this home has no readable secondmate identity or parent binding (.fm-secondmate-home, .fm-secondmate-parent)\n' \
      "$URL" >&2
    ;;
  *)
    printf 'actionable: merged %s but could not record the outcome for supervision\n' "$URL" >&2
    ;;
esac
