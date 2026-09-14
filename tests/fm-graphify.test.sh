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
- stray [no-mistakes] - directory without a clone
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

init_record() {
  local dest=$1
  mkdir -p "$dest"
  git init --quiet -b main "$dest"
  git -C "$dest" commit --quiet --allow-empty -m init
  git -C "$dest" rev-parse HEAD
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
  mkdir -p "$projects/stray" "$record" "$world/empty-bin"
  git init --quiet -b main "$world"
  write_registry "$registry"
  init_repo "$projects/firstmate" "https://github.com/guanchengh-lgtm/firstmate.git" 'firstmate'
  init_repo "$home" "https://github.com/guanchengh-lgtm/firstmate.git" 'home copy'
  init_repo "$projects/fm-home" "https://github.com/guanchengh-lgtm/fm-home.git" 'seed'
  init_repo "$extra" "https://github.com/guanchengh-lgtm/agent-skills.git" 'skills'
  init_repo "$world/fixture-origin" "https://example.invalid/fixture.git" 'origin'
  init_repo "$projects/extra-app" "$world/fixture-origin" 'clone'
  init_repo "$world/ssh-clone" "git@github.com:guanchengh-lgtm/firstmate.git" 'ssh copy'
  init_repo "$world/no-origin" "https://example.invalid/unused.git" 'primary'
  git -C "$world/no-origin" remote remove origin
  git -C "$world/no-origin" worktree add --quiet "$world/no-origin-wt" -b wt
  init_repo "$world/a:b/colon-origin" "https://example.invalid/colon.git" 'colon'
  init_repo "$world/colon-clone" "$world/a:b/colon-origin" 'colon clone'
  run_g inventory --projects-root "$projects" --record "$record" --registry "$registry" \
    --home "$home" --extra "$extra" --extra "$world/fixture-origin" \
    --extra "$world/ssh-clone" --extra "$world/no-origin-wt" --extra "$world/no-origin" \
    --extra "$world/a:b/colon-origin" --extra "$world/colon-clone"
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
  assert_contains "$OUT" $'ssh-clone\tcode\tduplicate' 'ssh origin dedupes against the https clone'
  assert_contains "$OUT" $'no-origin-wt\tcode\tunregistered' 'remote-less worktree is unregistered'
  assert_contains "$OUT" $'no-origin\tcode\tduplicate' 'primary checkout dedupes against its worktree by common dir'
  assert_not_contains "$OUT" '/no-origin-wt	graphify-out' 'worktree path is not an identity'
  assert_contains "$OUT" $'stray\tcode\tincomplete\tno-mistakes\t\t\t' 'directory inside the home checkout is not-git, not the parent repo'
  assert_contains "$OUT" $'colon-clone\tcode\tduplicate' 'local origin path with a colon dedupes as a path'
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
NODE Archive [src=done-archive.md loc=12 community=Memory]
NODE Install [src=ov-kb-graphify/report.md loc=1 community=Install]
NODE Hook [src=ov-kb-graphify/report.md loc=8 community=Install]
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
  assert_contains "$OUT" $'2\tgraphify\t2\t-\tY\tY\t0.5000\tmiss:archive-without-block:done-archive.md,ov-kb-graphify' \
    'graphify collapses duplicate nodes and a top-ranked archive miss consumes rank 1'
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
  assert_contains "$OUT" $'.py\t1\t0\t0\t1\t0\t0\t0\t0' 'python is represented but not claimed detected'
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
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
  write_graph "$world/state/graphify/merged-graph.json" "$commit"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
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
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
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
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
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
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
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
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 1 "$RC" 'doc nightly'
  assert_contains "$OUT" $'status=finding\tdetail=docs-stale' 'doc edit is docs-stale'
  [ ! -f "$fakebin/log" ] || assert_not_contains "$(cat "$fakebin/log")" 'update' \
    'doc-only edit does not claim a shell update'
  pass "fm-graphify: document edit is docs-stale and skips shell update"
}

test_nightly_docs_stale_survives_code_update() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-durable"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "$commit"
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
  write_graph "$world/state/graphify/merged-graph.json" "$commit"
  printf '# doc\n' > "$repo/NOTE.md"
  printf 'def x():\n    return 1\n' > "$repo/app.py"
  git -C "$repo" add NOTE.md app.py
  git -C "$repo" commit --quiet -m both
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/log"
if [ "$1" = update ]; then
  python3 - "$(git rev-parse HEAD)" <<'PY'
import json, sys
json.dump({"built_at_commit": sys.argv[1], "nodes": [], "links": []}, open("graphify-out/graph.json", "w", encoding="utf-8"))
PY
fi
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 1 "$RC" 'first night'
  assert_contains "$OUT" $'status=finding\tdetail=docs-stale' 'mixed edit is docs-stale'
  assert_grep 'update .' "$fakebin/log" 'mixed edit still ran the code update'
  rm -f "$fakebin/log"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 1 "$RC" 'second night'
  assert_contains "$OUT" $'status=finding\tdetail=docs-stale' 'docs-stale survives the code update'
  [ ! -f "$fakebin/log" ] || fail 'second night invoked graphify again'
  python3 - "$repo/graphify-out/graph.json" "$(git -C "$repo" rev-parse HEAD)" <<'PY'
import json, sys
json.dump({"built_at_commit": sys.argv[2], "nodes": [{"id": "doc"}], "links": []}, open(sys.argv[1], "w", encoding="utf-8"))
PY
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 0 "$RC" 'third night'
  assert_contains "$OUT" $'status=ok\tdetail=unchanged' 'host wiki rebuild clears docs-stale'
  pass "fm-graphify: docs-stale stays until the host wiki rebuild replaces the graph"
}

test_nightly_unknown_built_at_updates() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-stale"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "0000000000000000000000000000000000000000"
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
  write_graph "$world/state/graphify/merged-graph.json" "$commit"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/log"
if [ "$1" = update ]; then
  python3 - "$(git rev-parse HEAD)" <<'PY'
import json, sys
json.dump({"built_at_commit": sys.argv[1], "nodes": [], "links": []}, open("graphify-out/graph.json", "w", encoding="utf-8"))
PY
fi
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 1 "$RC" 'unknown built_at nightly'
  assert_grep 'update .' "$fakebin/log" 'unknown built_at forces a code update'
  rm -f "$fakebin/log"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 1 "$RC" 'unknown baseline second night'
  assert_contains "$OUT" $'status=finding\tdetail=docs-stale' 'unknown document baseline stays docs-stale after the code rebuild'
  [ ! -f "$fakebin/log" ] || fail 'second night after unknown baseline invoked graphify again'
  pass "fm-graphify: a graph stamped with an unknown commit is rebuilt, not reported unchanged"
}

test_nightly_merge_keeps_paths_with_spaces() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night space"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$projects"
  commit=$(init_record "$record")
  write_graph "$record/graphify-out/graph.json" "$commit"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$#" "$@" > "$(dirname "$0")/log"
# Installed Graphify 0.9.53 needs at least two graphs for merge-graphs.
if [ "$1" = merge-graphs ] && [ "$#" -lt 5 ]; then
  echo 'Usage: graphify merge-graphs <graph1.json> <graph2.json> [...] [--out merged.json]' >&2
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 0 "$RC" 'single ready graph nightly'
  assert_contains "$OUT" $'status=ok\tdetail=merge-single' 'one ready graph waits for a second input'
  [ ! -f "$fakebin/log" ] || fail 'single ready graph invoked graphify merge-graphs'
  [ ! -f "$world/state/graphify/merged-graph.json" ] || fail 'single ready graph wrote a merged graph'
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  write_graph "$repo/graphify-out/graph.json" "$(git -C "$repo" rev-parse HEAD)"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 0 "$RC" 'space merge nightly'
  assert_contains "$OUT" $'status=ok\tdetail=merge-ready' 'ready set merges'
  assert_contains "$(cat "$fakebin/log")" "$record/graphify-out/graph.json" 'graph path with a space is one argument'
  [ "$(head -n 1 "$fakebin/log")" = 5 ] || fail 'merge-graphs receives exactly five arguments'
  pass "fm-graphify: merge needs two ready graphs and passes a path with a space as one argument"
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
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
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
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 0 "$RC" 'rename nightly'
  assert_contains "$OUT" $'status=ok\tdetail=code-updated' 'rename is a code update'
  pass "fm-graphify: rename runs the code update path"
}

test_nightly_tracked_graph_is_not_rewritten() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-tracked"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "$commit"
  git -C "$repo" add graphify-out/graph.json
  git -C "$repo" commit --quiet -m graph
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
  write_graph "$world/state/graphify/merged-graph.json" "$commit"
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
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 1 "$RC" 'tracked nightly'
  assert_contains "$OUT" $'status=finding\tdetail=docs-stale' 'tracked graph code edit is docs-stale'
  [ ! -f "$fakebin/log" ] || fail 'tracked graph nightly invoked graphify'
  [ -z "$(git -C "$repo" status --porcelain)" ] || fail 'tracked graph nightly dirtied the clone'
  [ ! -f "$repo/graphify-out/code-only-build.tsv" ] || fail 'tracked graph nightly stamped a code-only build'
  pass "fm-graphify: tracked graph is not rewritten by the shell"
}

test_nightly_missing_ready_graph_refuses_merge() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-missing"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record/graphify-out" "$repo" "$world/state/graphify"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
  printf '%s\n' '{"ok":true}' > "$world/state/graphify/merged-graph.json"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		ready	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 10 "$RC" 'missing ready graph'
  assert_contains "$OUT" $'status=failed\tdetail=missing-input' 'missing ready graph fails closed'
  assert_contains "$(cat "$world/state/graphify/merged-graph.json")" '{"ok":true}' \
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
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	abc	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes		firstmate	graphify-out/graph.json	firstmate		pending	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 0 "$RC" 'pending nightly'
  assert_contains "$OUT" $'status=ok\tdetail=pending-inputs' 'pending selected rows skip merge'
  [ ! -f "$fakebin/log" ] || fail 'pending nightly invoked graphify'
  pass "fm-graphify: pending selected rows skip merge"
}

test_nightly_pending_row_with_graph_reports_pending() {
  local world record projects fakebin repo commit
  world="$TMP_ROOT/night-pending-graph"
  record="$world/record"
  projects="$world/projects"
  fakebin="$world/fakebin"
  repo="$projects/firstmate"
  mkdir -p "$fakebin" "$record" "$repo"
  init_repo "$repo" "https://github.com/guanchengh-lgtm/firstmate.git" 'code'
  commit=$(git -C "$repo" rev-parse HEAD)
  write_graph "$repo/graphify-out/graph.json" "$commit"
  write_graph "$record/graphify-out/graph.json" "$(init_record "$record")"
  write_ledger "$record/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv" \
"record	record	selected	local-only	$commit	record	graphify-out/graph.json	record		ready	
firstmate	code	selected	no-mistakes	$commit	firstmate	graphify-out/graph.json	firstmate		pending	"
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
echo invoked >> "$(dirname "$0")/log"
exit 0
SH
  chmod +x "$fakebin/graphify"
  FAKEBIN=$fakebin run_g nightly --record "$record" --projects-root "$projects" --state "$world/state"
  expect_code 0 "$RC" 'pending graph nightly'
  assert_contains "$OUT" $'status=ok\tdetail=pending-inputs' 'pending row with a graph reports pending-inputs'
  [ ! -f "$fakebin/log" ] || fail 'pending graph nightly invoked graphify'
  [ ! -f "$world/state/graphify/merged-graph.json" ] || fail 'pending graph nightly merged'
  pass "fm-graphify: pending row with a built graph still reports pending-inputs"
}

test_help_names_contract
test_inventory_dedupes_and_marks_absent
test_eval_dedupes_nodes_and_rejects_archive
test_eval_marks_ambiguous_readme
test_cover_counts_unsupported_pine
test_nightly_unchanged_skips_graphify
test_nightly_code_edit_updates
test_nightly_doc_edit_is_finding
test_nightly_docs_stale_survives_code_update
test_nightly_unknown_built_at_updates
test_nightly_merge_keeps_paths_with_spaces
test_nightly_rename_updates
test_nightly_tracked_graph_is_not_rewritten
test_nightly_missing_ready_graph_refuses_merge
test_nightly_pending_skips_merge
test_nightly_pending_row_with_graph_reports_pending
