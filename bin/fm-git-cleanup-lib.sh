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
FM_GIT_CLEANUP_DEFERRED=0
FM_GIT_CLEANUP_FAILED=0
FM_GIT_CLEANUP_LOCKS=
FM_GIT_CLEANUP_CWD_SNAP=
FM_GIT_CLEANUP_META_PATHS=
FM_GIT_CLEANUP_META_BRANCHES=
FM_GIT_CLEANUP_DEFAULT_REF=
FM_GIT_CLEANUP_ATTRIB_BRANCHES=

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
  local target=$1
  [ -n "$target" ] || return 1
  case "$target" in *$'\n'*|*$'\r'*) return 1 ;; esac
  if [ -d "$target" ]; then
    ( cd "$target" && pwd -P )
  else
    ( cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")" )
  fi
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
  [ -n "$path" ] && [ -d "$path" ] || return 1
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
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
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
  out=$( cd "$repo" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_git_cleanup_ensure_commit_object() {
  local repo=$1 target=$2 commit=$3 n
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_git_cleanup_pr_number_from_target "$target") || return 1
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$repo" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
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
  view=$(cd "$repo" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
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
  local repo=$1 mode=$2 pr_url=$3 commit=${4:-HEAD} name ref default_tree merged_tree
  [ -n "$repo" ] || return 1
  name=$(fm_git_cleanup_default_branch "$repo") || return 1
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif [ "$mode" = local-only ] && git -C "$repo" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
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
    fm_git_cleanup_content_in_default "$repo" "$mode" "$pr_url" "$commit"
    return $?
  fi
  if [ -n "$pr_url" ] || { [ -n "$branch" ] && [ "$branch" != HEAD ]; }; then
    if fm_git_cleanup_pr_is_merged "$repo" "$branch" "$pr_url" "$commit" >/dev/null; then
      return 0
    fi
  fi
  fm_git_cleanup_content_in_default "$repo" "$mode" "$pr_url" "$commit"
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

fm_git_cleanup_is_main_or_default() {
  local repo=$1 branch=$2 default_name
  [ "$branch" = main ] && return 0
  default_name=$(fm_git_cleanup_default_branch "$repo") || return 1
  [ "$branch" = "$default_name" ]
}

# Returns 0 when the branch may be deleted. Prints a retain reason on stdout when not.
fm_git_cleanup_branch_may_delete() {
  local repo=$1 branch=$2 tip=$3 mode=$4 pr_url=$5 allow_task_force=$6 current
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
  if fm_git_cleanup_is_main_or_default "$repo" "$branch"; then
    printf '%s\n' "default-branch"
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
  for host in ${FM_GC_ROOT:-} ${FM_GC_HOME:-} ${FM_GC_HOST_CWD:-}; do
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

fm_git_cleanup_treehouse_pool_of() {
  local path=$1 abs parent pool
  abs=$(fm_git_cleanup_abs_dir "$path" 2>/dev/null || printf '%s\n' "$path")
  case "$abs" in
    */.treehouse/*/*/*)
      parent=$(dirname "$abs")
      pool=$(dirname "$parent")
      case "$pool" in
        */.treehouse/*)
          printf '%s\n' "$pool"
          return 0
          ;;
      esac
      ;;
  esac
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
  local path=$1 raw
  [ -d "$path" ] || return 1
  if [ -e "$path/.git/MERGE_HEAD" ] || [ -e "$path/.git/CHERRY_PICK_HEAD" ] \
     || [ -e "$path/.git/REVERT_HEAD" ] || [ -e "$path/.git/REBASE_HEAD" ] \
     || [ -d "$path/.git/rebase-merge" ] || [ -d "$path/.git/rebase-apply" ]; then
    return 1
  fi
  raw=$(git -C "$path" status --porcelain --ignored 2>/dev/null) || return 1
  [ -z "$raw" ]
}

fm_git_cleanup_cwd_snapshot() {
  local out dest=$1 pid=
  : > "$dest" || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
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
    [ "$pid" != "$$" ] || continue
    case "$path" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done < "$snap"
  return 1
}

fm_git_cleanup_meta_refs_from_state() {
  local state=$1 meta wt abs branch
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$wt" ] || continue
    case "$wt" in *$'\n'*|*$'\r'*)
      FM_GIT_CLEANUP_META_PATHS=$FM_GIT_CLEANUP_META_PATHS$'\n''unreadable'
      continue
      ;;
    esac
    if abs=$(fm_git_cleanup_abs_dir "$wt" 2>/dev/null); then
      FM_GIT_CLEANUP_META_PATHS=$FM_GIT_CLEANUP_META_PATHS$'\n'$abs
    else
      FM_GIT_CLEANUP_META_PATHS=$FM_GIT_CLEANUP_META_PATHS$'\n'$wt
    fi
    if [ -d "$wt" ]; then
      branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
        FM_GIT_CLEANUP_META_BRANCHES=$FM_GIT_CLEANUP_META_BRANCHES$'\n'$branch
      fi
    fi
  done
}

fm_git_cleanup_collect_homes() {
  local home=$1 data=$2 reg line
  printf '%s\n' "$home"
  data=${data:-$home/data}
  reg="$data/secondmates.md"
  [ -f "$reg" ] || return 0
  if [ -L "$reg" ]; then
    printf '%s\n' "unreadable-registry"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        if command -v secondmate_registry_parse_line >/dev/null 2>&1 \
           || declare -F secondmate_registry_parse_line >/dev/null 2>&1; then
          if secondmate_registry_parse_line "$line"; then
            if [ "${SECONDMATE_REGISTRY_REMOTE:-0}" = 1 ]; then
              printf '%s\n' "remote-home"
              continue
            fi
            printf '%s\n' "$SECONDMATE_REGISTRY_HOME"
          else
            printf '%s\n' "unreadable-registry"
          fi
        else
          printf '%s\n' "unreadable-registry"
        fi
        ;;
    esac
  done < "$reg"
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
    [ -d "$state" ] || continue
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
        path=${line#worktree }
        case "$path" in *$'\t'*) return 1 ;; esac
        ;;
      HEAD\ *) head=${line#HEAD } ;;
      branch\ refs/heads/*) branch=${line#branch refs/heads/} ;;
      detached) branch=HEAD ;;
      locked*) locked=1 ;;
      prunable*) prunable=1 ;;
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

fm_git_cleanup_treehouse_status() {
  local repo=$1
  command -v treehouse >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  ( cd "$repo" && treehouse status --json ) 2>/dev/null
}

fm_git_cleanup_treehouse_slot_field() {
  local json=$1 path=$2 field=$3
  printf '%s\n' "$json" | jq -r --arg p "$path" --arg f "$field" '
    .[] | select(.path == $p) | .[$f] // empty
  ' 2>/dev/null
}

fm_git_cleanup_treehouse_destroy() {
  local repo=$1 path=$2
  ( cd "$repo" && treehouse destroy --yes -- "$path" )
}

fm_git_cleanup_treehouse_return_if_lease() {
  local repo=$1 path=$2 lease_id=$3 lease_holder=$4
  ( cd "$repo" && treehouse return --if-lease-id "$lease_id" --if-lease-holder "$lease_holder" -- "$path" )
}

fm_git_cleanup_revalidate_copy() {
  local repo=$1 path=$2 head=$3
  local now
  [ -d "$path" ] || return 1
  fm_git_cleanup_is_copy_root "$path" || return 1
  fm_git_cleanup_same_repo "$repo" "$path" || return 1
  now=$(git -C "$path" rev-parse --verify HEAD 2>/dev/null) || return 1
  [ "$now" = "$head" ]
}

fm_git_cleanup_consider_branch() {
  local repo=$1 branch=$2 tip=$3 mode=$4 pr_url=$5 allow_force=$6 known=$7 reason
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 0
  if [ "$known" != 1 ]; then
    fm_git_cleanup_retain "branch $branch" "unknown-attribution"
    return 0
  fi
  if fm_git_cleanup_meta_mentions_branch "$branch"; then
    fm_git_cleanup_retain "branch $branch" "live-meta"
    return 0
  fi
  if reason=$(fm_git_cleanup_delete_branch "$repo" "$branch" "$tip" "$mode" "$pr_url" "$allow_force"); then
    fm_git_cleanup_removed "branch $branch"
    return 0
  fi
  fm_git_cleanup_retain "branch $branch" "${reason:-unproved}"
}

fm_git_cleanup_handle_sibling() {
  local repo=$1 path=$2 head=$3 branch=$4 mode=$5
  local snap=$FM_GIT_CLEANUP_CWD_SNAP
  if fm_git_cleanup_protects_host "$path"; then
    fm_git_cleanup_retain "$path" "host"
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
  if fm_git_cleanup_meta_mentions_path "$path"; then
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
  if [ "$branch" = HEAD ] || [ -z "$branch" ]; then
    if ! fm_git_cleanup_work_is_landed "$path" "$branch" "$mode" "" "$head"; then
      fm_git_cleanup_retain "$path" "unique-unpublished"
      return 0
    fi
  elif ! fm_git_cleanup_work_is_landed "$path" "$branch" "$mode" "" "$head"; then
    fm_git_cleanup_retain "$path" "unique-unpublished"
    return 0
  fi
  if ! fm_git_cleanup_cwd_snapshot "$snap" || fm_git_cleanup_cwd_live "$snap" "$path"; then
    fm_git_cleanup_retain "$path" "live-cwd"
    return 0
  fi
  if ! fm_git_cleanup_revalidate_copy "$repo" "$path" "$head"; then
    fm_git_cleanup_retain "$path" "identity-changed"
    return 0
  fi
  if ! fm_git_cleanup_copy_is_clean "$path"; then
    fm_git_cleanup_retain "$path" "dirty"
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
  local repo=$1 path=$2 head=$3 branch=$4 mode=$5 backend=$6 returned_pool=$7
  local snap=$FM_GIT_CLEANUP_CWD_SNAP pool json status lease_id lease_holder
  if [ "$path" = "${FM_GC_REPO:-}" ]; then
    fm_git_cleanup_retain "$path" "primary"
    return 0
  fi
  if [ "$path" = "${FM_GC_RETURNED:-}" ]; then
    fm_git_cleanup_retain "$path" "idle-pool-slot"
    return 0
  fi
  if fm_git_cleanup_protects_host "$path"; then
    fm_git_cleanup_retain "$path" "host"
    return 0
  fi
  pool=$(fm_git_cleanup_treehouse_pool_of "$path" 2>/dev/null || true)
  if [ -n "$returned_pool" ] && [ -n "$pool" ] && [ "$pool" = "$returned_pool" ]; then
    fm_git_cleanup_retain "$path" "idle-pool-slot"
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
  if [ -z "$pool" ]; then
    fm_git_cleanup_retain "$path" "unknown-lease"
    return 0
  fi
  if [ "$backend" = orca ]; then
    fm_git_cleanup_retain "$path" "orca-managed"
    return 0
  fi
  if fm_git_cleanup_meta_mentions_path "$path"; then
    fm_git_cleanup_retain "$path" "live-meta"
    return 0
  fi
  if ! fm_git_cleanup_cwd_snapshot "$snap"; then
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
  if ! fm_git_cleanup_work_is_landed "$path" "$branch" "$mode" "" "$head"; then
    fm_git_cleanup_retain "$path" "unique-unpublished"
    return 0
  fi
  json=$(fm_git_cleanup_treehouse_status "$repo" 2>/dev/null || true)
  if [ -n "$json" ]; then
    status=$(fm_git_cleanup_treehouse_slot_field "$json" "$path" status)
    lease_id=$(fm_git_cleanup_treehouse_slot_field "$json" "$path" lease_id)
    lease_holder=$(fm_git_cleanup_treehouse_slot_field "$json" "$path" lease_holder)
    case "$status" in
      leased)
        case "$lease_id" in ''|*$'\n'*)
          fm_git_cleanup_retain "$path" "unknown-lease"
          return 0
          ;;
        esac
        case "$lease_holder" in
          ''|*$' '*|*$'\n'*|*$'\t'*)
            fm_git_cleanup_retain "$path" "unknown-lease"
            return 0
            ;;
          *[!A-Za-z0-9._-]*)
            fm_git_cleanup_retain "$path" "unknown-lease"
            return 0
            ;;
        esac
        if ! fm_git_cleanup_revalidate_copy "$repo" "$path" "$head"; then
          fm_git_cleanup_retain "$path" "identity-changed"
          return 0
        fi
        if ! fm_git_cleanup_treehouse_return_if_lease "$repo" "$path" "$lease_id" "$lease_holder"; then
          fm_git_cleanup_retain "$path" "unknown-lease"
          return 0
        fi
        if [ -d "$path" ]; then
          json=$(fm_git_cleanup_treehouse_status "$repo" 2>/dev/null || true)
          status=$(fm_git_cleanup_treehouse_slot_field "$json" "$path" status)
          if [ "$status" = leased ]; then
            fm_git_cleanup_retain "$path" "unknown-lease"
            return 0
          fi
          if ! fm_git_cleanup_treehouse_destroy "$repo" "$path"; then
            FM_GIT_CLEANUP_FAILED=1
            fm_git_cleanup_retain "$path" "provider-failure"
            return 0
          fi
        fi
        if [ -d "$path" ]; then
          fm_git_cleanup_retain "$path" "provider-failure"
          FM_GIT_CLEANUP_FAILED=1
          return 0
        fi
        fm_git_cleanup_removed "$path"
        if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
          FM_GIT_CLEANUP_ATTRIB_BRANCHES=$FM_GIT_CLEANUP_ATTRIB_BRANCHES$'\n'"$branch $head"
        fi
        return 0
        ;;
    esac
  fi
  if ! fm_git_cleanup_revalidate_copy "$repo" "$path" "$head"; then
    fm_git_cleanup_retain "$path" "identity-changed"
    return 0
  fi
  if ! fm_git_cleanup_cwd_snapshot "$snap" || fm_git_cleanup_cwd_live "$snap" "$path"; then
    fm_git_cleanup_retain "$path" "live-cwd"
    return 0
  fi
  if ! fm_git_cleanup_treehouse_destroy "$repo" "$path"; then
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

fm_git_cleanup_prune_gone_tmp() {
  local repo=$1 path head branch locked prunable unsafe=0 unsafe_row
  local entries missing admin
  entries=$(fm_git_cleanup_porcelain_entries "$repo") || {
    FM_GIT_CLEANUP_FAILED=1
    fm_git_cleanup_note "git prune skipped: unreadable inventory"
    return 0
  }
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
    if fm_git_cleanup_meta_mentions_path "$path"; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "live-meta"
      continue
    fi
    if [ -n "$head" ] && [ "$branch" = HEAD ]; then
      if ! fm_git_cleanup_tip_on_remotes "$repo" "$head" \
         && ! fm_git_cleanup_content_in_default "$repo" "${FM_GC_MODE:-}" "" "$head"; then
        unsafe=1
        unsafe_row=$path
        fm_git_cleanup_retain "$path" "unique-unpublished"
        continue
      fi
    fi
    admin=$(git -C "$repo" rev-parse --git-path "worktrees/$(basename "$path")" 2>/dev/null || true)
    if [ -n "$admin" ] && [ -e "$admin" ] && [ ! -r "$admin/HEAD" ]; then
      unsafe=1
      unsafe_row=$path
      fm_git_cleanup_retain "$path" "unreadable"
      continue
    fi
  done <<EOF
$entries
EOF
  if [ "$unsafe" = 1 ]; then
    fm_git_cleanup_note "skipped whole prune because $unsafe_row is unsafe"
    return 0
  fi
  if git -C "$repo" worktree prune --expire now; then
    fm_git_cleanup_note "pruned eligible temporary registrations"
    return 0
  fi
  FM_GIT_CLEANUP_FAILED=1
  fm_git_cleanup_note "git prune failed"
}

# After successful recorded-copy cleanup and task closure.
# Args: repo home state data returned_path captured_branch captured_tip mode kind force pr backend root
fm_git_cleanup_leftover_pass() {
  local repo=$1 home=$2 state=$3 data=$4 returned=$5 cap_branch=$6 cap_tip=$7
  local mode=$8 kind=$9 force=${10} pr_url=${11} backend=${12} root=${13}
  local homes snap tmp returned_pool path head branch locked prunable
  local allow_force=0 pair b t
  FM_GIT_CLEANUP_REMOVED=0
  FM_GIT_CLEANUP_RETAINED=0
  FM_GIT_CLEANUP_DEFERRED=0
  FM_GIT_CLEANUP_FAILED=0
  FM_GIT_CLEANUP_ATTRIB_BRANCHES=
  FM_GIT_CLEANUP_META_PATHS=
  FM_GIT_CLEANUP_META_BRANCHES=
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
  if ! homes=$(fm_git_cleanup_collect_homes "$home" "$data"); then
    fm_git_cleanup_warn "home inventory failed"
    return 1
  fi
  case "$homes" in
    *unreadable-registry*)
      fm_git_cleanup_note "deferred extra pass (unreadable home inventory)"
      FM_GIT_CLEANUP_DEFERRED=1
      return 0
      ;;
    *remote-home*)
      fm_git_cleanup_note "deferred extra pass (remote home cannot be checked)"
      FM_GIT_CLEANUP_DEFERRED=1
      return 0
      ;;
  esac
  if ! fm_git_cleanup_try_taskset_locks "$homes"; then
    fm_git_cleanup_note "deferred extra pass (publication lock contended)"
    FM_GIT_CLEANUP_DEFERRED=1
    return 0
  fi
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    fm_git_cleanup_meta_refs_from_state "$h/state"
  done <<EOF
$homes
EOF
  if printf '%s\n' "$FM_GIT_CLEANUP_META_PATHS" | grep -Fxq unreadable; then
    fm_git_cleanup_release_taskset_locks
    fm_git_cleanup_note "deferred extra pass (unreadable task metadata)"
    FM_GIT_CLEANUP_DEFERRED=1
    return 0
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
    fm_git_cleanup_note "deferred extra pass (cwd inspection failed)"
    FM_GIT_CLEANUP_DEFERRED=1
    return 0
  fi
  if ! fm_git_cleanup_worktree_list_ok "$repo"; then
    fm_git_cleanup_release_taskset_locks
    rm -rf -- "$tmp"
    fm_git_cleanup_warn "worktree list failed; leftover copies were not examined"
    return 1
  fi
  returned_pool=
  if [ -n "$FM_GC_RETURNED" ]; then
    returned_pool=$(fm_git_cleanup_treehouse_pool_of "$FM_GC_RETURNED" 2>/dev/null || true)
  fi
  while IFS=$(printf '\t') read -r path head branch locked prunable; do
    [ -n "$path" ] || continue
    case "$path" in *$'\n'*)
      fm_git_cleanup_retain "malformed-inventory" "unreadable"
      continue
      ;;
    esac
    if ! path=$(fm_git_cleanup_abs_dir "$path" 2>/dev/null); then
      fm_git_cleanup_retain "${path:-unreadable}" "unreadable"
      continue
    fi
    [ "$path" != "$repo" ] || continue
    [ "$path" != "$FM_GC_RETURNED" ] || continue
    if [ -n "$FM_GC_RETURNED" ] && fm_git_cleanup_is_sibling_name "$FM_GC_RETURNED" "$path"; then
      fm_git_cleanup_handle_sibling "$repo" "$path" "$head" "$branch" "$mode"
      continue
    fi
    if [ "$prunable" = 1 ]; then
      continue
    fi
    fm_git_cleanup_handle_orphan "$repo" "$path" "$head" "$branch" "$mode" "$backend" "$returned_pool"
  done <<EOF
$(fm_git_cleanup_porcelain_entries "$repo")
EOF
  fm_git_cleanup_prune_gone_tmp "$repo"
  if [ "$force" = --force ]; then
    allow_force=1
  fi
  if [ -n "$cap_branch" ] && [ "$cap_branch" != HEAD ]; then
    fm_git_cleanup_consider_branch "$repo" "$cap_branch" "$cap_tip" "$mode" "$pr_url" "$allow_force" 1
  fi
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    b=${pair%% *}
    t=${pair#* }
    fm_git_cleanup_consider_branch "$repo" "$b" "$t" "$mode" "" 0 1
  done <<EOF
$FM_GIT_CLEANUP_ATTRIB_BRANCHES
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
