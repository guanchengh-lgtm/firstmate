#!/usr/bin/env bash
# Behavior tests for the read-only tasks-axi decision-ledger projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER="$ROOT/bin/fm-decision-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-ledger)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1 i day
  {
    printf '%s\n' '# Backlog' '' '## In flight'
    printf '%s\n' '- [ ] build-route - Build chosen route (repo: sample) (kind: ship) (since 2026-08-13)'
    printf '%s\n' '  decision=route-review' '  owner=cos' '  acceptance-test=route output matches fixture'
    printf '%s\n' '- [ ] build-without-decision - Ordinary build (repo: sample) (kind: ship) (since 2026-08-16)'
    printf '%s\n' '' '## Queued'
    printf '%s\n' '- [ ] choose-new - Choose new route (repo: sample) (kind: captain) (since 2026-08-16) (hold: captain choice pending) (hold-kind: captain)'
    printf '%s\n' '  acceptance-test=captain records route'
    printf '%s\n' '- [ ] choose-old - Choose old route (repo: sample) (kind: captain) (since 2026-08-10)'
    printf '%s\n' '- [ ] held-review - Review held choice (repo: sample) (kind: scout) (since 2026-08-12) (hold: captain review pending) (hold-kind: captain)'
    printf '%s\n' '- [ ] idea-row - Discuss optional colors (repo: sample) (kind: idea) (since 2026-08-16)'
    printf '%s\n' '  decision=color-review' '  owner=cos'
    printf '%s\n' '' '## Done'
    printf '%s\n' '- [x] decided-route - Record route decision (repo: sample) (kind: captain) (done 2026-08-14)'
    printf '%s\n' '  acceptance-test=dependent work is queued'
    printf '%s\n' '- [x] shipped-route - Ship route https://github.com/acme/sample/pull/42 (repo: sample) (kind: captain) (merged 2026-08-15)'
    printf '%s\n' '  owner=cos' '  acceptance-test=checks are green'
    i=1
    while [ "$i" -le 9 ]; do
      day=$(printf '%02d' "$i")
      printf -- '- [x] history-%02d - Historical decision %02d (repo: sample) (kind: captain) (done 2026-07-%s)\n' "$i" "$i" "$day"
      i=$((i + 1))
    done
  } > "$home/data/backlog.md"
  printf '%s\n' '| PI-001 | Product idea must stay private | unscheduled | data/report.md#Ideas |' \
    > "$home/data/product-ideas.md"
}

line_number() {  # <file> <fixed-string>
  grep -nF "$2" "$1" | head -1 | cut -d: -f1
}

test_render_contract_and_admission() {
  local home out backlog_before ideas_before backlog_after ideas_after open_new open_old decided shipped
  home=$(make_home render)
  write_fixture "$home"
  out="$home/data/ledger.md"
  backlog_before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  ideas_before=$(shasum -a 256 "$home/data/product-ideas.md" | awk '{print $1}')

  "$LEDGER" render --home "$home" --out "$out" --recent 2 \
    || fail "ledger render failed"

  [ "$(head -1 "$out")" = '| Decision | Owner | Status | Acceptance test | PR / artifact |' ] \
    || fail "ledger columns or order changed"
  [ "$(grep -c '^|' "$out")" -eq 7 ] \
    || fail "open rows plus bounded recent tail produced wrong row count"
  assert_contains "$(cat "$out")" '| Choose new route | captain | open | captain records route | - |' \
    "open captain decision was not rendered"
  assert_contains "$(cat "$out")" '| Review held choice | captain | open | - | - |' \
    "captain-held non-captain row was not rendered"
  assert_contains "$(cat "$out")" '| Record route decision | eng | decided | dependent work is queued | - |' \
    "resolved decision did not derive eng/decided"
  assert_contains "$(cat "$out")" '| Ship route | cos | shipped | checks are green | https://github.com/acme/sample/pull/42 |' \
    "shipped decision did not preserve owner override and PR"
  assert_no_grep 'Ordinary build' "$out" "ship work without decision provenance was admitted"
  assert_no_grep 'Discuss optional colors' "$out" "idea-kind row was admitted"
  assert_no_grep 'Product idea must stay private' "$out" "product-idea ledger was read"
  assert_no_grep 'Build chosen route' "$out" "bounded recent tail retained an older decided build"

  open_new=$(line_number "$out" 'Choose new route')
  open_old=$(line_number "$out" 'Choose old route')
  decided=$(line_number "$out" 'Record route decision')
  shipped=$(line_number "$out" 'Ship route')
  [ "$open_new" -lt "$open_old" ] || fail "open rows were not newest first"
  [ "$open_old" -lt "$decided" ] || fail "open rows did not sort before decided rows"
  [ "$decided" -lt "$shipped" ] || fail "decided rows did not sort before shipped rows"

  backlog_after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  ideas_after=$(shasum -a 256 "$home/data/product-ideas.md" | awk '{print $1}')
  [ "$backlog_before" = "$backlog_after" ] || fail "renderer mutated backlog state"
  [ "$ideas_before" = "$ideas_after" ] || fail "renderer touched product-ideas.md"
  pass "renderer enforces columns, admission, derivation, sorting, and read-only inputs"
}

test_default_tail_and_determinism() {
  local home first second
  home=$(make_home deterministic)
  write_fixture "$home"
  first="$home/data/first.md"
  second="$home/data/second.md"

  "$LEDGER" render --home "$home" --out "$first" || fail "first default render failed"
  "$LEDGER" render --home "$home" --out "$second" || fail "second default render failed"
  cmp -s "$first" "$second" || fail "identical backlog state produced different bytes"
  [ "$(grep -c '^|' "$first")" -eq 15 ] \
    || fail "default recent tail was not bounded to 10 rows"
  pass "renderer is byte-deterministic and defaults to a 10-row recent tail"
}

test_output_safety() {
  local home backlog_link ideas_link backlog_hardlink
  home=$(make_home safety)
  write_fixture "$home"
  if "$LEDGER" render --home "$home" --out "$home/data/backlog.md" > "$home/backlog.out" 2> "$home/backlog.err"; then
    fail "renderer overwrote backlog through --out"
  fi
  if "$LEDGER" render --home "$home" --out "$home/data/product-ideas.md" > "$home/ideas.out" 2> "$home/ideas.err"; then
    fail "renderer overwrote product ideas through --out"
  fi
  backlog_link="$home/data/backlog-link.md"
  ideas_link="$home/data/ideas-link.md"
  backlog_hardlink="$home/data/backlog-hardlink.md"
  ln -s backlog.md "$backlog_link"
  ln -s product-ideas.md "$ideas_link"
  ln "$home/data/backlog.md" "$backlog_hardlink"
  if "$LEDGER" render --home "$home" --out "$backlog_link" > "$home/backlog-link.out" 2> "$home/backlog-link.err"; then
    fail "renderer overwrote backlog through a symbolic-link output"
  fi
  if "$LEDGER" render --home "$home" --out "$ideas_link" > "$home/ideas-link.out" 2> "$home/ideas-link.err"; then
    fail "renderer overwrote product ideas through a symbolic-link output"
  fi
  if "$LEDGER" render --home "$home" --out "$backlog_hardlink" > "$home/backlog-hardlink.out" 2> "$home/backlog-hardlink.err"; then
    fail "renderer overwrote backlog through a hard-link output"
  fi
  pass "renderer refuses direct and linked protected output targets"
}

test_empty_backlog() {
  local home out
  home=$(make_home empty)
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  out="$home/data/ledger.md"
  "$LEDGER" render --home "$home" --out "$out" || fail "empty backlog render failed"
  [ "$(grep -c '^|' "$out")" -eq 2 ] || fail "empty backlog did not render a header-only table"
  pass "empty backlog renders a header-only table"
}

test_artifact_scheme_filter() {
  local home out rendered
  home=$(make_home artifact-schemes)
  {
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done'
    printf '%s\n' '- [x] secure-artifact - Publish evidence https://example.com/evidence (repo: sample) (kind: captain) (done 2026-08-16)'
    printf '%s\n' '- [x] insecure-artifact - Publish draft http://example.com/draft (repo: sample) (kind: captain) (done 2026-08-15)'
  } > "$home/data/backlog.md"
  out="$home/data/ledger.md"
  "$LEDGER" render --home "$home" --out "$out" || fail "artifact-scheme render failed"
  rendered=$(cat "$out")
  assert_contains "$rendered" '| Publish evidence | eng | shipped | - | https://example.com/evidence |' \
    "HTTPS artifact was not rendered"
  assert_contains "$rendered" '| Publish draft http://example.com/draft | eng | decided | - | - |' \
    "non-HTTPS URL was emitted as an artifact"
  pass "artifact column accepts HTTPS URLs and rejects other schemes"
}

test_render_contract_and_admission
test_default_tail_and_determinism
test_output_safety
test_empty_backlog
test_artifact_scheme_filter
