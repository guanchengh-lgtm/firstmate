#!/usr/bin/env bash
# PreToolUse guard against primary-session file-tool writes into project clones.
#
# AGENTS.md hard rule 1 is "never write to a project": firstmate reads projects
# and crewmates change them. That rule is self-attested, and the observed
# failure mode is unreflective drift - the primary edits a clone directly
# instead of writing a brief and spawning a crewmate - not an adversarial agent.
# This guard converts the file-tool half of that rule from self-attested to
# refused at the tool boundary.
#
# The predicate is an UNCONDITIONAL deny of primary-session file-modification
# tool calls whose resolved target lies under the active home's projects/
# directory or under any live task worktree recorded in state/*.meta. Durable
# task state widens the deny set; it never allows. An open task on a project is
# NOT a reason to let the primary write into that clone: bin/fm-spawn.sh refuses
# a worktree that equals the clone, so a crewmate's writes never happen there,
# and treating a live task as an allowance would disarm this guard for exactly
# as long as the fleet is busy.
#
# The single exception is AGENTS.md hard rule 1's concrete captain-approved
# project operation, which that rule performs "with its own file tools". It is
# carried by a short-TTL, path-scoped, single-use grant written by
# bin/fm-project-write-grant.sh, which this script consumes and expires. That
# makes the exception deliberate and audited rather than unforgeable; see
# docs/project-write-guard.md for why that trade is the right one here.
#
# See docs/project-write-guard.md for the complete contract, the honest
# out-of-scope list (Bash-mediated writes, data/, the firstmate repo's own
# tracked surface, MCP write tools, other homes' trees), and the validation
# record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-project-write-pretool-check.sh
#   bin/fm-project-write-pretool-check.sh --tool '<name>' --path '<path>' ...
#
# Stdin mode extracts .tool_name for Claude and Codex or .toolName for Grok,
# plus every known path field of .tool_input / .toolInput.
# CLI mode is for adapters that already hold the tool name and target path
# (OpenCode, Pi). --path may be repeated.
#
# Exit/output contract (identical shape to bin/fm-subagent-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   ESCAPE - a valid grant covering the target path, consumed on use.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or a
#               target path that cannot be resolved at all.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

# Lowercase substrings that mark a tool name as file-MODIFYING. A tool whose
# name carries one of these and whose payload names a path under a protected
# root is refused. The list is shape-based rather than a fixed tool inventory,
# for the same reason the delegation guard classifies by shape: a future
# write tool that no list knows about yet must still be caught.
WRITE_STEMS='write edit patch notebook create replace insert append delete remove rename move copy'

# Exact lowercase tool names that carry a write stem but only READ. Firstmate
# reads project clones constantly - that is the half of hard rule 1 this guard
# must never touch - so a read tool whose name happens to contain "notebook"
# must stay allowed. Exact-name, never substring, so the exclusion cannot widen
# by accident: NotebookEdit stays denied.
READ_ONLY_TOOLS='notebookread readnotebook'

TOOL=""
TOOL_SET=0
CLAUDE_MODE=0
PATHS=()

usage() {
  cat <<'EOF'
Usage: fm-project-write-pretool-check.sh [--tool <name>] [--path <path>]... [--claude]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name plus tool_input path fields, or Grok toolName plus toolInput).
Denies a file-MODIFYING tool call in a genuine primary home when its target
resolves under the active home's projects/ directory or under any live task
worktree recorded in state/*.meta.
Reads are never denied, and the guard is a silent no-op in a crewmate/scout task
worktree or any non-firstmate repo, where editing project files is the job.
Exits 0 to allow and 2 to deny, naming bin/fm-brief.sh and bin/fm-spawn.sh.
A captain-approved concrete project operation is carried by a single-use grant
from bin/fm-project-write-grant.sh, which this check consumes.
Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --path)
      [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }
      PATHS+=("$2")
      shift 2
      ;;
    --path=*)
      PATHS+=("${1#--path=}")
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
fi

[ -n "$TOOL" ] || exit 0

# An MCP tool belongs to an external integration whose payload shape this script
# cannot know, so it is never classified. That is a documented false negative:
# an MCP filesystem server could write into a clone and this guard would not see
# it (docs/project-write-guard.md "Out of scope").
case "$TOOL" in
  mcp__*) exit 0 ;;
esac

LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

for allowed in $READ_ONLY_TOOLS; do
  [ "$NORMALIZED" != "$allowed" ] || exit 0
done

MATCHED_STEM=""
for stem in $WRITE_STEMS; do
  case "$NORMALIZED" in
    *"$stem"*) MATCHED_STEM=$stem; break ;;
  esac
done
[ -n "$MATCHED_STEM" ] || exit 0

# Path fields are collected only after the tool is known to be write-shaped, so
# a read tool carrying a path never reaches this at all.
if [ "$TOOL_SET" -eq 0 ]; then
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    PATHS+=("$candidate")
  done < <(printf '%s' "${PAYLOAD:-}" | jq -r '
      [(.tool_input // .toolInput // {})
       | (.file_path?, .notebook_path?, .path?, .filePath?, .notebookPath?,
          .target_file?, .file?, .old_path?, .new_path?)]
      | map(select(type == "string" and length > 0))[]' 2>/dev/null)
fi

[ "${#PATHS[@]}" -gt 0 ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
ACTIVE_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$ACTIVE_HOME/state}

# Scope to a genuine primary home, exactly as the delegation guard, the
# session-start nudge, and the turn-end guard do, so the primary-scoped hooks
# cannot drift apart. A crewmate's linked task worktree is out of scope: a
# crewmate editing project files there is the entire point of dispatch. A marked
# secondmate home is in scope, because a secondmate primary owns its own fleet
# and must not write its own projects/ either. Any failure to confirm the home
# is inert, never a block.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# shellcheck source=bin/fm-project-write-lib.sh
. "$SCRIPT_DIR/fm-project-write-lib.sh"

PROTECTED=()
while IFS= read -r root; do
  [ -n "$root" ] || continue
  PROTECTED+=("$root")
done < <(fm_project_write_protected_roots "$ACTIVE_HOME" "$STATE")

[ "${#PROTECTED[@]}" -gt 0 ] || exit 0

TAB=$(printf '\t')
TARGET=""
HIT_ROOT=""
HIT_KIND=""
for candidate in ${PATHS[@]+"${PATHS[@]}"}; do
  resolved=$(fm_project_write_resolve "$candidate") || continue
  [ -n "$resolved" ] || continue
  for entry in ${PROTECTED[@]+"${PROTECTED[@]}"}; do
    kind=${entry%%"$TAB"*}
    root=${entry#*"$TAB"}
    if fm_project_write_path_under "$resolved" "$root"; then
      TARGET=$resolved
      HIT_ROOT=$root
      HIT_KIND=$kind
      break 2
    fi
  done
done

[ -n "$TARGET" ] || exit 0

# The hard-rule-1 exception. A valid grant is consumed here: it covers exactly
# one later call, so an approved concrete operation proceeds and the guard
# re-arms immediately afterwards.
GRANT_NOTE=""
GRANT_RC=0
fm_project_write_consume_grant "$STATE" "$TARGET" || GRANT_RC=$?
if [ "$GRANT_RC" -eq 0 ]; then
  exit 0
fi
case "$GRANT_RC" in
  2) GRANT_NOTE=' A grant for this path existed but had already expired.' ;;
  3) GRANT_NOTE=' An active grant exists but covers a different path.' ;;
esac

if [ "$HIT_KIND" = projects ]; then
  WHAT="a project clone this home only reads"
  ROUTE="write the instructions with bin/fm-brief.sh and dispatch a worker with bin/fm-spawn.sh"
else
  WHAT="a live task worktree that belongs to the worker running there"
  ROUTE="steer that worker with bin/fm-send.sh, or dispatch new work with bin/fm-brief.sh then bin/fm-spawn.sh"
fi

REASON="[project-write] $TARGET is inside $WHAT, and firstmate never writes to a project with its own file tools: $ROUTE (blocked tool: $TOOL, write-shaped on \"$MATCHED_STEM\"; protected root: $HIT_ROOT).$GRANT_NOTE For a concrete project operation the captain approved in the moment, record it with bin/fm-project-write-grant.sh '$TARGET' --reason '<the captain's exact instruction>' and retry; that grant covers one call and then expires."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
