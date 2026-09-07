#!/usr/bin/env bash
# Archive, weekly-check, coverage, and restore tests for bin/fm-nightly.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NIGHTLY="$ROOT/bin/fm-nightly.sh"
TMP_ROOT=$(fm_test_tmproot fm-nightly-archive)
OUTER_STATUS_BEFORE=$(git -C "$ROOT" status --short --untracked-files=all)
fm_git_identity fmtest fmtest@example.invalid
export NIGHTLY_RUN_BOUND_SECONDS=30

NOW=2026-09-07T03:00:00Z
DATE=2026-09-07

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  git init --quiet -b main "$home/data"
  printf '# record\n' > "$home/data/README.md"
  git -C "$home/data" add README.md
  git -C "$home/data" commit --quiet -m initial
  printf '%s\n' "$home"
}

run_nightly() {
  set +e
  OUT=$(
    HOME="${NIGHTLY_HOME:-$TMP_ROOT/empty-home}" \
    FM_ROOT_OVERRIDE="$ROOT" \
    "$NIGHTLY" "$@" 2>&1
  )
  RC=$?
  set -e
}

write_restic_double() {
  local fakebin=$1
  cat > "$fakebin/restic" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_RESTIC_ARGV:-}" ]; then
  {
    printf '%s\0' "$@"
    printf '\n'
  } >> "$FAKE_RESTIC_ARGV"
fi
mode=backup
for a in "$@"; do
  case "$a" in
    backup) mode=backup ;;
    check) mode=check ;;
    restore) mode=restore ;;
    init) mode=init ;;
  esac
done
case "$mode" in
  check)
    rc=${FAKE_RESTIC_CHECK_EXIT:-${FAKE_RESTIC_EXIT:-0}}
    out=${FAKE_RESTIC_CHECK_STDOUT:-${FAKE_RESTIC_STDOUT:-}}
    ;;
  restore)
    rc=${FAKE_RESTIC_RESTORE_EXIT:-${FAKE_RESTIC_EXIT:-0}}
    out=${FAKE_RESTIC_RESTORE_STDOUT:-${FAKE_RESTIC_STDOUT:-}}
    ;;
  *)
    rc=${FAKE_RESTIC_EXIT:-0}
    out=${FAKE_RESTIC_STDOUT-}
    ;;
esac
if [ -z "$out" ] && [ "$mode" = backup ]; then
  out='{"message_type":"summary","snapshot_id":"testsnap001"}'
fi
[ -n "$out" ] && printf '%s\n' "$out"
exit "$rc"
SH
  chmod +x "$fakebin/restic"
}

write_rclone_double() {
  local fakebin=$1
  cat > "$fakebin/rclone" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_RCLONE_ARGV:-}" ]; then
  {
    printf '%s\0' "$@"
    printf '\n'
  } >> "$FAKE_RCLONE_ARGV"
fi
[ -n "${FAKE_RCLONE_STDOUT:-}" ] && printf '%s\n' "$FAKE_RCLONE_STDOUT"
exit ${FAKE_RCLONE_EXIT:-0}
SH
  chmod +x "$fakebin/rclone"
}

write_config() {
  local home=$1
  {
    printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s/repo\n' "$TMP_ROOT/$2"
    printf 'NIGHTLY_RCLONE_CONFIG=%s/rclone.conf\n' "$TMP_ROOT/$2"
    printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s/pw\n' "$TMP_ROOT/$2"
    printf 'NIGHTLY_ARCHIVE_HOST=testhost\n'
  } > "$home/config/nightly.env"
  printf '[fixture]\ntype = local\n' > "$TMP_ROOT/$2/rclone.conf"
  printf 'secret\n' > "$TMP_ROOT/$2/pw"
}

seed_families() {
  local root=$1
  mkdir -p "$root/.claude/projects/demo" \
    "$root/.codex/sessions" \
    "$root/.pi/agent/sessions" \
    "$root/.cursor/projects/my project/agent-transcripts" \
    "$root/.cursor/projects/[a]star/agent-transcripts" \
    "$root/.cursor/projects/ünicode/agent-transcripts" \
    "$root/.grok/sessions/[a]*"
  printf 'space file\n' > "$root/.claude/projects/demo/my file.txt"
  printf 'cafe\n' > "$root/.codex/sessions/café.txt"
  printf 'han\n' > "$root/.pi/agent/sessions/文件.txt"
  printf 'cursor-a\n' > "$root/.cursor/projects/my project/agent-transcripts/note.md"
  printf 'cursor-b\n' > "$root/.cursor/projects/[a]star/agent-transcripts/note.md"
  printf 'cursor-c\n' > "$root/.cursor/projects/ünicode/agent-transcripts/note.md"
  printf 'glob\n' > "$root/.grok/sessions/[a]*/note.txt"
}

argv_has_literal() {
  python3 - "$1" "$2" <<'PY'
import sys
needle = sys.argv[2].encode()
raw = open(sys.argv[1], "rb").read()
sys.exit(0 if needle in raw else 1)
PY
}

argv_has_unexpanded_glob() {
  python3 - "$1" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
# A restic source argument that still contains the family glob pattern.
if b"projects/*/agent-transcripts" in raw:
    sys.exit(0)
sys.exit(1)
PY
}

test_archive_argv_five_families() {
  local home fakebin trans
  home=$(new_home argv)
  write_config "$home" argv
  trans="$TMP_ROOT/argv/trans"
  seed_families "$trans"
  fakebin=$(fm_fakebin "$TMP_ROOT/argv")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  mkdir -p "$TMP_ROOT/empty-home"
  FAKE_RESTIC_ARGV="$TMP_ROOT/argv/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'archive argv'
  assert_not_contains "$OUT" 'secret' 'password leaked into stdout'
  assert_present "$TMP_ROOT/argv/restic.argv" 'restic was invoked'
  argv_has_unexpanded_glob "$TMP_ROOT/argv/restic.argv" && fail 'unexpanded cursor glob reached restic'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "--compression" || fail 'missing --compression'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "auto" || fail 'missing auto'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "--json" || fail 'missing --json'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "fm-transcripts" || fail 'missing tag'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "$trans/.claude/projects" || fail 'claude family missing'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "$trans/.cursor/projects/my project/agent-transcripts" \
    || fail 'cursor path with space missing'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "$trans/.cursor/projects/[a]star/agent-transcripts" \
    || fail 'cursor glob-char path missing'
  argv_has_literal "$TMP_ROOT/argv/restic.argv" "$trans/.cursor/projects/ünicode/agent-transcripts" \
    || fail 'cursor unicode path missing'
  python3 - "$home/data/.git/nightly/archive.json" <<'PY' || fail 'snapshot id missing'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["last_complete_snapshot"] == "testsnap001"
assert data["last_result"] == "ok"
PY
  pass "fm-nightly: archive passes real family dirs after -- and records a snapshot id"
}

test_cursor_zero_and_n_matches() {
  local home fakebin trans
  home=$(new_home cursor0)
  write_config "$home" cursor0
  trans="$TMP_ROOT/cursor0/trans"
  mkdir -p "$trans/.claude/projects" "$trans/.codex/sessions" \
    "$trans/.pi/agent/sessions" "$trans/.grok/sessions"
  fakebin=$(fm_fakebin "$TMP_ROOT/cursor0")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  FAKE_RESTIC_ARGV="$TMP_ROOT/cursor0/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'cursor 0'
  python3 - "$home/data/.git/nightly/archive.json" <<'PY' || fail 'cursor 0 coverage'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
fam = data["families"][".cursor/projects/*/agent-transcripts"]["coverage"]
assert fam == "missing", fam
PY
  argv_has_unexpanded_glob "$TMP_ROOT/cursor0/restic.argv" && fail 'zero-match still passed a glob'

  home=$(new_home cursorn)
  write_config "$home" cursorn
  trans="$TMP_ROOT/cursorn/trans"
  seed_families "$trans"
  fakebin=$(fm_fakebin "$TMP_ROOT/cursorn")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  FAKE_RESTIC_ARGV="$TMP_ROOT/cursorn/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'cursor N'
  python3 - "$home/data/.git/nightly/archive.json" <<'PY' || fail 'cursor N coverage'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
fam = data["families"][".cursor/projects/*/agent-transcripts"]["coverage"]
assert fam == "present", fam
PY
  pass "fm-nightly: cursor 0 matches are missing and N matches are present"
}

test_restic_exit_3_incomplete() {
  local home fakebin trans
  home=$(new_home inc)
  write_config "$home" inc
  trans="$TMP_ROOT/inc/trans"
  seed_families "$trans"
  fakebin=$(fm_fakebin "$TMP_ROOT/inc")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  FAKE_RESTIC_EXIT=3 FAKE_RESTIC_STDOUT='{"message_type":"summary","snapshot_id":"partial999"}' \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  assert_grep $'archive\tfinding\t' "$home/data/.git/nightly/stages.tsv" 'exit 3 is finding'
  assert_grep $'incomplete' "$home/data/.git/nightly/stages.tsv" 'incomplete detail'
  python3 - "$home/data/.git/nightly/archive.json" <<'PY' || fail 'incomplete recorded as complete'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("last_complete_snapshot") in (None, "")
assert data["last_result"] == "incomplete"
PY
  pass "fm-nightly: restic exit 3 is incomplete and does not record last_complete_snapshot"
}

test_restic_exit_1_failed() {
  local home fakebin trans
  home=$(new_home fail1)
  write_config "$home" fail1
  trans="$TMP_ROOT/fail1/trans"
  seed_families "$trans"
  fakebin=$(fm_fakebin "$TMP_ROOT/fail1")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  FAKE_RESTIC_EXIT=1 \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  expect_code 1 "$RC" 'archive failed'
  assert_grep $'archive\tfailed\t' "$home/data/.git/nightly/stages.tsv" 'exit 1 failed'
  python3 - "$home/data/.git/nightly/archive.json" <<'PY' || fail 'failed result'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["last_result"] == "failed"
assert data.get("last_complete_snapshot") in (None, "")
PY
  pass "fm-nightly: restic exit 1 is failed"
}

test_weekly_check_due_missed_advance() {
  local home fakebin trans
  home=$(new_home weekly)
  write_config "$home" weekly
  trans="$TMP_ROOT/weekly/trans"
  seed_families "$trans"
  fakebin=$(fm_fakebin "$TMP_ROOT/weekly")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  mkdir -p "$home/data/.git/nightly"
  printf '{"subset":1,"next_due":"2026-09-14","last_result":"ok"}\n' \
    > "$home/data/.git/nightly/weekly-check.json"
  FAKE_RESTIC_ARGV="$TMP_ROOT/weekly/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW" --scheduled-date "$DATE"
  assert_grep $'weekly-check\tskipped\t' "$home/data/.git/nightly/stages.tsv" 'not due skipped'
  python3 - "$home/data/.git/nightly/weekly-check.json" <<'PY' || fail 'not-due mutated'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["subset"] == 1
assert data["next_due"] == "2026-09-14"
PY

  printf '{"subset":2,"next_due":"2026-09-07","last_result":"ok"}\n' \
    > "$home/data/.git/nightly/weekly-check.json"
  FAKE_RESTIC_CHECK_EXIT=1 FAKE_RESTIC_ARGV="$TMP_ROOT/weekly/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW" --scheduled-date "$DATE"
  assert_grep $'weekly-check\tfailed\t' "$home/data/.git/nightly/stages.tsv" 'failed weekly'
  python3 - "$home/data/.git/nightly/weekly-check.json" <<'PY' || fail 'failed weekly advanced'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["subset"] == 2
assert data["next_due"] == "2026-09-07"
assert data["last_result"] == "failed"
PY

  printf '{"subset":2,"next_due":"2026-09-07","last_result":"failed"}\n' \
    > "$home/data/.git/nightly/weekly-check.json"
  unset FAKE_RESTIC_CHECK_EXIT
  FAKE_RESTIC_CHECK_EXIT=0 FAKE_RESTIC_ARGV="$TMP_ROOT/weekly/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW" --scheduled-date "$DATE"
  python3 - "$home/data/.git/nightly/weekly-check.json" <<'PY' || fail 'success did not advance'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["subset"] == 3
assert data["next_due"] == "2026-09-14"
assert data["last_result"] == "ok"
PY
  argv_has_literal "$TMP_ROOT/weekly/restic.argv" "--read-data-subset=2/4" \
    || fail 'subset 2/4 not passed'
  pass "fm-nightly: weekly-check skips when not due, stays due on failure, and advances on success"
}

test_coverage_regression() {
  local home fakebin trans
  home=$(new_home regress)
  write_config "$home" regress
  trans="$TMP_ROOT/regress/trans"
  seed_families "$trans"
  fakebin=$(fm_fakebin "$TMP_ROOT/regress")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'baseline archive'
  rm -rf "$trans/.codex"
  NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  assert_grep $'archive\tfinding\t' "$home/data/.git/nightly/stages.tsv" 'regression finding'
  assert_grep $'coverage-regressed' "$home/data/.git/nightly/stages.tsv" 'regression detail'
  pass "fm-nightly: a disappeared family is coverage-regressed"
}

test_restore_refuses_nonempty_and_implicit_latest() {
  local home target
  home=$(new_home restore-ref)
  target="$TMP_ROOT/restore-ref/out"
  mkdir -p "$target"
  printf 'x\n' > "$target/kept"
  run_nightly restore --fm-home "$home" --target "$target"
  expect_code 2 "$RC" 'non-empty'
  run_nightly restore --fm-home "$home" --target "$TMP_ROOT/restore-ref/empty"
  expect_code 2 "$RC" 'no snapshot'
  pass "fm-nightly: restore refuses a non-empty target and latest unless --snapshot is passed"
}

test_restore_explicit_latest_hits_restic() {
  local home fakebin dest
  home=$(new_home restore-latest)
  write_config "$home" restore-latest
  dest="$TMP_ROOT/restore-latest/dest"
  mkdir -p "$dest"
  fakebin=$(fm_fakebin "$TMP_ROOT/restore-latest")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  FAKE_RESTIC_ARGV="$TMP_ROOT/restore-latest/restic.argv" \
    PATH="$fakebin:$PATH" \
    run_nightly restore --fm-home "$home" --target "$dest" --snapshot latest
  expect_code 0 "$RC" 'explicit latest'
  argv_has_literal "$TMP_ROOT/restore-latest/restic.argv" "latest" || fail 'latest not passed'
  argv_has_literal "$TMP_ROOT/restore-latest/restic.argv" "restore" || fail 'restore not passed'
  pass "fm-nightly: --snapshot latest is passed to restic only when explicit"
}

test_symlink_family_skipped() {
  local home fakebin trans
  home=$(new_home symlink)
  write_config "$home" symlink
  trans="$TMP_ROOT/symlink/trans"
  mkdir -p "$trans/.codex/sessions" "$trans/.pi/agent/sessions" "$trans/.grok/sessions" "$trans/elsewhere"
  ln -s "$trans/elsewhere" "$trans/.claude"
  fakebin=$(fm_fakebin "$TMP_ROOT/symlink")
  write_restic_double "$fakebin"
  write_rclone_double "$fakebin"
  FAKE_RESTIC_ARGV="$TMP_ROOT/symlink/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  python3 - "$home/data/.git/nightly/archive.json" <<'PY' || fail 'symlink coverage'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["families"][".claude/projects"]["coverage"] == "symlink-skipped"
PY
  argv_has_literal "$TMP_ROOT/symlink/restic.argv" "$trans/.claude/projects" \
    && fail 'symlinked family was passed to restic'
  pass "fm-nightly: a symlinked family root is symlink-skipped"
}

test_real_restic_roundtrip() {
  local home trans repo dest src hash_src hash_dst
  if ! command -v restic >/dev/null || ! command -v rclone >/dev/null; then
    echo 'skip: restic not found'
    return 0
  fi
  home=$(new_home real)
  trans="$TMP_ROOT/real/trans"
  repo="$TMP_ROOT/real/repo"
  dest="$TMP_ROOT/real/restore"
  seed_families "$trans"
  mkdir -p "$repo" "$dest"
  printf '[fixture]\ntype = local\n' > "$TMP_ROOT/real/rclone.conf"
  printf 'real-password\n' > "$TMP_ROOT/real/pw"
  {
    printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s\n' "$repo"
    printf 'NIGHTLY_RCLONE_CONFIG=%s\n' "$TMP_ROOT/real/rclone.conf"
    printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s\n' "$TMP_ROOT/real/pw"
    printf 'NIGHTLY_ARCHIVE_HOST=testhost\n'
  } > "$home/config/nightly.env"
  RCLONE_CONFIG="$TMP_ROOT/real/rclone.conf" \
    RESTIC_PASSWORD_COMMAND="cat $TMP_ROOT/real/pw" \
    restic -r "rclone:fixture:$repo" init >/dev/null
  NIGHTLY_HOME="$trans" \
    run_nightly archive --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'real archive'
  python3 - "$home/data/.git/nightly/archive.json" <<'PY' || fail 'real snapshot missing'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("last_complete_snapshot")
PY
  NIGHTLY_HOME="$trans" \
    run_nightly restore --fm-home "$home" --target "$dest"
  expect_code 0 "$RC" 'real restore'
  src="$trans/.claude/projects/demo/my file.txt"
  hash_src=$(shasum -a 256 -- "$src" | awk '{print $1}')
  hash_dst=$(find "$dest" -name 'my file.txt' -type f -print | head -n 1)
  [ -n "$hash_dst" ] || fail 'restored file missing'
  hash_dst=$(shasum -a 256 -- "$hash_dst" | awk '{print $1}')
  [ "$hash_src" = "$hash_dst" ] || fail "sha256 mismatch $hash_src $hash_dst"
  pass "fm-nightly: real restic archive and restore keep file bytes"
}

test_outer_repository_stays_clean() {
  local after
  after=$(git -C "$ROOT" status --short --untracked-files=all)
  [ "$after" = "$OUTER_STATUS_BEFORE" ] || fail "outer repository changed: $after"
  pass "fm-nightly-archive: the outer repository stays clean"
}

test_archive_argv_five_families
test_cursor_zero_and_n_matches
test_restic_exit_3_incomplete
test_restic_exit_1_failed
test_weekly_check_due_missed_advance
test_coverage_regression
test_restore_refuses_nonempty_and_implicit_latest
test_restore_explicit_latest_hits_restic
test_symlink_family_skipped
test_real_restic_roundtrip
test_outer_repository_stays_clean
