#!/usr/bin/env bash
# Behavior tests for grill-with-docs model-invocation + map-skill routing.
#
# User-facing contracts under test:
#   1. grill-with-docs is model-invocable (Claude Code skill frontmatter omits
#      disable-model-invocation / sets it false). That flag is the harness's
#      machine-facing eligibility bit for auto-invocation.
#   2. Its description names the live-map / resume edges and the two negatives
#      (not every unclear sentence; do not chart a map). The description field
#      is the intentional emitted interface the model reads when choosing a
#      skill — not body prose.
#   3. wayfinder's description is limited to the no-live-map edge and redirects
#      an existing map to grill-with-docs.
#   4. Workers may slash /grill-with-docs; worker briefs refuse /wayfinder.
#      Exercised through bin/fm-brief.sh --check-worker (spawn-time brief lint).
#   5. The in-repo Codex openai.yaml for grill-with-docs stays dormant
#      (allow_implicit_invocation: false). That yaml is not the Codex copy of
#      the skill; dormancy is the recorded decision for this sitting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gwd-inv)

# Parse Claude-style SKILL.md YAML frontmatter into KEY=VALUE lines.
# Handles plain scalars, booleans, and folded `>-` / `>` blocks used by these
# skills. Output is a normalized semantic model, not a raw file snapshot.
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
my ($key, $folded, @acc);
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
  if (defined $key && $line =~ /^(?:\s{2,}|\t+)\S/) {
    push @acc, $line;
    next;
  }
  $flush->();
  next if $line =~ /^\s*$/ || $line =~ /^\s*#/;
  if ($line =~ /^([A-Za-z0-9_-]+):\s*(.*)$/) {
    my ($k, $v) = ($1, $2);
    if ($v eq '>' || $v eq '>-' || $v eq '|' || $v eq '|-') {
      $key = $k;
      $folded = 1;
      @acc = ();
    } elsif ($v eq '') {
      $key = $k;
      $folded = 0;
      @acc = ();
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

# Truthy only when disable-model-invocation is explicitly true.
is_model_invocable() {  # <kv-file>
  local raw
  raw=$(frontmatter_get "$1" disable-model-invocation)
  case "${raw:-}" in
    true|True|TRUE|yes|Yes|YES|1) return 1 ;;
    *) return 0 ;;
  esac
}

test_grill_with_docs_is_model_invocable() {
  local kv desc
  kv="$TMP_ROOT/grill-with-docs.kv"
  parse_skill_frontmatter "$ROOT/.agents/skills/grill-with-docs/SKILL.md" > "$kv" \
    || fail "grill-with-docs SKILL.md frontmatter failed to parse"

  [ "$(frontmatter_get "$kv" name)" = "grill-with-docs" ] \
    || fail "grill-with-docs frontmatter name mismatch"

  is_model_invocable "$kv" \
    || fail "grill-with-docs is not model-invocable (disable-model-invocation still blocks auto-invocation)"

  desc=$(frontmatter_get "$kv" description)
  [ -n "$desc" ] || fail "grill-with-docs description is empty"

  # Description is the intentional agent-facing routing interface.
  printf '%s' "$desc" | grep -qi 'live map' \
    || fail "grill-with-docs description missing live-map edge"
  printf '%s' "$desc" | grep -Eqi 'unspecified|open' \
    || fail "grill-with-docs description missing open/unspecified items edge"
  printf '%s' "$desc" | grep -qi 'resume' \
    || fail "grill-with-docs description missing captain-resume edge"
  printf '%s' "$desc" | grep -Eqi 'unclear sentence|every unclear' \
    || fail "grill-with-docs description missing 'do not start on every unclear sentence' guard"
  printf '%s' "$desc" | grep -Eqi 'do not chart|not chart a map' \
    || fail "grill-with-docs description missing 'do not chart a map' guard"
  printf '%s' "$desc" | grep -qi 'wayfinder' \
    || fail "grill-with-docs description must name wayfinder as the charting skill"
  printf '%s' "$desc" | grep -Eqi 'worker' \
    || fail "grill-with-docs description missing workers-may-slash signal"

  pass "grill-with-docs: model-invocable with live-map/resume routing description"
}

test_wayfinder_description_is_no_live_map_only() {
  local kv desc
  kv="$TMP_ROOT/wayfinder.kv"
  parse_skill_frontmatter "$ROOT/.agents/skills/wayfinder/SKILL.md" > "$kv" \
    || fail "wayfinder SKILL.md frontmatter failed to parse"

  [ "$(frontmatter_get "$kv" name)" = "wayfinder" ] \
    || fail "wayfinder frontmatter name mismatch"

  desc=$(frontmatter_get "$kv" description)
  [ -n "$desc" ] || fail "wayfinder description is empty"

  printf '%s' "$desc" | grep -Eqi 'no live map|live map already exists' \
    || fail "wayfinder description missing no-live-map edge"
  printf '%s' "$desc" | grep -qi 'grill-with-docs' \
    || fail "wayfinder description must redirect existing maps to grill-with-docs"

  pass "wayfinder: description limited to no-live-map edge; redirects to grill-with-docs"
}

test_worker_brief_allows_grill_with_docs_refuses_wayfinder() {
  local brief out status

  brief="$TMP_ROOT/worker-gwd.md"
  printf '# Task\nInvoke /grill-with-docs before coding.\n\n# Setup\nfixture\n' > "$brief"
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker ship "$brief" >/dev/null 2>&1 \
    || fail "worker brief check refused allowed /grill-with-docs"
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker scout "$brief" >/dev/null 2>&1 \
    || fail "scout worker brief check refused allowed /grill-with-docs"

  brief="$TMP_ROOT/worker-wayfinder.md"
  printf '# Task\nInvoke /wayfinder before coding.\n\n# Setup\nfixture\n' > "$brief"
  out=$(FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker ship "$brief" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "worker brief check accepted forbidden /wayfinder"
  assert_contains "$out" "/wayfinder" "wayfinder refusal did not name /wayfinder"

  out=$(FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker scout "$brief" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "scout worker brief check accepted forbidden /wayfinder"
  assert_contains "$out" "/wayfinder" "scout wayfinder refusal did not name /wayfinder"

  # Plain name remains allowed (slash is the invocation signal).
  brief="$TMP_ROOT/worker-plain.md"
  printf '# Task\nName wayfinder as optional feeder; do not invoke it.\n\n# Setup\nfixture\n' > "$brief"
  FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" --check-worker ship "$brief" >/dev/null 2>&1 \
    || fail "worker brief check confused plain name wayfinder with slash invocation"

  pass "worker brief: allows /grill-with-docs, refuses /wayfinder, permits plain names"
}

test_codex_yaml_stays_dormant() {
  local yaml raw
  yaml="$ROOT/.agents/skills/grill-with-docs/agents/openai.yaml"
  assert_present "$yaml" "grill-with-docs openai.yaml missing"

  # Semantic policy bit: Codex implicit invocation stays off this sitting.
  raw=$(awk '
    BEGIN { in_policy = 0 }
    /^policy:[[:space:]]*$/ { in_policy = 1; next }
    in_policy && /^[^[:space:]#]/ { in_policy = 0 }
    in_policy {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^allow_implicit_invocation:[[:space:]]*/) {
        sub(/^allow_implicit_invocation:[[:space:]]*/, "", line)
        gsub(/[[:space:]]/, "", line)
        print line
        exit
      }
    }
  ' "$yaml")
  [ "$raw" = "false" ] \
    || fail "grill-with-docs openai.yaml must keep allow_implicit_invocation: false (got: ${raw:-<missing>})"

  pass "grill-with-docs: Codex openai.yaml remains dormant (allow_implicit_invocation false)"
}

test_grill_with_docs_is_model_invocable
test_wayfinder_description_is_no_live_map_only
test_worker_brief_allows_grill_with_docs_refuses_wayfinder
test_codex_yaml_stays_dormant
