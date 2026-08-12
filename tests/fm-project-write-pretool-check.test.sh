#!/usr/bin/env bash
# Behavior tests for the project-write guard: the tracked hook registration, the
# PreToolUse classifier and path predicate, and the hard-rule-1 grant lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-project-write-pretool-check.sh"
GRANT_CMD="$ROOT/bin/fm-project-write-grant.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-write-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
PROJECTS="$PRIMARY/projects"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE" "$PROJECTS/alpha" "$PRIMARY/data"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
printf 'clone\n' > "$PROJECTS/alpha/README.md"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" config user.name fixture
git -C "$PRIMARY" config user.email fixture@example.test
git -C "$PRIMARY" add AGENTS.md
git -C "$PRIMARY" commit -qm fixture

# Claude's own file-modification tools, plus the shapes a future harness release
# could plausibly ship. None of the hypothetical names is on any list, which is
# the case a fixed tool inventory is fail-open against.
WRITE_TOOLS='Write Edit NotebookEdit MultiEdit ApplyPatch CreateFile WriteFile
             EditFile PatchFile ReplaceInFile InsertLines AppendToFile DeleteFile
             RemoveFile RenameFile MoveFile CopyFile'

# Tools that must keep working against a clone: firstmate reads projects
# constantly, and that half of hard rule 1 must be untouched.
READ_TOOLS='Read Grep Glob NotebookRead ReadNotebook ListFiles Search View'

run_check() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" "$@" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

run_grant() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$GRANT_CMD" "$@" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 rc=0
  shift
  run_check "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 rc=0
  shift
  run_check "$@" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e '.systemMessage | startswith("[project-write]")' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny lost its reason code: $(jq -r '.systemMessage' "$ERR")"
}

# ---------------------------------------------------------------------------
# Tracked hook registration.
# ---------------------------------------------------------------------------

test_tracked_claude_registration() {
  local settings="$ROOT/.claude/settings.json"
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  jq -e '
    .hooks.PreToolUse
    | map(select(.matcher == ".*"))
    | map(.hooks[].command)
    | map(select(contains("fm-project-write-pretool-check.sh")))
    | length == 1 and (.[0] | contains("--claude"))' "$settings" >/dev/null 2>&1 \
    || fail "the guard must be registered exactly once under the match-all PreToolUse matcher with --claude"
  # A stem-enumerating matcher would never deliver a future write-tool name to
  # the script, which is the fail-open-by-enumeration problem the classifier
  # exists to solve.
  jq -e '
    .hooks.PreToolUse
    | map(select(.hooks[].command | contains("fm-project-write-pretool-check.sh")))
    | all(.matcher == ".*")' "$settings" >/dev/null 2>&1 \
    || fail "the guard must never be registered behind an enumerated tool matcher"
  pass "the tracked Claude registration is match-all and passes --claude"
}

# ---------------------------------------------------------------------------
# Tool-shape classification.
# ---------------------------------------------------------------------------

test_write_tools_into_a_clone_are_denied() {
  local tool
  for tool in $WRITE_TOOLS; do
    expect_deny "write tool $tool into a clone" --claude --tool "$tool" --path "$PROJECTS/alpha/x.txt"
  done
  pass "every current and hypothetical write-shaped tool is denied inside a project clone"
}

test_read_tools_are_never_denied() {
  local tool
  for tool in $READ_TOOLS; do
    expect_allow "read tool $tool" --claude --tool "$tool" --path "$PROJECTS/alpha/README.md"
  done
  pass "reading a project clone stays allowed, including read tools whose names carry a write stem"
}

test_read_only_exclusion_is_exact_name() {
  # The exclusion releases NotebookRead, never anything that merely contains it.
  local tool
  for tool in NotebookEdit NotebookReadWrite NotebookReadAndPatch WriteNotebookRead; do
    expect_deny "read-only near miss $tool" --claude --tool "$tool" --path "$PROJECTS/alpha/n.ipynb"
  done
  pass "the read-only exclusion releases exact names only and never widens by substring"
}

test_writes_outside_protected_roots_are_allowed() {
  # data/, state/, config/ and the firstmate repo's own tracked surface stay
  # writable: those are legitimate primary writes, and the guard must not be a
  # general-purpose file lock.
  expect_allow "home data write" --claude --tool Write --path "$PRIMARY/data/backlog.md"
  expect_allow "home state write" --claude --tool Write --path "$STATE/notes"
  expect_allow "tracked surface write" --claude --tool Edit --path "$PRIMARY/AGENTS.md"
  expect_allow "path outside the home" --claude --tool Write --path "$TMP_ROOT/scratch.txt"
  pass "writes outside the protected roots are untouched"
}

test_write_tool_without_a_path_is_allowed() {
  # A write-shaped name with no path field cannot be resolved against a
  # protected root, so it is not this guard's business.
  expect_allow "write-shaped tool with no path" --claude --tool CreateFile
  pass "a write-shaped tool call carrying no path is allowed"
}

test_mcp_tools_are_never_classified() {
  local tool
  for tool in mcp__fs__write_file mcp__acme__edit_document; do
    expect_allow "MCP tool $tool" --claude --tool "$tool" --path "$PROJECTS/alpha/x.txt"
  done
  pass "MCP tool names are never classified, the documented residual gap"
}

# ---------------------------------------------------------------------------
# Path resolution.
# ---------------------------------------------------------------------------

test_relative_and_traversal_paths_resolve_before_matching() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  ( cd "$PROJECTS/alpha" \
    && env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude --tool Write --path 'sub/../x.txt' > "$OUT" 2> "$ERR" ) || rc=$?
  [ "$rc" -eq 2 ] || fail "a relative path inside a clone must deny, got exit $rc"

  expect_deny "traversal back into a clone" --claude --tool Write \
    --path "$PROJECTS/alpha/../alpha/x.txt"
  expect_allow "traversal out of the clone tree" --claude --tool Write \
    --path "$PROJECTS/../data/x.txt"
  pass "relative paths and .. traversal are resolved before the protected-root test"
}

test_symlink_into_a_clone_is_denied() {
  ln -sfn "$PROJECTS/alpha" "$TMP_ROOT/alpha-link"
  expect_deny "symlink into a clone" --claude --tool Write --path "$TMP_ROOT/alpha-link/x.txt"
  pass "a symlink pointing into a clone resolves to the clone and is denied"
}

test_nonexistent_target_still_matches() {
  expect_deny "unborn file deep inside a clone" --claude --tool Write \
    --path "$PROJECTS/alpha/does/not/exist/yet.txt"
  pass "a target that does not exist yet still resolves against the protected root"
}

# ---------------------------------------------------------------------------
# Live task worktrees widen the deny set.
# ---------------------------------------------------------------------------

test_recorded_worktree_is_protected() {
  local wt="$TMP_ROOT/task-worktree"
  mkdir -p "$wt/src"
  fm_write_meta "$STATE/fm-task.meta" "window=firstmate:fm-task" "worktree=$wt" "project=alpha"
  expect_deny "edit inside a live task worktree" --claude --tool Edit --path "$wt/src/main.rs"
  rm -f "$STATE/fm-task.meta"
  expect_allow "same path once the task record is gone" --claude --tool Edit --path "$wt/src/main.rs"
  pass "a live task worktree is protected from the primary and stops being protected when its record goes"
}

test_secondmate_home_worktree_is_protected() {
  local home="$TMP_ROOT/secondmate-home"
  mkdir -p "$home/data"
  fm_write_secondmate_meta "$STATE/fm-second.meta" "$home"
  expect_deny "edit inside a secondmate home" --claude --tool Write --path "$home/data/backlog.md"
  rm -f "$STATE/fm-second.meta"
  pass "a secondmate home recorded as a worktree is protected from the main primary"
}

test_recorded_worktree_equal_to_the_home_is_ignored() {
  # A record pointing at the home itself would otherwise lock firstmate out of
  # its own data/ and state/, which is far worse than the case it would catch.
  fm_write_meta "$STATE/fm-self.meta" "window=firstmate:fm-self" "worktree=$PRIMARY"
  expect_allow "home write with a self-referencing record" --claude --tool Write --path "$PRIMARY/data/backlog.md"
  expect_deny "the clone tree is still protected" --claude --tool Write --path "$PROJECTS/alpha/x.txt"
  rm -f "$STATE/fm-self.meta"
  pass "a worktree record pointing at the home itself never locks the home out of its own files"
}

# ---------------------------------------------------------------------------
# Scope.
# ---------------------------------------------------------------------------

test_task_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state" "$child/projects/alpha"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"; : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool Write --path "$child/projects/alpha/x.txt" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "task-worktree no-op wrote output"

  mkdir -p "$plain/bin" "$plain/projects/alpha"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool Write --path "$plain/projects/alpha/x.txt" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "the guard is inert in a crewmate task worktree and in a non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state" "$second/projects/beta"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool Write --path "$second/projects/beta/x.txt" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home owns a fleet and must be guarded, got exit $rc"
  pass "a marked secondmate home protects its own clone tree even though it is a linked worktree"
}

# ---------------------------------------------------------------------------
# Harness transports and output shapes.
# ---------------------------------------------------------------------------

test_stdin_transports_and_output_shapes() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$PROJECTS/alpha/x.txt" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$PROJECTS/alpha/n.ipynb" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "the notebook path field must be read, got exit $rc"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"toolName":"Write","toolInput":{"file_path":"%s"}}' "$PROJECTS/alpha/x.txt" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[project-write]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$PROJECTS/alpha/README.md" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "reading a clone through stdin must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "stdin allow wrote output"
  pass "Claude, Codex, Grok stdin and the OpenCode/Pi CLI form all classify correctly with the right stream shapes"
}

test_malformed_transport_fails_open() {
  local rc payload
  for payload in '{not-json' '' '{}' '{"tool_name":null}' '{"tool_name":"Write"}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, tool-name-less, and path-less payloads fail open rather than blocking every tool call"
}

test_missing_jq_stdin_transport_fails_open() {
  local fakebin="$TMP_ROOT/no-jq-bin" bash_bin cat_bin rc=0
  bash_bin=$(command -v bash) || fail "test needs bash to simulate the hook shebang"
  cat_bin=$(command -v cat) || fail "test needs cat to feed stdin without jq"
  mkdir -p "$fakebin"
  ln -sf "$bash_bin" "$fakebin/bash"
  ln -sf "$cat_bin" "$fakebin/cat"
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$PROJECTS/alpha/x.txt" \
    | env PATH="$fakebin" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq transport must fail open, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "missing jq fail-open path wrote output"
  pass "missing jq for stdin transport fails open rather than denying every tool call"
}

# ---------------------------------------------------------------------------
# Hard-rule-1 grant lifecycle.
# ---------------------------------------------------------------------------

test_grant_refuses_records_that_would_protect_nothing() {
  local rc=0
  run_grant "$PRIMARY/data/x.md" --reason 'captain: fix this file' || rc=$?
  [ "$rc" -eq 2 ] || fail "a grant outside every protected root must be refused, got exit $rc"
  assert_contains "$(cat "$ERR")" 'not under a protected root' 'unprotected-path refusal must say why'

  rc=0
  run_grant "$PROJECTS" --reason 'captain: fix the clone tree' || rc=$?
  [ "$rc" -eq 2 ] || fail "a grant for a whole protected root must be refused, got exit $rc"

  rc=0
  run_grant "$PROJECTS/alpha/x.txt" || rc=$?
  [ "$rc" -eq 2 ] || fail "a grant with no reason must be refused, got exit $rc"

  rc=0
  run_grant "$PROJECTS/alpha/x.txt" --reason 'ok' || rc=$?
  [ "$rc" -eq 2 ] || fail "a grant whose reason cannot be a quoted instruction must be refused, got exit $rc"

  rc=0
  run_grant "$PROJECTS/alpha/x.txt" --reason 'captain: fix the typo' --ttl 99999 || rc=$?
  [ "$rc" -eq 2 ] || fail "a grant beyond the maximum TTL must be refused, got exit $rc"

  assert_absent "$STATE/.project-write-grant" 'a refused grant must leave no record'
  pass "the grant script refuses blanket, unexplained, and long-lived records"
}

test_grant_allows_exactly_one_matching_write() {
  local rc=0
  run_grant "$PROJECTS/alpha/x.txt" --reason 'captain: fix the typo in the alpha README' \
    || fail "a concrete grant must succeed: $(cat "$ERR")"
  assert_present "$STATE/.project-write-grant" 'a successful grant must leave a record'

  expect_deny "another path while a grant is active" --claude --tool Write --path "$PROJECTS/alpha/other.txt"
  jq -e '.systemMessage | contains("covers a different path")' "$ERR" >/dev/null 2>&1 \
    || fail "a path-mismatched grant must be explained in the deny: $(jq -r '.systemMessage' "$ERR")"
  assert_present "$STATE/.project-write-grant" 'a mismatched call must not consume the grant'

  expect_allow "the granted path" --claude --tool Write --path "$PROJECTS/alpha/x.txt"
  assert_absent "$STATE/.project-write-grant" 'a consumed grant must be gone'

  expect_deny "the same path a second time" --claude --tool Write --path "$PROJECTS/alpha/x.txt"
  assert_grep 'issued' "$STATE/.project-write-grant.log" 'the audit log must record the issue'
  assert_grep 'consumed' "$STATE/.project-write-grant.log" 'the audit log must record the consumption'
  assert_grep 'captain: fix the typo in the alpha README' "$STATE/.project-write-grant.log" \
    'the audit log must carry the quoted captain instruction'
  pass "a grant covers exactly one matching write, is consumed by it, and is audited"
}

test_grant_covers_a_directory_scope_but_not_its_siblings() {
  run_grant "$PROJECTS/alpha/docs" --reason 'captain: rewrite the alpha docs directory' \
    || fail "a directory-scoped grant must succeed: $(cat "$ERR")"
  expect_deny "a sibling of the granted directory" --claude --tool Write --path "$PROJECTS/alpha/src/x.txt"
  expect_allow "a file inside the granted directory" --claude --tool Write --path "$PROJECTS/alpha/docs/x.md"
  pass "a grant scopes to its path prefix and never leaks to a sibling"
}

test_expired_grant_is_refused_and_cleared() {
  run_grant "$PROJECTS/alpha/x.txt" --reason 'captain: fix the typo now' --ttl 1 \
    || fail "a short-TTL grant must succeed: $(cat "$ERR")"
  sleep 2
  expect_deny "an expired grant" --claude --tool Write --path "$PROJECTS/alpha/x.txt"
  jq -e '.systemMessage | contains("already expired")' "$ERR" >/dev/null 2>&1 \
    || fail "an expired grant must be explained in the deny: $(jq -r '.systemMessage' "$ERR")"
  assert_absent "$STATE/.project-write-grant" 'an expired grant must be cleared'
  pass "an expired grant is refused, explained, and removed"
}

test_grant_show_and_revoke() {
  run_grant --show || fail "--show must succeed with no grant"
  assert_contains "$(cat "$OUT")" 'no active grant' '--show must report an absent grant'

  run_grant "$PROJECTS/alpha/x.txt" --reason 'captain: fix the typo now' \
    || fail "grant must succeed: $(cat "$ERR")"
  run_grant --show || fail "--show must succeed with an active grant"
  assert_contains "$(cat "$OUT")" 'projects/alpha/x.txt' '--show must print the granted path'
  assert_contains "$(cat "$OUT")" 'reason=captain: fix the typo now' '--show must print the quoted instruction'

  run_grant --revoke || fail "--revoke must succeed"
  assert_absent "$STATE/.project-write-grant" 'a revoked grant must be gone'
  expect_deny "after revoke" --claude --tool Write --path "$PROJECTS/alpha/x.txt"
  assert_grep 'revoked' "$STATE/.project-write-grant.log" 'the audit log must record the revoke'
  pass "an active grant can be inspected and revoked, and the revoke is audited"
}

test_grant_refused_outside_a_primary_home() {
  local child="$TMP_ROOT/grant-child" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-grant-child "$child"
  mkdir -p "$child/bin" "$child/state" "$child/projects/alpha"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"; : > "$ERR"
  env FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$GRANT_CMD" "$child/projects/alpha/x.txt" --reason 'captain: fix the typo now' \
    > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a grant where the guard is inert must be refused, got exit $rc"
  assert_absent "$child/state/.project-write-grant" 'no record may be written where the guard is inert'
  pass "the grant script refuses to write a record where the guard never fires"
}

test_tracked_claude_registration
test_write_tools_into_a_clone_are_denied
test_read_tools_are_never_denied
test_read_only_exclusion_is_exact_name
test_writes_outside_protected_roots_are_allowed
test_write_tool_without_a_path_is_allowed
test_mcp_tools_are_never_classified
test_relative_and_traversal_paths_resolve_before_matching
test_symlink_into_a_clone_is_denied
test_nonexistent_target_still_matches
test_recorded_worktree_is_protected
test_secondmate_home_worktree_is_protected
test_recorded_worktree_equal_to_the_home_is_ignored
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_malformed_transport_fails_open
test_missing_jq_stdin_transport_fails_open
test_grant_refuses_records_that_would_protect_nothing
test_grant_allows_exactly_one_matching_write
test_grant_covers_a_directory_scope_but_not_its_siblings
test_expired_grant_is_refused_and_cleared
test_grant_show_and_revoke
test_grant_refused_outside_a_primary_home
