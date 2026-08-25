#!/usr/bin/env bash
# Outside-voice backpass apply contract for AGENTS.md + extracted supervisor skills.
#
# User-facing contracts under test (locked by ov-backpass-edits-apply-2026-08-25):
#   1. worker-control and firstmate-no-mistakes are supervisor-only skill packages:
#      frontmatter carries user-invocable: false and metadata.internal=true, and
#      descriptions identify them as agent-only Firstmate procedures (not a second
#      public no-mistakes driver).
#   2. bin/fm-brief.sh --check-worker refuses worker slash-invocation of those
#      firstmate-only skills (the real spawn-time consumer of user-invocable).
#   3. AGENTS.md is the always-loaded operating contract. After option A apply it
#      must still expose the report's required residual always-on facts as a
#      structured section model: section 1 hard-rule titles, section 4 quota
#      load trigger, section 8 away-mode marker bytes + wake lines, section 13
#      residual skill list, and captain-instruction anti-rigid / before-acting
#      clauses. Companion skill ownership lines must point at text that still
#      exists rather than dangling at deleted homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ov-backpass)

# Parse skill frontmatter into KEY=VALUE lines, including one-level nested maps
# such as metadata.internal. Output is a normalized semantic model.
parse_skill_frontmatter() {
  local path=$1
  perl - "$path" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $fh, '<', $path or die "$path: $!\n";
my $text = do { local $/; <$fh> };
close $fh;

die "$path: missing opening frontmatter fence\n" unless $text =~ /\A---\r?\n/;
my $rest = substr($text, $+[0]);
my $end = index($rest, "\n---\n");
$end = index($rest, "\n---\r\n") if $end < 0;
die "$path: missing closing frontmatter fence\n" if $end < 0;
my $body = substr($rest, 0, $end);

my %data;
my ($key, $folded, $map_prefix, @acc);
my $flush = sub {
  return unless defined $key;
  my $val;
  if ($folded) {
    $val = join(' ', grep { length } map { s/^\s+|\s+$//gr } @acc);
  } else {
    $val = @acc ? $acc[0] : '';
  }
  $data{$key} = $val;
  $key = undef;
  $folded = 0;
  @acc = ();
};

for my $line (split /\r?\n/, $body) {
  if (defined $map_prefix && $line =~ /^(?:\s{2,}|\t+)([A-Za-z0-9_-]+):\s*(.*)$/) {
    $flush->();
    my ($nk, $nv) = ($1, $2);
    $data{"$map_prefix.$nk"} = $nv;
    next;
  }
  if (defined $key && $line =~ /^(?:\s{2,}|\t+)\S/) {
    push @acc, $line;
    next;
  }
  $flush->();
  $map_prefix = undef;
  next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
  if ($line =~ /^([A-Za-z0-9_-]+):\s*(.*)$/) {
    my ($k, $v) = ($1, $2);
    if ($v eq '>' || $v eq '>-' || $v eq '|' || $v eq '|-') {
      $key = $k;
      $folded = 1;
      @acc = ();
    } elsif ($v eq '') {
      # Nested map parent (e.g. metadata:)
      $map_prefix = $k;
    } else {
      $data{$k} = $v;
    }
    next;
  }
  die "$path: unparseable frontmatter line: $line\n";
}
$flush->();

for my $k (sort keys %data) {
  my $v = $data{$k};
  $v =~ s/\n/ /g;
  print "$k=$v\n";
}
PERL
}

frontmatter_get() {  # <kv-file> <key>
  local kv=$1 key=$2
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$kv"
}

# Split AGENTS.md into a section index: heading slug -> body path under out_dir.
# Treats the owned operating contract as a structured document model.
index_agents_sections() {
  local agents=$1 out_dir=$2
  mkdir -p "$out_dir"
  perl - "$agents" "$out_dir" <<'PERL'
use strict;
use warnings;
my ($path, $out) = @ARGV;
open my $fh, '<', $path or die "$path: $!\n";
my @lines = <$fh>;
close $fh;
my ($cur, @body);
my $flush = sub {
  return unless defined $cur;
  my $file = "$out/$cur";
  open my $o, '>', $file or die "$file: $!\n";
  print {$o} @body;
  close $o;
  @body = ();
};
for my $line (@lines) {
  if ($line =~ /^##\s+(.*\S)\s*$/) {
    $flush->();
    my $title = $1;
    $title =~ s/[^\w.-]+/_/g;
    $cur = $title;
    next;
  }
  if ($line =~ /^#\s+/ && !defined $cur) {
    $cur = 'preamble';
    next;
  }
  push @body, $line if defined $cur;
}
$flush->();
PERL
}

assert_section_has() {  # <body-file> <fixed-string> <msg>
  local body=$1 needle=$2 msg=$3
  grep -F -- "$needle" "$body" >/dev/null 2>&1 || fail "$msg"
}

test_supervisor_skills_are_internal_not_public() {
  local skill kv desc name
  for skill in worker-control firstmate-no-mistakes; do
    kv="$TMP_ROOT/${skill}.kv"
    parse_skill_frontmatter "$ROOT/.agents/skills/$skill/SKILL.md" > "$kv" \
      || fail "$skill SKILL.md frontmatter failed to parse"

    name=$(frontmatter_get "$kv" name)
    [ "$name" = "$skill" ] || fail "$skill frontmatter name mismatch (got: ${name:-<missing>})"

    [ "$(frontmatter_get "$kv" user-invocable)" = "false" ] \
      || fail "$skill must set user-invocable: false (supervisor procedure, not captain slash skill)"

    [ "$(frontmatter_get "$kv" metadata.internal)" = "true" ] \
      || fail "$skill must set metadata.internal: true for installers"

    desc=$(frontmatter_get "$kv" description)
    [ -n "$desc" ] || fail "$skill description is empty"
    printf '%s' "$desc" | grep -Eqi 'agent-only|Agent-only' \
      || fail "$skill description must identify agent-only Firstmate procedure"
  done

  kv="$TMP_ROOT/firstmate-no-mistakes.kv"
  desc=$(frontmatter_get "$kv" description)
  printf '%s' "$desc" | grep -Eqi 'Firstmate|firstmate' \
    || fail "firstmate-no-mistakes description must name Firstmate supervisor role"
  printf '%s' "$desc" | grep -Eqi 'validat' \
    || fail "firstmate-no-mistakes description must stay on supervisor validation custody"

  # Body must cross-reference public no-mistakes for sync mechanics rather than
  # restating the driver loop (same word, different job).
  assert_grep "public \`no-mistakes\` skill" \
    "$ROOT/.agents/skills/firstmate-no-mistakes/SKILL.md" \
    "firstmate-no-mistakes must cross-reference the public no-mistakes skill for sync mechanics"
  assert_grep "recover_custody" \
    "$ROOT/.agents/skills/firstmate-no-mistakes/SKILL.md" \
    "firstmate-no-mistakes must keep recover_custody guarded-recovery clause"

  # worker-control must forbid key AND text lifecycle paths and link operator docs.
  assert_grep "key or text paths" \
    "$ROOT/.agents/skills/worker-control/SKILL.md" \
    "worker-control must forbid fm-send key and text lifecycle paths"
  assert_grep "docs/agent-control.md" \
    "$ROOT/.agents/skills/worker-control/SKILL.md" \
    "worker-control must link docs/agent-control.md"

  pass "supervisor skills: internal frontmatter + agent-only descriptions + required body contracts"
}

test_worker_brief_refuses_supervisor_skill_slash() {
  local skill brief out status
  for skill in worker-control firstmate-no-mistakes; do
    brief="$TMP_ROOT/worker-${skill}.md"
    printf '# Task\nInvoke /%s before coding.\n\n# Setup\nfixture\n' "$skill" > "$brief"
    out=$(FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker ship "$brief" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "worker brief check accepted forbidden /$skill"
    assert_contains "$out" "/$skill" "refusal for /$skill did not name the skill"
    assert_contains "$out" "REFUSED" "refusal for /$skill missing REFUSED marker"

    out=$(FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker scout "$brief" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "scout worker brief check accepted forbidden /$skill"
    assert_contains "$out" "/$skill" "scout refusal for /$skill did not name the skill"
  done

  # Plain name remains allowed (slash is the invocation signal).
  brief="$TMP_ROOT/worker-plain-supervisor.md"
  printf '# Task\nCoordinate with firstmate-no-mistakes custody; do not slash it.\n\n# Setup\nfixture\n' > "$brief"
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker ship "$brief" >/dev/null 2>&1 \
    || fail "worker brief check confused plain firstmate-no-mistakes name with slash invocation"

  pass "worker brief: refuses /worker-control and /firstmate-no-mistakes; permits plain names"
}

test_agents_contract_keeps_locked_always_on_facts() {
  local agents idx body
  agents="$ROOT/AGENTS.md"
  idx="$TMP_ROOT/agents-sections"
  index_agents_sections "$agents" "$idx"

  # Section 1 hard rules - titles are the safety boundary identity.
  body="$idx/1._Identity_and_prime_directives"
  assert_present "$body" "AGENTS.md missing section 1 Identity and prime directives"
  assert_section_has "$body" "Never write to a project." "section 1 lost project-write ban"
  assert_section_has "$body" "Never merge a PR without the captain" "section 1 lost merge-authority ban"
  assert_section_has "$body" "Never tear down unlanded work." "section 1 lost unlanded-work ban"
  assert_section_has "$body" "Crewmates never address the captain." "section 1 lost crewmate-address ban"
  assert_section_has "$body" "Report outcomes faithfully." "section 1 lost faithful-report rule"
  assert_section_has "$body" "firstmate-coding-guidelines" \
    "section 1 must require loading firstmate-coding-guidelines before shared tracked edits"

  # e1 restorations in section 2
  body="$idx/2._Layout_and_state"
  assert_present "$body" "AGENTS.md missing section 2"
  assert_section_has "$body" "scripts still come from the tracked code root" \
    "e1 restoration missing: scripts from tracked code root"
  assert_section_has "$body" "metadata.internal=true" \
    "e1 restoration missing: internal skills metadata convention"

  # e2 restorations in section 3
  body=$(ls "$idx"/3._Session_start* 2>/dev/null | head -1)
  [ -n "$body" ] || fail "AGENTS.md missing section 3 Session start"
  assert_section_has "$body" "If the harness shows only a preview and persists the full output to a file, read that file before acting." \
    "e2 restoration missing: read full digest file when harness previews"
  assert_section_has "$body" "An \`ABSENT\` context file means the built-in default" \
    "e2 restoration missing: ABSENT semantics"
  assert_section_has "$body" "rebuild an absent or stale project registry from the clones before dispatch." \
    "e2 restoration missing: registry rebuild before dispatch"

  # e3: section 4 keeps load trigger; safety rules must have an owner (skill).
  body=$(ls "$idx"/4._* 2>/dev/null | head -1)
  [ -n "$body" ] || fail "AGENTS.md missing section 4"
  assert_section_has "$body" "load \`quota-array-dispatch\`" \
    "section 4 missing quota-array-dispatch load trigger"
  assert_grep "this skill owns malformed-config refusal, every-candidate accounting, and strongest-reasoning and tie safety rules" \
    "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" \
    "e3 rewrite failed: quota safety rules have no owner after section 4 cut"
  assert_grep "Malformed configuration is an actionable error" \
    "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" \
    "quota-array-dispatch missing malformed-config refusal body"
  assert_grep "Account for every candidate visibly" \
    "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" \
    "quota-array-dispatch missing every-candidate accounting body"
  assert_grep "Genuine ties: stop and report every tied candidate" \
    "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" \
    "quota-array-dispatch missing tie-break body"

  # e6/e7 inline stubs
  body=$(ls "$idx"/7._* 2>/dev/null | head -1)
  [ -n "$body" ] || fail "AGENTS.md missing section 7"
  assert_section_has "$body" "Load \`worker-control\` before steering" \
    "missing worker-control inline trigger"
  assert_section_has "$body" "Load \`firstmate-no-mistakes\`" \
    "missing firstmate-no-mistakes inline trigger"
  assert_section_has "$body" "Builder and verifier never share a context, and firstmate never drives a worker-owned run itself." \
    "e7 restoration missing: isolation / never-drive-worker-run inline line"

  # e8 rewrites in section 8
  body=$(ls "$idx"/8._* 2>/dev/null | head -1)
  [ -n "$body" ] || fail "AGENTS.md missing section 8"
  assert_section_has "$body" "FM_OPERATIONAL_PREFIX" \
    "e8 rewrite missing away-mode marker name"
  assert_section_has "$body" "U+2063" \
    "e8 rewrite missing U+2063 marker byte"
  assert_section_has "$body" "FIRSTMATE_OP:" \
    "e8 rewrite missing FIRSTMATE_OP marker text"
  assert_section_has "$body" "bin/fm-inbox.sh drain --ack" \
    "e8 rewrite missing inbox ack wake line"
  assert_section_has "$body" "On a heartbeat, review the whole fleet" \
    "e8 rewrite missing heartbeat fleet review"
  assert_section_has "$body" "Leave a \`paused:\` worker alone" \
    "e8 rewrite missing paused vs blocked reaction"

  # e9 restorations
  body=$(ls "$idx"/9._* 2>/dev/null | head -1)
  [ -n "$body" ] || fail "AGENTS.md missing section 9"
  assert_section_has "$body" "Private evidence reports may retain exact identifiers" \
    "e9 restoration missing private-report carve-out"
  assert_section_has "$body" "evidence-first form for objections" \
    "e9 restoration missing evidence-first objections clause"

  # e10 restoration
  body=$(ls "$idx"/10._* 2>/dev/null | head -1)
  [ -n "$body" ] || fail "AGENTS.md missing section 10"
  assert_section_has "$body" "Inspect the current note before replacing it" \
    "e10 restoration missing inspect-before-replace note hygiene"

  # e12 residual always-on trigger list (do not delete section 13 wholesale)
  body=$(ls "$idx"/13._* 2>/dev/null | head -1)
  [ -n "$body" ] || fail "e12 rewrite failed: section 13 residual catalog missing entirely"
  assert_section_has "$body" "firstmate-orca" "section 13 residual list missing firstmate-orca"
  assert_section_has "$body" "process-event-sources" "section 13 residual list missing process-event-sources"
  assert_section_has "$body" "before arming a long-polling source" \
    "section 13 missing process-event-sources arming trigger"
  assert_section_has "$body" "firstmate-codexapp" "section 13 residual list missing firstmate-codexapp"
  assert_section_has "$body" "firstmate-coding-guidelines" \
    "section 13 residual list missing firstmate-coding-guidelines"

  # e13 captain instruction precedence
  body=$(ls "$idx"/Captain_instruction_precedence 2>/dev/null | head -1)
  [ -n "$body" ] || fail "AGENTS.md missing Captain instruction precedence section"
  assert_section_has "$body" "clarify ambiguous scope before acting" \
    "e13 rewrite missing before-acting clarification"
  assert_section_has "$body" "a conflicting Firstmate-written rule must not block it" \
    "e13 rewrite missing anti-rigid-block clause"

  pass "AGENTS.md contract: locked always-on facts and restorations present"
}

test_companion_cross_references_point_at_live_text() {
  # firstmate-coding-guidelines: away-mode stub still models section 8 marker facts;
  # trigger hygiene accepts operating-section OR residual section 13.
  assert_grep "section 8's away-mode contract" \
    "$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md" \
    "coding-guidelines lost section 8 away-mode stub model"
  assert_grep "or in section 13 when no operating section fits" \
    "$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md" \
    "coding-guidelines must allow residual section 13 triggers after e12"

  # Prove the cross-ref targets still exist in AGENTS.md.
  assert_grep "FM_OPERATIONAL_PREFIX" "$ROOT/AGENTS.md" \
    "coding-guidelines section 8 cross-ref dangles: marker format missing from AGENTS.md"
  assert_grep "## 13. Agent-only reference skills" "$ROOT/AGENTS.md" \
    "coding-guidelines section 13 cross-ref dangles: residual catalog heading missing"

  # bootstrap-diagnostics: TANGLE guard must not cite deleted section 8 tangle prose.
  if grep -F "section 8 explains why this guard exists" \
    "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md" >/dev/null 2>&1; then
    fail "bootstrap-diagnostics still cites deleted section 8 tangle rationale"
  fi
  assert_grep "section 1's unlanded-work rule" \
    "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md" \
    "bootstrap-diagnostics TANGLE line must point at section 1 unlanded-work owner"
  assert_grep "Never tear down unlanded work." "$ROOT/AGENTS.md" \
    "bootstrap-diagnostics section 1 cross-ref dangles: unlanded-work rule missing"

  # quota-array-dispatch ownership split matches section 4 after e3 move.
  assert_grep "section 4 owns the always-loaded intake boundary and load trigger" \
    "$ROOT/.agents/skills/quota-array-dispatch/SKILL.md" \
    "quota-array-dispatch must keep section 4 intake/load-trigger ownership line"
  assert_grep "load \`quota-array-dispatch\`" "$ROOT/AGENTS.md" \
    "quota-array-dispatch section 4 cross-ref dangles: load trigger missing from AGENTS.md"

  pass "companion skills: cross-references resolve to live AGENTS.md text"
}

test_style_plain_dash_one_sentence_and_no_en_dash() {
  # Style gate for the applied operating contract and new supervisor skills.
  python3 - "$ROOT/AGENTS.md" \
    "$ROOT/.agents/skills/worker-control/SKILL.md" \
    "$ROOT/.agents/skills/firstmate-no-mistakes/SKILL.md" <<'PY' \
    || fail "style gate failed on applied contract surfaces"
import re
import sys
from pathlib import Path

en_dash = "\u2013"
em_dash = "\u2014"
errors = []
for path in map(Path, sys.argv[1:]):
    text = path.read_text()
    if en_dash in text or em_dash in text:
        errors.append(f"{path}: contains en dash or em dash; plain dash required")
    if path.name != "AGENTS.md":
        continue
    fence = False
    for i, line in enumerate(text.splitlines(), 1):
        if line.startswith("```"):
            fence = not fence
            continue
        if fence or not line.strip() or line.startswith("#") or line.lstrip().startswith("|"):
            continue
        if re.search(r'[.!?]["\']?\s+[A-Z`]', line):
            errors.append(f"{path}:{i}: multi-sentence physical line: {line}")
if errors:
    sys.stderr.write("\n".join(errors) + "\n")
    sys.exit(1)
PY

  pass "style: plain dash and one-sentence-per-line on applied contract surfaces"
}

test_supervisor_skills_are_internal_not_public
test_worker_brief_refuses_supervisor_skill_slash
test_agents_contract_keeps_locked_always_on_facts
test_companion_cross_references_point_at_live_text
test_style_plain_dash_one_sentence_and_no_en_dash
