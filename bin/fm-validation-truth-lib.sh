#!/usr/bin/env bash
# Shared no-mistakes validation-truth refusal.
#
# A no-mistakes ship may be armed, merged, or cleaned up only when one of two
# proofs holds. First try: a fresh fm-crew-state.sh read reports source:
# run-step (the no-mistakes axi status run, not a live pane or status log) and
# state: done. Second try, when that is unreadable or not done: a no-mistakes
# run row keyed by PR URL (argument, else pr= from meta) whose status is not
# failed or cancelled, whose head matches the forge headRefOid, and whose
# forge check rollup is all green with none pending. The second proof keys on
# `no-mistakes runs --limit N` (sqlite read-only only when those text rows
# lack a PR URL). It never keys on bare `axi status` and never consults or
# resets a worktree. direct-PR, local-only, scout, and secondmate tasks are
# exempt because they have no validation run by design.
#
# fm-pr-merge.sh additionally re-reads the forge rollup independently of
# which proof passed, refuses a red or pending rollup, and passes
# --match-head-commit <forge head>. An empty rollup is not a second-proof
# pass (it cannot tell "no CI" from a broken trigger) but is not a red
# merge refusal, matching the no-CI merge path.
#
# When the run is unreadable, the message is "validation truth unreadable"
# rather than "not validated". Callers must not restart the shared no-mistakes
# daemon; escalate instead.
#
# Test-harness escape: FM_VALIDATION_TRUTH_BYPASS=1 is exported only by
# tests/lib.sh so firstmate's own suite can drive pr-check, pr-merge, and
# teardown without a real validation run. Production callers never set it.
# tests/fm-validation-truth.test.sh strips it to verify real refusal.
#
# Residual: speech that a ship is fine without running this helper, ci-step
# override inherited from fm-crew-state.sh, time-of-check to time-of-use,
# direct-PR ships, empty-rollup second proof, check drift in the seconds
# after the rollup read (branch protection owns that), and worktree
# validated-code identity (owned by bin/fm-nm-run-lib.sh). No completeness
# claim. No standing merge-N rule.
#
# Sourced by bin/fm-pr-check.sh, bin/fm-pr-merge.sh, and bin/fm-teardown.sh.
# No side effects on source. set -u / set -e safe.

if ! command -v fm_nm_sha_same >/dev/null 2>&1; then
  _fm_vt_self=${BASH_SOURCE[0]}
  if [ -L "$_fm_vt_self" ]; then
    _fm_vt_link=$(readlink "$_fm_vt_self")
    case "$_fm_vt_link" in
      /*) _fm_vt_self=$_fm_vt_link ;;
      *) _fm_vt_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$_fm_vt_link" ;;
    esac
  fi
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$(cd "$(dirname "$_fm_vt_self")" && pwd)/fm-nm-run-lib.sh"
  unset _fm_vt_self _fm_vt_link
fi

fm_validation_truth_parse() {
  local line=$1
  FM_VT_STATE=
  FM_VT_SOURCE=
  case "$line" in
    state:\ *' · source: '*)
      FM_VT_STATE=${line#state: }
      FM_VT_STATE=${FM_VT_STATE%% · *}
      FM_VT_SOURCE=${line#* · source: }
      FM_VT_SOURCE=${FM_VT_SOURCE%% · *}
      FM_VT_STATE=${FM_VT_STATE#"${FM_VT_STATE%%[![:space:]]*}"}
      FM_VT_STATE=${FM_VT_STATE%"${FM_VT_STATE##*[![:space:]]}"}
      FM_VT_SOURCE=${FM_VT_SOURCE#"${FM_VT_SOURCE%%[![:space:]]*}"}
      FM_VT_SOURCE=${FM_VT_SOURCE%"${FM_VT_SOURCE##*[![:space:]]}"}
      ;;
  esac
}

fm_vt_canon_url() {
  local u
  u=$(fm_nm_trim "${1:-}")
  u=${u%/}
  printf '%s' "$u"
}

fm_vt_meta_pr_url() {  # <meta-file>
  local u
  u=$(grep '^pr=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fm_vt_canon_url "$u"
}

fm_vt_runs_limit() {
  local n=${FM_VT_RUNS_LIMIT:-200}
  case "$n" in
    ''|*[!0-9]*|0) n=200 ;;
  esac
  printf '%s' "$n"
}

# Newest-first rows: "<status> <branch> <sha> <date> [<pr-url>]".
# Prints "status<TAB>sha" for the first row whose PR URL matches $1.
fm_vt_parse_runs_for_pr() {  # <pr-url> <listing>
  local want row st rest sha url had_row=0 had_url=0
  want=$(fm_vt_canon_url "$1")
  [ -n "$want" ] || return 1
  while IFS= read -r row; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    had_row=1
    st=${row%% *}
    rest=${row#* }
    rest=$(fm_nm_trim "$rest")
    rest=${rest#* }
    rest=$(fm_nm_trim "$rest")
    sha=${rest%% *}
    rest=${rest#* }
    rest=$(fm_nm_trim "$rest")
    url=${rest##* }
    case "$url" in
      http://*|https://*)
        had_url=1
        if [ "$(fm_vt_canon_url "$url")" = "$want" ]; then
          printf '%s\t%s\n' "$st" "$sha"
          return 0
        fi
        ;;
    esac
  done <<EOF
$2
EOF
  if [ "$had_row" -eq 1 ] && [ "$had_url" -eq 0 ]; then
    return 2
  fi
  return 1
}

fm_vt_sqlite_runs_for_pr() {  # <pr-url>
  local want db out st sha url
  want=$(fm_vt_canon_url "$1")
  [ -n "$want" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  db=${NO_MISTAKES_HOME:-$HOME/.no-mistakes}/state.sqlite
  [ -f "$db" ] && [ ! -L "$db" ] || return 1
  out=$(sqlite3 -readonly -separator $'\t' "$db" \
    "select status, coalesce(nullif(last_pushed_sha,''), head_sha), pr_url from runs where pr_url is not null and pr_url != '' order by coalesce(ci_ready_at, 0) desc, rowid desc limit $(fm_vt_runs_limit);" \
    2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  while IFS=$'\t' read -r st sha url; do
    [ -n "$st" ] || continue
    if [ "$(fm_vt_canon_url "$url")" = "$want" ]; then
      printf '%s\t%s\n' "$st" "$sha"
      return 0
    fi
  done <<EOF
$out
EOF
  return 1
}

# Find the newest no-mistakes run for PR URL $1. Prints "status<TAB>sha".
# Keys on `no-mistakes runs`, never on bare `axi status`.
fm_vt_run_for_pr() {  # <pr-url>
  local url listing row rc=0 timeout
  url=$(fm_vt_canon_url "$1")
  [ -n "$url" ] || return 1
  command -v no-mistakes >/dev/null 2>&1 || return 1
  timeout=$(fm_nm_remote_timeout)
  listing=$(fm_run_timed "$timeout" no-mistakes runs --limit "$(fm_vt_runs_limit)" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 124 ]; then
    return 1
  fi
  if [ "$rc" -eq 0 ] && [ -n "$listing" ]; then
    rc=0
    row=$(fm_vt_parse_runs_for_pr "$url" "$listing") || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$row"
      return 0
    fi
    if [ "$rc" -eq 2 ]; then
      fm_vt_sqlite_runs_for_pr "$url"
      return $?
    fi
    return 1
  fi
  return 1
}

# gh --jq program: one line "<head> <EMPTY|RED|PENDING|GREEN>".
# Check classification matches bin/fm-bearings-snapshot.sh's rollup cases.
fm_vt_forge_jq() {
  # jq program for gh -q: $h/$v are jq bindings, not shell.
  # shellcheck disable=SC2016
  printf '%s' '.headRefOid as $h | (.statusCheckRollup // [] | if length == 0 then "EMPTY" elif any(.[]; (.conclusion // .state // "") as $s | ($s=="FAILURE" or $s=="ERROR" or $s=="TIMED_OUT" or $s=="CANCELLED" or $s=="ACTION_REQUIRED")) then "RED" elif any(.[]; ((.status // "") != "COMPLETED") and ((.status // "") != "SKIPPED") and ((.state // "") != "SUCCESS")) then "PENDING" else "GREEN" end) as $v | "\($h) \($v)"'
}

# Read forge head and rollup for PR URL $1. Sets FM_VT_FORGE_HEAD and
# FM_VT_ROLLUP (GREEN|RED|PENDING|EMPTY). Returns 1 when unreadable.
fm_vt_read_forge() {  # <pr-url>
  local url out rc=0 timeout head verdict
  FM_VT_FORGE_HEAD=
  FM_VT_ROLLUP=
  url=$(fm_vt_canon_url "$1")
  [ -n "$url" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  timeout=$(fm_nm_remote_timeout)
  out=$(fm_run_timed "$timeout" gh pr view "$url" --json headRefOid,statusCheckRollup -q "$(fm_vt_forge_jq)" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  out=$(fm_nm_trim "$out")
  out=$(fm_nm_strip_quotes "$out")
  head=${out%% *}
  verdict=${out#* }
  verdict=$(fm_nm_trim "$verdict")
  head=$(fm_nm_strip_quotes "$head")
  fm_nm_sha_form "$head" || return 1
  case "$verdict" in
    GREEN|RED|PENDING|EMPTY) ;;
    *) return 1 ;;
  esac
  FM_VT_FORGE_HEAD=$head
  FM_VT_ROLLUP=$verdict
  return 0
}

# Independent merge-time rollup gate. Refuses red, pending, or unreadable.
# Allows GREEN and EMPTY (no-CI). Sets FM_VT_FORGE_HEAD for --match-head-commit.
fm_vt_require_merge_pin() {  # <pr-url> <task-id>
  local url=$1 id=$2
  if ! fm_vt_read_forge "$url"; then
    echo "REFUSED: no-mistakes task $id forge check rollup is unreadable" >&2
    return 1
  fi
  case "$FM_VT_ROLLUP" in
    RED)
      echo "REFUSED: no-mistakes task $id forge check rollup is red" >&2
      return 1
      ;;
    PENDING)
      echo "REFUSED: no-mistakes task $id forge check rollup is pending" >&2
      return 1
      ;;
  esac
  return 0
}

# Second proof. 0 on pass. 1 on fail; sets FM_VT_PROOF_MSG when the PR-URL
# path had a concrete reason (cancelled, mismatch, red). Leaves the message
# empty when there is no PR URL or no matching run, so the caller keeps the
# first-try wording.
fm_vt_pr_url_proof() {  # <meta-file> <task-id> [pr-url]
  local meta=$1 id=$2 url row st sha
  FM_VT_PROOF_MSG=
  url=$(fm_vt_canon_url "${3:-}")
  if [ -z "$url" ]; then
    url=$(fm_vt_meta_pr_url "$meta")
  fi
  [ -n "$url" ] || return 1
  row=$(fm_vt_run_for_pr "$url") || return 1
  st=${row%%$'\t'*}
  sha=${row#*$'\t'}
  case "$st" in
    failed|cancelled)
      FM_VT_PROOF_MSG="REFUSED: no-mistakes task $id validation run is $st"
      return 1
      ;;
  esac
  if ! fm_nm_sha_form "$sha"; then
    FM_VT_PROOF_MSG="REFUSED: no-mistakes task $id has no validation-run current state (source: none). validation truth unreadable"
    return 1
  fi
  if ! fm_vt_read_forge "$url"; then
    FM_VT_PROOF_MSG="REFUSED: no-mistakes task $id has no validation-run current state (source: none). validation truth unreadable"
    return 1
  fi
  if ! fm_nm_sha_same "$sha" "$FM_VT_FORGE_HEAD"; then
    FM_VT_PROOF_MSG="REFUSED: no-mistakes task $id validation run head does not match forge head"
    return 1
  fi
  if [ "$FM_VT_ROLLUP" != GREEN ]; then
    FM_VT_PROOF_MSG="REFUSED: no-mistakes task $id forge check rollup is ${FM_VT_ROLLUP:-unreadable}"
    return 1
  fi
  return 0
}

fm_require_validation_truth() {  # <meta-file> <task-id> [pr-url]
  local meta=$1 id=$2 mode kind line crew_state first_msg
  [ "${FM_VALIDATION_TRUTH_BYPASS:-}" = 1 ] && return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2- || true)
  case "$kind" in
    scout|secondmate) return 0 ;;
  esac
  mode=$(grep '^mode=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ "$mode" = no-mistakes ] || return 0
  crew_state=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
  if [ -x "$crew_state" ]; then
    line=$("$crew_state" "$id" 2>/dev/null || true)
    fm_validation_truth_parse "$line"
    if [ "$FM_VT_SOURCE" = run-step ] && [ "$FM_VT_STATE" = "done" ]; then
      return 0
    fi
    if [ "$FM_VT_SOURCE" = run-step ]; then
      first_msg="REFUSED: no-mistakes task $id validation run is not done (state: ${FM_VT_STATE:-unknown}, source: run-step)"
    else
      first_msg="REFUSED: no-mistakes task $id has no validation-run current state (source: ${FM_VT_SOURCE:-none}). validation truth unreadable"
    fi
  else
    first_msg="REFUSED: no-mistakes task $id has no validation-run current state (source: none). validation truth unreadable"
  fi
  if fm_vt_pr_url_proof "$meta" "$id" "${3:-}"; then
    return 0
  fi
  if [ -n "${FM_VT_PROOF_MSG:-}" ]; then
    echo "$FM_VT_PROOF_MSG" >&2
    return 1
  fi
  echo "$first_msg" >&2
  return 1
}

