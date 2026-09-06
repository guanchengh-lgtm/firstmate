#!/usr/bin/env bash
# Shared primary-home checks for hooks and state-reading entrypoints.
# This library has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

# Return 0 only for an unmarked linked worktree used as an effective home.
# Plain checkouts, marked secondmates, and non-git fixtures return 1.
# Return 2 when Git cannot classify a repository-shaped home.
fm_home_is_linked_worktree() {
  local home=$1 inside git_dir git_common_dir
  fm_root_is_secondmate_home "$home" && return 1
  command -v git >/dev/null 2>&1 || return 2
  if ! inside=$(git -C "$home" rev-parse --is-inside-work-tree 2>/dev/null); then
    [ -e "$home/.git" ] || [ -L "$home/.git" ] || return 1
    return 2
  fi
  [ "$inside" = true ] || return 1
  git_dir=$(git -C "$home" rev-parse --git-dir 2>/dev/null) || return 2
  git_common_dir=$(git -C "$home" rev-parse --git-common-dir 2>/dev/null) || return 2
  [ "$git_dir" != "$git_common_dir" ]
}

# Single owner of the linked-home refusal; callers choose their exit status.
# Resolve the common checkout for advice only, without changing any state.
fm_home_refuse_linked_worktree() {
  local home=$1 caller=$2 status=0 common real_home='<real-home>'
  fm_home_is_linked_worktree "$home" || status=$?
  if [ "$status" -eq 1 ]; then
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    printf 'REFUSED: %s cannot verify whether home %s is a linked worktree because Git classification failed; restore Git access, then retry.\n' "$caller" "$home" >&2
    return 1
  fi
  common=$(git -C "$home" rev-parse --git-common-dir 2>/dev/null) || common=
  if [ -n "$common" ]; then
    case "$common" in /*) ;; *) common="$home/$common" ;; esac
    real_home=$(cd "$common/.." 2>/dev/null && pwd -P) || real_home='<real-home>'
  fi
  printf "REFUSED: %s self-located its home to linked worktree %s; that copy's state/ is not a firstmate home. Set FM_HOME=%s or start firstmate from %s, then retry.\n" "$caller" "$home" "$real_home" "$real_home" >&2
  return 1
}

# Walk at most 64 ancestors, excluding pid 1, and print pid<TAB>comm<TAB>cwd.
# Return 1 for no match and 2 for an unverifiable ps, lsof, or Git result.
# On 2, stdout names the failed tool so command-substitution callers retain it.
fm_ancestor_cwd_in_linked_worktree() {
  local pid=$1 hops=0 info parent comm cwd output line home_status
  case "$pid" in ''|*[!0-9]*) printf 'ps\n'; return 2 ;; esac
  while [ "$pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
    info=$(ps -p "$pid" -o ppid= -o comm= 2>/dev/null) || { printf 'ps\n'; return 2; }
    read -r parent comm <<< "$info"
    case "$parent" in ''|*[!0-9]*) printf 'ps\n'; return 2 ;; esac
    output=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null) || { printf 'lsof\n'; return 2; }
    cwd=
    while IFS= read -r line; do
      case "$line" in n*) cwd=${line#n}; break ;; esac
    done <<< "$output"
    [ -n "$cwd" ] || { printf 'lsof\n'; return 2; }
    home_status=0
    fm_home_is_linked_worktree "$cwd" || home_status=$?
    if [ "$home_status" -eq 0 ]; then
      printf '%s\t%s\t%s\n' "$pid" "$comm" "$cwd"
      return 0
    fi
    [ "$home_status" -ne 2 ] || { printf 'git\n'; return 2; }
    pid=$parent
    hops=$((hops + 1))
  done
  return 1
}
