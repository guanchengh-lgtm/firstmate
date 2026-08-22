#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo and each secondmate home fast-forward from its
#     configured update remote when set, otherwise upstream when configured,
#     then origin.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
#   - After firstmate updates or is already current, the Pi mid-line slash
#     dist patch is reapplied; an honest skip or layout fail does not abort
#     the git update, and a skipped firstmate does not patch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

# Add an upstream remote containing the initial origin commit, plus a checkout
# that can advance upstream independently from the fork-facing origin.
add_upstream() {
  local w=$1
  git clone -q --bare "file://$w/origin.git" "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git -C "$w/main" remote add upstream "file://$w/upstream.git"
  git clone -q "file://$w/upstream.git" "$w/upstream-seed"
  git -C "$w/upstream-seed" config user.email fmtest@example.com
  git -C "$w/upstream-seed" config user.name fmtest
}

bump_upstream() {
  local w=$1 mode=$2
  printf 'u-%s\n' "$mode" >> "$w/upstream-seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'upstream-v2\n' > "$w/upstream-seed/AGENTS.md"
    printf 'echo upstream\n' > "$w/upstream-seed/bin/tool.sh"
    printf 'upstream-s2\n' > "$w/upstream-seed/.agents/skills/note.md"
  fi
  git -C "$w/upstream-seed" add -A
  git -C "$w/upstream-seed" commit -qm "upstream-$mode"
  git -C "$w/upstream-seed" push -q origin main
}

add_standalone_sm() {
  local w=$1 id=$2
  git clone -q "file://$w/origin.git" "$w/$id"
  git -C "$w/$id" remote add upstream "file://$w/upstream.git"
  git -C "$w/$id" checkout -q --detach HEAD
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

run_update() {
  local w=$1
  # Isolate the Pi dist patch from the live global install. Tests that exercise
  # the helper set FM_PI_TUI_DIST to a fixture before calling run_update.
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_PI_TUI_DIST="${FM_PI_TUI_DIST:-$w/absent-pi-tui-dist}" \
    "$UPDATE" 2>/dev/null
}

CLEAN_PI_TUI_DIST="$ROOT/tests/fixtures/fm-pi-midline-slash-patch/clean"

copy_clean_pi_tui_dist() {
  local dest=$1
  mkdir -p "$dest/components"
  cp "$CLEAN_PI_TUI_DIST/components/editor.js" "$dest/components/editor.js"
  cp "$CLEAN_PI_TUI_DIST/autocomplete.js" "$dest/autocomplete.js"
  cp "$CLEAN_PI_TUI_DIST/components/editor.d.ts" "$dest/components/editor.d.ts"
}

# --- T1: no upstream falls back to origin; FF, not a merge ------------------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"
  git -C "$w/main" remote get-url upstream >/dev/null 2>&1 \
    && fail "origin fallback fixture unexpectedly has an upstream remote"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 absent upstream falls back to origin for main and secondmate"
}

# --- T2: upstream wins independently for every code root and is fetch-only --
test_prefers_upstream_without_push() {
  local w out upstream_before upstream_after origin_tip trace
  w=$(new_world t2)
  add_sm "$w" linked
  add_upstream "$w"
  add_standalone_sm "$w" standalone

  # Fork origin and product upstream advance to different commits from the same
  # base, so choosing the wrong remote is observable rather than accidentally
  # reaching the same tip.
  bump_origin "$w" readme
  bump_upstream "$w" instr
  upstream_before=$(git -C "$w/upstream.git" rev-parse main)
  origin_tip=$(git -C "$w/origin.git" rev-parse main)
  trace="$w/update.git-trace"

  out=$(GIT_TRACE="$trace" run_update "$w")
  upstream_after=$(git -C "$w/upstream.git" rev-parse main)

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded from upstream"
  assert_contains "$out" "secondmate linked: updated " "linked secondmate fast-forwarded from upstream"
  assert_contains "$out" "secondmate standalone: updated " "standalone secondmate fast-forwarded from its upstream"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$upstream_before" ] \
    || fail "firstmate did not land on upstream/main"
  [ "$(git -C "$w/linked" rev-parse HEAD)" = "$upstream_before" ] \
    || fail "linked secondmate did not land on upstream/main"
  [ "$(git -C "$w/standalone" rev-parse HEAD)" = "$upstream_before" ] \
    || fail "standalone secondmate did not land on its upstream/main"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$origin_tip" ] \
    || fail "updater used origin even though upstream was configured"
  [ "$upstream_after" = "$upstream_before" ] \
    || fail "the update path changed the upstream repository"
  if grep -Eq '(^|[[:space:]])push([[:space:]]|$)' "$trace"; then
    fail "the update path invoked git push against a fetch-only upstream"
  fi
  pass "T2 upstream is preferred per code root and the update path never pushes"
}

test_configured_origin_overrides_upstream() {
  local w out origin_tip upstream_tip
  w=$(new_world configured-origin)
  add_sm "$w" linked
  add_upstream "$w"

  bump_origin "$w" readme
  bump_upstream "$w" instr
  origin_tip=$(git -C "$w/origin.git" rev-parse main)
  upstream_tip=$(git -C "$w/upstream.git" rev-parse main)
  printf 'origin\n' > "$w/home/config/update-remote"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "configured origin fast-forwarded firstmate"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$origin_tip" ] \
    || fail "configured origin did not win over upstream"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$upstream_tip" ] \
    || fail "updater used upstream despite configured origin"
  [ "$(git -C "$w/linked" rev-parse HEAD)" = "$upstream_tip" ] \
    || fail "primary update-remote preference was inherited by secondmate"
  pass "configured origin overrides upstream only for its own home"
}

test_empty_config_preserves_default_remote_preference() {
  local w out upstream_tip
  w=$(new_world empty-config)
  add_upstream "$w"
  bump_upstream "$w" readme
  upstream_tip=$(git -C "$w/upstream.git" rev-parse main)
  : > "$w/home/config/update-remote"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "empty config preserved default remote preference"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$upstream_tip" ] \
    || fail "empty update-remote did not preserve upstream preference"
  pass "empty update-remote preserves upstream-then-origin preference"
}

test_missing_configured_remote_refuses_update() {
  local w out before
  w=$(new_world missing-configured-remote)
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)
  printf 'fork\n' > "$w/home/config/update-remote"

  if out=$(run_update "$w"); then
    fail "missing configured remote did not refuse the update"
  fi

  assert_contains "$out" "firstmate: error: configured update remote 'fork' does not exist" \
    "missing configured remote reported clearly"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "missing configured remote moved firstmate HEAD"
  pass "missing configured remote refuses the self-update"
}

assert_malformed_update_remote_refused() {
  local name=$1 content=$2 w out before
  w=$(new_world "malformed-$name")
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)
  printf '%b' "$content" > "$w/home/config/update-remote"

  if out=$(run_update "$w"); then
    fail "malformed $name update remote did not refuse the update"
  fi

  assert_contains "$out" "firstmate: error: malformed config/update-remote" \
    "malformed $name update remote reported clearly"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "malformed $name update remote moved firstmate HEAD"
}

test_malformed_update_remote_refuses_update() {
  assert_malformed_update_remote_refused whitespace 'origin upstream\n'
  assert_malformed_update_remote_refused multiline 'origin\nupstream\n'
  assert_malformed_update_remote_refused control 'origin\r\n'
  pass "malformed update-remote content refuses the self-update"
}

# --- T3: fetch before branch resolution honors upstream's different default --
test_upstream_default_without_remote_head() {
  local w out upstream_tip upstream_main
  w=$(new_world t8)
  add_upstream "$w"

  # Upstream defaults to master while origin defaults to main. The updater has
  # no local upstream/HEAD symref, so it must fetch before choosing its base.
  git -C "$w/upstream-seed" checkout -qb master
  printf 'upstream master\n' >> "$w/upstream-seed/README.md"
  git -C "$w/upstream-seed" add -A
  git -C "$w/upstream-seed" commit -qm upstream-master
  git -C "$w/upstream-seed" push -q origin master
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/master
  upstream_tip=$(git -C "$w/upstream.git" rev-parse master)
  upstream_main=$(git -C "$w/upstream.git" rev-parse main)
  [ "$upstream_tip" != "$upstream_main" ] || fail "fixture upstream main and master tips match"
  git -C "$w/main" show-ref --verify --quiet refs/remotes/upstream/HEAD \
    && fail "fixture unexpectedly has upstream/HEAD"
  git -C "$w/main" checkout -qb master

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded from upstream/master"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$upstream_tip" ] \
    || fail "firstmate did not use upstream's fetched master branch"
  pass "T3 fetched upstream default wins when upstream/HEAD is absent"
}

# --- T4: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

test_secondmate_bad_update_remote_continues_fleet() {
  local w out origin_tip before_bad
  w=$(new_world secondmate-bad-config)
  add_sm "$w" bad
  add_sm "$w" good
  bump_origin "$w" instr
  origin_tip=$(git -C "$w/origin.git" rev-parse main)
  before_bad=$(git -C "$w/bad" rev-parse HEAD)
  mkdir -p "$w/bad/config"
  printf 'origin upstream\n' > "$w/bad/config/update-remote"

  if ! out=$(run_update "$w"); then
    fail "secondmate config error aborted the update fleet"
  fi

  assert_contains "$out" "firstmate: updated " "firstmate still updated"
  assert_contains "$out" "secondmate bad: error: malformed config/update-remote" \
    "bad secondmate refused loudly"
  assert_contains "$out" "secondmate good: updated " "later secondmate still updated"
  assert_contains "$out" "reread-firstmate: yes" "summary still printed after secondmate error"
  assert_contains "$out" "nudge-secondmates: fm-good" "only the advanced secondmate is nudged"
  [ "$(git -C "$w/good" rev-parse HEAD)" = "$origin_tip" ] \
    || fail "good secondmate did not advance after sibling config error"
  [ "$(git -C "$w/bad" rev-parse HEAD)" = "$before_bad" ] \
    || fail "bad secondmate moved despite configured-remote refusal"
  pass "secondmate update-remote refusal keeps the fleet sweep running"
}

test_pi_midline_patch_on_updated_and_already_current() {
  local w dist out
  w=$(new_world pi-midline)
  dist="$w/pi-tui-dist"
  copy_clean_pi_tui_dist "$dist"
  bump_origin "$w" instr

  out=$(FM_PI_TUI_DIST="$dist" run_update "$w")
  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "pi-midline-slash: patched " \
    "updated firstmate did not reapply the Pi mid-line patch"
  assert_grep "isAtSlashCommandStart" "$dist/components/editor.js" \
    "updated firstmate left the clean dist unpatched"

  copy_clean_pi_tui_dist "$dist"
  out=$(FM_PI_TUI_DIST="$dist" run_update "$w")
  assert_contains "$out" "firstmate: already current" "second update was not already current"
  assert_contains "$out" "pi-midline-slash: patched " \
    "already-current firstmate did not reapply a wiped Pi dist"
  assert_grep "isAtSlashCommandStart" "$dist/components/editor.js" \
    "already-current firstmate left the wiped dist unpatched"
  pass "fm-update.sh reapplies the Pi mid-line patch when firstmate updates or is current"
}

test_pi_midline_skip_does_not_block_update() {
  local w out
  w=$(new_world pi-midline-skip)
  bump_origin "$w" instr

  out=$(run_update "$w")
  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "pi-midline-slash: skipped: Pi tui dist not found" \
    "missing Pi dist did not print an honest skip"
  assert_contains "$out" "reread-firstmate: yes" "honest patch skip blocked the git update summary"
  pass "fm-update.sh continues when the Pi mid-line patch skips"
}

test_pi_midline_not_run_when_firstmate_skipped() {
  local w dist out
  w=$(new_world pi-midline-skipped-ff)
  dist="$w/pi-tui-dist"
  copy_clean_pi_tui_dist "$dist"
  bump_origin "$w" instr
  git -C "$w/main" checkout -q -b feature/wip

  out=$(FM_PI_TUI_DIST="$dist" run_update "$w")
  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" \
    "off-default firstmate skipped"
  assert_not_contains "$out" "pi-midline-slash:" \
    "skipped firstmate still ran the Pi mid-line patch"
  assert_grep "isAtStartOfMessage" "$dist/components/editor.js" \
    "skipped firstmate mutated the clean dist"
  pass "fm-update.sh does not patch Pi when firstmate itself is skipped"
}

test_pi_midline_fail_does_not_block_update() {
  local w dist out
  w=$(new_world pi-midline-fail)
  dist="$w/pi-tui-dist"
  mkdir -p "$dist/components"
  printf 'not a pi tui dist\n' > "$dist/components/editor.js"
  printf 'not a pi tui dist\n' > "$dist/autocomplete.js"
  printf 'not a pi tui dist\n' > "$dist/components/editor.d.ts"
  bump_origin "$w" instr

  out=$(FM_PI_TUI_DIST="$dist" run_update "$w")
  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "pi-midline-slash: failed: dist layout changed:" \
    "layout-changed dist did not print a fail"
  assert_contains "$out" "reread-firstmate: yes" "patch fail blocked the git update summary"
  grep -qx 'not a pi tui dist' "$dist/components/editor.js" \
    || fail "failed patch helper wrote the layout-changed dist"
  pass "fm-update.sh continues when the Pi mid-line patch fails"
}

test_updates_main_and_secondmate
test_prefers_upstream_without_push
test_configured_origin_overrides_upstream
test_empty_config_preserves_default_remote_preference
test_missing_configured_remote_refuses_update
test_malformed_update_remote_refuses_update
test_upstream_default_without_remote_head
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_secondmate_bad_update_remote_continues_fleet
test_pi_midline_patch_on_updated_and_already_current
test_pi_midline_skip_does_not_block_update
test_pi_midline_not_run_when_firstmate_skipped
test_pi_midline_fail_does_not_block_update

echo "# all fm-update tests passed"
