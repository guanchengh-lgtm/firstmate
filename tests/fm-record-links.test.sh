#!/usr/bin/env bash
# Behavior tests for bin/fm-record-links.py through the public CLI only.
# Fixtures are scratch Record trees. Tests never assert implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINKS="$ROOT/bin/fm-record-links.py"
TMP_ROOT=$(fm_test_tmproot fm-record-links)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

run_links() {
  set +e
  OUT=$(python3 "$LINKS" "$@" 2>&1)
  RC=$?
  set -e
}

write_file() {
  local path=$1
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

out_dir() {
  printf '%s\n' "$TMP_ROOT/$(basename "$1")-out"
}

copy_record() {
  local src=$1 dest=$2
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$src" "$dest"
}

seed_base() {
  local root=$1
  mkdir -p "$root/decisions" "$root/playbook" "$root/knowledge-system-wayfinder/tickets" \
    "$root/other" "$root/task-alpha" "$root/wiki" "$root/raw" "$root/copied" \
    "$root/archive" "$root/graphify-out" "$root/fixtures/sample"
  write_file "$root/captain.md" "# Captain" "Fleet memory."
  write_file "$root/decisions/old.md" "# Old decision" "Prior accepted choice."
  write_file "$root/other/report.md" "# Other report" "Cited source."
  write_file "$root/knowledge-system-wayfinder/CONTEXT.md" "# CONTEXT" "Glossary anchor."
  write_file "$root/playbook/example.md" "# Playbook" "How to write."
  write_file "$root/task-alpha/brief.md" "# Task" "Implement the widget."
  write_file "$root/task-alpha/report.md" "# Report" "The widget shipped."
}

class_of() {
  python3 - "$1" "$2" <<'PY'
import json, sys
manifest, path = sys.argv[1], sys.argv[2]
data = json.load(open(manifest, encoding="utf-8"))
for row in data["files"]:
    if row["path"] == path:
        print(row["classification"])
        raise SystemExit(0)
raise SystemExit("missing %s" % path)
PY
}

json_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' "$1" "$2"
}

test_help_prints_header() {
  run_links --help
  expect_code 0 "$RC" "help exit"
  assert_contains "$OUT" "Footer grammar" "help omitted footer grammar"
  assert_contains "$OUT" "propose --root" "help omitted propose"
  assert_contains "$OUT" "Classification is first-match" "help omitted classification"
  pass "fm-record-links.py: --help prints the header contract"
}

test_usage_exits_two() {
  run_links
  expect_code 2 "$RC" "missing command"
  run_links lint --root "$TMP_ROOT/missing-json"
  expect_code 2 "$RC" "lint without --json"
  pass "fm-record-links.py: invalid invocation exits 2"
}

test_classify_authored_generated_raw_active_unknown() {
  local rec out
  rec="$TMP_ROOT/g1"
  seed_base "$rec"
  write_file "$rec/wiki/page.md" "# Generated" "wiki page"
  write_file "$rec/graphify-out/view.md" "# View" "generated"
  write_file "$rec/raw/clip.md" "# Clip" "raw clip"
  write_file "$rec/copied/AGENTS.md" "# Copied" "copied agents"
  write_file "$rec/archive/old.md" "# Archive" "archived"
  write_file "$rec/fixtures/sample/note.md" "# Fixture" "fixture"
  write_file "$rec/AGENTS.md" "# Agents" "copied fragment"
  write_file "$rec/backlog.md" "- [ ] item"
  write_file "$rec/mystery.md" "# Mystery" "unknown owner"
  write_file "$rec/live-task/report.md" "# Live" "in flight"
  mkdir -p "$rec/../state/live-task"
  printf 'working: implementing\n' > "$rec/../state/live-task/status"
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g1 propose"
  [ "$(class_of "$out/manifest.json" "task-alpha/report.md")" = eligible ] \
    || fail "report.md was not eligible"
  [ "$(class_of "$out/manifest.json" "decisions/old.md")" = eligible ] \
    || fail "decision was not eligible"
  [ "$(class_of "$out/manifest.json" "wiki/page.md")" = generated ] \
    || fail "wiki was not generated"
  [ "$(class_of "$out/manifest.json" "raw/clip.md")" = raw ] \
    || fail "raw clip was not raw"
  [ "$(class_of "$out/manifest.json" "AGENTS.md")" = raw ] \
    || fail "AGENTS.md was not raw"
  [ "$(class_of "$out/manifest.json" "backlog.md")" = owner-exempt ] \
    || fail "backlog was not owner-exempt"
  [ "$(class_of "$out/manifest.json" "live-task/report.md")" = active-writer ] \
    || fail "live task was not active-writer"
  [ "$(class_of "$out/manifest.json" "mystery.md")" = needs-review ] \
    || fail "mystery was not needs-review"
  pass "fm-record-links.py: classification covers authored, generated, raw, active, and unknown"
}

test_citations_resolve_and_reject_fakes() {
  local rec out
  rec="$TMP_ROOT/g2"
  seed_base "$rec"
  write_file "$rec/task-cite/report.md" \
    "# Cite mix" \
    "See \`data/other/report.md\` and [old](../decisions/old.md)." \
    "Also [[knowledge-system-wayfinder/CONTEXT.md]] and playbook/example.md." \
    "Missing: \`data/absent/report.md\`." \
    "Outside: \`/tmp/outside.md\`." \
    "Standalone \`task-alpha\` only." \
    '```' \
    "Fake: [[decisions/old.md]]" \
    '```' \
    "Do not cite \`data/captain.md\`."
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g2 propose"
  python3 - "$out/manifest.json" <<'PY' || fail "g2 citation contract failed"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
prop = next(row for row in data["proposals"] if row["path"] == "task-cite/report.md")
targets = {(edge["key"], edge["target"]) for edge in prop["edges"]}
assert ("cites", "other/report.md") in targets, targets
assert ("cites", "decisions/old.md") in targets, targets
assert ("cites", "knowledge-system-wayfinder/CONTEXT.md") in targets, targets
assert ("cites", "playbook/example.md") in targets, targets
assert ("cites", "captain.md") not in targets, targets
assert ("cites", "decisions/old.md") in targets
unresolved = {row["token"] for row in data["unresolved"]}
assert any("absent/report.md" in token for token in unresolved), unresolved
assert any("standalone id" in row["reason"] for row in data["ambiguous_ids"]), data["ambiguous_ids"]
questions = " ".join(row["why"] for row in prop["questions"])
assert "do-not-cite" in questions or "do-not-cite passage" in questions, questions
PY
  pass "fm-record-links.py: path, markdown, wiki, outside, missing, and fenced citations classify"
}

test_cites_relates_supersedes_and_ambiguous_amendment() {
  local rec out
  rec="$TMP_ROOT/g3"
  seed_base "$rec"
  write_file "$rec/decisions/replace.md" \
    "# Replacement" \
    "Supersedes: data/decisions/old.md" \
    "This is the later accepted form."
  write_file "$rec/decisions/amended.md" \
    "# Amended twice" \
    "**AMENDED 2026-08-22 later.** This supersedes \`data/decisions/old.md\` for wait policy." \
    "" \
    "**AMENDED 2026-08-22.** Another same-day change without a unique latest."
  write_file "$rec/decisions/clause.md" \
    "# Clause" \
    "Supersedes: the quoted wait options, not a document."
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g3 propose"
  python3 - "$out/manifest.json" <<'PY' || fail "g3 relation contract failed"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
by = {row["path"]: row for row in data["proposals"]}
rep = next(edge["target"] for edge in by["decisions/replace.md"]["edges"] if edge["key"] == "supersedes")
assert rep == "decisions/old.md", by["decisions/replace.md"]["edges"]
super_auto = [edge for edge in by["decisions/amended.md"]["edges"] if edge["key"] == "supersedes"]
assert super_auto == [], super_auto
assert data["partial_replacements"], data["partial_replacements"]
brief = by["task-alpha/brief.md"]
rel = {edge["target"] for edge in brief["edges"] if edge["key"] == "relates"}
assert "task-alpha/report.md" in rel, brief["edges"]
PY
  pass "fm-record-links.py: cites, relates, supersedes, and ambiguous amendments"
}

test_duplicate_self_cycle_shadow_slug() {
  local rec out
  rec="$TMP_ROOT/g4"
  seed_base "$rec"
  write_file "$rec/decisions/self.md" \
    "# Self" \
    "Supersedes: data/decisions/self.md"
  write_file "$rec/decisions/a.md" \
    "# A" \
    "Supersedes: data/decisions/b.md"
  write_file "$rec/decisions/b.md" \
    "# B" \
    "Supersedes: data/decisions/a.md"
  mkdir -p "$rec/shadow-src/other"
  write_file "$rec/shadow-src/other/report.md" "# Local other" "shadow"
  write_file "$rec/shadow-src/report.md" \
    "# Shadow source" \
    "See [[other/report.md]]."
  write_file "$rec/knowledge-system-wayfinder/context.md" "# lower context" "slug pair"
  write_file "$rec/dup-a.md" \
    "---" \
    'id: shared-id' \
    'date: "2026-09-07"' \
    "type: report" \
    "status: open" \
    "---" \
    "# Dup A"
  write_file "$rec/dup-b.md" \
    "---" \
    'id: shared-id' \
    'date: "2026-09-07"' \
    "type: report" \
    "status: open" \
    "---" \
    "# Dup B"
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g4 propose"
  python3 - "$out/manifest.json" <<'PY' || fail "g4 graph contract failed"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
by = {row["path"]: row for row in data["proposals"]}
self_edges = [edge for edge in by["decisions/self.md"]["edges"] if edge["key"] == "supersedes"]
assert self_edges == [], self_edges
assert data["cycles"], data["cycles"]
cycle_paths = {"decisions/a.md", "decisions/b.md"}
for path in cycle_paths:
    kept = [edge for edge in by[path]["edges"] if edge["key"] == "supersedes"]
    assert kept == [], kept
    assert by[path]["proposed_footer"].startswith("Related: supersedes: none;"), by[path]
stale = [
    row for row in data["candidates"]
    if row["path"] in cycle_paths and row["key"] == "supersedes"
]
assert stale == [], stale
asked = {
    row["path"] for row in data["candidates"]
    if row["confidence"] == "question" and row["reason"] == "supersession cycle"
}
assert asked == cycle_paths, asked
assert data["path_shadows"], data["path_shadows"]
assert data["slug_collisions"], data["slug_collisions"]
lint = json.loads(open(sys.argv[1], encoding="utf-8").read())
PY
  run_links lint --root "$rec" --json
  expect_code 0 "$RC" "g4 lint"
  python3 -c 'import json,sys; data=json.loads(sys.stdin.read()); assert data["status"]=="ok"; kinds={row["kind"] for row in data["findings"]}; assert "duplicate-id" in kinds or any("shared-id" in row["detail"] for row in data["findings"]), data["findings"]' <<< "$OUT" \
    || fail "g4 lint missed duplicate ids"
  pass "fm-record-links.py: self, cycle, shadow, slug, and duplicate id stay report-only"
}

test_existing_footer_none_stable_rerun() {
  local rec out first second
  rec="$TMP_ROOT/g5"
  seed_base "$rec"
  write_file "$rec/already/report.md" \
    "# Already" \
    "Body stays." \
    "" \
    "Related: cites [T1](decisions/old.md) and a prose footer"
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g5 first propose"
  first=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$out/manifest.json")
  python3 - "$out/manifest.json" <<'PY' || fail "g5 existing/none contract failed"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert any(row["path"] == "already/report.md" for row in data["existing_footers"])
empty = next(row for row in data["proposals"] if row["path"] == "captain.md")
assert empty["proposed_footer"] == "Related: supersedes: none; cites: none; relates: none"
PY
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g5 second propose"
  second=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$out/manifest.json")
  [ "$first" = "$second" ] || fail "g5 rerun was not byte-identical"
  pass "fm-record-links.py: existing footers, none defaults, and stable reruns"
}

test_apply_hash_and_altered_plan() {
  local rec copy out
  rec="$TMP_ROOT/g6"
  seed_base "$rec"
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g6 propose"
  copy="$TMP_ROOT/g6-copy"
  copy_record "$rec" "$copy"
  python3 - "$out/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["proposals"][0]["proposed_footer"] = "Related: not-canonical"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 1 "$RC" "altered plan"
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g6 repropose"
  printf 'changed\n' >> "$copy/captain.md"
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 1 "$RC" "changed input"
  pass "fm-record-links.py: changed input and altered plans refuse apply"
}

test_apply_refuses_before_any_write() {
  local rec copy out
  rec="$TMP_ROOT/g6-atomic"
  seed_base "$rec"
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "atomic propose"
  copy="$TMP_ROOT/g6-atomic-copy"
  copy_record "$rec" "$copy"
  printf 'changed\n' >> "$copy/task-alpha/report.md"
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 1 "$RC" "later hash mismatch"
  assert_contains "$OUT" "source hash changed" "refusal reason"
  if grep -rl '^Related:' "$copy" >/dev/null; then
    fail "apply wrote footers before refusing on a later hash mismatch"
  fi
  pass "fm-record-links.py: a later hash mismatch refuses apply with no earlier writes"
}

test_apply_preserves_body_and_is_idempotent() {
  local rec copy out before after
  rec="$TMP_ROOT/g7"
  seed_base "$rec"
  write_file "$rec/task-cite/report.md" \
    "# Cite" \
    "Uses \`data/other/report.md\`."
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "g7 propose"
  copy="$TMP_ROOT/g7-copy"
  copy_record "$rec" "$copy"
  before=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$copy/task-cite/report.md")
  run_links propose --root "$copy" --out "$(out_dir "$copy")"
  expect_code 0 "$RC" "g7 dry-run"
  after=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$copy/task-cite/report.md")
  [ "$before" = "$after" ] || fail "propose wrote the Record"
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 0 "$RC" "g7 apply"
  python3 - "$copy/task-cite/report.md" "$rec/task-cite/report.md" <<'PY' || fail "g7 body was rewritten"
import sys
new, old = open(sys.argv[1], encoding="utf-8").read(), open(sys.argv[2], encoding="utf-8").read()
assert new.startswith(old.rstrip("\n") + "\nRelated:"), (old, new)
assert "Related: " in new.splitlines()[-1]
PY
  python3 -c 'from pathlib import Path; p=Path(r"""'"$copy"'""")/"task-cite/report.md"; t=p.read_bytes(); p.write_bytes(t)' 
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 0 "$RC" "g7 apply rerun"
  python3 - "$copy/task-cite/report.md" <<'PY' || fail "g7 second apply changed bytes"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert text.count("Related:") == 1, text
PY
  pass "fm-record-links.py: apply is footer-only, dry-run is inert, and reruns are idempotent"
}

test_apply_preserves_non_utf8_body_bytes() {
  local rec copy out
  rec="$TMP_ROOT/g7-bytes"
  seed_base "$rec"
  mkdir -p "$rec/task-bytes"
  printf '# Bytes\n\nLatin-1 caf\xe9 cites [[other/report.md]].\n' > "$rec/task-bytes/report.md"
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "non-utf8 propose"
  copy="$TMP_ROOT/g7-bytes-copy"
  copy_record "$rec" "$copy"
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 0 "$RC" "non-utf8 apply"
  python3 - "$copy/task-bytes/report.md" "$rec/task-bytes/report.md" <<'PY' || fail "non-utf8 body bytes were rewritten"
import sys
new = open(sys.argv[1], "rb").read()
old = open(sys.argv[2], "rb").read()
assert b"\xe9" in old
assert new.startswith(old), (old, new)
tail = new[len(old):]
assert tail.startswith(b"Related: ") and tail.endswith(b"\n"), tail
assert b"\xef\xbf\xbd" not in new, new
PY
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 0 "$RC" "non-utf8 apply rerun"
  [ "$(grep -c '^Related:' "$copy/task-bytes/report.md")" = "1" ] \
    || fail "non-utf8 rerun appended a second footer"
  pass "fm-record-links.py: apply preserves non-UTF-8 body bytes"
}

test_lint_findings_exit_zero_and_missing_root_unavailable() {
  local rec
  rec="$TMP_ROOT/g11"
  seed_base "$rec"
  run_links lint --root "$rec" --json
  expect_code 0 "$RC" "lint with findings"
  python3 -c 'import json,sys; data=json.loads(sys.stdin.read()); assert data["status"]=="ok"; assert data["missing"]>=1' <<< "$OUT" \
    || fail "lint did not report missing footers with status=ok"
  run_links lint --root "$TMP_ROOT/no-such-record" --json
  expect_code 1 "$RC" "missing root"
  python3 -c 'import json,sys; data=json.loads(sys.stdin.read()); assert data["status"]=="unavailable"' <<< "$OUT" \
    || fail "missing root was not unavailable"
  pass "fm-record-links.py: lint findings exit 0 and a missing root is unavailable"
}

test_lint_never_rewrites_or_blocks() {
  local rec before i
  rec="$TMP_ROOT/g12"
  seed_base "$rec"
  before=$(python3 -c 'import hashlib,os,sys
root=sys.argv[1]
h=0
for dirpath, _, names in os.walk(root):
    for name in names:
        path=os.path.join(dirpath,name)
        if os.path.isfile(path) and not os.path.islink(path):
            h ^= int(hashlib.sha256(open(path,"rb").read()).hexdigest(),16)
print(h)
' "$rec")
  i=0
  while [ "$i" -lt 7 ]; do
    run_links lint --root "$rec" --json
    expect_code 0 "$RC" "lint pass $i"
    i=$((i + 1))
  done
  python3 -c 'import hashlib,os,sys
root=sys.argv[1]
h=0
for dirpath, _, names in os.walk(root):
    for name in names:
        path=os.path.join(dirpath,name)
        if os.path.isfile(path) and not os.path.islink(path):
            h ^= int(hashlib.sha256(open(path,"rb").read()).hexdigest(),16)
print(h)
' "$rec" > "$TMP_ROOT/g12.after"
  [ "$before" = "$(cat "$TMP_ROOT/g12.after")" ] || fail "lint rewrote the Record"
  pass "fm-record-links.py: lint stays advisory across seven clean runs"
}

test_acceptance_mixed_legacy_citations() {
  local rec out copy
  rec="$TMP_ROOT/accept"
  seed_base "$rec"
  write_file "$rec/task/report.md" \
    "# Mixed citations" \
    "Backtick \`data/other/report.md\`." \
    "Markdown [old](../decisions/old.md)." \
    "Prose path playbook/example.md." \
    '```' \
    "Fenced [[captain.md]]" \
    '```' \
    "Supersedes: data/decisions/old.md"
  write_file "$rec/legacy/report.md" \
    "# Legacy footer" \
    "Kept as-is." \
    "" \
    "Related: cites [T1](decisions/old.md) ; relates maybe"
  out=$(out_dir "$rec")
  run_links propose --root "$rec" --out "$out"
  expect_code 0 "$RC" "acceptance propose"
  copy="$TMP_ROOT/accept-copy"
  copy_record "$rec" "$copy"
  run_links apply --root "$copy" --plan "$out/manifest.json"
  expect_code 0 "$RC" "acceptance apply"
  python3 - "$out/manifest.json" "$copy/task/report.md" "$copy/legacy/report.md" <<'PY' || fail "acceptance fixture contract failed"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
text = open(sys.argv[2], encoding="utf-8").read()
legacy = open(sys.argv[3], encoding="utf-8").read()
prop = next(row for row in data["proposals"] if row["path"] == "task/report.md")
targets = {(edge["key"], edge["target"]) for edge in prop["edges"]}
assert ("cites", "other/report.md") in targets
assert ("cites", "decisions/old.md") in targets
assert ("cites", "playbook/example.md") in targets
assert ("supersedes", "decisions/old.md") in targets
assert ("cites", "captain.md") not in targets
assert "Related: cites [T1]" in legacy
assert "Related:" in text.splitlines()[-1]
PY
  first=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$out/manifest.json")
  run_links propose --root "$rec" --out "$out"
  second=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$out/manifest.json")
  [ "$first" = "$second" ] || fail "acceptance propose was not deterministic"
  pass "fm-record-links.py: mixed legacy citations yield deterministic footer-only proposals"
}

test_help_prints_header
test_usage_exits_two
test_classify_authored_generated_raw_active_unknown
test_citations_resolve_and_reject_fakes
test_cites_relates_supersedes_and_ambiguous_amendment
test_duplicate_self_cycle_shadow_slug
test_existing_footer_none_stable_rerun
test_apply_hash_and_altered_plan
test_apply_refuses_before_any_write
test_apply_preserves_body_and_is_idempotent
test_apply_preserves_non_utf8_body_bytes
test_lint_findings_exit_zero_and_missing_root_unavailable
test_lint_never_rewrites_or_blocks
test_acceptance_mixed_legacy_citations
