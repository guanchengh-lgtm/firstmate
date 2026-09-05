#!/usr/bin/env bash
# Shared Git leftover cleanup for ordinary teardown and fleet sync.
#
# CONTRACT (one owner). This library owns extra-candidate inventory, keep-set
# application, same-repository committed-work proof, missing-registration
# preflight, safe branch deletion, and leftover result classification.
# bin/fm-teardown.sh owns when leftover cleanup runs (after successful
# recorded-copy cleanup and task closure only), plus task exceptions that must
# never leak onto a discovered leftover.
# bin/fm-fleet-sync.sh keeps [gone] discovery and refresh, then calls the
# shared deletion predicate.
# Treehouse owns managed-pool removal. Git owns linked-worktree admin removal.
# Treehouse exact-path cleanup uses its execution flags; no-mistakes gates never use --yes.
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
#     registered rows until their own missing-registration proof passes
#   remotes and remote-tracking refs as deletion targets
#   other repositories, nested directories, unknown leases, unreadable identity
#
# Fail-closed: dirty, uniquely unpublished, unknown-lease, live-cwd, live-meta,
# idle pool-slot, primary, host, remote, and other-project candidates are
# retained. There is no automatic discard mode.
# Git prune has no path selector: one unsafe prune row skips the whole prune.
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
FM_GIT_CLEANUP_ATTRIB_BRANCHES=
FM_GIT_CLEANUP_TREEHOUSE_FILTER_JSON=
FM_GIT_CLEANUP_TREEHOUSE_FILTER_READY=0
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

fm_git_cleanup_patch_id_for_commit() {
  local repo=$1 commit=$2
  git -C "$repo" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

fm_git_cleanup_unpushed_patches_in_pr_head() {
  local repo=$1 pr_head=$2 current=$3 base pr_patch_ids commit patch_id unpushed
  [ -n "$current" ] || return 1
  base=$(git -C "$repo" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$repo" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_git_cleanup_patch_id_for_commit "$repo" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$repo" log --format=%H "$current" --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_git_cleanup_patch_id_for_commit "$repo" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Prints the resolved PR URL on success. Never assigns a caller global.
fm_git_cleanup_pr_is_merged() {
  local repo=$1 branch=$2 pr_url=$3 current=${4:-} target view state remainder head resolved_url landed=0
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
  if git -C "$repo" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif fm_git_cleanup_unpushed_patches_in_pr_head "$repo" "$head" "$current"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
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
  leftover=$(git -C "$repo" rev-list --count "$tip" --not --remotes -- 2>/dev/null) || return 1
  [ "$leftover" = 0 ]
}

# Candidate-specific landed proof. Does not mutate PR_URL.
fm_git_cleanup_work_is_landed() {
  local repo=$1 branch=$2 mode=$3 pr_url=$4 commit=${5:-}
  [ -n "$repo" ] || return 1
  if [ -z "$commit" ]; then
    commit=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) || return 1
  fi
  if fm_git_cleanup_tip_on_remotes "$repo" "$commit"; then
    return 0
  fi
  if [ "$mode" = local-only ]; then
    fm_git_cleanup_content_in_default "$repo" "$mode" "$commit"
    return $?
  fi
  if [ -n "$pr_url" ] || { [ -n "$branch" ] && [ "$branch" != HEAD ]; }; then
    if fm_git_cleanup_pr_is_merged "$repo" "$branch" "$pr_url" "$commit" >/dev/null; then
      return 0
    fi
  fi
  fm_git_cleanup_content_in_default "$repo" "$mode" "$commit"
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
  if git -C "$repo" branch -d -- "$branch" >/dev/null 2>&1; then
    return 0
  fi
  if ! git -C "$repo" branch -D -- "$branch" >/dev/null 2>&1; then
    printf '%s\n' "delete-failed"
    return 1
  fi
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s\n' "delete-failed"
    return 1
  fi
  return 0
}

fm_git_cleanup_is_tmp_path() {
  local path=$1 abs
  abs=$(fm_git_cleanup_abs_dir "$path" 2>/dev/null || printf '%s\n' "$path")
  case "$abs" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) return 0 ;;
  esac
  return 1
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

fm_git_cleanup_private_refs() {
  local path=$1
  git -C "$path" for-each-ref --format='%(refname)%09%(objectname)' \
    refs/worktree refs/bisect refs/rewritten 2>/dev/null
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
    abs=$(fm_git_cleanup_abs_dir "$wt" 2>/dev/null) || return 1
    FM_GIT_CLEANUP_META_PATHS=$FM_GIT_CLEANUP_META_PATHS$'\n'$abs
    if [ -d "$wt" ]; then
      branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
        FM_GIT_CLEANUP_META_BRANCHES=$FM_GIT_CLEANUP_META_BRANCHES$'\n'$branch
      fi
    fi
    id=${meta##*/}
    id=${id%.meta}
    kind=$(sed -n 's/^kind=//p' "$meta") || return 1
    case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    case "$kind" in ship|scout)
      FM_GIT_CLEANUP_META_BRANCHES=$FM_GIT_CLEANUP_META_BRANCHES$'\n'"fm/$id"
      ;;
    esac
  done
}

fm_git_cleanup_collect_homes() {
  local home=$1 data=$2 pending current current_data reg line child visited= abs root
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
    --file "$backlog" --state done --fields closed 2>/dev/null) || return 1
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
    [ "$state" = done ] || return 1
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
    printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$head" "$branch" "$locked" "$prunable"
  fi
}

fm_git_cleanup_remove_unmanaged_worktree() {
  local repo=$1 path=$2
  git -C "$repo" worktree remove -- "$path"
}

fm_git_cleanup_tmp_key() {
  local path=$1
  case "$path" in
    /private/tmp) printf '/tmp\n' ;;
    /private/tmp/*) printf '/tmp/%s\n' "${path#/private/tmp/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

fm_git_cleanup_admin_for_path() {
  local repo=$1 path=$2 common admin gitdir want found= count=0
  common=$(fm_git_cleanup_common_dir "$repo") || return 1
  want=$(fm_git_cleanup_tmp_key "$path/.git")
  for admin in "$common"/worktrees/*; do
    [ -d "$admin" ] && [ ! -L "$admin" ] || continue
    [ -f "$admin/gitdir" ] && [ ! -L "$admin/gitdir" ] && [ -r "$admin/gitdir" ] || continue
    IFS= read -r gitdir < "$admin/gitdir" || [ -n "$gitdir" ] || continue
    case "$gitdir" in /*) ;; *) continue ;; esac
    if [ "$(fm_git_cleanup_tmp_key "$gitdir")" = "$want" ]; then
      count=$((count + 1))
      found=$admin
    fi
  done
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$found"
}

fm_git_cleanup_admin_head() {
  local repo=$1 admin=$2 value ref
  [ -f "$admin/HEAD" ] && [ ! -L "$admin/HEAD" ] && [ -r "$admin/HEAD" ] || return 1
  IFS= read -r value < "$admin/HEAD" || [ -n "$value" ] || return 1
  case "$value" in
    'ref: refs/heads/'*)
      ref=${value#ref: }
      git -C "$repo" rev-parse --verify "$ref^{commit}" 2>/dev/null
      ;;
    [0-9a-fA-F]*)
      git -C "$repo" rev-parse --verify "$value^{commit}" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_git_cleanup_admin_has_operation() {
  local admin=$1 op
  for op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD rebase-merge rebase-apply; do
    [ ! -e "$admin/$op" ] && [ ! -L "$admin/$op" ] || return 0
  done
  return 1
}

fm_git_cleanup_admin_private_refs() {
  local repo=$1 admin=$2 common
  common=$(fm_git_cleanup_common_dir "$repo") || return 1
  GIT_DIR=$admin GIT_COMMON_DIR=$common git for-each-ref \
    --format='%(refname)%09%(objectname)' refs/worktree refs/bisect refs/rewritten 2>/dev/null
}

fm_git_cleanup_admin_refs_are_landed() {
  local repo=$1 admin=$2 branch=$3 mode=$4 head refs line oid
  head=$(fm_git_cleanup_admin_head "$repo" "$admin") || return 1
  fm_git_cleanup_work_is_landed "$repo" "$branch" "$mode" "" "$head" || return 1
  refs=$(fm_git_cleanup_admin_private_refs "$repo" "$admin") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *$'\t'*) ;; *) return 1 ;; esac
    oid=${line#*$'\t'}
    fm_git_cleanup_work_is_landed "$repo" HEAD "$mode" "" "$oid" || return 1
  done <<EOF
$refs
EOF
}

fm_git_cleanup_treehouse_status() {
  local repo=$1 root=${2:-} out
  command -v treehouse >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -d "$repo" ] || return 1
  if [ -n "$root" ]; then
    out=$(cd "$repo" && fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" \
      env TREEHOUSE_ROOT="$root" treehouse status --json 2>/dev/null) || return 1
  else
    out=$(cd "$repo" && fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" \
      treehouse status --json 2>/dev/null) || return 1
  fi
  printf '%s\n' "$out" | jq -ce 'select(type == "array")' 2>/dev/null
}

fm_git_cleanup_prepare_treehouse_filter() {
  local repo=$1
  [ "$FM_GIT_CLEANUP_TREEHOUSE_FILTER_READY" = 1 ] && return 0
  FM_GIT_CLEANUP_TREEHOUSE_FILTER_JSON=$(fm_git_cleanup_treehouse_status "$repo" 2>/dev/null) \
    || return 1
  FM_GIT_CLEANUP_TREEHOUSE_FILTER_READY=1
}

fm_git_cleanup_treehouse_slot() {
  local json=$1 path=$2 base=${3:-.} rows row raw normalized found= count=0
  rows=$(printf '%s\n' "$json" | jq -ce '.[]' 2>/dev/null) || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    raw=$(printf '%s\n' "$row" | jq -er '.path | strings | select(length > 0)' 2>/dev/null) \
      || return 1
    case "$raw" in /*) ;; *) raw="$base/$raw" ;; esac
    normalized=$(fm_git_cleanup_abs_dir "$raw" 2>/dev/null) || return 1
    if [ "$normalized" = "$path" ]; then
      count=$((count + 1))
      found=$row
    fi
  done <<EOF
$rows
EOF
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$found"
}

fm_git_cleanup_treehouse_root_of() {
  local path=$1 slot pool root
  slot=$(dirname "$path") || return 1
  pool=$(dirname "$slot") || return 1
  root=$(dirname "$pool") || return 1
  [ "$(basename "$root")" != .treehouse ] || root=$(dirname "$root")
  [ "$root" != / ] || return 1
  fm_git_cleanup_abs_dir "$root"
}

fm_git_cleanup_treehouse_status_has_root() {
  local json=$1 root=$2 base=$3 rows raw normalized row_root
  rows=$(printf '%s\n' "$json" | jq -r '
    if all(.[]; ((.path | type) == "string" and (.path | length) > 0))
    then .[].path
    else error("invalid path")
    end
  ' 2>/dev/null) || return 2
  [ -n "$rows" ] || return 1
  while IFS= read -r raw; do
    [ -n "$raw" ] || return 2
    case "$raw" in /*) ;; *) raw="$base/$raw" ;; esac
    normalized=$(fm_git_cleanup_abs_dir "$raw" 2>/dev/null) || return 2
    row_root=$(fm_git_cleanup_treehouse_root_of "$normalized" 2>/dev/null) || return 2
    [ "$row_root" = "$root" ] && return 0
  done <<EOF
$rows
EOF
  return 1
}

fm_git_cleanup_treehouse_slot_field() {
  local slot=$1 field=$2
  printf '%s\n' "$slot" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
}

fm_git_cleanup_treehouse_slot_is_available() {
  local slot=$1 status lease_id lease_holder
  status=$(fm_git_cleanup_treehouse_slot_field "$slot" status) || return 1
  lease_id=$(fm_git_cleanup_treehouse_slot_field "$slot" lease_id) || return 1
  lease_holder=$(fm_git_cleanup_treehouse_slot_field "$slot" lease_holder) || return 1
  [ -n "$status" ] || return 1
  case "$status" in available|clean) ;; *) return 1 ;; esac
  [ -z "$lease_id" ] && [ -z "$lease_holder" ]
}

fm_git_cleanup_treehouse_destroy() {
  local repo=$1 root=$2 path=$3
  (cd "$repo" && fm_run_timed "$FM_GIT_CLEANUP_TIMEOUT_SECS" \
    env TREEHOUSE_ROOT="$root" treehouse destroy --yes -- "$path")
}

fm_git_cleanup_revalidate_copy() {
  local repo=$1 path=$2 signature=$3 now
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  fm_git_cleanup_is_copy_root "$path" || return 1
  fm_git_cleanup_same_repo "$repo" "$path" || return 1
  now=$(fm_git_cleanup_copy_signature "$path") || return 1
  [ "$now" = "$signature" ]
}

fm_git_cleanup_copy_ready_at_mutation() {
  local repo=$1 path=$2 branch=$3 mode=$4 signature=$5 snap=$6
  local head current_branch signature_head
  fm_git_cleanup_revalidate_copy "$repo" "$path" "$signature" || return 1
  signature_head=${signature%%$'\n'*}
  case "$signature_head" in *$'\t'*) ;; *) return 1 ;; esac
  head=${signature_head%%$'\t'*}
  current_branch=${signature_head#*$'\t'}
  [ -n "$head" ] && [ -n "$current_branch" ] || return 1
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
  local snap=$FM_GIT_CLEANUP_CWD_SNAP signature
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
  if ! fm_git_cleanup_copy_ready_at_mutation "$repo" "$path" "$branch" "$mode" "$signature" "$snap"; then
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
  local repo=$1 path=$2 head=$3 branch=$4 mode=$5
  local snap=$FM_GIT_CLEANUP_CWD_SNAP active_json json slot status root
  local signature post_signature post_branch rc
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
    return 0
  fi
  if ! fm_git_cleanup_is_copy_root "$path" || ! fm_git_cleanup_same_repo "$repo" "$path"; then
    fm_git_cleanup_retain "$path" "other-project"
    return 0
  fi
  fm_git_cleanup_prepare_treehouse_filter "$repo" || {
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "provider-failure"
    return 0
  }
  active_json=$FM_GIT_CLEANUP_TREEHOUSE_FILTER_JSON
  if slot=$(fm_git_cleanup_treehouse_slot "$active_json" "$path" "$repo" 2>/dev/null); then
    status=$(fm_git_cleanup_treehouse_slot_field "$slot" status)
    case "$status" in
      available|clean) fm_git_cleanup_retain "$path" "idle-pool-slot" ;;
      leased|in_use|in-use|busy|reserved) fm_git_cleanup_retain "$path" "active-pool-slot" ;;
      *) fm_git_cleanup_retain "$path" "unknown-lease" ;;
    esac
    return 0
  fi
  root=$(fm_git_cleanup_treehouse_root_of "$path" 2>/dev/null) || {
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  }
  if fm_git_cleanup_treehouse_status_has_root "$active_json" "$root" "$repo"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" = 0 ]; then
    fm_git_cleanup_retain "$path" "idle-pool-slot"
    return 0
  elif [ "$rc" != 1 ]; then
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "provider-failure"
    return 0
  fi
  json=$(fm_git_cleanup_treehouse_status "$repo" "$root" 2>/dev/null) || {
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  }
  slot=$(fm_git_cleanup_treehouse_slot "$json" "$path" "$repo" 2>/dev/null) || {
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  }
  status=$(fm_git_cleanup_treehouse_slot_field "$slot" status)
  [ -n "$status" ] || {
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  }
  if fm_git_cleanup_meta_mentions_copy "$path" "$branch"; then
    fm_git_cleanup_retain "$path" "live-meta"
    return 0
  fi
  if [ -z "$snap" ] || ! fm_git_cleanup_cwd_snapshot "$snap" \
     || fm_git_cleanup_cwd_live "$snap" "$path"; then
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
  case "$status" in
    leased)
      fm_git_cleanup_retain "$path" "unknown-lease"
      return 0
      ;;
    available|clean)
      fm_git_cleanup_treehouse_slot_is_available "$slot" || {
        fm_git_cleanup_retain "$path" "unknown-lease"
        return 0
      }
      post_signature=$signature
      post_branch=$branch
      ;;
    *)
      fm_git_cleanup_retain "$path" "unknown-lease"
      return 0
      ;;
  esac
  if ! fm_git_cleanup_copy_ready_at_mutation "$repo" "$path" "$post_branch" "$mode" "$post_signature" "$snap"; then
    fm_git_cleanup_retain "$path" "mutation-recheck"
    return 0
  fi
  active_json=$(fm_git_cleanup_treehouse_status "$repo" 2>/dev/null) || {
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "provider-failure"
    return 0
  }
  if fm_git_cleanup_treehouse_status_has_root "$active_json" "$root" "$repo"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" = 0 ]; then
    fm_git_cleanup_retain "$path" "idle-pool-slot"
    return 0
  elif [ "$rc" != 1 ]; then
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "provider-failure"
    return 0
  fi
  json=$(fm_git_cleanup_treehouse_status "$repo" "$root" 2>/dev/null) || {
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  }
  slot=$(fm_git_cleanup_treehouse_slot "$json" "$path" "$repo" 2>/dev/null) || {
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  }
  fm_git_cleanup_treehouse_slot_is_available "$slot" || {
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  }
  if ! fm_git_cleanup_copy_ready_at_mutation "$repo" "$path" "$post_branch" "$mode" "$post_signature" "$snap"; then
    fm_git_cleanup_retain "$path" "mutation-recheck"
    return 0
  fi
  if ! fm_git_cleanup_treehouse_destroy "$repo" "$root" "$path"; then
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "provider-failure"
    return 0
  fi
  if [ -d "$path" ]; then
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_retain "$path" "provider-failure"
    return 0
  fi
  fm_git_cleanup_removed "$path"
  if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
    FM_GIT_CLEANUP_ATTRIB_BRANCHES=$FM_GIT_CLEANUP_ATTRIB_BRANCHES$'\n'"$branch $head"
  fi
}

fm_git_cleanup_prune_inventory_safe() {
  local repo=$1 entries=$2 path head branch locked prunable unsafe=0 unsafe_row
  local missing admin admin_head
  while IFS=$(printf '\t') read -r path head branch locked prunable; do
    [ -n "$path" ] || continue
    missing=0
    if [ "$prunable" = 1 ] || [ ! -d "$path" ]; then
      missing=1
    fi
    [ "$missing" = 1 ] || continue
    if [ "$locked" = 1 ]; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "locked"
      continue
    fi
    if [ -n "${FM_GC_RETURNED:-}" ] && [ "$path" = "$FM_GC_RETURNED" ]; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "returned-slot"
      continue
    fi
    if [ "$branch" = main ] \
       || { [ -n "$FM_GIT_CLEANUP_DEFAULT_NAME" ] \
            && [ "$branch" = "$FM_GIT_CLEANUP_DEFAULT_NAME" ]; }; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "default-branch"
      continue
    fi
    if ! fm_git_cleanup_is_tmp_path "$path"; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "non-temporary"
      continue
    fi
    if fm_git_cleanup_protects_host "$path"; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "host"
      continue
    fi
    if fm_git_cleanup_protects_home "$path"; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "registered-home"
      continue
    fi
    if fm_git_cleanup_meta_mentions_copy "$path" "$branch"; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "live-meta"
      continue
    fi
    admin=$(fm_git_cleanup_admin_for_path "$repo" "$path" 2>/dev/null) || {
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "unreadable"
      continue
    }
    if fm_git_cleanup_admin_has_operation "$admin"; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "operation-in-progress"
      continue
    fi
    admin_head=$(fm_git_cleanup_admin_head "$repo" "$admin") || {
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "unreadable"
      continue
    }
    if [ -n "$head" ] && [ "$head" != "$admin_head" ]; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "identity-changed"
      continue
    fi
    if ! fm_git_cleanup_admin_refs_are_landed "$repo" "$admin" "$branch" "${FM_GC_MODE:-}"; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "unique-unpublished"
      continue
    fi
  done <<EOF
$entries
EOF
  if [ "$unsafe" = 1 ]; then
    fm_git_cleanup_note "skipped whole prune because $unsafe_row is unsafe"
    return 1
  fi
  return 0
}

fm_git_cleanup_entries_has_path() {
  local entries=$1 target=$2 path head branch locked prunable
  while IFS=$(printf '\t') read -r path head branch locked prunable; do
    [ "$path" = "$target" ] && return 0
  done <<EOF
$entries
EOF
  return 1
}

fm_git_cleanup_record_pruned_entries() {
  local before=$1 after=$2 path head branch locked prunable missing
  while IFS=$(printf '\t') read -r path head branch locked prunable; do
    [ -n "$path" ] || continue
    missing=0
    if [ "$prunable" = 1 ] || [ ! -d "$path" ]; then
      missing=1
    fi
    [ "$missing" = 1 ] || continue
    if fm_git_cleanup_entries_has_path "$after" "$path"; then
      fm_git_cleanup_retain "$path" "prune-race"
    else
      fm_git_cleanup_removed "registration $path"
    fi
  done <<EOF
$before
EOF
}

fm_git_cleanup_prune_gone_tmp() {
  local repo=$1 entries=$2 fresh after
  fm_git_cleanup_prune_inventory_safe "$repo" "$entries" || return 0
  fresh=$(fm_git_cleanup_porcelain_entries "$repo") || {
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_note "git prune skipped: unreadable mutation inventory"
    return 0
  }
  fm_git_cleanup_prune_inventory_safe "$repo" "$fresh" || return 0
  if git -C "$repo" worktree prune --expire now; then
    after=$(fm_git_cleanup_porcelain_entries "$repo") || {
      FM_GIT_CLEANUP_FAILED=1
      fm_git_cleanup_note "git prune count unavailable: unreadable result inventory"
      return 0
    }
    fm_git_cleanup_record_pruned_entries "$fresh" "$after"
    fm_git_cleanup_note "pruned eligible temporary registrations"
    return 0
  fi
  FM_GIT_CLEANUP_FAILED=1
  fm_git_cleanup_note "git prune failed"
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
  FM_GIT_CLEANUP_TREEHOUSE_FILTER_JSON=
  FM_GIT_CLEANUP_TREEHOUSE_FILTER_READY=0
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
  FM_GC_MODE=$mode
  repo=$FM_GC_REPO
  if ! fm_git_cleanup_prepare_keep_set "$home" "$data" "$repo"; then
    fm_git_cleanup_note "deferred extra pass (ownership inventory or publication lock unavailable)"
    return 0
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
  fm_git_cleanup_prune_gone_tmp "$repo" "$entries"
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
    if [ "$prunable" = 1 ]; then
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
    fm_git_cleanup_warn "a provider or git step failed"
    return 1
  fi
  return 0
}
