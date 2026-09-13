#!/usr/bin/env bash
# Behavior tests for bin/fm-graphify.sh through the public executable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRAPHIFY="$ROOT/bin/fm-graphify.sh"
TMP_ROOT=$(fm_test_tmproot fm-graphify)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
fm_git_identity fmtest fmtest@example.invalid
trap fm_test_cleanup EXIT

run_g() {
  set +e
  OUT=$(
    PATH="${FAKEBIN:-$TMP_ROOT/empty-bin}:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" \
    "$GRAPHIFY" "$@" 2>&1
  )
  RC=$?
  set -e
}

init_repo() {
  local dest=$1 remote=$2
  mkdir -p "$dest"
  git init --quiet -b main "$dest"
  printf '%s\n' "$3" > "$dest/README.md"
  git -C "$dest" add README.md
  git -C "$dest" commit --quiet -m init
  git -C "$dest" remote add origin "$remote"
}

write_registry() {
  local dest=$1
  cat > "$dest" <<'EOF'
# Projects

- firstmate [no-mistakes +yolo] - fleet code
- fm-home [local-only] - seed
- fm-vault [local-only] - retired
- extra-app [no-mistakes] - other
- ghost [no-mistakes] - missing
EOF
}

write_ledger() {
  local dest=$1
  mkdir -p "$(dirname "$dest")"
  cat > "$dest" <<EOF
repo	kind	state	delivery	source_revision	identity	graph_relpath	merge_tag	graph_hash	publication	notes
$2
EOF
}

write_graph() {
  local dest=$1 commit=$2
  mkdir -p "$(dirname "$dest")"
  python3 - "$dest" "$commit" <<'PY'
import json, sys
path, commit = sys.argv[1], sys.argv[2]
json.dump({"built_at_commit": commit, "nodes": [], "links": []}, open(path, "w", encoding="utf-8"))
PY
}

test_help_names_contract() {
  run_g --help
  expect_code 0 "$RC" 'help'
  assert_contains "$OUT" 'fm-graphify.sh inventory' 'help names inventory'
  assert_contains "$OUT" 'never installs or upgrades graphify' 'help names install refusal'
  pass "fm-graphify: --help prints the T10 contract"
}

test_inventory_dedupes_and_marks_absent() {
  local world projects record registry home extra
  world="$TMP_ROOT/inv"
  projects="$world/projects"
  record="$world/record"
  registry="$world/projects.md"
  home="$world/home-clone"
  extra="$world/agent-skills"
  mkdir -p "$projects" "$record" "$world/empty-bin"
  write_registry "$registry"
  init_repo "$projects/firstmate" "https://github.com/guanchengh-lgtm/firstmate.git" 'firstmate'
  init_repo "$home" "https://github.com/guanchengh-lgtm/firstmate.git" 'home copy'
  init_repo "$projects/fm-home" "https://github.com/guanchengh-lgtm/fm-home.git" 'seed'
  init_repo "$extra" "https://github.com/guanchengh-lgtm/agent-skills.git" 'skills'
  init_repo "$world/fixture-origin" "https://example.invalid/fixture.git" 'origin'
  init_repo "$projects/extra-app" "$world/fixture-origin" 'clone'
  run_g inventory --projects-root "$projects" --record "$record" --registry "$registry" \
    --home "$home" --extra "$extra" --extra "$world/fixture-origin"
  expect_code 0 "$RC" 'inventory'
  assert_contains "$OUT" $'record\trecord\tincomplete\tlocal-only' 'record without git is incomplete'
  assert_contains "$OUT" $'firstmate\tcode\tselected\tno-mistakes' 'firstmate is selected'
  assert_contains "$OUT" $'fm-home\tcode\tselected\tlocal-only' 'fm-home stays selected'
  assert_contains "$OUT" $'fm-vault\tcode\tabsent\tlocal-only' 'fm-vault is absent'
  assert_contains "$OUT" $'ghost\tcode\tabsent\tno-mistakes' 'missing clone is absent'
  assert_contains "$OUT" $'home-clone\tcode\tduplicate' 'home firstmate clone is duplicate'
  assert_contains "$OUT" $'agent-skills\tcode\tunregistered' 'captain extra is unregistered'
  assert_contains "$OUT" 'captain-owned-unregistered' 'unregistered note names captain remote'
  assert_contains "$OUT" $'extra-app\tcode\tselected' 'file-origin clone is selected'
  assert_contains "$OUT" $'fixture-origin\tcode\tduplicate' 'file-origin extra matches the selected clone'
  pass "fm-graphify: inventory dedupes clones and keeps absent vault explicit"
}

test_eval_dedupes_nodes_and_rejects_archive() {
  local world
  world="$TMP_ROOT/eval"
  mkdir -p "$world"
  cat > "$world/probes.tsv" <<'EOF'
# n	probe_date	dispatched_ids	prior_ids	query
2	2026-08-31	ov-kb-graphify		graphify project install hook-free shape
EOF
  cat > "$world/graphify.raw" <<'EOF'
NODE Install [src=ov-kb-graphify/report.md loc=1 community=Install]
NODE Hook [src=ov-kb-graphify/report.md loc=8 community=Install]
NODE Archive [src=done-archive.md loc=12 community=Memory]
EOF
  cat > "$world/t2.raw" <<'EOF'
ov-kb-graphify
other-doc
EOF
  cat > "$world/graph.json" <<'EOF'
{"nodes":[{"id":"a","source_file":"ov-kb-graphify/report.md","repo":"record"},{"id":"b","source_file":"ov-kb-graphify/report.md","repo":"record"},{"id":"c","source_file":"done-archive.md","repo":"record"}]}
EOF
  run_g eval --probes "$world/probes.tsv" --graphify-raw "$world/graphify.raw" \
    --t2-raw "$world/t2.raw" --graph "$world/graph.json"
  expect_code 0 "$RC" 'eval'
  assert_contains "$OUT" $'2\tgraphify\t1\tY\tY\tY\t1.0000\tov-kb-graphify,miss:archive-without-block:done-archive.md' \
    'graphify collapses duplicate nodes and refuses a bare archive hit'
  assert_contains "$OUT" $'2\tt2\t1\tY\tY\tY\t1.0000\tov-kb-graphify,other-doc' \
    't2 ranks the expected document first'
  pass "fm-graphify: eval maps nodes to documents and rejects archive-only hits"
}

test_eval_marks_ambiguous_readme() {
  local world
  world="$TMP_ROOT/ambig"
  mkdir -p "$world"
  cat > "$world/probes.tsv" <<'EOF'
# n	probe_date	dispatched_ids	prior_ids	query
1	2026-08-31	ov-kb-feeder		feeder export
EOF
  printf '%s\n' 'NODE Readme [src=README.md loc=1 community=Docs]' > "$world/graphify.raw"
  printf '%s\n' 'ov-kb-feeder' > "$world/t2.raw"
  printf '%s\n' '{"nodes":[{"id":"n","source_file":"README.md"}]}' > "$world/graph.json"
  run_g eval --probes "$world/probes.tsv" --graphify-raw "$world/graphify.raw" \
    --t2-raw "$world/t2.raw" --graph "$world/graph.json"
  expect_code 0 "$RC" 'ambig eval'
  assert_contains "$OUT" $'1\tgraphify\t-\t-\t-\t-\t-\tmiss:ambiguous:README.md' \
    'common filename without repo identity is a miss'
  pass "fm-graphify: eval treats an unscoped README as ambiguous"
}

test_cover_counts_unsupported_pine() {
  local repo
  repo="$TMP_ROOT/cover/repo"
  mkdir -p "$repo"
  git init --quiet -b main "$repo"
  printf 'x\n' > "$repo/app.py"
  printf '// pine\n' > "$repo/script.pine"
  printf 'a,b\n' > "$repo/rows.csv"
  git -C "$repo" add app.py script.pine rows.csv
  git -C "$repo" commit --quiet -m init
  mkdir -p "$repo/graphify-out"
  python3 - "$repo/graphify-out/graph.json" <<'PY'
import json, sys
json.dump({"nodes":[{"id":"n","source_file":"app.py"}], "links":[]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
  run_g cover --root "$repo" --graph "$repo/graphify-out/graph.json"
  expect_code 0 "$RC" 'cover'
  assert_contains "$OUT" $'.pine\t1\t0\t0\t0\t0\t1\t0\t0' 'pine stays unsupported'
  assert_contains "$OUT" $'.csv\t1\t0\t0\t0\t0\t1\t0\t0' 'csv stays unsupported'
  assert_contains "$OUT" $'.py\t1\t1\t1\t1\t0\t0\t0\t0' 'python is represented'
  pass "fm-graphify: cover counts pine and csv as unsupported"
}

test_nightly_unchanged_skips_graphify() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-unchanged"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "$commit"
  write_graph "$record/graphify-out/graph.json" "$commit"
  write_graph "$record/graphify-out/merged-graph.json" "$commit"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects"
  expect_code 0 "$RC" 'unchanged nightly'
  assert_contains "$OUT" $'status=ok\tdetail=unchanged' 'unchanged ready set stays unchanged'
  [ ! -f "$fakebin/log" ] || fail 'unchanged nightly invoked graphify'
  pass "fm-graphify: unchanged ready set does not invoke graphify update"
}

test_nightly_code_edit_updates() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-code"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "$commit"
  write_graph "$record/graphify-out/graph.json" "$commit"
  printf 'def x():\n    return 1\n' > "$repo/app.py"
  git -C "$repo" add app.py
  git -C "$repo" commit --quiet -m code
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects"
  expect_code 0 "$RC" 'code nightly'
  assert_contains "$OUT" $'status=ok\tdetail=code-updated' 'code edit is code-updated'
  assert_grep 'update .' "$fakebin/log" 'code edit ran graphify update'
  assert_grep 'export wiki' "$fakebin/log" 'code edit exported wiki'
  pass "fm-graphify: code edit runs update and wiki"
}

test_nightly_doc_edit_is_finding() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-doc"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "$commit"
  write_graph "$record/graphify-out/graph.json" "$commit"
  printf '# doc\n' > "$repo/NOTE.md"
  git -C "$repo" add NOTE.md
  git -C "$repo" commit --quiet -m docs
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects"
  expect_code 1 "$RC" 'doc nightly'
  assert_contains "$OUT" $'status=finding\tdetail=docs-stale' 'doc edit is docs-stale'
  [ ! -f "$fakebin/log" ] || assert_not_contains "$(cat "$fakebin/log")" 'update' \
    'doc-only edit does not claim a shell update'
  pass "fm-graphify: document edit is docs-stale and skips shell update"
}

test_nightly_rename_updates() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-rename"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  printf 'def x():\n    return 1\n' > "$repo/app.py"
  git -C "$repo" add app.py
  git -C "$repo" commit --quiet -m add
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "$commit"
  write_graph "$record/graphify-out/graph.json" "$commit"
  git -C "$repo" mv app.py util.py
  git -C "$repo" commit --quiet -m rename
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects"
  expect_code 0 "$RC" 'rename nightly'
  assert_contains "$OUT" $'status=ok\tdetail=code-updated' 'rename is a code update'
  pass "fm-graphify: rename runs the code update path"
}

test_nightly_missing_ready_graph_refuses_merge() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-missing"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record/graphify-out" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$record/graphify-out/graph.json" "$commit"
  printf '%s\n' '{"ok":true}' > "$record/graphify-out/merged-graph.json"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects"
  expect_code 10 "$RC" 'missing ready graph'
  assert_contains "$OUT" $'status=failed\tdetail=missing-input' 'missing ready graph fails closed'
  assert_contains "$(cat "$record/graphify-out/merged-graph.json")" '{"ok":true}' \
    'prior merged graph stays in place'
  [ ! -f "$fakebin/log" ] || fail 'missing-input invoked graphify merge'
  pass "fm-graphify: missing ready graph refuses merge and keeps the prior file"
}

test_nightly_pending_skips_merge() {
  local world record projects fakebin commit
  world="$TMP_ROOT/night-pending"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  mkdir -p "$fakebin" "$record" "$projects"
  write_graph "$record/graphify-out/graph.json" "abc"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	abc	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes		firstmate	graphify-out/graph.json	firstmate		pending	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects"
  expect_code 0 "$RC" 'pending nightly'
  assert_contains "$OUT" $'status=ok\tdetail=pending-inputs' 'pending selected rows skip merge'
  [ ! -f "$fakebin/log" ] || fail 'pending nightly invoked graphify'
  pass "fm-graphify: pending selected rows skip merge"
}

test_help_names_contract
test_inventory_dedupes_and_marks_absent
test_eval_dedupes_nodes_and_rejects_archive
test_eval_marks_ambiguous_readme
test_cover_counts_unsupported_pine
test_nightly_unchanged_skips_graphify
test_nightly_code_edit_updates
test_nightly_doc_edit_is_finding
test_nightly_rename_updates
test_nightly_missing_ready_graph_refuses_merge
test_nightly_pending_skips_merge
