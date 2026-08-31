#!/usr/bin/env bash
# Executable contract for the AGENTS.md calibrated-byte, growth, and why-trace gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lint-agentsmd-budget)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SHELLCHECK_LOG="$TMP_ROOT/shellcheck.log"

cat > "$FAKEBIN/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'ShellCheck - shell script analysis tool' 'version: 0.11.0'
  exit 0
fi
printf '%s\n' "$*" >> "${SHELLCHECK_LOG:?}"
[ "${SHELLCHECK_EXIT:-0}" -eq 0 ] || printf '%s\n' 'fixture ShellCheck failure' >&2
exit "${SHELLCHECK_EXIT:-0}"
SH
chmod +x "$FAKEBIN/shellcheck"
cat > "$FAKEBIN/actionlint" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -version ]; then
  printf '%s\n' '1.7.12'
  exit 0
fi
[ "${ACTIONLINT_EXIT:-0}" -eq 0 ] || printf '%s\n' 'fixture workflow lint failure' >&2
exit "${ACTIONLINT_EXIT:-0}"
SH
chmod +x "$FAKEBIN/actionlint"

fm_git_identity
REAL_GIT=$(command -v git)
cat > "$FAKEBIN/git" <<'SH'
#!/usr/bin/env bash
if [ "${GIT_FAIL_PATCH:-0}" -eq 1 ]; then
  case "$*" in
    "diff --no-index --no-ext-diff --no-color --text --unified=0 "*) exit 86 ;;
  esac
fi
if [ "${GIT_FAIL_MESSAGE:-0}" -eq 1 ]; then
  case "$*" in
    "show -s --format=%B "*) exit 87 ;;
  esac
fi
if [ "${GIT_FAIL_BLOB:-0}" -eq 1 ]; then
  case "$*" in
    "cat-file blob "*) exit 88 ;;
  esac
fi
exec "${REAL_GIT:?}" "$@"
SH
chmod +x "$FAKEBIN/git"

write_bytes() { # <file> <bytes>
  perl -e '$n=shift; print "A" x ($n-1), "\n"' "$2" > "$1"
}

write_marked_bytes() { # <file> <bytes>
  perl -e '$n=shift; $m="docs/example.md owns this. <!-- why: doc:docs/example.md#document -->\n"; die if $n < length($m); print "B" x ($n-length($m)), $m' "$2" > "$1"
}

repo_new() { # <name> <AGENTS-bytes>
  local repo="$TMP_ROOT/$1"
  mkdir -p "$repo/bin" "$repo/docs" "$repo/.agents/skills/demo" "$repo/.github/workflows"
  git -C "$repo" init -q -b main
  cp "$ROOT/bin/fm-lint.sh" "$repo/bin/fm-lint.sh"
  cp "$ROOT/bin/fm-lint-workflows.sh" "$repo/bin/fm-lint-workflows.sh"
  chmod +x "$repo/bin/fm-lint.sh" "$repo/bin/fm-lint-workflows.sh"
  printf '#!/usr/bin/env bash\n# Usage: example-owner.sh --help\nexit 0\n' > "$repo/bin/example-owner.sh"
  chmod +x "$repo/bin/example-owner.sh"
  printf '# Document\n' > "$repo/docs/example.md"
  printf '%s\n' '---' 'name: demo' 'description: fixture' '---' '# Demo' > "$repo/.agents/skills/demo/SKILL.md"
  printf 'name: fixture\non: push\njobs: {}\n' > "$repo/.github/workflows/ci.yml"
  write_bytes "$repo/AGENTS.md" "$2"
  git -C "$repo" add .
  git -C "$repo" commit -qm base
  printf '%s\n' "$repo"
}

run_lint() { # <repo> [lint args...]
  local repo=$1
  shift
  (
    cd "$repo" || exit 125
    PATH="$FAKEBIN:$PATH" SHELLCHECK_LOG="$SHELLCHECK_LOG" FM_LINT_JOBS=1 \
      GITHUB_ACTIONS="${TEST_GITHUB_ACTIONS:-}" CI="${TEST_CI:-}" \
      GITHUB_EVENT_NAME="${TEST_GITHUB_EVENT_NAME:-}" \
      FM_LINT_BASE_SHA="${TEST_FM_LINT_BASE_SHA:-}" REAL_GIT="$REAL_GIT" \
      GIT_FAIL_PATCH="${GIT_FAIL_PATCH:-0}" \
      GIT_FAIL_MESSAGE="${GIT_FAIL_MESSAGE:-0}" \
      GIT_FAIL_BLOB="${GIT_FAIL_BLOB:-0}" "$repo/bin/fm-lint.sh" "$@"
  )
}

capture_lint() { # <repo> [args...]; sets OUT RC
  RC=0
  OUT=$(run_lint "$@" 2>&1) || RC=$?
}

commit_all() { # <repo> <message-file-or-subject>
  local repo=$1 message=$2
  git -C "$repo" add -A
  if [ -f "$message" ]; then
    git -C "$repo" commit -qF "$message"
  else
    git -C "$repo" commit -qm "$message"
  fi
}

add_marked_line() { # <repo> <line>
  printf '%s\n' "$2" >> "$1/AGENTS.md"
}

expect_pass() { # <label> <repo> [args...]
  local label=$1 repo=$2
  shift 2
  capture_lint "$repo" "$@"
  expect_code 0 "$RC" "$label"
}

expect_fail() { # <label> <needle> <repo> [args...]
  local label=$1 needle=$2 repo=$3
  shift 3
  capture_lint "$repo" "$@"
  [ "$RC" -ne 0 ] || fail "$label: expected failure"
  assert_contains "$OUT" "$needle" "$label did not explain the refusal"
}

test_calibrated_byte_ceiling() {
  local repo
  repo=$(repo_new cap-minus-one 29249)
  expect_pass '29,249 calibrated bytes' "$repo"
  repo=$(repo_new cap-exact 29250)
  expect_pass '29,250 calibrated bytes' "$repo"
  repo=$(repo_new cap-plus-one 29251)
  expect_fail '29,251 calibrated bytes' '29250' "$repo"
  assert_not_contains "$OUT" 'tokenizer' 'runtime diagnostic introduced a tokenizer dependency'
  pass 'calibrated-byte ceiling accepts 29249 and 29250, then rejects 29251'
}

test_file_safety_and_utf8() {
  local kind repo target rc out expected
  for kind in missing symlink hardlink directory unreadable utf8 nul; do
    repo=$(repo_new "unsafe-$kind" 120)
    target="$repo/AGENTS.md"
    case "$kind" in
      missing) rm "$target" ;;
      symlink) mv "$target" "$repo/real"; ln -s real "$target" ;;
      hardlink) ln "$target" "$repo/other-link" ;;
      directory) rm "$target"; mkdir "$target" ;;
      unreadable) chmod 000 "$target" ;;
      utf8) printf '\377\n' > "$target" ;;
      nul) printf 'valid\0text\n' > "$target" ;;
    esac
    rc=0; out=$(run_lint "$repo" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$kind AGENTS.md unexpectedly passed"
    case "$kind" in
      missing) expected='AGENTS.md is missing' ;;
      symlink) expected='must not be a symlink' ;;
      hardlink) expected='must not be hardlinked' ;;
      directory) expected='must be a regular file' ;;
      unreadable) expected='AGENTS.md is unreadable' ;;
      utf8) expected='not valid UTF-8' ;;
      nul) expected='contains NUL bytes' ;;
    esac
    assert_contains "$out" "$expected" "$kind refusal used the wrong diagnostic"
    chmod 600 "$target" 2>/dev/null || true
  done
  pass 'missing, unsafe, unreadable, and invalid UTF-8 AGENTS.md files fail closed'
}

test_unchanged_and_missing_base_modes() {
  local repo
  repo=$(repo_new unchanged-no-base 200)
  expect_pass 'unchanged main root without a parent base' "$repo"
  git -C "$repo" checkout -qb feature
  git -C "$repo" branch -D main >/dev/null
  expect_fail 'unchanged feature without target ref' 'target AGENTS.md base is missing' "$repo"
  add_marked_line "$repo" 'docs/example.md owns the new rule. <!-- why: doc:docs/example.md#document -->'
  commit_all "$repo" committed-change
  expect_fail 'committed change without target ref' 'target AGENTS.md base is missing' "$repo"
  pass 'main root content needs no base while feature branches require a target ref'
}

test_pr_local_and_main_bases() {
  local mode repo base
  for mode in pr local main; do
    repo=$(repo_new "base-$mode" 200)
    base=$(git -C "$repo" rev-parse HEAD)
    case "$mode" in
      pr) git -C "$repo" checkout -qb feature; write_marked_bytes "$repo/AGENTS.md" 199; TEST_FM_LINT_BASE_SHA=$base TEST_GITHUB_EVENT_NAME=pull_request TEST_CI=true TEST_GITHUB_ACTIONS=true expect_pass 'PR base SHA' "$repo" ;;
      local) git -C "$repo" checkout -qb feature; write_marked_bytes "$repo/AGENTS.md" 199; expect_pass 'local target base' "$repo" ;;
      main) write_marked_bytes "$repo/AGENTS.md" 199; commit_all "$repo" main-change; expect_pass 'main parent base' "$repo" ;;
    esac
  done
  repo=$(repo_new pr-missing-base 200)
  git -C "$repo" checkout -qb feature
  write_marked_bytes "$repo/AGENTS.md" 199
  TEST_GITHUB_EVENT_NAME=pull_request TEST_CI=true TEST_GITHUB_ACTIONS=true \
    expect_fail 'PR without base SHA' 'FM_LINT_BASE_SHA is required' "$repo"
  repo=$(repo_new local-explicit-base 200)
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb feature
  write_marked_bytes "$repo/AGENTS.md" 199
  TEST_FM_LINT_BASE_SHA=$base \
    expect_fail 'local explicit base SHA' 'FM_LINT_BASE_SHA is CI-only' "$repo"
  pass 'PR, local feature, and main-push modes select the expected base blob'
}

test_ci_base_must_be_ancestor() {
  local repo base
  repo=$(repo_new ci-unrelated-base 200)
  git -C "$repo" checkout -qb feature
  write_marked_bytes "$repo/AGENTS.md" 250
  commit_all "$repo" feature-content
  git -C "$repo" checkout -q --orphan unrelated
  write_marked_bytes "$repo/AGENTS.md" 300
  commit_all "$repo" unrelated-base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q feature
  TEST_FM_LINT_BASE_SHA=$base TEST_GITHUB_EVENT_NAME=pull_request \
    TEST_CI=true TEST_GITHUB_ACTIONS=true \
    expect_fail 'unrelated CI base' 'stale or unrelated' "$repo"
  pass 'CI requires its supplied target base to be a HEAD ancestor'
}

test_generic_ci_feature_uses_target_base() {
  local repo
  repo=$(repo_new generic-ci-feature 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
  commit_all "$repo" growth
  git -C "$repo" commit --allow-empty -qm follow-up
  TEST_CI=true expect_fail 'generic CI feature baseline' 'AGENTS-Budget-Override' "$repo"
  pass 'generic CI feature builds compare against the accepted target base'
}

test_deleted_wrong_type_and_utf8_bases() {
  local kind repo bad_base
  for kind in deleted symlink utf8 nul; do
    repo=$(repo_new "bad-base-$kind" 200)
    git -C "$repo" checkout -qb badbase
    case "$kind" in
      deleted) git -C "$repo" rm -q AGENTS.md ;;
      symlink) rm "$repo/AGENTS.md"; ln -s docs/example.md "$repo/AGENTS.md"; git -C "$repo" add AGENTS.md ;;
      utf8) printf '\377\n' > "$repo/AGENTS.md"; git -C "$repo" add AGENTS.md ;;
      nul) printf 'valid\0text\n' > "$repo/AGENTS.md"; git -C "$repo" add AGENTS.md ;;
    esac
    git -C "$repo" commit -qm "bad $kind base"
    bad_base=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" checkout -qb feature
    rm -f "$repo/AGENTS.md"
    write_marked_bytes "$repo/AGENTS.md" 199
    case "$kind" in
      deleted) TEST_FM_LINT_BASE_SHA=$bad_base TEST_CI=true TEST_GITHUB_ACTIONS=true expect_fail 'deleted base AGENTS.md' 'no regular AGENTS.md blob' "$repo" ;;
      symlink) TEST_FM_LINT_BASE_SHA=$bad_base TEST_CI=true TEST_GITHUB_ACTIONS=true expect_fail 'symlink-mode base AGENTS.md' 'no regular AGENTS.md blob' "$repo" ;;
      utf8) TEST_FM_LINT_BASE_SHA=$bad_base TEST_CI=true TEST_GITHUB_ACTIONS=true expect_fail 'invalid UTF-8 base AGENTS.md' 'unreadable or invalid UTF-8' "$repo" ;;
      nul) TEST_FM_LINT_BASE_SHA=$bad_base TEST_CI=true TEST_GITHUB_ACTIONS=true expect_fail 'NUL base AGENTS.md' 'contains NUL bytes' "$repo" ;;
    esac
  done
  pass 'deleted, wrong-type, and invalid UTF-8 base AGENTS.md blobs fail precisely'
}

test_stale_local_target() {
  local repo
  repo=$(repo_new stale-local 200)
  git -C "$repo" checkout -qb feature
  git -C "$repo" branch -f main HEAD~0
  git -C "$repo" checkout -q main
  add_marked_line "$repo" 'docs/example.md owns target advance. <!-- why: doc:docs/example.md#document -->'
  commit_all "$repo" target-advance
  git -C "$repo" checkout -q feature
  add_marked_line "$repo" 'docs/example.md owns feature rule. <!-- why: doc:docs/example.md#document -->'
  expect_fail 'stale local target' 'sync' "$repo"
  pass 'a stale local target fails with synchronization guidance'
}

test_remote_target_precedence() {
  local repo old_target
  repo=$(repo_new remote-target-precedence 300)
  old_target=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/remotes/origin/main "$old_target"
  write_marked_bytes "$repo/AGENTS.md" 100
  commit_all "$repo" newer-local-main
  git -C "$repo" checkout -qb feature
  write_marked_bytes "$repo/AGENTS.md" 200
  expect_pass 'remote target precedes different local main' "$repo"
  pass 'origin/main remains the target when local main differs'
}

test_shrink_equal_and_growth() {
  local repo
  repo=$(repo_new replacement 300)
  git -C "$repo" checkout -qb feature
  printf '%s\n' 'docs/example.md owns replacement. <!-- why: doc:docs/example.md#document -->' > "$repo/AGENTS.md"
  expect_pass shrink "$repo"
  write_marked_bytes "$repo/AGENTS.md" 300
  expect_pass equal "$repo"
  add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
  expect_fail 'growth without trailers' 'AGENTS-Budget-Override' "$repo"
  pass 'shrink and equal replacement pass while unapproved growth fails'
}

make_override_commit() { # <repo> <before> <after> <captain text> [override replacement]
  local repo=$1 before=$2 after=$3 words=$4 override=${5:-} base target msg
  base=$(git -C "$repo" rev-parse "HEAD:AGENTS.md")
  target=$(git -C "$repo" hash-object AGENTS.md)
  [ -n "$override" ] || override="AGENTS-Budget-Override: v1 base=$base target=$target before=$before after=$after"
  msg="$repo/message"
  printf '%s\n\n%s\n%s\n' 'test growth' "$override" "Captain-Instruction: $words" > "$msg"
  commit_all "$repo" "$msg"
}

test_override_failure_matrix_and_exact_pair() {
  local case repo base target override words expected before=200 after
  for case in duplicate malformed stale-base stale-target wrong-before wrong-after missing-reason generic-reason over-cap; do
    repo=$(repo_new "override-$case" "$before")
    git -C "$repo" checkout -qb feature
    add_marked_line "$repo" 'docs/example.md owns approved growth. <!-- why: doc:docs/example.md#document -->'
    after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
    base=$(git -C "$repo" rev-parse "HEAD:AGENTS.md")
    target=$(git -C "$repo" hash-object AGENTS.md)
    override="AGENTS-Budget-Override: v1 base=$base target=$target before=$before after=$after"
    words='Add this exact approved growth.'
    case "$case" in
      duplicate) override="$override"$'\n'"$override"; expected='exactly one AGENTS-Budget-Override trailer; found 2' ;;
      malformed) override='AGENTS-Budget-Override: yes'; expected='does not match the v1 grammar' ;;
      stale-base) override=${override/base=$base/base=0000000000000000000000000000000000000000}; expected='base blob is stale' ;;
      stale-target) override=${override/target=$target/target=0000000000000000000000000000000000000000}; expected='target blob is stale' ;;
      wrong-before) override=${override/before=$before/before=199}; expected='before count is wrong' ;;
      wrong-after) override=${override/after=$after/after=999}; expected='after count is wrong' ;;
      missing-reason) words=; expected='must quote the captain exact words' ;;
      generic-reason) words=approved; expected='Captain-Instruction trailer is generic' ;;
      over-cap) write_bytes "$repo/AGENTS.md" 29251; target=$(git -C "$repo" hash-object AGENTS.md); override="AGENTS-Budget-Override: v1 base=$base target=$target before=$before after=29251"; expected='hard ceiling is 29250' ;;
    esac
    make_override_commit "$repo" "$before" "$after" "$words" "$override"
    expect_fail "override $case" "$expected" "$repo"
  done
  repo=$(repo_new override-exact 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns approved growth. <!-- why: doc:docs/example.md#document -->'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$after" 'Add docs/example.md ownership rule to AGENTS.md.'
  expect_pass 'exact trailer pair' "$repo"
  pass 'all trailer failures reject and one exact content-bound pair passes'
}

test_override_duplicate_pairing_and_mutation() {
  local repo base target after msg
  repo=$(repo_new duplicate-captain 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  base=$(git -C "$repo" rev-parse 'HEAD:AGENTS.md')
  target=$(git -C "$repo" hash-object AGENTS.md)
  msg="$repo/duplicate-captain-message"
  printf '%s\n\n%s\n%s\n%s\n' test \
    "AGENTS-Budget-Override: v1 base=$base target=$target before=200 after=$after" \
    'Captain-Instruction: Add this exact growth.' \
    'Captain-Instruction: Add this exact growth.' > "$msg"
  commit_all "$repo" "$msg"
  expect_fail 'duplicate Captain-Instruction' 'exactly one paired Captain-Instruction trailer; found 2' "$repo"

  repo=$(repo_new split-pair 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  base=$(git -C "$repo" rev-parse 'HEAD:AGENTS.md')
  target=$(git -C "$repo" hash-object AGENTS.md)
  git -C "$repo" add AGENTS.md
  git -C "$repo" commit -qm $'growth\n\nAGENTS-Budget-Override: v1 base='"$base"' target='"$target"' before=200 after='"$after"
  git -C "$repo" commit --allow-empty -qm $'authority\n\nCaptain-Instruction: Add this exact growth.'
  expect_fail 'split trailer pair' 'must be in the same commit' "$repo"

  repo=$(repo_new duplicate-pair 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$after" 'Add this exact growth.'
  git -C "$repo" commit --allow-empty -qm $'duplicate pair\n\nAGENTS-Budget-Override: v1 base=0000000000000000000000000000000000000000 target=0000000000000000000000000000000000000000 before=1 after=2\nCaptain-Instruction: Add this exact growth.'
  expect_fail 'duplicate complete pair' 'exactly one AGENTS-Budget-Override trailer; found 2' "$repo"

  repo=$(repo_new mutated-exact-pair 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$after" 'Add this exact growth.'
  add_marked_line "$repo" 'docs/example.md owns later edit. <!-- why: doc:docs/example.md#document -->'
  expect_fail 'valid pair mutated afterward' 'target blob is stale' "$repo"
  pass 'duplicate, split, and mutated trailer pairs fail precisely'
}

test_generic_captain_phrases() {
  local words repo after
  for words in 'captain approved' 'approved by captain' 'permission granted' \
    '  approved  ' 'Approved.' 'CAPTAIN-APPROVED!' 'Approval granted.' \
    'Approval received.' 'ok' 'LGTM' 'go ahead' 'Growth authorized.'; do
    repo=$(repo_new "generic-${words// /-}" 200)
    git -C "$repo" checkout -qb feature
    add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
    after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
    make_override_commit "$repo" 200 "$after" "$words"
    expect_fail "generic captain phrase: $words" 'Captain-Instruction trailer is generic' "$repo"
  done
  pass 'finite generic approval shapes do not grant growth authority'
}

test_natural_language_not_certified() {
  local words repo after
  for words in 'Add 1.' 'Add it.' 'Add this exact growth.' \
    'The captain has authorized this growth request.'; do
    repo=$(repo_new "residual-${words// /-}" 200)
    git -C "$repo" checkout -qb feature
    add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
    after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
    make_override_commit "$repo" 200 "$after" "$words"
    expect_pass "residual natural-language instruction: $words" "$repo"
  done
  pass 'lint rejects only the finite generic list and does not certify natural language'
}

test_override_does_not_bypass_why() {
  local repo after
  repo=$(repo_new override-no-why 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'Untraced growth.'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$after" 'Add this exact untraced growth.'
  expect_fail 'override without why trace' 'why' "$repo"
  pass 'a budget override does not bypass why-trace checks'
}

test_stale_pair_blob_binding() {
  local repo first_after second_after first_base first_target
  repo=$(repo_new stale-copied-pair 200)
  add_marked_line "$repo" 'docs/example.md owns the first growth. <!-- why: doc:docs/example.md#document -->'
  first_after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$first_after" 'Add docs/example.md first ownership rule.'
  first_base=$(git -C "$repo" rev-parse 'HEAD~1:AGENTS.md')
  first_target=$(git -C "$repo" rev-parse 'HEAD:AGENTS.md')
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns the second growth. <!-- why: doc:docs/example.md#document -->'
  second_after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$second_after" 'Add docs/example.md first ownership rule.' \
    "AGENTS-Budget-Override: v1 base=$first_base target=$first_target before=200 after=$first_after"
  expect_fail 'copied prior trailer pair' 'stale' "$repo"
  pass 'a copied prior trailer pair fails on blob binding'
}

test_why_structural_and_content_lines() {
  local repo
  repo=$(repo_new structural-lines 200)
  git -C "$repo" checkout -qb feature
  printf '%s\n' '' '## Heading' '```' '```' '  ~~~ markdown' '   ~~~   ' > "$repo/AGENTS.md"
  expect_pass 'structural exemptions' "$repo"
  for line in 'Added prose.' '- Added list item.' '> Added quote.' 'code inside a fence' \
    '    ```' '``' '~~' "\`~\`" '  ``~' $'\t# untraced content' \
    $'\v' $'\f' $'#\vUntraced prose' $'#\fUntraced prose'; do
    git -C "$repo" checkout -q -- AGENTS.md
    printf '%s\n' "$line" > "$repo/AGENTS.md"
    expect_fail "untraced content: $line" 'why' "$repo"
  done
  git -C "$repo" checkout -q -- AGENTS.md
  printf '%s\n' '```' '# ATX-looking fenced content' '```' > "$repo/AGENTS.md"
  expect_fail 'ATX-looking content inside a fence' 'why' "$repo"
  git -C "$repo" checkout -q -- AGENTS.md
  printf '%s\n' '```' '``` trailing closing text' '```' > "$repo/AGENTS.md"
  expect_fail 'closing fence with trailing text' 'why' "$repo"
  git -C "$repo" checkout -q -- AGENTS.md
  printf '%s\n' '<!-- why: doc:docs/example.md#document -->' > "$repo/AGENTS.md"
  expect_fail 'metadata-only trace' 'visible owner pointer' "$repo"
  git -C "$repo" checkout -q -- AGENTS.md
  printf '%s\n' 'This rule hides <!-- docs/example.md --> its owner. <!-- why: doc:docs/example.md#document -->' > "$repo/AGENTS.md"
  expect_fail 'owner pointer hidden in a comment' 'visible owner pointer' "$repo"
  git -C "$repo" checkout -q -- AGENTS.md
  printf '%s\n' 'docs/example.md owns this rule. <!-- outer <!-- why: doc:docs/example.md#document -->' > "$repo/AGENTS.md"
  expect_fail 'why marker nested in a comment' 'nested inside another HTML comment' "$repo"
  git -C "$repo" checkout -q -- AGENTS.md
  printf '# Heading\rUntraced prose\n' > "$repo/AGENTS.md"
  expect_fail 'bare carriage return line ending' 'without a why trace' "$repo"
  pass 'only blank, heading, and fence delimiters receive structural exemptions'
}

test_binary_attributes_do_not_hide_added_lines() {
  local repo
  repo=$(repo_new binary-attributes 200)
  git -C "$repo" checkout -qb feature
  printf '%s\n' 'AGENTS.md binary' > "$repo/.gitattributes"
  printf '%s\n' 'Untraced replacement.' > "$repo/AGENTS.md"
  expect_fail 'binary AGENTS.md diff' 'without a why trace' "$repo"
  pass 'binary attributes cannot hide added AGENTS.md lines'
}

test_why_targets_locks_and_patch_like_lines() {
  local repo marker outside
  repo=$(repo_new why-targets 200)
  git -C "$repo" checkout -qb feature
  for marker in \
    'skill:demo#demo' \
    'doc:docs/example.md#document' \
    'script:bin/example-owner.sh--help' \
    'lock:agentsmd-budget-2026-08-31'; do
    git -C "$repo" checkout -q -- AGENTS.md
    printf '%s\n' "+ $marker owns this content. <!-- why: $marker -->" > "$repo/AGENTS.md"
    expect_pass "why target $marker" "$repo"
  done
  for marker in \
    'skill:absent#demo' \
    'doc:docs/absent.md#document' \
    'script:bin/absent.sh--help' \
    'lock:Bad ID!' \
    'lock:'; do
    git -C "$repo" checkout -q -- AGENTS.md
    printf '%s\n' "--- content. <!-- why: $marker -->" > "$repo/AGENTS.md"
    expect_fail "invalid why target $marker" 'why' "$repo"
  done
  outside="$TMP_ROOT/outside-why-targets"
  mkdir -p "$outside/doc" "$outside/skill" "$outside/script"
  printf '# Outside document\n' > "$outside/doc/target.md"
  printf '%s\n' '---' 'name: escaped' 'description: outside fixture' '---' '# Escaped' > "$outside/skill/SKILL.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$outside/script/owner.sh"
  chmod +x "$outside/script/owner.sh"
  ln -s "$outside/doc" "$repo/docs/external"
  ln -s "$outside/skill" "$repo/.agents/skills/escaped"
  ln -s "$outside/script" "$repo/bin/external"
  for marker in \
    'doc:docs/external/target.md#document' \
    'skill:escaped#escaped' \
    'script:bin/external/owner.sh--help'; do
    git -C "$repo" checkout -q -- AGENTS.md
    printf '%s\n' "$marker owns escaped content. <!-- why: $marker -->" > "$repo/AGENTS.md"
    expect_fail "symlinked why target $marker" 'why' "$repo"
  done
  git -C "$repo" checkout -q -- AGENTS.md
  printf '%s\n' \
    '+++ docs/example.md owns literal. <!-- why: doc:docs/example.md#document -->' \
    '--- docs/example.md owns literal. <!-- why: doc:docs/example.md#document -->' > "$repo/AGENTS.md"
  expect_pass 'patch-like content' "$repo"
  pass 'why target kinds, stable locks, and patch-like content parse safely'
}

test_modified_moved_and_deleted_lines() {
  local repo
  repo=$(repo_new diff-kinds 200)
  printf '%s\n' 'Original sentence.' 'Moved sentence.' >> "$repo/AGENTS.md"
  commit_all "$repo" seed-lines
  git -C "$repo" checkout -qb feature
  sed -i.bak 's/Original sentence./Modified sentence./' "$repo/AGENTS.md"; rm "$repo/AGENTS.md.bak"
  expect_fail 'modified line' 'why' "$repo"
  git -C "$repo" checkout -q -- AGENTS.md
  sed -i.bak '/Moved sentence./d' "$repo/AGENTS.md"; rm "$repo/AGENTS.md.bak"
  printf '%s\n' 'Moved sentence.' | cat - "$repo/AGENTS.md" > "$repo/moved"; mv "$repo/moved" "$repo/AGENTS.md"
  expect_fail 'moved line' 'why' "$repo"
  git -C "$repo" checkout -q -- AGENTS.md
  sed -i.bak '/Original sentence./d' "$repo/AGENTS.md"; rm "$repo/AGENTS.md.bak"
  expect_pass 'delete-only diff' "$repo"
  pass 'modified and moved lines need trace while a delete-only diff passes'
}

test_final_worktree_content_states() {
  local state repo
  for state in unstaged staged committed; do
    repo=$(repo_new "final-$state" 200)
    git -C "$repo" checkout -qb feature
    printf '%s\n' 'docs/example.md owns final content. <!-- why: doc:docs/example.md#document -->' > "$repo/AGENTS.md"
    case "$state" in staged) git -C "$repo" add AGENTS.md ;; committed) commit_all "$repo" final-content ;; esac
    expect_pass "$state final content" "$repo"
  done
  pass 'unstaged, staged, and committed final content uses one measurement path'
}

test_list_files_explicit_paths_and_lint_exits() {
  local repo listed
  repo=$(repo_new interface 200)
  listed=$(run_lint "$repo" --list-files) || fail '--list-files failed'
  assert_not_contains "$listed" 'AGENTS.md' '--list-files changed the shell inventory contract'
  : > "$SHELLCHECK_LOG"
  expect_pass 'explicit shell path' "$repo" bin/example-owner.sh
  assert_contains "$(cat "$SHELLCHECK_LOG")" 'bin/example-owner.sh' 'explicit path did not remain ShellCheck-only'
  SHELLCHECK_EXIT=1 expect_fail 'normal shell lint failure' 'ShellCheck' "$repo" bin/example-owner.sh
  ACTIONLINT_EXIT=1 expect_fail 'workflow lint failure' 'workflow' "$repo"
  pass '--list-files and explicit paths stay shell-only, and both lint exits remain deterministic'
}

test_default_shellcheck_exit_wins_over_budget() {
  local repo
  repo=$(repo_new shell-and-budget 29250)
  git -C "$repo" checkout -qb feature
  printf '%s\n' '# changed shell target' >> "$repo/bin/example-owner.sh"
  write_bytes "$repo/AGENTS.md" 29251
  SHELLCHECK_EXIT=7 capture_lint "$repo"
  expect_code 7 "$RC" 'default ShellCheck and budget failure'
  assert_contains "$OUT" 'fixture ShellCheck failure' 'default path omitted the ShellCheck failure'
  assert_contains "$OUT" 'hard ceiling is 29250' 'default path omitted the budget failure'
  pass 'default-path ShellCheck exit wins while both lint diagnostics remain visible'
}

test_git_and_parser_failures_close_the_gate() {
  local repo after
  repo=$(repo_new no-worktree 200)
  mv "$repo/.git" "$TMP_ROOT/no-worktree.git"
  expect_fail 'missing Git worktree' 'Git worktree is required' "$repo"

  repo=$(repo_new diff-command-failure 200)
  git -C "$repo" checkout -qb feature
  write_marked_bytes "$repo/AGENTS.md" 199
  GIT_FAIL_PATCH=1 expect_fail 'zero-context diff failure' 'zero-context AGENTS.md diff' "$repo"

  repo=$(repo_new commit-message-failure 200)
  git -C "$repo" checkout -qb feature
  add_marked_line "$repo" 'docs/example.md owns growth. <!-- why: doc:docs/example.md#document -->'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$after" 'Add this exact growth.'
  GIT_FAIL_MESSAGE=1 expect_fail 'commit message read failure' 'could not read a commit' "$repo"

  repo=$(repo_new base-blob-read-failure 200)
  git -C "$repo" checkout -qb feature
  write_marked_bytes "$repo/AGENTS.md" 199
  GIT_FAIL_BLOB=1 expect_fail 'base blob read failure' 'unreadable or invalid UTF-8' "$repo"
  pass 'missing Git state and failed Git reads cannot skip the budget gate'
}

test_zero_shell_targets_still_runs_companion_checks() {
  local repo
  repo=$(repo_new zero-shell 200)
  git -C "$repo" checkout -qb feature
  printf '%s\n' 'docs/example.md owns this. <!-- why: doc:docs/example.md#document -->' > "$repo/AGENTS.md"
  expect_pass 'zero changed shell target' "$repo"
  pass 'zero changed shell targets still run the budget and workflow companions'
}

test_existing_backpass_and_coverage_routing() {
  local all pure
  all=$("$ROOT/bin/fm-test-run.sh" --list --all) \
    || fail 'the test runner could not list the complete suite'
  pure=$("$ROOT/bin/fm-test-run.sh" --list --family pure-contract-unit) \
    || fail 'the test runner could not list pure-contract-unit'
  assert_contains "$all" 'tests/fm-ov-backpass-apply.test.sh' \
    'the complete suite omitted the prior safety contract test'
  assert_contains "$all" 'tests/fm-lint-agentsmd-budget.test.sh' \
    'the complete suite omitted the new lint budget test'
  assert_contains "$pure" 'tests/fm-lint-agentsmd-budget.test.sh' \
    'pure-contract-unit omitted the new lint budget test'
  pass 'runner listings retain the old safety test and route the new test exactly'
}

test_shallow_ci_fails_closed() {
  local repo base after
  repo=$(repo_new shallow-source 200)
  base=$(git -C "$repo" rev-parse HEAD)
  add_marked_line "$repo" 'docs/example.md owns CI content. <!-- why: doc:docs/example.md#document -->'
  commit_all "$repo" ci-content
  git clone -q --depth 1 "file://$repo" "$TMP_ROOT/shallow"
  TEST_FM_LINT_BASE_SHA=$base TEST_CI=true TEST_GITHUB_ACTIONS=true \
    expect_fail 'shallow CI base' 'fetch' "$TMP_ROOT/shallow"

  repo=$(repo_new shallow-ancestry-source 200)
  git -C "$repo" commit --allow-empty -qm $'prior authority\n\nCaptain-Instruction: Add docs/example.md ownership rule to AGENTS.md.'
  git -C "$repo" commit --allow-empty -qm accepted-base
  base=$(git -C "$repo" rev-parse HEAD)
  add_marked_line "$repo" 'docs/example.md owns shallow growth. <!-- why: doc:docs/example.md#document -->'
  after=$(wc -c < "$repo/AGENTS.md" | tr -d ' ')
  make_override_commit "$repo" 200 "$after" 'Add docs/example.md ownership rule to AGENTS.md.'
  git clone -q --depth 2 "file://$repo" "$TMP_ROOT/shallow-ancestry"
  TEST_FM_LINT_BASE_SHA=$base TEST_CI=true TEST_GITHUB_ACTIONS=true \
    expect_fail 'present base with shallow ancestry' 'full target history' "$TMP_ROOT/shallow-ancestry"
  pass 'CI rejects absent bases and present bases with shallow ancestry'
}

test_calibrated_byte_ceiling
test_file_safety_and_utf8
test_unchanged_and_missing_base_modes
test_pr_local_and_main_bases
test_ci_base_must_be_ancestor
test_generic_ci_feature_uses_target_base
test_deleted_wrong_type_and_utf8_bases
test_stale_local_target
test_remote_target_precedence
test_shrink_equal_and_growth
test_override_failure_matrix_and_exact_pair
test_override_duplicate_pairing_and_mutation
test_generic_captain_phrases
test_natural_language_not_certified
test_override_does_not_bypass_why
test_stale_pair_blob_binding
test_why_structural_and_content_lines
test_binary_attributes_do_not_hide_added_lines
test_why_targets_locks_and_patch_like_lines
test_modified_moved_and_deleted_lines
test_final_worktree_content_states
test_list_files_explicit_paths_and_lint_exits
test_default_shellcheck_exit_wins_over_budget
test_git_and_parser_failures_close_the_gate
test_zero_shell_targets_still_runs_companion_checks
test_existing_backpass_and_coverage_routing
test_shallow_ci_fails_closed
