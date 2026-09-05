#!/usr/bin/env bash
# Shared Git leftover cleanup for ordinary teardown and fleet sync.
#
# CONTRACT (one owner). This library owns extra-candidate inventory, keep-set
# application, same-repository committed-work proof, safe sibling removal,
# guarded branch deletion, and leftover result classification.
# bin/fm-teardown.sh owns when leftover cleanup runs (after successful
# recorded-copy cleanup and task closure only), plus task exceptions that must
# never leak onto a discovered leftover.
# bin/fm-fleet-sync.sh keeps [gone] discovery and refresh, then calls the
# shared deletion predicate.
# Missing registrations and same-repository orphan copies are discover-and-report
# classes only. The pass never prunes registrations, inspects missing-registration
# administrative state, calls Treehouse, or proves leases. Manual cleanup remains
# the captain's direct path.
#
# Proof functions take explicit repo, ref, mode, and optional PR inputs.
# They never read teardown FORCE, KIND, WT, or PR_URL, and they never write
# a caller's completion URL.
# A leftover candidate never inherits the closing task's PR, scout exception,
# --force, or validation exemption. The captured task branch may use the
# closing task's already-authorized discard only; discovered leftovers may not.
#
# Keep-set (never remove or reset through leftover cleanup):
#   primary checkout, default branch, and literal main
#   FM_ROOT, FM_HOME, this-home host, cleanup process and ancestors
#   just-returned slot and other clean idle slots in the active pool
#   any copy or branch named by extant task metadata (dead PID still counts)
#   registered secondmate homes and their live-task copies
#   any candidate with a live cwd at or below its root
#   any branch checked out in any linked worktree, including missing-but-still
#     registered rows
#   remotes and remote-tracking refs as deletion targets
#   other repositories, nested directories, unknown leases, unreadable identity
#
# Fail-closed: dirty, uniquely unpublished, unknown-lease, live-cwd, live-meta,
# idle pool-slot, primary, host, remote, and other-project candidates are
# retained. There is no automatic discard mode.
# Deletion failure is a retained/error result, never `|| true` success.
#
# Sourced by bin/fm-teardown.sh, bin/fm-fleet-sync.sh, and tests.
# No side effects on source. Safe under set -u.

FM_GIT_CLEANUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_GIT_CLEANUP_LIB_DIR/fm-timeout-lib.sh"

FM_GIT_CLEANUP_NOTE_PREFIX=${FM_GIT_CLEANUP_NOTE_PREFIX:-leftover}
FM_GIT_CLEANUP_REMOVED=0
FM_GIT_CLEANUP_RETAINED=0
FM_GIT_CLEANUP_FAILED=0
FM_GIT_CLEANUP_LOCKS=
FM_GIT_CLEANUP_CWD_SNAP=
FM_GIT_CLEANUP_META_PATHS=
FM_GIT_CLEANUP_META_BRANCHES=
FM_GIT_CLEANUP_HOME_PATHS=
FM_GIT_CLEANUP_SHIP_BRANCHES=
FM_GIT_CLEANUP_DEFAULT_REF=
FM_GIT_CLEANUP_DEFAULT_NAME=
FM_GIT_CLEANUP_DEFAULT_REPO=
FM_GIT_CLEANUP_REMOTE_PROOF_REPO=
FM_GIT_CLEANUP_REMOTE_PROOF_TIPS=
FM_GIT_CLEANUP_REMOTE_PROOF_READY=0
FM_GIT_CLEANUP_ATTRIB_BRANCHES=
FM_GIT_CLEANUP_TIMEOUT_SECS=${FM_GIT_CLEANUP_TIMEOUT_SECS:-15}
case "$FM_GIT_CLEANUP_TIMEOUT_SECS" in
  ''|*[!0-9]*|0) FM_GIT_CLEANUP_TIMEOUT_SECS=15 ;;
esac

fm_git_cleanup_note() {
  printf '%s: %s\n' "$FM_GIT_CLEANUP_NOTE_PREFIX" "$*"
}

fm_git_cleanup_warn() {
  printf 'warning: leftover cleanup did not finish after task closure succeeded: %s\n' "$*" >&2
}

fm_git_cleanup_retain() {
  FM_GIT_CLEANUP_RETAINED=$((FM_GIT_CLEANUP_RETAINED + 1))
  fm_git_cleanup_note "retained $1 ($2)"
}

fm_git_cleanup_removed() {
  FM_GIT_CLEANUP_REMOVED=$((FM_GIT_CLEANUP_REMOVED + 1))
  fm_git_cleanup_note "removed $1"
}

fm_git_cleanup_abs_dir() {
  local target=$1 parent base
  [ -n "$target" ] || return 1
  case "$target" in *$'\n'*|*$'\r'*) return 1 ;; esac
  parent=$(dirname "$target")
  base=$(basename "$target")
  ( cd "$parent" && printf '%s/%s\n' "$(pwd -P)" "$base" )
}

fm_git_cleanup_path_has_symlink_component() {
  local path=$1 current parent
  case "$path" in /*) ;; *) return 0 ;; esac
  current=$path
  while [ "$current" != / ]; do
    [ ! -L "$current" ] || return 0
    parent=$(dirname "$current") || return 0
    [ "$parent" != "$current" ] || return 0
    current=$parent
  done
  return 1
}

fm_git_cleanup_common_dir() {
  local path=$1 common abs
  [ -n "$path" ] || return 1
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || return 1
  common=$(git -C "$path" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) abs=$common ;;
    *) abs=$(cd "$path" && cd "$common" && pwd -P) || return 1 ;;
  esac
  printf '%s\n' "$abs"
}

fm_git_cleanup_is_copy_root() {
  local path=$1 top abs
  [ -n "$path" ] && [ -d "$path" ] && [ ! -L "$path" ] || return 1
  ! fm_git_cleanup_path_has_symlink_component "$path" || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  abs=$(fm_git_cleanup_abs_dir "$path") || return 1
  [ "$top" = "$abs" ]
}

fm_git_cleanup_same_repo() {
  local a=$1 b=$2 ca cb
  ca=$(fm_git_cleanup_common_dir "$a") || return 1
  cb=$(fm_git_cleanup_common_dir "$b") || return 1
  [ "$ca" = "$cb" ]
}

fm_git_cleanup_default_branch() {
  local repo=$1 ref branch
  [ -n "$repo" ] || return 1
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
    case "$ref" in origin/?*) ;; *) return 1 ;; esac
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

fm_git_cleanup_resolve_default() {
  local repo=$1 mode=$2 refresh=$3 name ref common
  common=$(fm_git_cleanup_common_dir "$repo") || return 1
  name=$(fm_git_cleanup_default_branch "$repo") || return 1
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    if [ "$refresh" = 1 ]; then
      fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" git -C "$repo" fetch --quiet origin \
        "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    fi
    ref="refs/remotes/origin/$name"
  elif [ "$mode" = local-only ] \
       && git -C "$repo" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  git -C "$repo" rev-parse --quiet --verify "$ref^{commit}" >/dev/null 2>&1 || return 1
  FM_GIT_CLEANUP_DEFAULT_REPO=$common
  FM_GIT_CLEANUP_DEFAULT_NAME=$name
  FM_GIT_CLEANUP_DEFAULT_REF=$ref
  if [ "$FM_GIT_CLEANUP_REMOTE_PROOF_REPO" != "$common" ]; then
    FM_GIT_CLEANUP_REMOTE_PROOF_REPO=
    FM_GIT_CLEANUP_REMOTE_PROOF_TIPS=
    FM_GIT_CLEANUP_REMOTE_PROOF_READY=0
  fi
}

fm_git_cleanup_default_is_prepared() {
  local common
  common=$(fm_git_cleanup_common_dir "$1") || return 1
  [ "$FM_GIT_CLEANUP_DEFAULT_REPO" = "$common" ] \
    && [ -n "$FM_GIT_CLEANUP_DEFAULT_NAME" ] \
    && [ -n "$FM_GIT_CLEANUP_DEFAULT_REF" ]
}

fm_git_cleanup_prepare_default() {
  fm_git_cleanup_resolve_default "$1" "$2" 1
}

fm_git_cleanup_prepare_fetched_default() {
  fm_git_cleanup_resolve_default "$1" "$2" 0
}

fm_git_cleanup_prepare_remote_proof() {
  local repo=$1 common remotes remote listed line oid ref tips=
  common=$(fm_git_cleanup_common_dir "$repo") || return 1
  if [ "$FM_GIT_CLEANUP_REMOTE_PROOF_REPO" = "$common" ] \
     && [ "$FM_GIT_CLEANUP_REMOTE_PROOF_READY" != 0 ]; then
    [ "$FM_GIT_CLEANUP_REMOTE_PROOF_READY" = 1 ]
    return $?
  fi
  FM_GIT_CLEANUP_REMOTE_PROOF_REPO=$common
  FM_GIT_CLEANUP_REMOTE_PROOF_TIPS=
  FM_GIT_CLEANUP_REMOTE_PROOF_READY=2
  remotes=$(git -C "$repo" remote 2>/dev/null) || return 1
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    case "$remote" in *$'\t'*|*$'\r'*) return 1 ;; esac
    listed=$(fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" \
      git -C "$repo" ls-remote --heads "$remote" 2>/dev/null) || return 1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in *$'\t'refs/heads/*) ;; *) return 1 ;; esac
      oid=${line%%$'\t'*}
      ref=${line#*$'\t'}
      case "$oid" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
      case "$ref" in refs/heads/?*) ;; *) return 1 ;; esac
      if git -C "$repo" cat-file -e "$oid^{commit}" 2>/dev/null; then
        tips=$tips$'\n'$oid
      fi
    done <<EOF
$listed
EOF
  done <<EOF
$remotes
EOF
  FM_GIT_CLEANUP_REMOTE_PROOF_TIPS=$(printf '%s\n' "$tips" | sed '/^$/d' | sort -u)
  FM_GIT_CLEANUP_REMOTE_PROOF_READY=1
}

fm_git_cleanup_remote_unpreserved_commits() {
  local repo=$1 tip=$2 common oid
  common=$(fm_git_cleanup_common_dir "$repo") || return 1
  [ "$FM_GIT_CLEANUP_REMOTE_PROOF_REPO" = "$common" ] \
    && [ "$FM_GIT_CLEANUP_REMOTE_PROOF_READY" = 1 ] || return 1
  set -- "$tip"
  if [ -n "$FM_GIT_CLEANUP_REMOTE_PROOF_TIPS" ]; then
    set -- "$@" --not
    while IFS= read -r oid; do
      [ -n "$oid" ] || continue
      set -- "$@" "$oid"
    done <<EOF
$FM_GIT_CLEANUP_REMOTE_PROOF_TIPS
EOF
  fi
  git -C "$repo" rev-list "$@" -- 2>/dev/null
}

fm_git_cleanup_pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '') return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_git_cleanup_pr_number_from_branch() {
  local repo=$1 branch=$2 out n
  [ -n "$repo" ] && [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$repo" && fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" \
    gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_git_cleanup_ensure_commit_object() {
  local repo=$1 target=$2 commit=$3 n
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_git_cleanup_pr_number_from_target "$target") || return 1
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 1
  fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" git -C "$repo" fetch --quiet origin \
    "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null
}

# Prints the resolved PR URL on success. Never assigns a caller global.
fm_git_cleanup_pr_is_merged() {
  local repo=$1 branch=$2 pr_url=$3 current=${4:-} target view state remainder head resolved_url
  [ -n "$repo" ] || return 1
  if [ -z "$current" ]; then
    current=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 1
  fi
  if [ -n "$pr_url" ]; then
    target=$pr_url
  else
    target=$(fm_git_cleanup_pr_number_from_branch "$repo" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$repo" && fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" \
    gh pr view "$target" --json state,headRefOid,url \
      -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_git_cleanup_ensure_commit_object "$repo" "$target" "$head" || return 1
  git -C "$repo" merge-base --is-ancestor "$current" "$head" 2>/dev/null || return 1
  printf '%s\n' "$resolved_url"
}

fm_git_cleanup_content_in_default() {
  local repo=$1 mode=$2 commit=${3:-HEAD} ref default_tree merged_tree
  [ -n "$repo" ] || return 1
  if ! fm_git_cleanup_default_is_prepared "$repo"; then
    fm_git_cleanup_prepare_default "$repo" "$mode" || return 1
  fi
  ref=$FM_GIT_CLEANUP_DEFAULT_REF
  default_tree=$(git -C "$repo" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$repo" merge-tree --write-tree "$ref" "$commit" 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

fm_git_cleanup_tip_on_remotes() {
  local repo=$1 tip=$2 leftover
  leftover=$(fm_git_cleanup_remote_unpreserved_commits "$repo" "$tip") || return 1
  [ -z "$leftover" ]
}

# Candidate-specific landed proof. Does not mutate PR_URL.
fm_git_cleanup_work_is_landed() {
  local repo=$1 branch=$2 mode=$3 pr_url=$4 commit=${5:-}
  [ -n "$repo" ] || return 1
  if [ -z "$commit" ]; then
    commit=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 1
  fi
  if ! fm_git_cleanup_default_is_prepared "$repo"; then
    fm_git_cleanup_prepare_default "$repo" "$mode" || return 1
  fi
  fm_git_cleanup_prepare_remote_proof "$repo" >/dev/null 2>&1 || true
  if fm_git_cleanup_tip_on_remotes "$repo" "$commit"; then
    return 0
  fi
  if fm_git_cleanup_content_in_default "$repo" "$mode" "$commit"; then
    return 0
  fi
  if [ "$mode" = local-only ]; then
    return 1
  fi
  if [ -n "$pr_url" ] || { [ -n "$branch" ] && [ "$branch" != HEAD ]; }; then
    if fm_git_cleanup_pr_is_merged "$repo" "$branch" "$pr_url" "$commit" >/dev/null; then
      return 0
    fi
  fi
  return 1
}

fm_git_cleanup_worktree_list() {
  local repo=$1
  git -C "$repo" -c core.quotePath=false worktree list --porcelain 2>/dev/null
}

fm_git_cleanup_branch_checked_out() {
  local repo=$1 branch=$2 listed line
  [ -n "$repo" ] && [ -n "$branch" ] || return 0
  listed=$(fm_git_cleanup_worktree_list "$repo") || return 0
  while IFS= read -r line; do
    case "$line" in
      "branch refs/heads/$branch") return 0 ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

# 0 when the worktree list could be read. 1 when it failed (full protection).
fm_git_cleanup_worktree_list_ok() {
  local repo=$1
  fm_git_cleanup_worktree_list "$repo" >/dev/null
}

# Returns 0 when the branch may be deleted. Prints a retain reason on stdout when not.
fm_git_cleanup_branch_may_delete() {
  local repo=$1 branch=$2 tip=$3 mode=$4 pr_url=$5 allow_task_force=$6 current default_name
  if [ -z "$branch" ] || [ "$branch" = HEAD ]; then
    printf '%s\n' "not-a-branch"
    return 1
  fi
  case "$branch" in
    refs/remotes/*|origin/*)
      printf '%s\n' "remote"
      return 1
      ;;
  esac
  if [ "$branch" = main ]; then
    printf '%s\n' "default-branch"
    return 1
  fi
  if fm_git_cleanup_default_is_prepared "$repo"; then
    default_name=$FM_GIT_CLEANUP_DEFAULT_NAME
  else
    default_name=$(fm_git_cleanup_default_branch "$repo") || {
      printf '%s\n' "unknown-default"
      return 1
    }
  fi
  if [ "$branch" = "$default_name" ]; then
    printf '%s\n' "default-branch"
    return 1
  fi
  if fm_git_cleanup_meta_mentions_branch "$branch"; then
    printf '%s\n' "live-meta"
    return 1
  fi
  if ! fm_git_cleanup_worktree_list_ok "$repo"; then
    printf '%s\n' "unreadable-worktrees"
    return 1
  fi
  current=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -n "$current" ] && [ "$branch" = "$current" ]; then
    printf '%s\n' "checked-out"
    return 1
  fi
  if fm_git_cleanup_branch_checked_out "$repo" "$branch"; then
    printf '%s\n' "checked-out"
    return 1
  fi
  if [ -z "$tip" ] || ! git -C "$repo" rev-parse --verify --quiet "$tip^{commit}" >/dev/null; then
    printf '%s\n' "unreadable-tip"
    return 1
  fi
  if [ "$(git -C "$repo" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)" != "$tip" ]; then
    printf '%s\n' "tip-changed"
    return 1
  fi
  if [ "$allow_task_force" = 1 ]; then
    return 0
  fi
  if fm_git_cleanup_work_is_landed "$repo" "$branch" "$mode" "$pr_url" "$tip"; then
    return 0
  fi
  printf '%s\n' "unique-unpublished"
  return 1
}

# Checked deletion. Failure is non-zero; never `|| true`.
fm_git_cleanup_delete_branch() {
  local repo=$1 branch=$2 tip=$3 mode=$4 pr_url=$5 allow_task_force=$6 reason now
  reason=$(fm_git_cleanup_branch_may_delete "$repo" "$branch" "$tip" "$mode" "$pr_url" "$allow_task_force") || {
    [ -n "$reason" ] || reason=unproved
    printf '%s\n' "$reason"
    return 1
  }
  now=$(git -C "$repo" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)
  if [ "$now" != "$tip" ]; then
    printf '%s\n' "tip-changed"
    return 1
  fi
  if fm_git_cleanup_branch_checked_out "$repo" "$branch"; then
    printf '%s\n' "checked-out"
    return 1
  fi
  if ! git -C "$repo" update-ref -d "refs/heads/$branch" "$tip" >/dev/null 2>&1; then
    now=$(git -C "$repo" rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)
    if [ "$now" != "$tip" ]; then
      printf '%s\n' "tip-changed"
    else
      printf '%s\n' "delete-failed"
    fi
    return 1
  fi
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s\n' "delete-failed"
    return 1
  fi
  return 0
}

fm_git_cleanup_protects_host() {
  local candidate=$1 host
  [ -n "$candidate" ] || return 0
  for host in "${FM_GC_ROOT:-}" "${FM_GC_HOME:-}" "${FM_GC_HOST_CWD:-}"; do
    [ -n "$host" ] || continue
    if [ "$candidate" = "$host" ]; then
      return 0
    fi
    case "$host" in
      "$candidate"/*) return 0 ;;
    esac
  done
  return 1
}

fm_git_cleanup_is_sibling_name() {
  local recorded=$1 candidate=$2 rec_base cand_base rec_parent cand_parent
  rec_parent=$(dirname "$recorded")
  cand_parent=$(dirname "$candidate")
  [ "$rec_parent" = "$cand_parent" ] || return 1
  rec_base=$(basename "$recorded")
  cand_base=$(basename "$candidate")
  case "$cand_base" in
    "$rec_base"-resolver|"$rec_base"-baseline) return 0 ;;
  esac
  return 1
}

fm_git_cleanup_copy_is_clean() {
  local path=$1 raw op op_path
  [ -d "$path" ] || return 1
  for op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD rebase-merge rebase-apply; do
    op_path=$(git -C "$path" rev-parse --git-path "$op" 2>/dev/null) || return 1
    [ ! -e "$op_path" ] && [ ! -L "$op_path" ] || return 1
  done
  raw=$(git -C "$path" status --porcelain --ignored --ignore-submodules=none 2>/dev/null) || return 1
  [ -z "$raw" ]
}

fm_git_cleanup_pseudorefs() {
  local gitdir=$1 common=$2 file name oid
  for file in "$gitdir"/*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    name=$(basename "$file")
    case "$name" in HEAD|*[!A-Z0-9_]*) continue ;; esac
    [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
    oid=$(GIT_DIR="$gitdir" GIT_COMMON_DIR="$common" \
      git rev-parse --verify "$name^{commit}" 2>/dev/null) || continue
    printf 'pseudoref/%s\t%s\n' "$name" "$oid"
  done
}

fm_git_cleanup_private_refs() {
  local path=$1 common gitdir refs pseudorefs
  common=$(fm_git_cleanup_common_dir "$path") || return 1
  gitdir=$(git -C "$path" rev-parse --git-dir 2>/dev/null) || return 1
  case "$gitdir" in
    /*) ;;
    *) gitdir=$(cd "$path" && cd "$gitdir" && pwd -P) || return 1 ;;
  esac
  refs=$(git -C "$path" for-each-ref --format='%(refname)%09%(objectname)' \
    refs/worktree refs/bisect refs/rewritten 2>/dev/null) || return 1
  pseudorefs=$(fm_git_cleanup_pseudorefs "$gitdir" "$common") || return 1
  printf '%s\n%s\n' "$refs" "$pseudorefs" | sed '/^$/d'
}

fm_git_cleanup_copy_signature() {
  local path=$1 head branch refs
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  head=$(git -C "$path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  branch=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD\n')
  refs=$(fm_git_cleanup_private_refs "$path") || return 1
  printf '%s\t%s\n%s\n' "$head" "$branch" "$refs"
}

fm_git_cleanup_copy_refs_are_landed() {
  local path=$1 branch=$2 mode=$3 head=$4 refs line oid
  fm_git_cleanup_work_is_landed "$path" "$branch" "$mode" "" "$head" || return 1
  refs=$(fm_git_cleanup_private_refs "$path") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *$'\t'*) ;; *) return 1 ;; esac
    oid=${line#*$'\t'}
    [ -n "$oid" ] || return 1
    fm_git_cleanup_work_is_landed "$path" HEAD "$mode" "" "$oid" || return 1
  done <<EOF
$refs
EOF
}

fm_git_cleanup_cwd_snapshot() {
  local out dest=$1 pid=
  : > "$dest" || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  out=$(fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        printf '%s\t%s\n' "$pid" "${line#n}" >> "$dest"
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

fm_git_cleanup_cwd_live() {
  local snap=$1 root=$2 pid path
  [ -f "$snap" ] || return 0
  [ -n "$root" ] || return 0
  while IFS=$(printf '\t') read -r pid path; do
    [ -n "$pid" ] || continue
    case "$path" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done < "$snap"
  return 1
}

fm_git_cleanup_meta_refs_from_state() {
  local state=$1 meta wt abs branch id kind count
  [ -d "$state" ] && [ ! -L "$state" ] && [ -r "$state" ] && [ -x "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
    count=$(grep -c '^worktree=' "$meta" 2>/dev/null) || return 1
    [ "$count" = 1 ] || return 1
    wt=$(sed -n 's/^worktree=//p' "$meta") || return 1
    case "$wt" in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
    count=$(grep -c '^kind=' "$meta" 2>/dev/null) || return 1
    [ "$count" = 1 ] || return 1
    kind=$(sed -n 's/^kind=//p' "$meta") || return 1
    case "$kind" in ship|scout|secondmate) ;; *) return 1 ;; esac
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    abs=$(fm_git_cleanup_abs_dir "$wt" 2>/dev/null) || return 1
    FM_GIT_CLEANUP_META_PATHS=$FM_GIT_CLEANUP_META_PATHS$'\n'$abs
    if [ -d "$wt" ]; then
      branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
        FM_GIT_CLEANUP_META_BRANCHES=$FM_GIT_CLEANUP_META_BRANCHES$'\n'$branch
      fi
    fi
    case "$kind" in ship|scout)
      FM_GIT_CLEANUP_META_BRANCHES=$FM_GIT_CLEANUP_META_BRANCHES$'\n'"fm/$id"
      ;;
    esac
  done
}

fm_git_cleanup_collect_homes() {
  local home=$1 data=$2 pending current current_data reg line child visited='' abs root
  root=$(fm_git_cleanup_abs_dir "$home" 2>/dev/null) || {
    printf '%s\n' "unreadable-registry"
    return 0
  }
  pending=$root
  data=${data:-$home/data}
  while [ -n "$pending" ]; do
    case "$pending" in
      *$'\n'*)
        current=${pending%%$'\n'*}
        pending=${pending#*$'\n'}
        ;;
      *)
        current=$pending
        pending=
        ;;
    esac
    abs=$(fm_git_cleanup_abs_dir "$current" 2>/dev/null) || {
      printf '%s\n' "unreadable-registry"
      return 0
    }
    if printf '%s\n' "$visited" | grep -Fxq -- "$abs"; then
      continue
    fi
    visited=$visited$'\n'$abs
    printf '%s\n' "$abs"
    if [ "$abs" = "$root" ]; then
      current_data=$data
    else
      current_data="$abs/data"
    fi
    reg="$current_data/secondmates.md"
    [ -e "$reg" ] || [ -L "$reg" ] || continue
    if [ ! -f "$reg" ] || [ -L "$reg" ] || [ ! -r "$reg" ]; then
      printf '%s\n' "unreadable-registry"
      return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          if ! command -v secondmate_registry_parse_line >/dev/null 2>&1 \
             && ! declare -F secondmate_registry_parse_line >/dev/null 2>&1; then
            printf '%s\n' "unreadable-registry"
            return 0
          fi
          if ! secondmate_registry_parse_line "$line"; then
            printf '%s\n' "unreadable-registry"
            return 0
          fi
          if [ "${SECONDMATE_REGISTRY_REMOTE:-0}" = 1 ]; then
            printf '%s\n' "remote-home"
            return 0
          fi
          child=$(fm_git_cleanup_abs_dir "$SECONDMATE_REGISTRY_HOME" 2>/dev/null) || {
            printf '%s\n' "unreadable-registry"
            return 0
          }
          if ! printf '%s\n' "$visited" | grep -Fxq -- "$child"; then
            if [ -n "$pending" ]; then
              pending=$pending$'\n'$child
            else
              pending=$child
            fi
          fi
          ;;
      esac
    done < "$reg"
  done
}

fm_git_cleanup_task_repo_matches() {
  local home=$1 task_repo=$2 repo=$3 candidate
  case "$task_repo" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  candidate="$home/projects/$task_repo"
  [ -d "$candidate" ] || return 1
  fm_git_cleanup_same_repo "$repo" "$candidate"
}

fm_git_cleanup_collect_done_evidence() {
  local data=$1 home=$2 repo=$3 backlog out header declared rows=0
  local line id state kind task_repo rest
  backlog="$data/backlog.md"
  [ -e "$backlog" ] || [ -L "$backlog" ] || return 0
  [ -f "$backlog" ] && [ ! -L "$backlog" ] && [ -r "$backlog" ] || return 1
  command -v tasks-axi >/dev/null 2>&1 || return 1
  out=$(fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" tasks-axi list \
    --file "$backlog" --state "done" --fields closed 2>/dev/null) || return 1
  header=$(printf '%s\n' "$out" | sed -n 's/^tasks\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  declared=$(printf '%s\n' "$out" | sed -n 's/^count:[[:space:]]*\([0-9][0-9]*\)$/\1/p' | head -1)
  [ -n "$header" ] && [ "$header" = "$declared" ] || return 1
  while IFS= read -r line; do
    case "$line" in '  '*','*','*','*) ;; *) continue ;; esac
    line=${line#  }
    IFS=, read -r id state kind task_repo rest <<EOF
$line
EOF
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    [ "$state" = "done" ] || return 1
    case "$kind" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    rows=$((rows + 1))
    case "$kind" in
      ship)
        if fm_git_cleanup_task_repo_matches "$home" "$task_repo" "$repo"; then
          FM_GIT_CLEANUP_SHIP_BRANCHES=$FM_GIT_CLEANUP_SHIP_BRANCHES$'\n'"fm/$id"
        fi
        ;;
    esac
  done <<EOF
$out
EOF
  [ "$rows" = "$declared" ]
}

fm_git_cleanup_prepare_keep_set() {
  local home=$1 data=$2 repo=$3 homes h abs home_abs
  FM_GIT_CLEANUP_META_PATHS=
  FM_GIT_CLEANUP_META_BRANCHES=
  FM_GIT_CLEANUP_HOME_PATHS=
  FM_GIT_CLEANUP_SHIP_BRANCHES=
  FM_GIT_CLEANUP_KEEP_SET_FAILURE=inventory
  home_abs=$(fm_git_cleanup_abs_dir "$home") || return 1
  homes=$(fm_git_cleanup_collect_homes "$home" "$data") || return 1
  case "$homes" in *unreadable-registry*|*remote-home*) return 1 ;; esac
  fm_git_cleanup_try_taskset_locks "$homes" || return 1
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    abs=$(fm_git_cleanup_abs_dir "$h" 2>/dev/null) || {
      fm_git_cleanup_release_taskset_locks
      return 1
    }
    FM_GIT_CLEANUP_HOME_PATHS=$FM_GIT_CLEANUP_HOME_PATHS$'\n'$abs
    fm_git_cleanup_meta_refs_from_state "$h/state" || {
      fm_git_cleanup_release_taskset_locks
      return 1
    }
    if [ "$h" = "$home_abs" ]; then
      fm_git_cleanup_collect_done_evidence "$data" "$h" "$repo" || {
        fm_git_cleanup_release_taskset_locks
        return 1
      }
    else
      fm_git_cleanup_collect_done_evidence "$h/data" "$h" "$repo" || {
        fm_git_cleanup_release_taskset_locks
        return 1
      }
    fi
  done <<EOF
$homes
EOF
}

fm_git_cleanup_try_taskset_locks() {
  local homes=$1 home state lock
  FM_GIT_CLEANUP_LOCKS=
  if ! declare -F fm_task_set_lock_path >/dev/null 2>&1 \
     || ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    return 1
  fi
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    case "$home" in
      unreadable-registry|remote-home) return 1 ;;
    esac
    state="$home/state"
    [ -d "$state" ] && [ ! -L "$state" ] && [ -r "$state" ] && [ -x "$state" ] || {
      fm_git_cleanup_release_taskset_locks
      return 1
    }
    lock=$(fm_task_set_lock_path "$state") || return 1
    if ! fm_lock_try_acquire "$lock"; then
      if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
        FM_GIT_CLEANUP_KEEP_SET_FAILURE=contention
      fi
      fm_git_cleanup_release_taskset_locks
      return 1
    fi
    FM_GIT_CLEANUP_LOCKS=$FM_GIT_CLEANUP_LOCKS$'\n'$lock
  done <<EOF
$homes
EOF
}

fm_git_cleanup_release_taskset_locks() {
  local lock
  [ -n "$FM_GIT_CLEANUP_LOCKS" ] || return 0
  if ! declare -F fm_lock_release >/dev/null 2>&1; then
    FM_GIT_CLEANUP_LOCKS=
    return 0
  fi
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    fm_lock_release "$lock" || true
  done <<EOF
$FM_GIT_CLEANUP_LOCKS
EOF
  FM_GIT_CLEANUP_LOCKS=
}

fm_git_cleanup_meta_mentions_path() {
  local path=$1
  printf '%s\n' "$FM_GIT_CLEANUP_META_PATHS" | grep -Fxq -- "$path"
}

fm_git_cleanup_meta_mentions_branch() {
  local branch=$1
  printf '%s\n' "$FM_GIT_CLEANUP_META_BRANCHES" | grep -Fxq -- "$branch"
}

fm_git_cleanup_meta_mentions_copy() {
  local path=$1 branch=$2
  fm_git_cleanup_meta_mentions_path "$path" && return 0
  [ -n "$branch" ] && [ "$branch" != HEAD ] \
    && fm_git_cleanup_meta_mentions_branch "$branch"
}

fm_git_cleanup_protects_home() {
  local candidate=$1 home
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    [ "$candidate" = "$home" ] && return 0
    case "$home" in "$candidate"/*) return 0 ;; esac
  done <<EOF
$FM_GIT_CLEANUP_HOME_PATHS
EOF
  return 1
}

fm_git_cleanup_porcelain_entries() {
  local repo=$1 listed line path head branch locked prunable
  listed=$(fm_git_cleanup_worktree_list "$repo") || return 1
  path=
  head=
  branch=
  locked=0
  prunable=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      if [ -n "$path" ]; then
        [ -n "$head" ] && [ -n "$branch" ] || return 1
        printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$head" "$branch" "$locked" "$prunable"
      fi
      path=
      head=
      branch=
      locked=0
      prunable=0
      continue
    fi
    case "$line" in
      worktree\ *)
        [ -z "$path" ] || return 1
        path=${line#worktree }
        case "$path" in ''|*$'\t'*) return 1 ;; esac
        ;;
      HEAD\ *)
        [ -n "$path" ] && [ -z "$head" ] || return 1
        head=${line#HEAD }
        case "$head" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
        ;;
      branch\ refs/heads/*)
        [ -n "$path" ] && [ -z "$branch" ] || return 1
        branch=${line#branch refs/heads/}
        case "$branch" in ''|*$'\t'*) return 1 ;; esac
        ;;
      detached)
        [ -n "$path" ] && [ -z "$branch" ] || return 1
        branch=HEAD
        ;;
      locked*) [ -n "$path" ] && [ "$locked" = 0 ] || return 1; locked=1 ;;
      prunable*) [ -n "$path" ] && [ "$prunable" = 0 ] || return 1; prunable=1 ;;
      *) return 1 ;;
    esac
  done <<EOF
$listed
EOF
  if [ -n "$path" ]; then
    [ -n "$head" ] && [ -n "$branch" ] || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$head" "$branch" "$locked" "$prunable"
  fi
}

fm_git_cleanup_remove_unmanaged_worktree() {
  local repo=$1 path=$2
  git -C "$repo" worktree remove -- "$path"
}

fm_git_cleanup_copy_ready_at_mutation() {
  local repo=$1 path=$2 branch=$3 mode=$4 signature=$5 snap=$6
  local head current_branch signature_head now
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  fm_git_cleanup_is_copy_root "$path" || return 1
  fm_git_cleanup_same_repo "$repo" "$path" || return 1
  now=$(fm_git_cleanup_copy_signature "$path") || return 1
  signature_head=${now%%$'\n'*}
  case "$signature_head" in *$'\t'*) ;; *) return 1 ;; esac
  head=${signature_head%%$'\t'*}
  current_branch=${signature_head#*$'\t'}
  [ -n "$head" ] && [ -n "$current_branch" ] || return 1
  if [ "$current_branch" = main ] || [ "$current_branch" = "$FM_GIT_CLEANUP_DEFAULT_NAME" ]; then
    return 2
  fi
  [ "$now" = "$signature" ] || return 1
  [ "$current_branch" = "$branch" ] || return 1
  ! fm_git_cleanup_protects_host "$path" || return 1
  ! fm_git_cleanup_protects_home "$path" || return 1
  ! fm_git_cleanup_meta_mentions_copy "$path" "$current_branch" || return 1
  fm_git_cleanup_copy_is_clean "$path" || return 1
  fm_git_cleanup_copy_refs_are_landed "$path" "$current_branch" "$mode" "$head" || return 1
  fm_git_cleanup_cwd_snapshot "$snap" || return 1
  ! fm_git_cleanup_cwd_live "$snap" "$path"
}

fm_git_cleanup_consider_branch() {
  local repo=$1 branch=$2 tip=$3 mode=$4 pr_url=$5 allow_force=$6 reason
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 0
  if reason=$(fm_git_cleanup_delete_branch "$repo" "$branch" "$tip" "$mode" "$pr_url" "$allow_force"); then
    fm_git_cleanup_removed "branch $branch"
    return 0
  fi
  fm_git_cleanup_retain "branch $branch" "${reason:-unproved}"
}

fm_git_cleanup_handle_sibling() {
  local repo=$1 path=$2 head=$3 branch=$4 mode=$5
  local snap=$FM_GIT_CLEANUP_CWD_SNAP signature ready
  if fm_git_cleanup_protects_host "$path"; then
    fm_git_cleanup_retain "$path" "host"
    return 0
  fi
  if fm_git_cleanup_protects_home "$path"; then
    fm_git_cleanup_retain "$path" "registered-home"
    return 0
  fi
  if [ ! -d "$path" ]; then
    return 0
  fi
  if ! fm_git_cleanup_is_copy_root "$path"; then
    fm_git_cleanup_retain "$path" "other-project"
    return 0
  fi
  if ! fm_git_cleanup_same_repo "$repo" "$path"; then
    fm_git_cleanup_retain "$path" "other-project"
    return 0
  fi
  if [ "$branch" = main ] || [ "$branch" = "$FM_GIT_CLEANUP_DEFAULT_NAME" ]; then
    fm_git_cleanup_retain "$path" "default-branch"
    return 0
  fi
  if fm_git_cleanup_meta_mentions_copy "$path" "$branch"; then
    fm_git_cleanup_retain "$path" "live-meta"
    return 0
  fi
  if [ -z "$snap" ] || [ ! -f "$snap" ]; then
    fm_git_cleanup_retain "$path" "live-cwd"
    return 0
  fi
  if fm_git_cleanup_cwd_live "$snap" "$path"; then
    fm_git_cleanup_retain "$path" "live-cwd"
    return 0
  fi
  if ! fm_git_cleanup_copy_is_clean "$path"; then
    fm_git_cleanup_retain "$path" "dirty"
    return 0
  fi
  signature=$(fm_git_cleanup_copy_signature "$path") || {
    fm_git_cleanup_retain "$path" "unreadable"
    return 0
  }
  if ! fm_git_cleanup_copy_refs_are_landed "$path" "$branch" "$mode" "$head"; then
    fm_git_cleanup_retain "$path" "unique-unpublished"
    return 0
  fi
  if fm_git_cleanup_copy_ready_at_mutation "$repo" "$path" "$branch" "$mode" "$signature" "$snap"; then
    :
  else
    ready=$?
    if [ "$ready" = 2 ]; then
      fm_git_cleanup_retain "$path" "default-branch"
      return 0
    fi
    fm_git_cleanup_retain "$path" "mutation-recheck"
    return 0
  fi
  if fm_git_cleanup_remove_unmanaged_worktree "$repo" "$path"; then
    fm_git_cleanup_removed "$path"
    if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
      FM_GIT_CLEANUP_ATTRIB_BRANCHES=$FM_GIT_CLEANUP_ATTRIB_BRANCHES$'\n'"$branch $head"
    fi
    return 0
  fi
  FM_GIT_CLEANUP_FAILED=1
  fm_git_cleanup_retain "$path" "git-failure"
}

fm_git_cleanup_handle_orphan() {
  local repo=$1 path=$2
  if [ "$path" = "${FM_GC_REPO:-}" ]; then
    fm_git_cleanup_retain "$path" "primary"
    return 0
  fi
  if fm_git_cleanup_protects_host "$path"; then
    fm_git_cleanup_retain "$path" "host"
    return 0
  fi
  if fm_git_cleanup_protects_home "$path"; then
    fm_git_cleanup_retain "$path" "registered-home"
    return 0
  fi
  if [ ! -d "$path" ]; then
    fm_git_cleanup_retain "$path" "gone-registration"
    return 0
  fi
  if ! fm_git_cleanup_is_copy_root "$path" || ! fm_git_cleanup_same_repo "$repo" "$path"; then
    fm_git_cleanup_retain "$path" "other-project"
    return 0
  fi
  fm_git_cleanup_retain "$path" "unrecorded-copy"
}

# After successful recorded-copy cleanup and task closure.
# Args: repo home data returned_path captured_branch captured_tip mode kind force root
fm_git_cleanup_leftover_pass() {
  local repo=$1 home=$2 data=$3 returned=$4 cap_branch=$5 cap_tip=$6
  local mode=$7 kind=$8 force=$9 root=${10}
  local snap tmp entries path head branch locked prunable
  local allow_force=0 pair b t
  FM_GIT_CLEANUP_REMOVED=0
  FM_GIT_CLEANUP_RETAINED=0
  FM_GIT_CLEANUP_FAILED=0
  FM_GIT_CLEANUP_ATTRIB_BRANCHES=
  FM_GIT_CLEANUP_META_PATHS=
  FM_GIT_CLEANUP_META_BRANCHES=
  FM_GIT_CLEANUP_HOME_PATHS=
  FM_GIT_CLEANUP_SHIP_BRANCHES=
  FM_GIT_CLEANUP_DEFAULT_REPO=
  FM_GIT_CLEANUP_DEFAULT_NAME=
  FM_GIT_CLEANUP_DEFAULT_REF=
  FM_GIT_CLEANUP_REMOTE_PROOF_REPO=
  FM_GIT_CLEANUP_REMOTE_PROOF_TIPS=
  FM_GIT_CLEANUP_REMOTE_PROOF_READY=0
  case "$kind" in
    ship|scout) ;;
    *) return 0 ;;
  esac
  [ -n "$repo" ] && [ -d "$repo" ] || return 0
  if ! fm_git_cleanup_is_copy_root "$repo"; then
    fm_git_cleanup_warn "project is not a clone root"
    return 1
  fi
  FM_GC_REPO=$(fm_git_cleanup_abs_dir "$repo") || return 1
  FM_GC_HOME=$(fm_git_cleanup_abs_dir "$home" 2>/dev/null || printf '%s\n' "$home")
  FM_GC_ROOT=$(fm_git_cleanup_abs_dir "$root" 2>/dev/null || printf '%s\n' "$root")
  FM_GC_HOST_CWD=$(pwd -P 2>/dev/null || true)
  FM_GC_RETURNED=
  if [ -n "$returned" ]; then
    FM_GC_RETURNED=$(fm_git_cleanup_abs_dir "$returned" 2>/dev/null || printf '%s\n' "$returned")
  fi
  repo=$FM_GC_REPO
  if ! fm_git_cleanup_prepare_keep_set "$home" "$data" "$repo"; then
    if [ "${FM_GIT_CLEANUP_KEEP_SET_FAILURE:-}" = contention ]; then
      fm_git_cleanup_note "deferred extra pass (publication lock unavailable)"
      return 0
    fi
    fm_git_cleanup_warn "ownership inventory unavailable"
    return 1
  fi
  if ! fm_git_cleanup_prepare_default "$repo" "$mode"; then
    fm_git_cleanup_release_taskset_locks
    fm_git_cleanup_warn "default branch proof unavailable"
    return 1
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-cleanup.XXXXXX") || {
    fm_git_cleanup_release_taskset_locks
    fm_git_cleanup_warn "could not create cleanup state"
    return 1
  }
  snap="$tmp/cwd"
  FM_GIT_CLEANUP_CWD_SNAP=$snap
  if ! fm_git_cleanup_cwd_snapshot "$snap"; then
    fm_git_cleanup_release_taskset_locks
    rm -rf -- "$tmp"
    fm_git_cleanup_warn "cwd inspection failed"
    return 1
  fi
  entries=$(fm_git_cleanup_porcelain_entries "$repo") || {
    fm_git_cleanup_release_taskset_locks
    rm -rf -- "$tmp"
    fm_git_cleanup_warn "worktree list failed; leftover copies were not examined"
    return 1
  }
  while IFS=$(printf '\t') read -r path head branch locked prunable; do
    [ -n "$path" ] || continue
    case "$path" in *$'\n'*)
      fm_git_cleanup_retain "malformed-inventory" "unreadable"
      continue
      ;;
    esac
    if fm_git_cleanup_path_has_symlink_component "$path"; then
      fm_git_cleanup_retain "$path" "symlink"
      continue
    fi
    if [ "$prunable" = 1 ] || [ ! -d "$path" ]; then
      fm_git_cleanup_retain "$path" "gone-registration"
      continue
    fi
    if ! path=$(fm_git_cleanup_abs_dir "$path" 2>/dev/null); then
      fm_git_cleanup_retain "${path:-unreadable}" "unreadable"
      continue
    fi
    [ "$path" != "$repo" ] || continue
    [ "$path" != "$FM_GC_RETURNED" ] || continue
    if [ "$locked" = 1 ]; then
      fm_git_cleanup_retain "$path" "locked"
      continue
    fi
    if [ -n "$FM_GC_RETURNED" ] && fm_git_cleanup_is_sibling_name "$FM_GC_RETURNED" "$path"; then
      fm_git_cleanup_handle_sibling "$repo" "$path" "$head" "$branch" "$mode"
      continue
    fi
    fm_git_cleanup_handle_orphan "$repo" "$path" "$head" "$branch" "$mode"
  done <<EOF
$entries
EOF
  if [ "$force" = --force ] || [ "$kind" = scout ]; then
    allow_force=1
  fi
  if [ -n "$cap_branch" ] && [ "$cap_branch" != HEAD ]; then
    fm_git_cleanup_consider_branch "$repo" "$cap_branch" "$cap_tip" "$mode" "" "$allow_force"
  fi
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    b=${pair%% *}
    t=${pair#* }
    fm_git_cleanup_consider_branch "$repo" "$b" "$t" "$mode" "" 0
  done <<EOF
$FM_GIT_CLEANUP_ATTRIB_BRANCHES
EOF
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$b" != "$cap_branch" ] || continue
    t=$(git -C "$repo" rev-parse --verify "refs/heads/$b" 2>/dev/null || true)
    [ -n "$t" ] || continue
    fm_git_cleanup_consider_branch "$repo" "$b" "$t" "$mode" "" 0
  done <<EOF
$FM_GIT_CLEANUP_SHIP_BRANCHES
EOF
  fm_git_cleanup_release_taskset_locks
  rm -rf -- "$tmp"
  FM_GIT_CLEANUP_CWD_SNAP=
  fm_git_cleanup_note "removed $FM_GIT_CLEANUP_REMOVED, retained $FM_GIT_CLEANUP_RETAINED"
  if [ "$FM_GIT_CLEANUP_FAILED" = 1 ]; then
    fm_git_cleanup_warn "a git step failed"
    return 1
  fi
  return 0
}
