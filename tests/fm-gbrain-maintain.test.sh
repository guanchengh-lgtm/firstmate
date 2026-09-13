#!/usr/bin/env bash
# Behavior tests for bin/fm-gbrain-maintain.py through the public executable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAINTAIN="$ROOT/bin/fm-gbrain-maintain.py"
NIGHTLY="$ROOT/bin/fm-nightly.sh"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-maintain)
OUTER_STATUS_BEFORE=$(git -C "$ROOT" status --short --untracked-files=all)
fm_git_identity fmtest fmtest@example.invalid

NOW=2026-09-13T03:00:00Z

run_m() {
  set +e
  OUT=$(python3 "$MAINTAIN" "$@" 2>&1)
  RC=$?
  set -e
}

new_record() {
  local rec=$1
  mkdir -p "$rec/decisions" "$rec/wiki/views"
  printf '# backlog\n' > "$rec/backlog.md"
  git -C "$rec" init -q --initial-branch=main
  git -C "$rec" add -A
  git -C "$rec" commit -qm initial
  printf '%s\n' "$rec"
}

write_gbrain_stub() {
  local dest=$1
  cat > "$dest" <<'SH'
#!/usr/bin/env bash
log=${GBRAIN_ARGV:-}
if [ -n "$log" ]; then
  printf '%s\n' "$*" >> "$log"
fi
if [ "${1:-}" = export ]; then
  out=
  prev=
  for arg in "$@"; do
    if [ "$prev" = --out ]; then
      out=$arg
    fi
    prev=$arg
  done
  [ -n "$out" ] || exit 1
  mkdir -p "$out/conversations/sessions"
  printf '%s\n' '# session one' 'cited from the Record' > "$out/conversations/sessions/s1.md"
fi
exit "${GBRAIN_RC:-0}"
SH
  chmod +x "$dest"
}

write_scan_stub() {
  local dest=$1
  cat > "$dest" <<'SH'
#!/usr/bin/env bash
exit "${SCAN_RC:-0}"
SH
  chmod +x "$dest"
}

write_launchctl_stub() {
  local dest=$1
  cat > "$dest" <<'SH'
#!/usr/bin/env bash
if [ -n "${LAUNCHCTL_ARGV:-}" ]; then
  printf '%s\n' "$*" >> "$LAUNCHCTL_ARGV"
fi
exit 0
SH
  chmod +x "$dest"
}

test_help_names_commands() {
  run_m --help
  expect_code 0 "$RC" 'help'
  assert_contains "$OUT" 'fm-gbrain-maintain.py project' 'help names project'
  assert_contains "$OUT" 'fm-gbrain-maintain.py run' 'help names run'
  pass 'fm-gbrain-maintain: --help names the public commands'
}

test_project_uses_committed_blobs_only() {
  local rec out commit
  rec=$(new_record "$TMP_ROOT/committed/record")
  printf '# live\n' > "$rec/decisions/alpha.md"
  git -C "$rec" add decisions/alpha.md
  git -C "$rec" commit -qm alpha
  commit=$(git -C "$rec" rev-parse HEAD)
  printf '# dirty\n' > "$rec/decisions/alpha.md"
  out="$TMP_ROOT/committed/brain"
  mkdir -p "$out"
  run_m project --record "$rec" --out "$out" --commit "$commit" --format json
  expect_code 0 "$RC" 'project committed'
  printf '%s\n' "$OUT" | python3 -c '
import json,sys,pathlib
p=json.load(sys.stdin)
assert p["record_commit"]==sys.argv[1]
paths=[row["original"] for row in p["pages"]]
assert "decisions/alpha.md" in paths
assert "decisions/alpha.md" == [r["original"] for r in p["pages"] if r["original"].endswith("alpha.md")][0]
text=pathlib.Path(sys.argv[2],"data/decisions/alpha.md").read_text()
assert "# live" in text
assert "dirty" not in text
' "$commit" "$out" || fail "committed projection leaked the dirty file: $OUT"
  pass 'fm-gbrain-maintain: project reads committed blobs only'
}

test_project_renders_text_and_reserved_names() {
  local rec out
  rec=$(new_record "$TMP_ROOT/render/record")
  printf 'a,b\n1,2\n' > "$rec/table.csv"
  printf '{"k":1}\n' > "$rec/meta.json"
  printf '# meta\n' > "$rec/meta.md"
  printf 'plain\n' > "$rec/plain.txt"
  printf '# index\n' > "$rec/index.md"
  git -C "$rec" add -A
  git -C "$rec" commit -qm text
  out="$TMP_ROOT/render/brain"
  mkdir -p "$out"
  run_m project --record "$rec" --out "$out" --format json
  expect_code 0 "$RC" 'project text'
  python3 - "$out" <<'PY' || fail "rendered text pages were wrong"
from pathlib import Path
import sys
root = Path(sys.argv[1])
csv = (root / "data/table.csv.md").read_text()
assert "record_path: table.csv" in csv
assert "a,b" in csv
txt = (root / "data/plain.txt.md").read_text()
assert "record_path: plain.txt" in txt
js = (root / "data/meta.json.md").read_text()
assert "record_path: meta.json" in js
assert (root / "data/meta.md").read_text() == "# meta\n"
idx = (root / "data/index.record.md").read_text()
assert "record_path: index.md" in idx
assert not (root / "data/index.md").exists()
PY
  pass 'fm-gbrain-maintain: reserved names and text files become wrapped markdown'
}

test_project_rejects_unsafe_and_colliding_inputs() {
  local rec out
  rec=$(new_record "$TMP_ROOT/unsafe/record")
  mkdir -p "$rec/transcripts" "$rec/wiki/gbrain/mystery" "$rec/wiki/views/gbrain/eval"
  printf '# ok\n' > "$rec/keep.md"
  printf 'version https://git-lfs.github.com/spec/v1\noid sha256:aa\nsize 1\n' > "$rec/lfs.md"
  printf 'hello\0world\n' > "$rec/bin.md"
  printf 'sid\n' > "$rec/transcripts/session.jsonl"
  printf 'tok\n' > "$rec/secrets-credentials.json"
  ln -s keep.md "$rec/link.md"
  printf '# eval\n' > "$rec/wiki/views/gbrain/eval/run.md"
  printf '# mystery\n' > "$rec/wiki/gbrain/mystery/x.md"
  git -C "$rec" add -A
  git -C "$rec" commit -qm unsafe
  out="$TMP_ROOT/unsafe/brain"
  mkdir -p "$out"
  run_m project --record "$rec" --out "$out"
  expect_code 1 "$RC" 'unknown generated prefix'
  assert_contains "$OUT" 'unknown generated prefix' 'prefix error'
  rm -rf "$out"
  mkdir -p "$out"
  git -C "$rec" rm -q wiki/gbrain/mystery/x.md
  git -C "$rec" commit -qm 'drop mystery'
  run_m project --record "$rec" --out "$out" --format json
  expect_code 0 "$RC" 'project after dropping mystery'
  printf '%s\n' "$OUT" | python3 -c '
import json,sys
p=json.load(sys.stdin)
orig=set(row["original"] for row in p["pages"])
assert "keep.md" in orig
assert "lfs.md" not in orig
assert "bin.md" not in orig
assert "link.md" not in orig
assert "transcripts/session.jsonl" not in orig
assert "secrets-credentials.json" not in orig
reasons=set(row["reason"] for row in p["excluded"])
assert "lfs-pointer" in reasons
assert "binary" in reasons
assert "symlink" in reasons
assert "eval-output" in reasons
' || fail "unsafe inputs were admitted: $OUT"
  rec2=$(new_record "$TMP_ROOT/collide/record")
  printf '# md\n' > "$rec2/foo.md"
  printf '{}\n' > "$rec2/foo.json"
  printf '# index\n' > "$rec2/index.md"
  printf '# record\n' > "$rec2/index.record.md"
  git -C "$rec2" add -A
  git -C "$rec2" commit -qm collide
  mkdir -p "$TMP_ROOT/collide/brain"
  run_m project --record "$rec2" --out "$TMP_ROOT/collide/brain"
  expect_code 1 "$RC" 'collision'
  assert_contains "$OUT" 'collision' 'collision error'
  run_m project --record "$TMP_ROOT/missing" --out "$TMP_ROOT/missing-out"
  expect_code 1 "$RC" 'missing record'
  pass 'fm-gbrain-maintain: unsafe inputs and collisions fail closed'
}

test_run_publishes_edges_and_primary_ingest_only() {
  local rec home fake scan launch out
  rec=$(new_record "$TMP_ROOT/run/record")
  mkdir -p "$rec/task-a"
  {
    printf '%s\n' '# Task A'
    printf '%s\n' 'date: 2026-09-01'
    printf '%s\n' 'status: reported'
    printf '%s\n' 'Body cites the decision.'
    printf '%s\n' 'Related: supersedes: none; cites: [[decisions/old.md]]; relates: none'
  } > "$rec/task-a/report.md"
  printf '# old\n' > "$rec/decisions/old.md"
  git -C "$rec" add -A
  git -C "$rec" commit -qm edges
  home="$TMP_ROOT/run/home"
  mkdir -p "$home/config" "$home/state" "$home/data"
  fake="$TMP_ROOT/run/gbrain"
  scan="$TMP_ROOT/run/scan"
  launch="$TMP_ROOT/run/launchctl"
  write_gbrain_stub "$fake"
  write_scan_stub "$scan"
  write_launchctl_stub "$launch"
  mkdir -p "$TMP_ROOT/run/trans"
  printf 'primary\n' > "$TMP_ROOT/run/trans/p.jsonl"
  printf 'worker\n' > "$TMP_ROOT/run/trans/w.jsonl"
  python3 - "$TMP_ROOT/run/trans/manifest.json" "$TMP_ROOT/run/trans" <<'PY'
import json,sys
root=sys.argv[2]
json.dump({"files":[
    {"path":root+"/p.jsonl","format":"claude-code","source_id":"p1","role":"primary"},
    {"path":root+"/w.jsonl","format":"claude-code","source_id":"w1","role":"worker"},
    {"path":root+"/missing.jsonl","format":"claude-code","source_id":"u1","role":"unclassified"},
]}, open(sys.argv[1],"w"))
PY
  {
    printf 'GBRAIN_BIN=%s\n' "$fake"
    printf 'GBRAIN_SCAN=%s\n' "$scan"
    printf 'GBRAIN_LAUNCHCTL=%s\n' "$launch"
    printf 'GBRAIN_TRANSCRIPT_MANIFEST=%s\n' "$TMP_ROOT/run/trans/manifest.json"
  } > "$home/config/gbrain.env"
  GBRAIN_ARGV="$TMP_ROOT/run/gbrain.argv" LAUNCHCTL_ARGV="$TMP_ROOT/run/launch.argv" \
    run_m run --fm-home "$home" --record "$rec" --now "$NOW" --skip-serve \
    --gbrain-bin "$fake" --scan-bin "$scan" --launchctl-bin "$launch" \
    --transcript-manifest "$TMP_ROOT/run/trans/manifest.json" --format json
  expect_code 0 "$RC" 'run ok'
  assert_present "$rec/wiki/gbrain/conversations/sessions/s1.md" 'exported session'
  assert_present "$rec/wiki/views/gbrain/footer-edges.json" 'edges view'
  python3 - "$rec/wiki/views/gbrain/footer-edges.json" "$TMP_ROOT/run/gbrain.argv" <<'PY' || fail "edges or ingest were wrong"
import json,sys
edges=json.load(open(sys.argv[1]))["edges"]
cites=[e for e in edges if e["link_type"]=="cites"]
assert cites, edges
assert cites[0]["to"]=="decisions/old.md"
assert cites[0]["link_source"]=="record-footer"
log=open(sys.argv[2]).read()
assert "p.jsonl" in log
assert "w.jsonl" not in log
assert "links replace" in log
assert "sync --no-pull" in log
PY
  first=$(cat "$rec/wiki/gbrain/conversations/sessions/s1.md")
  GBRAIN_ARGV="$TMP_ROOT/run/gbrain.argv2" \
    run_m run --fm-home "$home" --record "$rec" --now "$NOW" --skip-serve \
    --gbrain-bin "$fake" --scan-bin "$scan" \
    --transcript-manifest "$TMP_ROOT/run/trans/manifest.json"
  expect_code 0 "$RC" 'second run'
  [ "$(cat "$rec/wiki/gbrain/conversations/sessions/s1.md")" = "$first" ] \
    || fail 'second run changed the published session page'
  pass 'fm-gbrain-maintain: run publishes footer edges and ingests primaries only'
}

test_lock_busy_does_not_stop_services() {
  local rec home fake scan
  rec=$(new_record "$TMP_ROOT/busy/record")
  home="$TMP_ROOT/busy/home"
  mkdir -p "$home/config" "$home/state/gbrain/maintain.lock" "$home/data"
  fake="$TMP_ROOT/busy/gbrain"
  scan="$TMP_ROOT/busy/scan"
  write_gbrain_stub "$fake"
  write_scan_stub "$scan"
  LAUNCHCTL_ARGV="$TMP_ROOT/busy/launch.argv" \
    run_m run --fm-home "$home" --record "$rec" --now "$NOW" \
    --gbrain-bin "$fake" --scan-bin "$scan" --launchctl-bin "$TMP_ROOT/busy/missing-launchctl"
  expect_code 3 "$RC" 'busy'
  assert_absent "$TMP_ROOT/busy/launch.argv" 'busy run invoked launchctl'
  pass 'fm-gbrain-maintain: a held lock exits 3 and does not stop services'
}

test_failed_sync_restores_and_leaves_record() {
  local rec home fake scan
  rec=$(new_record "$TMP_ROOT/fail/record")
  printf '# page\n' > "$rec/keep.md"
  git -C "$rec" add keep.md
  git -C "$rec" commit -qm keep
  home="$TMP_ROOT/fail/home"
  mkdir -p "$home/config" "$home/state" "$home/data"
  fake="$TMP_ROOT/fail/gbrain"
  scan="$TMP_ROOT/fail/scan"
  write_gbrain_stub "$fake"
  write_scan_stub "$scan"
  GBRAIN_ARGV="$TMP_ROOT/fail/ok.argv" \
    run_m run --fm-home "$home" --record "$rec" --now "$NOW" --skip-serve \
    --gbrain-bin "$fake" --scan-bin "$scan"
  expect_code 0 "$RC" 'seed run'
  assert_present "$rec/wiki/gbrain/conversations/sessions/s1.md" 'seed publish'
  printf '# extra\n' > "$rec/extra.md"
  git -C "$rec" add extra.md
  git -C "$rec" commit -qm extra
  GBRAIN_RC=1 GBRAIN_ARGV="$TMP_ROOT/fail/bad.argv" \
    run_m run --fm-home "$home" --record "$rec" --now "$NOW" --skip-serve \
    --gbrain-bin "$fake" --scan-bin "$scan"
  expect_code 1 "$RC" 'failed sync'
  assert_present "$rec/wiki/gbrain/conversations/sessions/s1.md" 'failed run unpublished'
  python3 - "$home/state/gbrain/brain" <<'PY' || fail "previous generation was not restored"
from pathlib import Path
import sys
brain=Path(sys.argv[1])
assert (brain/"data/keep.md").is_file()
assert not (brain/"data/extra.md").exists()
PY
  SCAN_RC=1 GBRAIN_RC=0 \
    run_m run --fm-home "$home" --record "$rec" --now "$NOW" --skip-serve \
    --gbrain-bin "$fake" --scan-bin "$scan"
  expect_code 1 "$RC" 'scan fail'
  pass 'fm-gbrain-maintain: sync or scan failure restores the prior generation'
}

test_install_archive_verifies_digest_and_refuses_mutation() {
  local src dest digest other
  src="$TMP_ROOT/install/src"
  dest="$TMP_ROOT/install/0.48.2.0"
  mkdir -p "$src"
  printf 'gbrain-bin\n' > "$src/gbrain"
  tar -C "$src" -cf "$TMP_ROOT/install/gbrain.tar" gbrain
  digest=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
    "$TMP_ROOT/install/gbrain.tar")
  run_m install-archive --archive "$TMP_ROOT/install/gbrain.tar" --sha256 "$digest" --dest "$dest"
  expect_code 0 "$RC" 'install'
  assert_present "$dest/gbrain" 'extracted binary'
  run_m install-archive --archive "$TMP_ROOT/install/gbrain.tar" --sha256 "$digest" --dest "$dest"
  expect_code 0 "$RC" 'matching reinstall'
  other=$(printf '%064x' 1)
  run_m install-archive --archive "$TMP_ROOT/install/gbrain.tar" --sha256 "$other" --dest "$dest.other"
  expect_code 1 "$RC" 'bad digest'
  printf 'old\n' > "$TMP_ROOT/install/old.tar"
  printf 'other\n' > "$dest/extra"
  run_m install-archive --archive "$TMP_ROOT/install/gbrain.tar" --sha256 "$digest" --dest "$dest"
  expect_code 0 "$RC" 'same dest same digest'
  [ -f "$dest/extra" ] || fail 'matching install rewrote dest'
  mkdir -p "$TMP_ROOT/install/other"
  printf 'x\n' > "$TMP_ROOT/install/other/gbrain"
  tar -C "$TMP_ROOT/install/other" -cf "$TMP_ROOT/install/other.tar" gbrain
  other=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' \
    "$TMP_ROOT/install/other.tar")
  run_m install-archive --archive "$TMP_ROOT/install/other.tar" --sha256 "$other" --dest "$dest"
  expect_code 1 "$RC" 'refuse mutate'
  assert_contains "$OUT" 'refusing to mutate' 'mutate error'
  pass 'fm-gbrain-maintain: install-archive checks the digest and will not mutate dest'
}

test_write_plist_is_loopback_and_secretless() {
  local bin home brain
  bin="$TMP_ROOT/plist/gbrain"
  mkdir -p "$TMP_ROOT/plist"
  printf 'bin\n' > "$bin"
  chmod +x "$bin"
  home="$TMP_ROOT/plist/home"
  brain="$TMP_ROOT/plist/brain"
  mkdir -p "$home" "$brain"
  run_m write-plist --gbrain-bin "$bin" --gbrain-home "$home" --brain "$brain" \
    --out "$TMP_ROOT/plist/job.plist"
  expect_code 0 "$RC" 'plist'
  python3 - "$TMP_ROOT/plist/job.plist" "$bin" "$home" "$brain" <<'PY' || fail "plist shape was wrong"
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert "127.0.0.1" in text
assert "--suppress-bootstrap-token" in text
assert sys.argv[2] in text
assert sys.argv[3] in text
assert sys.argv[4] in text
assert "token=" not in text.lower()
assert "password" not in text.lower()
assert "KeepAlive" in text
PY
  pass 'fm-gbrain-maintain: write-plist is loopback-only and has no secrets'
}

test_nightly_dry_run_stays_silent_and_configured_home_runs() {
  local home rec fake scan
  rec=$(new_record "$TMP_ROOT/night/record")
  home="$TMP_ROOT/night/home"
  mkdir -p "$home/config" "$home/state" "$home/data"
  mkdir -p "$TMP_ROOT/empty-home"
  set +e
  OUT=$(
    HOME="$TMP_ROOT/empty-home" FM_ROOT_OVERRIDE="$ROOT" \
      "$NIGHTLY" run --fm-home "$home" --dry-run --now "$NOW" 2>&1
  )
  RC=$?
  set -e
  expect_code 0 "$RC" 'dry-run'
  assert_contains "$OUT" $'dry-run\tviews\t' 'dry-run lists views'
  assert_not_contains "$OUT" 'gbrain' 'dry-run named gbrain'
  fake="$TMP_ROOT/night/gbrain"
  scan="$TMP_ROOT/night/scan"
  write_gbrain_stub "$fake"
  write_scan_stub "$scan"
  {
    printf 'GBRAIN_BIN=%s\n' "$fake"
    printf 'GBRAIN_SCAN=%s\n' "$scan"
  } > "$home/config/gbrain.env"
  # A configured home still keeps dry-run on the views row.
  set +e
  OUT=$(
    HOME="$TMP_ROOT/empty-home" FM_ROOT_OVERRIDE="$ROOT" \
      "$NIGHTLY" run --fm-home "$home" --dry-run --now "$NOW" 2>&1
  )
  RC=$?
  set -e
  expect_code 0 "$RC" 'configured dry-run'
  assert_not_contains "$OUT" 'gbrain' 'configured dry-run named gbrain'
  GBRAIN_ARGV="$TMP_ROOT/night/gbrain.argv" \
    run_m run --fm-home "$home" --record "$rec" --now "$NOW" --skip-serve \
    --gbrain-bin "$fake" --scan-bin "$scan"
  expect_code 0 "$RC" 'direct run from a configured home'
  assert_present "$rec/wiki/views/gbrain/receipt.json" 'receipt'
  python3 - "$home/state/gbrain/brain" "$rec" <<'PY' || fail "brain or record roots crossed"
from pathlib import Path
import os,sys
brain=os.path.realpath(sys.argv[1])
record=os.path.realpath(sys.argv[2])
assert os.path.commonpath([brain, record]) != record
PY
  pass 'fm-gbrain-maintain: nightly dry-run stays silent and the brain stays off the Record'
}

test_outer_repository_stays_clean() {
  local after
  after=$(git -C "$ROOT" status --short --untracked-files=all)
  [ "$after" = "$OUTER_STATUS_BEFORE" ] \
    || fail "fixtures changed the outer repository"$'\n'"before: $OUTER_STATUS_BEFORE"$'\n'"after: $after"
  pass 'fm-gbrain-maintain: fixtures leave the outer repository unchanged'
}

test_help_names_commands
test_project_uses_committed_blobs_only
test_project_renders_text_and_reserved_names
test_project_rejects_unsafe_and_colliding_inputs
test_run_publishes_edges_and_primary_ingest_only
test_lock_busy_does_not_stop_services
test_failed_sync_restores_and_leaves_record
test_install_archive_verifies_digest_and_refuses_mutation
test_write_plist_is_loopback_and_secretless
test_nightly_dry_run_stays_silent_and_configured_home_runs
test_outer_repository_stays_clean
