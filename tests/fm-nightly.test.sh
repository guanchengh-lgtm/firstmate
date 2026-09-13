#!/usr/bin/env bash
# Behavior tests for bin/fm-nightly.sh through the public executable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NIGHTLY="$ROOT/bin/fm-nightly.sh"
RECORD="$ROOT/bin/fm-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-nightly)
OUTER_STATUS_BEFORE=$(git -C "$ROOT" status --short --untracked-files=all)
fm_git_identity fmtest fmtest@example.invalid
export FM_RECORD_SETTLE_SECONDS=${FM_RECORD_SETTLE_SECONDS:-0}
export FM_RECORD_LOCK_WAIT_SECONDS=${FM_RECORD_LOCK_WAIT_SECONDS:-1}
export FM_RECORD_PUSH_TIMEOUT=${FM_RECORD_PUSH_TIMEOUT:-5}
export NIGHTLY_TICK_RETRY_SECONDS=0
export NIGHTLY_RUN_BOUND_SECONDS=30

NOW=2026-09-07T03:00:00Z
DATE=2026-09-07

new_home() {
  local name=$1 home origin
  home="$TMP_ROOT/$name/home"
  origin="$TMP_ROOT/$name/origin.git"
  mkdir -p "$home/data" "$home/state" "$home/config" "$TMP_ROOT/$name/logs"
  git init --quiet --bare --initial-branch=main "$origin"
  printf '%s\t%s\n' "$home" "$origin"
}

run_rec() {
  local home=$1
  shift
  set +e
  OUT=$(
    HOME="$TMP_ROOT/empty-home" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_RECORD_SETTLE_SECONDS="${FM_RECORD_SETTLE_SECONDS}" \
    FM_RECORD_LOCK_WAIT_SECONDS="${FM_RECORD_LOCK_WAIT_SECONDS}" \
    FM_RECORD_PUSH_TIMEOUT="${FM_RECORD_PUSH_TIMEOUT}" \
    "$RECORD" "$@" 2>&1
  )
  RC=$?
  set -e
}

setup_record() {
  local home=$1 origin=$2
  mkdir -p "$TMP_ROOT/empty-home"
  run_rec "$home" setup --init --origin "file://$origin" --code-root "$ROOT"
  expect_code 0 "$RC" "setup $home"
  printf '# backlog\n' > "$home/data/backlog.md"
  # A live Record always has a pushed first commit before any night runs.
  run_rec "$home" tick
  expect_code 0 "$RC" "first tick $home"
}

setup_minimal_record() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config"
  if [ ! -d "$home/data/.git" ]; then
    git init --quiet -b main "$home/data"
    printf '# record\n' > "$home/data/README.md"
    git -C "$home/data" add README.md
    git -C "$home/data" commit --quiet -m initial
  fi
}

make_code_root() {
  local dest=$1
  mkdir -p "$dest"
  cp -R "$ROOT/bin" "$dest/bin"
  git init --quiet --initial-branch=main "$dest"
  git -C "$dest" add bin
  git -C "$dest" commit --quiet -m 'nightly code root'
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

write_named_double() {
  local fakebin=$1 name=$2 argv_var=$3 exit_var=$4 stdout_var=$5
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
if [ -n "\${$argv_var:-}" ]; then
  {
    printf '%s\\0' "\$@"
    printf '\\n'
  } >> "\$$argv_var"
fi
out=\${$stdout_var:-}
[ -n "\$out" ] && printf '%s\\n' "\$out"
exit \${$exit_var:-0}
SH
  chmod +x "$fakebin/$name"
}

write_tool_doubles() {
  local fakebin=$1
  write_restic_double "$fakebin"
  write_named_double "$fakebin" rclone FAKE_RCLONE_ARGV FAKE_RCLONE_EXIT FAKE_RCLONE_STDOUT
  write_named_double "$fakebin" launchctl FAKE_LAUNCHCTL_ARGV FAKE_LAUNCHCTL_EXIT FAKE_LAUNCHCTL_STDOUT
  write_named_double "$fakebin" plutil FAKE_PLUTIL_ARGV FAKE_PLUTIL_EXIT FAKE_PLUTIL_STDOUT
}

test_help_lists_subcommands() {
  run_nightly --help
  expect_code 0 "$RC" 'nightly --help'
  assert_contains "$OUT" 'fm-nightly.sh run --fm-home PATH' 'help names run'
  assert_contains "$OUT" 'fm-nightly.sh archive --fm-home PATH' 'help names archive'
  assert_contains "$OUT" 'fm-nightly.sh restore --fm-home PATH --target DIR' 'help names restore'
  assert_contains "$OUT" 'fm-nightly.sh install --fm-home PATH' 'help names install'
  assert_contains "$OUT" 'fm-nightly.sh status --fm-home PATH' 'help names status'
  pass "fm-nightly: --help prints the operator contract"
}

test_install_renders_plist() {
  local home origin plist code_root logs
  IFS=$(printf '\t') read -r home origin < <(new_home install-plist)
  setup_minimal_record "$home"
  plist="$TMP_ROOT/install-plist/nightly.plist"
  logs="$TMP_ROOT/install-plist/logs"
  mkdir -p "$logs"
  code_root="$TMP_ROOT/install-plist/code"
  make_code_root "$code_root"
  FM_NIGHTLY_PLIST="$plist" FM_NIGHTLY_LOG_DIR="$logs" \
    run_nightly install --fm-home "$home" --hour 4 --minute 15 --code-root "$code_root"
  expect_code 0 "$RC" 'install'
  assert_present "$plist" 'rendered plist'
  python3 - "$plist" "$code_root" "$home" "$logs" <<'PY' || fail 'plist keys'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    job = plistlib.load(fh)
assert job["Label"] == "com.firstmate.nightly"
assert job["ProgramArguments"] == [sys.argv[2] + "/bin/fm-nightly.sh", "run", "--fm-home", sys.argv[3]]
assert job["EnvironmentVariables"]["FM_HOME"] == sys.argv[3]
assert "PATH" in job["EnvironmentVariables"]
assert job["StartCalendarInterval"]["Hour"] == 4
assert job["StartCalendarInterval"]["Minute"] == 15
assert job["ProcessType"] == "Background"
assert job["LimitLoadToSessionType"] == "Aqua"
assert "RunAtLoad" not in job
assert "KeepAlive" not in job
assert job["StandardOutPath"] == sys.argv[4] + "/firstmate-nightly.stdout.log"
assert job["StandardErrorPath"] == sys.argv[4] + "/firstmate-nightly.stderr.log"
PY
  grep -Fq 'firstmate-nightly-v1' "$plist" || fail 'missing nightly marker'
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null || fail 'plutil -lint failed'
  fi
  pass "fm-nightly: install renders a parsable LaunchAgent plist"
}

test_install_refuses_unknown_plist() {
  local home origin plist code_root before
  IFS=$(printf '\t') read -r home origin < <(new_home install-unknown)
  setup_minimal_record "$home"
  plist="$TMP_ROOT/install-unknown/nightly.plist"
  printf 'not-our-job\n' > "$plist"
  before=$(cat "$plist")
  code_root="$TMP_ROOT/install-unknown/code"
  make_code_root "$code_root"
  FM_NIGHTLY_PLIST="$plist" \
    run_nightly install --fm-home "$home" --code-root "$code_root"
  expect_code 8 "$RC" 'unknown plist'
  [ "$(cat "$plist")" = "$before" ] || fail 'unknown plist was rewritten'
  pass "fm-nightly: install leaves an unknown LaunchAgent untouched"
}

test_install_invalid_hour() {
  local home origin plist code_root
  IFS=$(printf '\t') read -r home origin < <(new_home install-hour)
  setup_minimal_record "$home"
  plist="$TMP_ROOT/install-hour/nightly.plist"
  code_root="$TMP_ROOT/install-hour/code"
  make_code_root "$code_root"
  FM_NIGHTLY_PLIST="$plist" \
    run_nightly install --fm-home "$home" --hour 24 --code-root "$code_root"
  expect_code 2 "$RC" 'hour 24'
  assert_absent "$plist" 'invalid hour wrote a plist'
  FM_NIGHTLY_PLIST="$plist" \
    run_nightly install --fm-home "$home" --minute 60 --code-root "$code_root"
  expect_code 2 "$RC" 'minute 60'
  pass "fm-nightly: install refuses an invalid hour or minute"
}

test_install_refuses_worktree_code_root() {
  local home origin plist code_root linked
  IFS=$(printf '\t') read -r home origin < <(new_home install-worktree)
  setup_minimal_record "$home"
  plist="$TMP_ROOT/install-worktree/nightly.plist"
  code_root="$TMP_ROOT/install-worktree/code"
  make_code_root "$code_root"
  linked="$TMP_ROOT/install-worktree/linked"
  git -C "$code_root" worktree add --quiet --detach "$linked"
  FM_NIGHTLY_PLIST="$plist" \
    run_nightly install --fm-home "$home" --code-root "$linked"
  expect_code 8 "$RC" 'worktree code-root'
  assert_contains "$OUT" 'primary code checkout' 'worktree refusal'
  assert_absent "$plist" 'worktree install wrote a plist'
  pass "fm-nightly: install refuses a worktree code root"
}

test_install_bootstrap_records_launchctl() {
  local home origin plist code_root fakebin logs
  IFS=$(printf '\t') read -r home origin < <(new_home install-boot)
  setup_minimal_record "$home"
  plist="$TMP_ROOT/install-boot/nightly.plist"
  logs="$TMP_ROOT/install-boot/logs"
  mkdir -p "$logs"
  code_root="$TMP_ROOT/install-boot/code"
  make_code_root "$code_root"
  fakebin=$(fm_fakebin "$TMP_ROOT/install-boot")
  write_tool_doubles "$fakebin"
  FAKE_LAUNCHCTL_ARGV="$TMP_ROOT/install-boot/launchctl.argv" \
    FM_NIGHTLY_PLIST="$plist" FM_NIGHTLY_LOG_DIR="$logs" \
    PATH="$fakebin:$PATH" \
    run_nightly install --fm-home "$home" --code-root "$code_root" --bootstrap
  expect_code 0 "$RC" 'bootstrap install'
  python3 - "$TMP_ROOT/install-boot/launchctl.argv" "$plist" <<'PY' || fail 'launchctl argv'
import sys
raw = open(sys.argv[1], "rb").read().split(b"\n")
chunks = [c.split(b"\0") for c in raw if c]
flat = [part.decode() for chunk in chunks for part in chunk if part]
joined = " ".join(flat)
assert "bootout" in joined
assert "bootstrap" in joined
assert sys.argv[2] in joined
PY
  pass "fm-nightly: --bootstrap records launchctl bootout and bootstrap"
}

test_dry_run_lists_every_stage() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home dry)
  setup_minimal_record "$home"
  mkdir -p "$TMP_ROOT/empty-home"
  run_nightly run --fm-home "$home" --dry-run --now "$NOW"
  expect_code 0 "$RC" 'dry-run'
  for name in config lock reconcile-local reconcile lint rollout fold views \
    graphify archive weekly-check injected-measures drift receipt \
    checkpoint verify; do
    assert_contains "$OUT" "dry-run	$name	" "dry-run lists $name"
  done
  assert_contains "$OUT" $'dry-run\treconcile\twould: skip home path' 'home path skip'
  assert_contains "$OUT" $'dry-run\tarchive\twould: skip not-configured' 'archive not-configured'
  assert_contains "$OUT" $'dry-run\tgraphify\twould: skip not-configured' 'graphify not-configured'
  assert_not_contains "$OUT" 'gbrain' 'no gbrain stage'
  assert_contains "$OUT" $'dry-run\tweekly-check\twould: skip not-configured' 'weekly-check not-configured'
  assert_absent "$home/data/.git/nightly/stages.tsv" 'dry-run wrote stages.tsv'
  pass "fm-nightly: dry-run lists every stage and writes nothing"
}

test_dry_run_record_only_skips_cloud() {
  local clone
  clone="$TMP_ROOT/dry-ro/clone"
  mkdir -p "$clone"
  git init --quiet -b main "$clone"
  printf 'x\n' > "$clone/README.md"
  git -C "$clone" add README.md
  git -C "$clone" commit --quiet -m init
  run_nightly run --record-only --record "$clone" --dry-run --now "$NOW"
  expect_code 0 "$RC" 'record-only dry-run'
  for name in reconcile-local graphify archive injected-measures weekly-check; do
    assert_contains "$OUT" "dry-run	$name	would: skip cloud scope" "cloud skip $name"
  done
  pass "fm-nightly: record-only dry-run skips cloud-ok stages from the table"
}

test_refuse_home_with_record_only() {
  local home origin clone
  IFS=$(printf '\t') read -r home origin < <(new_home refuse-combo)
  setup_minimal_record "$home"
  clone="$home/data"
  run_nightly run --fm-home "$home" --record-only --record "$clone" --dry-run --now "$NOW"
  expect_code 2 "$RC" 'combined flags'
  mkdir -p "$TMP_ROOT/empty-home"
  set +e
  OUT=$(
    cd "$home" || exit 1
    HOME="$TMP_ROOT/empty-home" FM_ROOT_OVERRIDE="$ROOT" "$NIGHTLY" run --dry-run --now "$NOW" 2>&1
  )
  RC=$?
  set -e
  expect_code 2 "$RC" 'missing --fm-home'
  pass "fm-nightly: refuses combined home/record flags and does not infer cwd"
}

test_busy_exit_3() {
  local home origin holder
  IFS=$(printf '\t') read -r home origin < <(new_home busy)
  setup_minimal_record "$home"
  mkdir -p "$home/data/.git/nightly" "$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_lock_try_acquire "$2" || exit 1
      sleep 120
    ' _ "$ROOT" "$home/data/.git/nightly/lock" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ]; do
    if [ -e "$home/data/.git/nightly/lock" ]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$home/data/.git/nightly/lock" ] || fail 'holder did not acquire the lock'
  printf 'archive\tfailed\t3\texit-1\n' > "$home/data/.git/nightly/stages.tsv"
  printf 'date=2026-09-06\nresult=failed\n' > "$home/data/.git/nightly/last-attempt"
  run_nightly run --fm-home "$home" --now "$NOW"
  expect_code 3 "$RC" 'busy run'
  assert_contains "$OUT" 'busy' 'busy printed'
  [ "$(cat "$home/data/.git/nightly/stages.tsv")" = $'archive\tfailed\t3\texit-1' ] \
    || fail 'a busy run rewrote the live stage table'
  [ "$(cat "$home/data/.git/nightly/last-attempt")" = $'date=2026-09-06\nresult=failed' ] \
    || fail 'a busy run rewrote last-attempt'
  assert_absent "$home/data/.git/nightly/last-complete" 'a busy run claimed a complete night'
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-nightly: a held lock prints busy, exits 3, and leaves the live run files alone"
}

test_run_bound_stops_the_in_flight_stage() {
  local home origin fakebin trans pidfile i
  IFS=$(printf '\t') read -r home origin < <(new_home run-bound)
  setup_minimal_record "$home"
  trans="$TMP_ROOT/run-bound/trans-home"
  mkdir -p "$trans/.claude/projects"
  printf 'hi\n' > "$trans/.claude/projects/a.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/run-bound")
  write_tool_doubles "$fakebin"
  pidfile="$TMP_ROOT/run-bound/restic.pid"
  cat > "$fakebin/restic" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$pidfile"
sleep 60
SH
  chmod +x "$fakebin/restic"
  {
    printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s/repo\n' "$TMP_ROOT/run-bound"
    printf 'NIGHTLY_RCLONE_CONFIG=%s/rclone.conf\n' "$TMP_ROOT/run-bound"
    printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s/pw\n' "$TMP_ROOT/run-bound"
    printf 'NIGHTLY_RUN_BOUND_SECONDS=3\n'
  } > "$home/config/nightly.env"
  printf '[fixture]\ntype = local\n' > "$TMP_ROOT/run-bound/rclone.conf"
  printf 'pw\n' > "$TMP_ROOT/run-bound/pw"
  mkdir -p "$home/data/.git/nightly"
  printf 'date=2026-09-06\n' > "$home/data/.git/nightly/last-complete"
  NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly run --fm-home "$home" --now "$NOW"
  expect_code 1 "$RC" 'bounded run'
  assert_grep $'interrupted\tinterrupted\t0\tbound-hit' "$home/data/.git/nightly/stages.tsv" \
    'run bound recorded'
  assert_grep 'result=failed' "$home/data/.git/nightly/last-attempt" 'bounded run is not ok'
  [ "$(cat "$home/data/.git/nightly/last-complete")" = 'date=2026-09-06' ] \
    || fail 'a bounded run overwrote the prior success'
  assert_present "$pidfile" 'restic double started'
  i=0
  while [ "$i" -lt 20 ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$(cat "$pidfile")" 2>/dev/null && fail 'the in-flight restic outlived the run bound'
  assert_absent "$home/data/.git/nightly/lock" 'lock released after the bound'
  pass "fm-nightly: the run bound stops the in-flight stage and keeps the prior success"
}

test_restore_refuses_nonempty_and_implicit_latest() {
  local home origin target
  IFS=$(printf '\t') read -r home origin < <(new_home restore-refuse)
  setup_minimal_record "$home"
  target="$TMP_ROOT/restore-refuse/out"
  mkdir -p "$target"
  printf 'keep\n' > "$target/file"
  run_nightly restore --fm-home "$home" --target "$target"
  expect_code 2 "$RC" 'non-empty target'
  run_nightly restore --fm-home "$home" --target "$TMP_ROOT/restore-refuse/empty"
  expect_code 2 "$RC" 'missing snapshot'
  assert_not_contains "$OUT" 'latest' 'implicit latest was used'
  pass "fm-nightly: restore refuses a non-empty target and implicit latest"
}

test_archive_subcommand_leaves_the_run_receipt_alone() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home archive-receipt)
  setup_minimal_record "$home"
  mkdir -p "$home/data/.git/nightly" "$TMP_ROOT/empty-home"
  printf 'date=2026-09-06\nresult=failed\n' > "$home/data/.git/nightly/last-attempt"
  run_nightly archive --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'archive subcommand'
  assert_grep $'archive\t' "$home/data/.git/nightly/stages.tsv" 'archive stage row'
  assert_grep 'result=failed' "$home/data/.git/nightly/last-attempt" 'the failed night receipt survives'
  assert_absent "$home/data/.git/nightly/last-complete" 'archive alone claimed a complete night'
  pass "fm-nightly: the archive subcommand never writes last-attempt or last-complete"
}

test_status_reads_local_files() {
  local home origin plist
  IFS=$(printf '\t') read -r home origin < <(new_home status)
  setup_minimal_record "$home"
  mkdir -p "$home/data/.git/nightly"
  printf 'date=%s\nresult=ok\n' "$DATE" > "$home/data/.git/nightly/last-attempt"
  printf 'date=%s\n' "$DATE" > "$home/data/.git/nightly/last-complete"
  printf '{"last_complete_snapshot":"abc","last_exit":0,"last_result":"ok","families":{}}\n' \
    > "$home/data/.git/nightly/archive.json"
  printf '{"subset":2,"next_due":"2026-09-14","last_result":"ok"}\n' \
    > "$home/data/.git/nightly/weekly-check.json"
  plist="$TMP_ROOT/status/nightly.plist"
  FM_NIGHTLY_PLIST="$plist" run_nightly status --fm-home "$home"
  expect_code 0 "$RC" 'status'
  assert_contains "$OUT" 'last-attempt:' 'status last-attempt'
  assert_contains "$OUT" 'abc' 'status archive id'
  assert_contains "$OUT" 'weekly-check:' 'status weekly'
  assert_contains "$OUT" 'plist: absent' 'status missing plist'
  pass "fm-nightly: status prints last-attempt, archive, weekly-check, and plist"
}

test_full_run_on_record_home() {
  local home origin fakebin trans
  IFS=$(printf '\t') read -r home origin < <(new_home full-run)
  setup_record "$home" "$origin"
  trans="$TMP_ROOT/full-run/trans-home"
  mkdir -p "$trans/.claude/projects" "$trans/.codex/sessions" \
    "$trans/.pi/agent/sessions" "$trans/.grok/sessions"
  printf 'hi\n' > "$trans/.claude/projects/a.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/full-run")
  write_tool_doubles "$fakebin"
  printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s/repo\n' "$TMP_ROOT/full-run" > "$home/config/nightly.env"
  printf 'NIGHTLY_RCLONE_CONFIG=%s/rclone.conf\n' "$TMP_ROOT/full-run" >> "$home/config/nightly.env"
  printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s/pw\n' "$TMP_ROOT/full-run" >> "$home/config/nightly.env"
  printf '[fixture]\ntype = local\n' > "$TMP_ROOT/full-run/rclone.conf"
  printf 'pw\n' > "$TMP_ROOT/full-run/pw"
  FAKE_RESTIC_ARGV="$TMP_ROOT/full-run/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly run --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'full run'
  assert_present "$home/data/.git/nightly/stages.tsv" 'stages.tsv'
  assert_grep $'config\tok\t' "$home/data/.git/nightly/stages.tsv" 'config ok'
  assert_grep $'checkpoint\tok\t' "$home/data/.git/nightly/stages.tsv" 'checkpoint ok'
  assert_grep $'verify\tok\t' "$home/data/.git/nightly/stages.tsv" 'verify ok'
  assert_grep $'\tequal=yes' "$home/data/.git/nightly/stages.tsv" 'verify equal=yes'
  assert_present "$home/data/wiki/views/maintenance" 'receipt dir'
  git --git-dir="$origin" log -1 --format=%s | grep -Fq "maintain $DATE" \
    || fail 'maintain commit missing from origin'
  assert_grep 'result=ok' "$home/data/.git/nightly/last-attempt" 'last-attempt result ok'
  assert_grep 'verify=fm-record: state=verified equal=yes' "$home/data/.git/nightly/last-attempt" 'last-attempt verify line'
  assert_grep "date=$DATE" "$home/data/.git/nightly/last-complete" 'last-complete date'
  pass "fm-nightly: full run on a Record home writes stages, receipt, and a maintain commit"
}

test_lint_finding_does_not_stop_archive() {
  local home origin fakebin trans
  IFS=$(printf '\t') read -r home origin < <(new_home lint-find)
  setup_record "$home" "$origin"
  printf -- '- [ ] T9 - pending later\n' >> "$home/data/backlog.md"
  git -C "$home/data" add backlog.md
  git -C "$home/data" commit --quiet -m 'deferral'
  trans="$TMP_ROOT/lint-find/trans-home"
  mkdir -p "$trans/.claude/projects"
  printf 'x\n' > "$trans/.claude/projects/a.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/lint-find")
  write_tool_doubles "$fakebin"
  printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s/repo\n' "$TMP_ROOT/lint-find" > "$home/config/nightly.env"
  printf 'NIGHTLY_RCLONE_CONFIG=%s/rclone.conf\n' "$TMP_ROOT/lint-find" >> "$home/config/nightly.env"
  printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s/pw\n' "$TMP_ROOT/lint-find" >> "$home/config/nightly.env"
  printf '[fixture]\ntype = local\n' > "$TMP_ROOT/lint-find/rclone.conf"
  printf 'pw\n' > "$TMP_ROOT/lint-find/pw"
  FAKE_RESTIC_ARGV="$TMP_ROOT/lint-find/restic.argv" \
    NIGHTLY_HOME="$trans" PATH="$fakebin:$PATH" \
    run_nightly run --fm-home "$home" --now "$NOW"
  [ -f "$TMP_ROOT/lint-find/restic.argv" ] || fail 'lint finding skipped archive'
  pass "fm-nightly: a lint finding does not stop archive"
}

test_missing_restic_still_runs_record_stages() {
  local home origin path_dir dir tool name path_dirs
  IFS=$(printf '\t') read -r home origin < <(new_home no-restic)
  setup_record "$home" "$origin"
  printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s/repo\n' "$TMP_ROOT/no-restic" > "$home/config/nightly.env"
  printf 'NIGHTLY_RCLONE_CONFIG=%s/rclone.conf\n' "$TMP_ROOT/no-restic" >> "$home/config/nightly.env"
  printf '[fixture]\ntype = local\n' > "$TMP_ROOT/no-restic/rclone.conf"
  path_dir="$TMP_ROOT/no-restic/path"
  mkdir -p "$path_dir"
  # Mirror the real PATH minus the two archive tools so only their absence changes.
  IFS=: read -r -a path_dirs <<< "$PATH"
  for dir in "${path_dirs[@]}"; do
    [ -d "$dir" ] || continue
    for tool in "$dir"/*; do
      name=$(basename "$tool")
      case "$name" in restic | rclone) continue ;; esac
      [ -x "$tool" ] && [ ! -e "$path_dir/$name" ] && ln -s "$tool" "$path_dir/$name"
    done
  done
  PATH="$path_dir" run_nightly run --fm-home "$home" --now "$NOW"
  expect_code 0 "$RC" 'run without restic'
  assert_grep $'archive\tnot-configured\t' "$home/data/.git/nightly/stages.tsv" 'archive not-configured'
  assert_grep $'lint\t' "$home/data/.git/nightly/stages.tsv" 'lint ran'
  pass "fm-nightly: missing restic leaves archive not-configured and still runs Record stages"
}

test_record_only_views_commit() {
  local home origin clone fakebin
  IFS=$(printf '\t') read -r home origin < <(new_home ro-views)
  setup_record "$home" "$origin"
  clone="$TMP_ROOT/ro-views/clone"
  git clone --quiet "file://$origin" "$clone"
  fakebin=$(fm_fakebin "$TMP_ROOT/ro-views")
  write_tool_doubles "$fakebin"
  PATH="$fakebin:$PATH" \
    run_nightly run --record-only --record "$clone" --now "$NOW"
  expect_code 0 "$RC" 'record-only run'
  assert_grep $'archive\tskipped\t' "$clone/.git/nightly/stages.tsv" 'archive skipped'
  assert_grep $'cloud scope' "$clone/.git/nightly/stages.tsv" 'cloud scope detail'
  git --git-dir="$origin" log -1 --format=%s | grep -Fq "maintain $DATE" \
    || fail 'record-only did not push a maintain commit'
  pass "fm-nightly: record-only commits views and skips archive"
}

test_record_only_racing_push() {
  local home origin clone_a clone_b
  IFS=$(printf '\t') read -r home origin < <(new_home ro-race)
  setup_record "$home" "$origin"
  clone_a="$TMP_ROOT/ro-race/a"
  clone_b="$TMP_ROOT/ro-race/b"
  git clone --quiet "file://$origin" "$clone_a"
  git clone --quiet "file://$origin" "$clone_b"
  printf 'from-a\n' > "$clone_a/local-note.md"
  git -C "$clone_a" add local-note.md
  git -C "$clone_a" commit --quiet -m 'A local'
  printf 'from-b\n' > "$clone_b/wiki-seed.md"
  git -C "$clone_b" add wiki-seed.md
  git -C "$clone_b" commit --quiet -m 'B wins'
  git -C "$clone_b" push --quiet origin HEAD
  run_nightly run --record-only --record "$clone_a" --now "$NOW"
  expect_code 1 "$RC" 'diverged run reports failure'
  assert_grep $'reconcile\tfailed\t0\tdiverged' "$clone_a/.git/nightly/stages.tsv" 'race diverged'
  assert_grep $'views\tskipped\t' "$clone_a/.git/nightly/stages.tsv" 'no Record writes after divergence'
  assert_grep $'rollout\tskipped\t0\twrites-disabled' "$clone_a/.git/nightly/stages.tsv" 'rollout skipped'
  assert_grep $'receipt\tskipped\t0\twrites-disabled' "$clone_a/.git/nightly/stages.tsv" 'receipt skipped'
  assert_grep $'checkpoint\tskipped\t0\twrites-disabled' "$clone_a/.git/nightly/stages.tsv" 'checkpoint skipped'
  [ "$(git -C "$clone_a" log --format=%s | grep -c "maintain $DATE")" = 0 ] \
    || fail 'an unreconciled clone gained a maintain commit'
  assert_absent "$clone_a/wiki/views/nightly-digest.json" 'a receipt was written on an unreconciled clone'
  git -C "$clone_a" log --format=%s | grep -Fq 'A local' || fail 'local commit lost'
  [ "$(cat "$clone_a/local-note.md")" = from-a ] || fail 'local file changed'
  git --git-dir="$origin" log --format=%s | grep -Fq 'B wins' || fail 'origin lost B'
  git --git-dir="$origin" log --format=%s | grep -Fq 'A local' && fail 'diverged local commit was pushed'
  pass "fm-nightly: record-only keeps a local commit when a racing push wins"
}

test_record_only_detached_head_pushes_nothing() {
  local home origin clone
  IFS=$(printf '\t') read -r home origin < <(new_home ro-detached)
  setup_record "$home" "$origin"
  clone="$TMP_ROOT/ro-detached/clone"
  git clone --quiet "file://$origin" "$clone"
  git -C "$clone" checkout --quiet --detach HEAD
  run_nightly run --record-only --record "$clone" --now "$NOW"
  expect_code 1 "$RC" 'detached record-only run fails'
  assert_grep $'reconcile\tfailed\t0\tdetached-head' "$clone/.git/nightly/stages.tsv" 'detached reconcile'
  assert_grep $'checkpoint\tskipped\t0\twrites-disabled' "$clone/.git/nightly/stages.tsv" 'detached checkpoint'
  assert_grep $'verify\tfailed\t0\tdetached-head' "$clone/.git/nightly/stages.tsv" 'detached verify'
  git --git-dir="$origin" show-ref --verify --quiet refs/heads/HEAD && fail 'a branch named HEAD was pushed'
  [ "$(git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')" = 1 ] \
    || fail 'origin gained a branch from a detached clone'
  pass "fm-nightly: a detached record-only clone pushes nothing and records detached-head"
}

test_record_only_verify_reports_fetch_failure() {
  local home origin clone
  IFS=$(printf '\t') read -r home origin < <(new_home ro-fetch)
  setup_record "$home" "$origin"
  clone="$TMP_ROOT/ro-fetch/clone"
  git clone --quiet "file://$origin" "$clone"
  git -C "$clone" remote set-url origin "file://$TMP_ROOT/ro-fetch/missing.git"
  run_nightly run --record-only --record "$clone" --now "$NOW"
  expect_code 1 "$RC" 'unreachable origin fails the run'
  assert_grep $'reconcile\tfailed\t' "$clone/.git/nightly/stages.tsv" 'reconcile failed'
  assert_grep $'verify\tfailed\t' "$clone/.git/nightly/stages.tsv" 'verify failed'
  assert_grep 'fetch-exit-' "$clone/.git/nightly/stages.tsv" 'verify names the fetch failure'
  assert_no_grep 'equal=yes' "$clone/.git/nightly/stages.tsv" 'a failed fetch never proves equality'
  assert_grep 'verify=fm-nightly: state=remote-unknown' "$clone/.git/nightly/last-attempt" 'last-attempt verify line'
  assert_absent "$clone/.git/nightly/last-complete" 'an unverified night claimed completion'
  pass "fm-nightly: record-only verify records a failed fetch instead of a stale equality"
}

test_scheduled_date_defaults_to_local_date() {
  local home origin
  IFS=$(printf '\t') read -r home origin < <(new_home local-date)
  setup_minimal_record "$home"
  mkdir -p "$TMP_ROOT/empty-home"
  TZ=Pacific/Honolulu run_nightly run --fm-home "$home" --now "$NOW"
  assert_grep 'date=2026-09-06' "$home/data/.git/nightly/last-attempt" 'west of UTC counts the previous local date'
  TZ=Asia/Tokyo run_nightly run --fm-home "$home" --now 2026-09-06T20:00:00Z
  assert_grep 'date=2026-09-07' "$home/data/.git/nightly/last-attempt" 'east of UTC counts the next local date'
  TZ=Pacific/Honolulu run_nightly run --fm-home "$home" --now "$NOW" --scheduled-date 2026-09-07
  assert_grep 'date=2026-09-07' "$home/data/.git/nightly/last-attempt" 'an explicit --scheduled-date wins'
  pass "fm-nightly: the default scheduled date is the local calendar date of --now"
}

test_external_term_records_signal_term() {
  local home origin fakebin trans pidfile nightly_pid i rc
  IFS=$(printf '\t') read -r home origin < <(new_home term)
  setup_minimal_record "$home"
  trans="$TMP_ROOT/term/trans-home"
  mkdir -p "$trans/.claude/projects"
  printf 'hi\n' > "$trans/.claude/projects/a.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/term")
  write_tool_doubles "$fakebin"
  pidfile="$TMP_ROOT/term/restic.pid"
  cat > "$fakebin/restic" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$pidfile"
sleep 60
SH
  chmod +x "$fakebin/restic"
  {
    printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s/repo\n' "$TMP_ROOT/term"
    printf 'NIGHTLY_RCLONE_CONFIG=%s/rclone.conf\n' "$TMP_ROOT/term"
    printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s/pw\n' "$TMP_ROOT/term"
  } > "$home/config/nightly.env"
  printf '[fixture]\ntype = local\n' > "$TMP_ROOT/term/rclone.conf"
  printf 'pw\n' > "$TMP_ROOT/term/pw"
  HOME="$trans" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    "$NIGHTLY" run --fm-home "$home" --now "$NOW" > "$TMP_ROOT/term/out" 2>&1 &
  nightly_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -f "$pidfile" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$pidfile" ] || fail 'restic double did not start'
  kill -TERM "$nightly_pid"
  set +e
  wait "$nightly_pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'a terminated run exited 0'
  assert_grep $'interrupted\tinterrupted\t0\tsignal-term' "$home/data/.git/nightly/stages.tsv" \
    'external TERM is signal-term'
  assert_no_grep 'bound-hit' "$home/data/.git/nightly/stages.tsv" 'external TERM is not a bound hit'
  assert_grep 'result=failed' "$home/data/.git/nightly/last-attempt" 'terminated run is not ok'
  pass "fm-nightly: an external SIGTERM is recorded as signal-term, not bound-hit"
}

test_status_survives_corrupt_archive_json() {
  local home origin plist
  IFS=$(printf '\t') read -r home origin < <(new_home status-corrupt)
  setup_minimal_record "$home"
  mkdir -p "$home/data/.git/nightly"
  printf '{"last_complete_snapshot": "abc"' > "$home/data/.git/nightly/archive.json"
  printf '{"subset":2,"next_due":"2026-09-14","last_result":"ok"}\n' \
    > "$home/data/.git/nightly/weekly-check.json"
  plist="$TMP_ROOT/status-corrupt/nightly.plist"
  FM_NIGHTLY_PLIST="$plist" run_nightly status --fm-home "$home"
  expect_code 0 "$RC" 'status with a corrupt archive.json'
  assert_contains "$OUT" 'archive: unreadable' 'status names the unreadable archive state'
  assert_contains "$OUT" 'weekly-check:' 'status still prints weekly-check'
  assert_contains "$OUT" 'plist: absent' 'status still prints the plist line'
  assert_not_contains "$OUT" 'Traceback' 'status printed a traceback'
  pass "fm-nightly: status reports an unreadable archive.json and keeps going"
}

test_outer_repository_stays_clean() {
  local after
  after=$(git -C "$ROOT" status --short --untracked-files=all)
  [ "$after" = "$OUTER_STATUS_BEFORE" ] || fail "outer repository changed: $after"
  pass "fm-nightly: the outer repository stays clean"
}

test_help_lists_subcommands
test_install_renders_plist
test_install_refuses_unknown_plist
test_install_invalid_hour
test_install_refuses_worktree_code_root
test_install_bootstrap_records_launchctl
test_dry_run_lists_every_stage
test_dry_run_record_only_skips_cloud
test_refuse_home_with_record_only
test_busy_exit_3
test_run_bound_stops_the_in_flight_stage
test_restore_refuses_nonempty_and_implicit_latest
test_archive_subcommand_leaves_the_run_receipt_alone
test_status_reads_local_files
test_full_run_on_record_home
test_lint_finding_does_not_stop_archive
test_missing_restic_still_runs_record_stages
test_record_only_views_commit
test_record_only_racing_push
test_record_only_detached_head_pushes_nothing
test_record_only_verify_reports_fetch_failure
test_scheduled_date_defaults_to_local_date
test_external_term_records_signal_term
test_status_survives_corrupt_archive_json
test_outer_repository_stays_clean
