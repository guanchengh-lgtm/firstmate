#!/usr/bin/env bash
# Shared path predicate and grant record owner for the project-write guard.
#
# Sourced by bin/fm-project-write-pretool-check.sh (which denies a write) and
# bin/fm-project-write-grant.sh (which records a captain-approved exception), so
# both agree on what "under a protected root" means and on the record format.
# This file is sourced by entrypoints and has no side effects on source.
#
# See docs/project-write-guard.md for the contract these helpers implement.

# Relative name of the single active grant record inside a home's state dir.
FM_PROJECT_WRITE_GRANT_NAME='.project-write-grant'

# Resolve $1 to an absolute path, following symlinks in the part that exists.
#
# A Write target usually does not exist yet, so realpath on the whole path is
# not available. This walks up to the nearest existing directory, resolves that
# with cd/pwd -P (which settles both symlinks and ".." in the existing prefix),
# then re-appends the remainder verbatim. A "..", which only appears in the
# non-existent tail, is therefore left lexically in place: a path that still
# reads as being under a protected root is treated as being under it. That is
# deliberate - the primary has no legitimate file-tool write under a protected
# root at all, so the conservative reading costs nothing real.
fm_project_write_resolve() {
  local p=$1 dir rest='' real
  [ -n "$p" ] || return 1
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do
    p=${p%/}
  done
  dir=$p
  while [ ! -d "$dir" ]; do
    case "$dir" in
      */?*)
        rest="/${dir##*/}$rest"
        dir=${dir%/*}
        [ -n "$dir" ] || dir=/
        ;;
      *)
        dir=/
        break
        ;;
    esac
  done
  real=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  [ "$real" != "/" ] || real=''
  printf '%s%s\n' "$real" "$rest"
}

# Return 0 when path $1 is $2 itself or lies beneath it.
fm_project_write_path_under() {
  local path=$1 root=$2
  [ -n "$path" ] && [ -n "$root" ] || return 1
  [ "$root" != "/" ] || return 1
  [ "$path" != "$root" ] || return 0
  case "$path" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# Print the protected roots of home $1 with state dir $2, one per line, as
# "<kind><TAB><absolute path>".
#
# Two kinds. "projects" is the home's own clone tree, which firstmate reads and
# never writes. "worktree" is every live task worktree recorded in a
# state/<id>.meta: those belong to the worker running there, so a primary
# file-editing one is the same self-implementation class plus a supervision
# hazard. Durable task state therefore only ever WIDENS this set.
#
# A recorded worktree equal to the home itself is skipped. That combination
# would otherwise make the home unable to write its own data/ and state/, which
# is a far worse failure than the case it would catch.
fm_project_write_protected_roots() {
  local home=$1 state=$2 home_real projects meta worktree resolved
  home_real=$(fm_project_write_resolve "$home") || home_real=$home
  projects=$(fm_project_write_resolve "$home/projects") || projects=''
  [ -z "$projects" ] || printf 'projects\t%s\n' "$projects"
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    worktree=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | head -n 1) || continue
    [ -n "$worktree" ] || continue
    resolved=$(fm_project_write_resolve "$worktree") || continue
    [ -n "$resolved" ] || continue
    [ "$resolved" != "$home_real" ] || continue
    printf 'worktree\t%s\n' "$resolved"
  done
}

# Read grant field $2 from record file $1.
fm_project_write_grant_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# Consume the active grant in state dir $1 if it covers target path $2.
#
# Returns 0 when the call is allowed, having claimed the record so it cannot
# cover a second call. Otherwise the exit code tells the deny message why the
# exception did not apply: 1 no grant, 2 expired (and removed), 3 covers a
# different path.
fm_project_write_consume_grant() {
  local state=$1 target=$2 grant granted expires now
  grant="$state/$FM_PROJECT_WRITE_GRANT_NAME"
  [ -f "$grant" ] || return 1
  granted=$(fm_project_write_grant_field "$grant" path)
  expires=$(fm_project_write_grant_field "$grant" expires)
  now=$(date +%s 2>/dev/null) || return 1
  case "$expires" in
    ''|*[!0-9]*)
      rm -f "$grant" 2>/dev/null
      return 2
      ;;
  esac
  if [ "$now" -ge "$expires" ]; then
    rm -f "$grant" 2>/dev/null
    return 2
  fi
  if ! fm_project_write_path_under "$target" "$granted"; then
    return 3
  fi
  # mv is the atomic claim: whichever call wins the rename consumes the grant,
  # and a loser falls through to the deny rather than riding the same record.
  mv -f "$grant" "$grant.consumed" 2>/dev/null || return 1
  fm_project_write_grant_log "$state" "consumed" "$target" \
    "$(fm_project_write_grant_field "$grant.consumed" reason)"
  return 0
}

# Append one audit line to the grant log in state dir $1.
# Fields: ISO-8601 timestamp, event, path, reason.
fm_project_write_grant_log() {
  local state=$1 event=$2 path=$3 reason=$4 stamp
  stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || stamp='?'
  reason=${reason//$'\n'/ }
  reason=${reason//$'\t'/ }
  printf '%s\t%s\t%s\t%s\n' "$stamp" "$event" "$path" "$reason" \
    >> "$state/$FM_PROJECT_WRITE_GRANT_NAME.log" 2>/dev/null || true
}
