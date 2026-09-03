#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
#
# --exact-sync is the second, wider authority on this script: it lands one
# pinned upstream-merge commit M on the remote default branch (origin/main by
# default) with no pull request. It is narrow in a different way: M is only the
# tip of fm/<id>, every input SHA is pinned by the caller, and the landing runs
# only after the whole gate chain in fm_exact_sync_run proves the two parents,
# the recorded stage tree, an unchanged origin base, and green push-triggered CI
# for exactly M. The push is plain and never forced, a re-run against an already
# landed M is idempotent, and the landing is recorded as a sync outcome through
# bin/fm-merge-outcome-lib.sh.
#
# Usage:
#   fm-merge-local.sh <task-id>
#   fm-merge-local.sh <task-id> --exact-sync --base <40-hex B> --upstream <40-hex U> \
#     --stage <40-hex S> --remote origin --branch main
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

USAGE='usage: fm-merge-local.sh <task-id> [--exact-sync --base <sha> --upstream <sha> --stage <sha> --remote origin --branch main]'
FM_EXACT_SYNC_CI_BRANCH=fm/merge-upstream-2

fm_exact_sync_refuse_force_argv() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force|--force-with-lease|--force=*|--force-with-lease=*)
        echo "REFUSED: exact-sync and local-only landing never take --force" >&2
        exit 1
        ;;
    esac
  done
}

# Record that an exact-sync request flag was passed, whatever value it carried,
# and refuse a repeat of the same flag.
fm_exact_sync_mark_flag() {  # <flag>
  case " $SYNC_SEEN " in
    *" $1 "*)
      echo "error: duplicate $1" >&2
      exit 2
      ;;
  esac
  SYNC_SEEN="$SYNC_SEEN $1"
}

fm_exact_sync_hex_sha() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[0-9a-f]{40}$ ]]
}

fm_exact_sync_git_token() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

fm_exact_sync_require_request() {
  fm_exact_sync_hex_sha "$SYNC_BASE" || { echo "error: --base must be a 40-hex SHA" >&2; exit 2; }
  fm_exact_sync_hex_sha "$SYNC_UPSTREAM" || { echo "error: --upstream must be a 40-hex SHA" >&2; exit 2; }
  fm_exact_sync_hex_sha "$SYNC_STAGE" || { echo "error: --stage must be a 40-hex SHA, not a branch name" >&2; exit 2; }
  fm_exact_sync_git_token "$SYNC_REMOTE" || { echo "error: --remote must be a simple remote name" >&2; exit 2; }
  fm_exact_sync_git_token "$SYNC_BRANCH" || { echo "error: --branch must be a simple branch name" >&2; exit 2; }
}

fm_exact_sync_require_merge_parents() {
  local p1 p2
  if ! git -C "$PROJ" rev-parse --verify --quiet "$SYNC_M^1" >/dev/null \
    || ! git -C "$PROJ" rev-parse --verify --quiet "$SYNC_M^2" >/dev/null \
    || git -C "$PROJ" rev-parse --verify --quiet "$SYNC_M^3" >/dev/null; then
    echo "REFUSED: $TASK_BRANCH tip $SYNC_M does not have exactly two parents" >&2
    return 1
  fi
  p1=$(git -C "$PROJ" rev-parse "$SYNC_M^1")
  p2=$(git -C "$PROJ" rev-parse "$SYNC_M^2")
  [ "$p1" = "$SYNC_BASE" ] && [ "$p2" = "$SYNC_UPSTREAM" ] || {
    echo "REFUSED: $SYNC_M parents are $p1 $p2, not --base $SYNC_BASE and --upstream $SYNC_UPSTREAM" >&2
    return 1
  }
}

fm_exact_sync_require_tree_match() {
  git -C "$PROJ" rev-parse --verify --quiet "$SYNC_STAGE^{commit}" >/dev/null || {
    echo "REFUSED: --stage $SYNC_STAGE is not a commit in $PROJ" >&2
    return 1
  }
  [ "$(git -C "$PROJ" rev-parse "$SYNC_M^{tree}")" = "$(git -C "$PROJ" rev-parse "$SYNC_STAGE^{tree}")" ] || {
    echo "REFUSED: tree($SYNC_M) does not equal tree(--stage $SYNC_STAGE)" >&2
    return 1
  }
  git -C "$PROJ" diff --exit-code --quiet "$SYNC_STAGE" "$SYNC_M" || {
    echo "REFUSED: git diff --stage $SYNC_STAGE $SYNC_M is not empty" >&2
    return 1
  }
}

fm_exact_sync_require_no_conflict_markers() {
  local rc=0
  git -C "$PROJ" grep -I -E -e '^<<<<<<< ' -e '^\|\|\|\|\|\|\| ' -e '^={7}$' \
    -e '^>>>>>>> ' "$SYNC_M" -- >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "REFUSED: tree($SYNC_M) still contains conflict markers" >&2
    return 1
  fi
  if [ "$rc" -ge 2 ]; then
    echo "REFUSED: exact-sync could not search tree($SYNC_M) for conflict markers" >&2
    return 1
  fi
}

fm_exact_sync_require_no_pr_base_branch() {
  local yaml
  git -C "$PROJ" cat-file -e "$SYNC_M:.no-mistakes.yaml" 2>/dev/null || return 0
  yaml=$(git -C "$PROJ" show "$SYNC_M:.no-mistakes.yaml")
  printf '%s\n' "$yaml" | python3 -c '
import sys
in_pr = False
pr_indent = None
for line in sys.stdin:
    raw = line.split("#", 1)[0].rstrip()
    if not raw.strip():
        continue
    indent = len(raw) - len(raw.lstrip())
    key = raw.strip()
    if in_pr and indent <= pr_indent:
        in_pr = False
    if key.startswith("pr.base_branch:"):
        sys.exit(1)
    if key == "pr:" or key.startswith("pr:"):
        in_pr = True
        pr_indent = indent
        rest = key[3:].strip()
        if "base_branch" in rest:
            sys.exit(1)
        continue
    if in_pr and key.startswith("base_branch:"):
        sys.exit(1)
sys.exit(0)
' || {
    echo "REFUSED: tree($SYNC_M) .no-mistakes.yaml still has pr.base_branch" >&2
    return 1
  }
}

fm_exact_sync_require_ci_push_branch() {
  git -C "$PROJ" cat-file -e "$SYNC_M:.github/workflows/ci.yml" 2>/dev/null || {
    echo "REFUSED: tree($SYNC_M) has no .github/workflows/ci.yml" >&2
    return 1
  }
  git -C "$PROJ" show "$SYNC_M:.github/workflows/ci.yml" | python3 -c '
import re, sys
lines = [line.split("#", 1)[0].rstrip() for line in sys.stdin]
in_on = False
on_indent = 0
on_lines = []
for raw in lines:
    if not in_on:
        if raw == "on:":
            in_on = True
            on_indent = 0
        continue
    if not raw.strip():
        continue
    indent = len(raw) - len(raw.lstrip())
    if indent <= on_indent:
        break
    on_lines.append((indent, raw))
push = []
in_push = False
for indent, raw in on_lines:
    if not in_push:
        if indent == 2 and raw.strip() == "push:":
            in_push = True
        continue
    if indent <= 2:
        break
    push.append(raw)
blob = "\n".join(push)
if "branches" not in blob:
    sys.exit(1)
if not re.search(r"(^|[,\[][\t ]*)fm/merge-upstream-2([,\]]|$|[\t ])", blob):
    sys.exit(1)
sys.exit(0)
' || {
    echo "REFUSED: tree($SYNC_M) ci.yml does not list fm/merge-upstream-2 under push" >&2
    return 1
  }
}

fm_exact_sync_job_names() {
  git -C "$PROJ" show "$1:.github/workflows/ci.yml" | python3 -c '
import sys
in_jobs = False
jobs = []
current = None
for line in sys.stdin:
    raw = line.split("#", 1)[0].rstrip()
    if not in_jobs:
        if raw == "jobs:":
            in_jobs = True
        continue
    if not raw.strip():
        continue
    indent = len(raw) - len(raw.lstrip())
    if indent == 0:
        break
    if indent == 2 and raw.endswith(":"):
        key = raw.strip()[:-1]
        if key and " " not in key:
            current = {"key": key, "name": None}
            jobs.append(current)
        continue
    if current is None:
        continue
    stripped = raw.strip()
    if indent == 4 and stripped.startswith("name:"):
        name = stripped[5:].strip()
        quotes = chr(34) + chr(39)
        if len(name) >= 2 and name[0] == name[-1] and name[0] in quotes:
            name = name[1:-1]
        if name:
            current["name"] = name
names = [job["name"] or job["key"] for job in jobs]
if not names:
    sys.exit(1)
print("\n".join(names))
'
}

fm_exact_sync_gh() {
  (cd "$PROJ" && gh "$@")
}

fm_exact_sync_require_ci_truth() {
  local list_json view_json run_id expected_names rc
  command -v gh >/dev/null 2>&1 || {
    echo "REFUSED: exact-sync needs gh on PATH to read push-triggered CI for $SYNC_M" >&2
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "REFUSED: exact-sync needs python3 to read push-triggered CI for $SYNC_M" >&2
    return 1
  }
  list_json=$(fm_exact_sync_gh run list \
    --commit "$SYNC_M" \
    --branch "$FM_EXACT_SYNC_CI_BRANCH" \
    --event push \
    --status completed \
    --json databaseId,headSha,headBranch,event,conclusion,status) || {
    echo "REFUSED: exact-sync could not read push-triggered CI for $SYNC_M" >&2
    return 1
  }
  run_id=$(printf '%s\n' "$list_json" | python3 -c '
import json, sys
sha, branch = sys.argv[1], sys.argv[2]
runs = json.load(sys.stdin)
if not isinstance(runs, list):
    sys.exit(2)
matched = []
for run in runs:
    if (run.get("headSha") == sha and run.get("headBranch") == branch
        and run.get("event") == "push"):
        matched.append(run)
if not matched:
    sys.exit(3)
success = [run for run in matched if run.get("conclusion") == "success"]
if not success:
    conclusion = matched[0].get("conclusion") or "missing"
    print(conclusion)
    sys.exit(4)
print(success[0]["databaseId"])
' "$SYNC_M" "$FM_EXACT_SYNC_CI_BRANCH") || {
    rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "REFUSED: exact-sync found no push-triggered CI run for $SYNC_M on $FM_EXACT_SYNC_CI_BRANCH" >&2
    elif [ "$rc" -eq 4 ]; then
      echo "REFUSED: exact-sync push-triggered CI for $SYNC_M concluded ${run_id:-missing}, not success" >&2
    else
      echo "REFUSED: exact-sync could not parse push-triggered CI for $SYNC_M" >&2
    fi
    return 1
  }
  view_json=$(fm_exact_sync_gh run view "$run_id" \
    --json jobs,conclusion,headSha,headBranch,event) || {
    echo "REFUSED: exact-sync could not read CI jobs for run $run_id" >&2
    return 1
  }
  expected_names=$(fm_exact_sync_job_names "$SYNC_M") || {
    echo "REFUSED: exact-sync could not read job names from tree($SYNC_M) ci.yml" >&2
    return 1
  }
  printf '%s\n' "$view_json" | python3 -c '
import json, sys
sha, branch, event = sys.argv[1], sys.argv[2], sys.argv[3]
expected = [line for line in sys.argv[4].split("\n") if line]
data = json.load(sys.stdin)
if (data.get("headSha") != sha or data.get("headBranch") != branch
    or data.get("event") != event or data.get("conclusion") != "success"):
    sys.exit(4)
jobs = [(job.get("name"), job.get("conclusion")) for job in (data.get("jobs") or [])]
success = set(name for name, conclusion in jobs if conclusion == "success")
marker = "${{"
for name in expected:
    if marker in name:
        prefix = name.split(marker, 1)[0]
        matched = [(n, c) for n, c in jobs if n and n.startswith(prefix)]
        if not matched or any(c != "success" for _, c in matched):
            sys.exit(5)
    elif name not in success:
        sys.exit(5)
' "$SYNC_M" "$FM_EXACT_SYNC_CI_BRANCH" push "$expected_names" || {
    echo "REFUSED: exact-sync CI run $run_id is missing successful job set from tree(M) ci.yml" >&2
    return 1
  }
}

fm_exact_sync_fetch() {
  git -C "$PROJ" fetch --quiet "$SYNC_REMOTE" "$SYNC_BRANCH" || {
    echo "REFUSED: exact-sync could not fetch $SYNC_REMOTE/$SYNC_BRANCH" >&2
    return 1
  }
  SYNC_ORIGIN_TIP=$(git -C "$PROJ" rev-parse --verify FETCH_HEAD)
}

fm_exact_sync_require_origin_base_or_landed() {
  SYNC_SKIP_PUSH=0
  if [ "$SYNC_ORIGIN_TIP" = "$SYNC_M" ]; then
    SYNC_SKIP_PUSH=1
    return 0
  fi
  [ "$SYNC_ORIGIN_TIP" = "$SYNC_BASE" ] || {
    echo "REFUSED: $SYNC_REMOTE/$SYNC_BRANCH is $SYNC_ORIGIN_TIP, not the pinned --base $SYNC_BASE" >&2
    return 1
  }
}

fm_exact_sync_land() {
  if [ "$SYNC_SKIP_PUSH" = 1 ]; then
    return 0
  fi
  git -C "$PROJ" push --porcelain "$SYNC_REMOTE" "$SYNC_M:refs/heads/$SYNC_BRANCH" || {
    echo "REFUSED: exact-sync push of $SYNC_M to $SYNC_REMOTE/$SYNC_BRANCH failed" >&2
    return 1
  }
}

fm_exact_sync_confirm_origin() {
  local p1 p2
  fm_exact_sync_fetch || return 1
  [ "$SYNC_ORIGIN_TIP" = "$SYNC_M" ] || {
    echo "REFUSED: after push, $SYNC_REMOTE/$SYNC_BRANCH is $SYNC_ORIGIN_TIP, not $SYNC_M" >&2
    return 1
  }
  p1=$(git -C "$PROJ" rev-parse "$SYNC_ORIGIN_TIP^1")
  p2=$(git -C "$PROJ" rev-parse "$SYNC_ORIGIN_TIP^2")
  [ "$p1" = "$SYNC_BASE" ] && [ "$p2" = "$SYNC_UPSTREAM" ] || {
    echo "REFUSED: after push, $SYNC_ORIGIN_TIP parents are $p1 $p2" >&2
    return 1
  }
}

fm_exact_sync_record_outcome() {
  local outcome_rc=0
  fm_merge_outcome_report_sync "$FM_HOME" "$STATE" "$ID" \
    "$SYNC_REMOTE" "$SYNC_BRANCH" "$SYNC_M" self || outcome_rc=$?
  [ "$outcome_rc" -eq 0 ] || {
    echo "error: exact-sync landed $SYNC_M but the sync outcome could not be recorded (rc=$outcome_rc)" >&2
    exit 1
  }
}

fm_exact_sync_run() {
  local already=0
  # shellcheck source=bin/fm-merge-outcome-lib.sh
  . "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
  fm_exact_sync_require_request
  SYNC_M=$(git -C "$PROJ" rev-parse --verify "$TASK_BRANCH^{commit}")
  fm_exact_sync_require_merge_parents || exit 1
  fm_exact_sync_require_tree_match || exit 1
  fm_exact_sync_require_no_conflict_markers || exit 1
  fm_exact_sync_require_no_pr_base_branch || exit 1
  fm_exact_sync_require_ci_push_branch || exit 1
  fm_exact_sync_fetch || exit 1
  fm_exact_sync_require_origin_base_or_landed || exit 1
  already=$SYNC_SKIP_PUSH
  fm_exact_sync_require_ci_truth || exit 1
  fm_exact_sync_land || exit 1
  fm_exact_sync_confirm_origin || exit 1
  fm_exact_sync_record_outcome
  if [ "$already" = 1 ]; then
    echo "exact-sync already on $SYNC_REMOTE/$SYNC_BRANCH at $SYNC_M"
  else
    echo "exact-sync landed $SYNC_M on $SYNC_REMOTE/$SYNC_BRANCH"
  fi
}

fm_exact_sync_refuse_force_argv "$@"

if [ "$#" -lt 1 ]; then
  echo "$USAGE" >&2
  exit 2
fi
ID=$1
shift

EXACT_SYNC=0
SYNC_BASE=
SYNC_UPSTREAM=
SYNC_STAGE=
SYNC_REMOTE=origin
SYNC_BRANCH=main
SYNC_SEEN=
SYNC_M=
SYNC_ORIGIN_TIP=
SYNC_SKIP_PUSH=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exact-sync) EXACT_SYNC=1 ;;
    --base)
      [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      fm_exact_sync_mark_flag --base
      SYNC_BASE=$2
      shift
      ;;
    --upstream)
      [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      fm_exact_sync_mark_flag --upstream
      SYNC_UPSTREAM=$2
      shift
      ;;
    --stage)
      [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      fm_exact_sync_mark_flag --stage
      SYNC_STAGE=$2
      shift
      ;;
    --remote)
      [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      fm_exact_sync_mark_flag --remote
      SYNC_REMOTE=$2
      shift
      ;;
    --branch)
      [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      fm_exact_sync_mark_flag --branch
      SYNC_BRANCH=$2
      shift
      ;;
    *)
      echo "$USAGE" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$EXACT_SYNC" = 0 ] && [ -n "$SYNC_SEEN" ]; then
  echo "error: --base/--upstream/--stage/--remote/--branch require --exact-sync" >&2
  exit 2
fi

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

TASK_BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$TASK_BRANCH" >/dev/null || { echo "error: branch $TASK_BRANCH does not exist in $PROJ" >&2; exit 1; }

if [ "$EXACT_SYNC" = 1 ]; then
  fm_exact_sync_run
  exit 0
fi

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of TASK_BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$TASK_BRANCH"; then
  echo "REFUSED: $TASK_BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $TASK_BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$TASK_BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $TASK_BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
