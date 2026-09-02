#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting) and fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment). Teardown uses only
# strict branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption defined below. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Code identity (fm_nm_head_matches_worktree) binds axi-status head= in this
# order: equal local HEAD; local HEAD is an ancestor of the run head; no match
# when the run head is a strict ancestor of local HEAD; else the live pushed
# tip of this branch. The live tip is git ls-remote of refs/heads/<branch>,
# else gh pr view --json headRefOid when a pr= URL is supplied, else recorded
# pr_head= as an offline fallback. The worktree checkout is not canonical:
# the pipeline rewrites and pushes without updating that copy, so a missing
# run-head object or a diverged rebase still matches when head= equals the
# live remote. Identity reads never git fetch. A bounded remote read that
# times out cannot bind.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

if ! command -v fm_run_timed >/dev/null 2>&1; then
  _fm_nm_self=${BASH_SOURCE[0]}
  if [ -L "$_fm_nm_self" ]; then
    _fm_nm_link=$(readlink "$_fm_nm_self")
    case "$_fm_nm_link" in
      /*) _fm_nm_self=$_fm_nm_link ;;
      *) _fm_nm_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$_fm_nm_link" ;;
    esac
  fi
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$(cd "$(dirname "$_fm_nm_self")" && pwd)/fm-timeout-lib.sh"
  unset _fm_nm_self _fm_nm_link
fi

# 0 if $1 is a hex SHA form (short or full, SHA-1 or SHA-256).
fm_nm_sha_form() {
  local s=$1 n
  case "$s" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  n=${#s}
  [ "$n" -ge 4 ] && [ "$n" -le 64 ]
}

# 0 if two SHA strings name the same commit, including short/full prefix.
fm_nm_sha_same() {
  local a b
  a=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  b=$(printf '%s' "$2" | tr 'A-F' 'a-f')
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  if [ ${#a} -lt ${#b} ]; then
    [ ${#a} -ge 7 ] || return 1
    case "$b" in "$a"*) return 0 ;; esac
  else
    [ ${#b} -ge 7 ] || return 1
    case "$a" in "$b"*) return 0 ;; esac
  fi
  return 1
}

fm_nm_remote_timeout() {
  local t=${FM_NM_REMOTE_TIMEOUT:-10}
  case "$t" in
    ''|*[!0-9]*|0) t=10 ;;
  esac
  printf '%s' "$t"
}

# Print the live pushed tip for worktree $1. pr_url $2 and recorded pr_head $3
# are optional. A ls-remote or gh timeout cannot bind. Never git fetch.
fm_nm_live_pushed_tip() {  # <worktree> [pr_url] [pr_head]
  local wt=$1 pr_url=${2:-} pr_head=${3:-} branch out rc tip timeout
  timeout=$(fm_nm_remote_timeout)
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || true
  if [ -n "$branch" ] && git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    rc=0
    out=$(fm_run_timed "$timeout" git -C "$wt" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 124 ]; then
      return 1
    fi
    if [ "$rc" -eq 0 ]; then
      tip=$(printf '%s\n' "$out" | awk '{print $1; exit}')
      if fm_nm_sha_form "$tip"; then
        printf '%s' "$tip"
        return 0
      fi
    fi
  fi
  if [ -n "$pr_url" ] && command -v gh >/dev/null 2>&1; then
    rc=0
    out=$(cd "$wt" && fm_run_timed "$timeout" gh pr view "$pr_url" --json headRefOid -q .headRefOid 2>/dev/null) || rc=$?
    if [ "$rc" -eq 124 ]; then
      return 1
    fi
    out=$(fm_nm_trim "$out")
    if [ "$rc" -eq 0 ] && fm_nm_sha_form "$out"; then
      printf '%s' "$out"
      return 0
    fi
  fi
  if fm_nm_sha_form "$pr_head"; then
    printf '%s' "$pr_head"
    return 0
  fi
  return 1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty/non-SHA head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD: no match, even if a stale
#     remote still equals the run (local work advanced outside the run)
#   - else live pushed tip equals run head: match (pipeline rewrote/pushed
#     without updating this checkout, including missing objects and diverged
#     rebase)
#   - else: no match (historical run whose head is not the live remote)
fm_nm_head_matches_worktree() {  # <worktree> <run_head> [pr_url] [pr_head]
  local wt=$1 run_head=$2 pr_url=${3:-} pr_head=${4:-} local_full run_full tip
  run_head=$(fm_nm_strip_quotes "$run_head")
  fm_nm_sha_form "$run_head" || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || run_full=
  if [ -n "$run_full" ]; then
    [ "$run_full" = "$local_full" ] && return 0
    if git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
      return 0
    fi
    if git -C "$wt" merge-base --is-ancestor "$run_full" "$local_full" 2>/dev/null; then
      return 1
    fi
  fi
  tip=$(fm_nm_live_pushed_tip "$wt" "$pr_url" "$pr_head") || return 1
  fm_nm_sha_same "$run_head" "$tip"
}

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# branch_sync.state from captured `axi status` TOON $1: the scalar directly
# under the top-level `branch_sync:` block. The first `state:` inside the
# block is the direct child (the nested local/pipeline/target/remote
# sub-blocks carry no `state:` key). Empty when the block is absent: no run
# on the current branch, another branch's run, or a CLI without branch sync.
fm_nm_branch_sync_state() {  # <toon-output>
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  fm_nm_strip_quotes "$s"
}

# 0 if the run in captured `axi status` TOON $1 is still in flight: no
# terminal outcome and no terminal status.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$1" status)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and
# head equality must not be required - the pipeline's lane head is routinely
# not a git object in the task worktree (rebase and fix commits that were
# never pushed back), so the head rule rejects exactly the run that is most
# current. The exemption never applies to a terminal run: a terminal run has
# released the branch, and binding one by branch name alone is the historical
# reused-branch misattribution the head rule exists to prevent.
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}
