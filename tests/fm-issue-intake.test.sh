#!/usr/bin/env bash
# Behavioral coverage for labeled GitHub issue intake and watcher registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-issue-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-intake)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

assert_queued_task_ids_creation_valid() {
  local home=$1 path id
  [ -d "$home/bodies" ] || fail "queued task body directory missing: $home/bodies"
  shopt -s nullglob
  for path in "$home/bodies"/*; do
    id=${path##*/}
    fm_task_id_creation_valid "$id" \
      || fail "queued task id rejected by creation contract: $id"
    [ "${#id}" -le 64 ] || fail "queued task id exceeds 64 characters: $id"
  done
  shopt -u nullglob
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

write_config() {
  local home=$1
  mkdir -p "$home/config"
  cat > "$home/config/issue-intake.json" <<'JSON'
{
  "repos": ["Octo/widgets"],
  "label": "fm:task"
}
JSON
}

write_class_config() {
  local home=$1
  mkdir -p "$home/config"
  cat > "$home/config/issue-intake.json" <<'JSON'
{
  "repos": ["Octo/widgets"],
  "label": "fm:task",
  "trusted_authors": ["trusted-bot[bot]"],
  "deny_classes": ["ship", "money", "credentials", "destructive", "locked-look"]
}
JSON
}

make_fake_tools() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
  if [ "${FM_TEST_COLLISION_REPOS:-0}" = 1 ]; then
    repo=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -R ]; then
        repo=$2
        break
      fi
      shift
    done
    case "$repo" in
      a-b/c) author=a-b; title='First collision task' ;;
      a/b-c) author=a; title='Second collision task' ;;
      *) exit 10 ;;
    esac
    printf '%s\n' \
      'count: 1' \
      'issues[1]{number,title,state,author,created}:' \
      "  1,$title,open,$author,1d ago"
    exit 0
  fi
  if [ "${FM_TEST_CLASS_GATE:-0}" = 1 ]; then
    cat <<'OUT'
count: 8
issues[8]{number,title,state,author,created}:
  1,Owner task,open,Octo,1d ago
  2,Approved task,open,alice,1d ago
  3,Untrusted class task,open,bob,1d ago
  4,Trusted allowed task,open,trusted-bot[bot],1d ago
  5,Trusted unclassified task,open,trusted-bot[bot],1d ago
  6,Trusted denied task,open,trusted-bot[bot],1d ago
  7,Trusted mixed task,open,trusted-bot[bot],1d ago
  8,Trusted approved denied task,open,trusted-bot[bot],1d ago
OUT
    exit 0
  fi
  cat <<'OUT'
count: 3
issues[3]{number,title,state,author,created}:
  1,Owner task,open,Octo,1d ago
  2,Approved task,open,alice,1d ago
  3,Unapproved task,open,bob,1d ago
OUT
  exit 0
fi
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    /repos/a-b/c/issues/1)
      title='First collision task'
      author=a-b
      labels='["fm:task"]'
      url='https://github.com/a-b/c/issues/1'
      number=1
      ;;
    /repos/a/b-c/issues/1)
      title='Second collision task'
      author=a
      labels='["fm:task"]'
      url='https://github.com/a/b-c/issues/1'
      number=1
      ;;
    */issues/1)
      title='Owner task'
      author=Octo
      if [ "${FM_TEST_CLASS_GATE:-0}" = 1 ]; then
        labels='["fm:task","class:ship"]'
      else
        labels='["fm:task"]'
      fi
      url='https://github.com/Octo/widgets/issues/1'
      number=1
      ;;
    */issues/2)
      title='Approved task'
      author=alice
      labels='["fm:task","FM:APPROVED"]'
      url='https://github.com/Octo/widgets/issues/2'
      number=2
      ;;
    */issues/3)
      if [ "${FM_TEST_CLASS_GATE:-0}" = 1 ]; then
        title='Untrusted class task'
        author=bob
        labels='["fm:task","class:docs"]'
      else
        title='Unapproved task'
        author=bob
        labels='["fm:task"]'
      fi
      url='https://github.com/Octo/widgets/issues/3'
      number=3
      ;;
    */issues/4)
      title='Trusted allowed task'
      author='Trusted-Bot[bot]'
      labels='["fm:task","CLASS:docs"]'
      url='https://github.com/Octo/widgets/issues/4'
      number=4
      ;;
    */issues/5)
      title='Trusted unclassified task'
      author='trusted-bot[bot]'
      labels='["fm:task"]'
      url='https://github.com/Octo/widgets/issues/5'
      number=5
      ;;
    */issues/6)
      title='Trusted denied task'
      author='trusted-bot[bot]'
      labels='["fm:task","class:MONEY"]'
      url='https://github.com/Octo/widgets/issues/6'
      number=6
      ;;
    */issues/7)
      title='Trusted mixed task'
      author='trusted-bot[bot]'
      labels='["fm:task","class:docs","class:ship"]'
      url='https://github.com/Octo/widgets/issues/7'
      number=7
      ;;
    */issues/8)
      title='Trusted approved denied task'
      author='trusted-bot[bot]'
      labels='["fm:task","class:credentials","fm:approved"]'
      url='https://github.com/Octo/widgets/issues/8'
      number=8
      ;;
    *) exit 9 ;;
  esac
  title_b64=$(jq -nr --arg value "$title" '$value | @base64')
  labels_b64=$(jq -nr --arg value "$labels" '$value | @base64')
  url_b64=$(jq -nr --arg value "$url" '$value | @base64')
  printf '%s\n' \
    '[1]{number,title_b64,author,labels_b64,url_b64}:' \
    "  $number,$title_b64,$author,$labels_b64,$url_b64"
  exit 0
fi
exit 8
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' '0.2.4'; exit 0 ;;
  update:--help) printf '%s\n' '--archive-body'; exit 0 ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]'; exit 0 ;;
esac
if [ "${1:-}" = add ]; then
  id=$2
  shift 2
  body_file=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --body-file ]; then
      body_file=$2
      break
    fi
    shift
  done
  [ -n "$body_file" ] || exit 7
  if [ -f "$FM_TEST_BODY_DIR/$id" ]; then
    printf '{"ok":true,"action":"add","already":true,"task":{"id":"%s"}}\n' "$id"
    exit 0
  fi
  printf '%s\n' "add $id" >> "$FM_TEST_TASKS_LOG"
  cp "$body_file" "$FM_TEST_BODY_DIR/$id"
  printf '{"ok":true,"action":"add","task":{"id":"%s"}}\n' "$id"
  exit 0
fi
if [ "${1:-}" = show ]; then
  id=$2
  [ -f "$FM_TEST_BODY_DIR/$id" ] || exit 5
  cat "$FM_TEST_BODY_DIR/$id"
  exit 0
fi
exit 6
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

run_intake() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_GH_AXI_LOG="$home/gh-axi.log" FM_TEST_TASKS_LOG="$home/tasks.log" \
    FM_TEST_BODY_DIR="$home/bodies" FM_TEST_COLLISION_REPOS="${FM_TEST_COLLISION_REPOS:-0}" \
    FM_TEST_CLASS_GATE="${FM_TEST_CLASS_GATE:-0}" \
    "$INTAKE" "$@"
}

test_dedupes_and_enforces_authorization() {
  local home fakebin first second calls seen body
  home="$TMP_ROOT/dedupe"
  mkdir -p "$home/bodies"
  write_config "$home"
  fakebin=$(make_fake_tools "$home")

  first=$(run_intake "$home" "$fakebin") || fail "first intake run failed"
  assert_contains "$first" 'new=2' "owner and approved issues were not queued"
  assert_contains "$first" 'skipped-awaiting-approval=1' "unauthorized issue was not counted"
  assert_contains "$first" 'Octo/widgets#3:untrusted-author' \
    "unauthorized issue and reason were not named"
  calls=$(wc -l < "$home/tasks.log" | tr -d ' ')
  [ "$calls" -eq 2 ] || fail "expected two queued tasks, got $calls"
  seen=$(wc -l < "$home/state/issue-intake.seen" | tr -d ' ')
  [ "$seen" -eq 2 ] || fail "expected two seen rows, got $seen"
  grep -F $'Octo/widgets\t1\thttps://github.com/Octo/widgets/issues/1' \
    "$home/state/issue-intake.seen" >/dev/null || fail "owner issue provenance was not recorded"
  body=$(grep -Fl 'https://github.com/Octo/widgets/issues/2' "$home/bodies"/* 2>/dev/null || true)
  [ -n "$body" ] || fail "approved issue backlog body was not created"
  grep -Fx -- '- Repository: Octo/widgets' "$body" >/dev/null \
    || fail "backlog body lost repository provenance"
  grep -Fx -- '- Issue: #2' "$body" >/dev/null \
    || fail "backlog body lost issue number provenance"
  grep -Fx -- '- URL: https://github.com/Octo/widgets/issues/2' "$body" >/dev/null \
    || fail "backlog body lost full URL provenance"
  [ "$(find "$home/bodies" -type f | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "unauthorized issue created a backlog item"
  assert_queued_task_ids_creation_valid "$home"

  second=$(run_intake "$home" "$fakebin") || fail "second intake run failed"
  assert_contains "$second" 'new=0' "second run queued duplicate work"
  assert_contains "$second" 'already-seen=2' "second run did not report seen issues"
  calls=$(wc -l < "$home/tasks.log" | tr -d ' ')
  [ "$calls" -eq 2 ] || fail "second run called tasks-axi again"
  pass "issue intake dedupes owner and approved work while counting unauthorized issues"
}

test_dry_run_does_not_mutate() {
  local home fakebin out
  home="$TMP_ROOT/dry-run"
  mkdir -p "$home/bodies"
  write_config "$home"
  fakebin=$(make_fake_tools "$home")

  out=$(run_intake "$home" "$fakebin" --dry-run) || fail "dry run failed"
  assert_contains "$out" 'would-ingest=2' "dry run did not report eligible issues"
  assert_contains "$out" 'skipped-awaiting-approval=1' "dry run did not count unauthorized issues"
  assert_contains "$out" 'Octo/widgets#3:untrusted-author' \
    "dry run did not name unauthorized issue and reason"
  [ ! -e "$home/state" ] || fail "dry run created state"
  [ ! -e "$home/tasks.log" ] || fail "dry run called tasks-axi add"
  [ -z "$(find "$home/bodies" -mindepth 1 -print -quit)" ] \
    || fail "dry run created a backlog body"
  pass "issue intake dry run reports work without mutation"
}

test_malformed_config_refuses_before_github() {
  local home fakebin out rc
  home="$TMP_ROOT/malformed"
  mkdir -p "$home/config" "$home/bodies"
  printf '%s\n' '{"repos":"Octo/widgets","label":"fm:task","approve_label":"fm:approved"}' \
    > "$home/config/issue-intake.json"
  fakebin=$(make_fake_tools "$home")

  set +e
  out=$(run_intake "$home" "$fakebin" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed config succeeded"
  assert_contains "$out" 'malformed config' "malformed config lacked a loud diagnostic"
  [ ! -e "$home/gh-axi.log" ] || fail "malformed config reached GitHub"
  [ ! -e "$home/state" ] || fail "malformed config mutated state"
  pass "issue intake refuses malformed config before external reads"
}

test_malformed_class_gate_config_refuses_before_github() {
  local home fakebin out rc config
  home="$TMP_ROOT/malformed-class-gate"
  mkdir -p "$home/config" "$home/bodies"
  fakebin=$(make_fake_tools "$home")

  for config in \
    '{"repos":["Octo/widgets"],"label":"fm:task","trusted_authors":"trusted-bot[bot]"}' \
    '{"repos":["Octo/widgets"],"label":"fm:task","deny_classes":"money"}' \
    '{"repos":["Octo/widgets"],"label":"fm:task","trusted_authors":[7]}' \
    '{"repos":["Octo/widgets"],"label":"fm:task","deny_classes":[false]}'
  do
    printf '%s\n' "$config" > "$home/config/issue-intake.json"
    rm -f -- "$home/gh-axi.log"
    set +e
    out=$(run_intake "$home" "$fakebin" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "malformed class-gate config succeeded: $config"
    assert_contains "$out" 'malformed config' \
      "malformed class-gate config lacked a loud diagnostic"
    [ ! -e "$home/gh-axi.log" ] || fail "malformed class-gate config reached GitHub"
  done
  pass "issue intake refuses malformed class-gate arrays before external reads"
}

test_class_gate_dispatches_only_allowed_trusted_work() {
  local home fakebin first second calls seen
  home="$TMP_ROOT/class-gate"
  mkdir -p "$home/bodies"
  write_class_config "$home"
  fakebin=$(make_fake_tools "$home")

  first=$(FM_TEST_CLASS_GATE=1 run_intake "$home" "$fakebin") \
    || fail "class-gate intake run failed"
  assert_contains "$first" 'new=4' \
    "owner, approved, allowed trusted, and approved denied issues were not queued"
  assert_contains "$first" 'skipped-awaiting-approval=4' \
    "class-gate skipped count was wrong"
  assert_contains "$first" 'Octo/widgets#3:untrusted-author' \
    "untrusted classed issue reason was not named"
  assert_contains "$first" 'Octo/widgets#5:unclassified' \
    "trusted unclassified issue reason was not named"
  assert_contains "$first" 'Octo/widgets#6:denied-class' \
    "trusted denied issue reason was not named"
  assert_contains "$first" 'Octo/widgets#7:denied-class' \
    "denied class did not override allowed class"
  calls=$(wc -l < "$home/tasks.log" | tr -d ' ')
  [ "$calls" -eq 4 ] || fail "expected four queued class-gate tasks, got $calls"
  seen=$(wc -l < "$home/state/issue-intake.seen" | tr -d ' ')
  [ "$seen" -eq 4 ] || fail "expected four seen class-gate rows, got $seen"

  second=$(FM_TEST_CLASS_GATE=1 run_intake "$home" "$fakebin") \
    || fail "second class-gate intake run failed"
  assert_contains "$second" 'new=0' "second class-gate run queued duplicate work"
  assert_contains "$second" 'already-seen=4' "second class-gate run lost seen work"
  calls=$(wc -l < "$home/tasks.log" | tr -d ' ')
  [ "$calls" -eq 4 ] || fail "second class-gate run called tasks-axi again"
  pass "issue intake class gate fails closed and remains idempotent"
}

test_malformed_repository_names_refuse() {
  local home fakebin out rc
  home="$TMP_ROOT/malformed-repository"
  mkdir -p "$home/config" "$home/bodies"
  printf '%s\n' \
    '{"repos":["owner-/repo","owner/..","aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/repo"],"label":"fm:task"}' \
    > "$home/config/issue-intake.json"
  fakebin=$(make_fake_tools "$home")

  set +e
  out=$(run_intake "$home" "$fakebin" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed repository names succeeded"
  assert_contains "$out" 'malformed config' "malformed repository names lacked a diagnostic"
  [ ! -e "$home/gh-axi.log" ] || fail "malformed repository names reached GitHub"
  pass "issue intake rejects invalid GitHub repository boundaries"
}

test_case_alias_repositories_refuse() {
  local home fakebin out rc
  home="$TMP_ROOT/case-alias"
  mkdir -p "$home/config" "$home/bodies"
  printf '%s\n' \
    '{"repos":["Octo/widgets","octo/WIDGETS"],"label":"fm:task"}' \
    > "$home/config/issue-intake.json"
  fakebin=$(make_fake_tools "$home")

  set +e
  out=$(run_intake "$home" "$fakebin" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "case-alias repositories succeeded"
  assert_contains "$out" 'malformed config' "case-alias repositories lacked a diagnostic"
  [ ! -e "$home/gh-axi.log" ] || fail "case-alias repositories reached GitHub"
  pass "issue intake rejects case-insensitive repository duplicates"
}

test_repository_task_ids_do_not_flatten_names() {
  local home fakebin out calls
  home="$TMP_ROOT/task-id-collision"
  mkdir -p "$home/config" "$home/bodies"
  printf '%s\n' \
    '{"repos":["a-b/c","a/b-c"],"label":"fm:task"}' \
    > "$home/config/issue-intake.json"
  fakebin=$(make_fake_tools "$home")

  out=$(FM_TEST_COLLISION_REPOS=1 run_intake "$home" "$fakebin") \
    || fail "collision-resistant intake run failed"
  assert_contains "$out" 'new=2' "distinct repository issues did not both queue"
  calls=$(wc -l < "$home/tasks.log" | tr -d ' ')
  [ "$calls" -eq 2 ] || fail "distinct repository identities collided in tasks-axi"
  [ "$(find "$home/bodies" -type f | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "distinct repository identities shared one backlog body"
  assert_queued_task_ids_creation_valid "$home"
  id_a=$(basename "$(grep -Fl 'https://github.com/a-b/c/issues/1' "$home/bodies"/*)")
  id_b=$(basename "$(grep -Fl 'https://github.com/a/b-c/issues/1' "$home/bodies"/*)")
  [ -n "$id_a" ] && [ -n "$id_b" ] || fail "collision fixture backlog bodies were missing"
  [ "$id_a" != "$id_b" ] || fail "distinct repositories produced identical task ids"
  pass "issue intake keeps dash-separated repository identities distinct"
}

test_missing_seen_record_recovers_without_duplicate() {
  local home fakebin calls seen out
  home="$TMP_ROOT/recover-seen"
  mkdir -p "$home/bodies"
  write_config "$home"
  fakebin=$(make_fake_tools "$home")

  run_intake "$home" "$fakebin" >/dev/null || fail "initial recovery fixture intake failed"
  rm -f -- "$home/state/issue-intake.seen"
  out=$(run_intake "$home" "$fakebin" --check) || fail "seen-record recovery run failed"
  [ -z "$out" ] || fail "seen-record recovery claimed new work landed: $out"
  calls=$(wc -l < "$home/tasks.log" | tr -d ' ')
  [ "$calls" -eq 2 ] || fail "seen-record recovery created duplicate backlog work"
  seen=$(wc -l < "$home/state/issue-intake.seen" | tr -d ' ')
  [ "$seen" -eq 2 ] || fail "seen-record recovery did not restore both authorized identities"
  pass "issue intake heals a missing seen record from deterministic backlog items"
}

test_install_check_registers_single_shim() {
  local home fakebin out
  home="$TMP_ROOT/install-check"
  mkdir -p "$home/bodies"
  write_config "$home"
  fakebin=$(make_fake_tools "$home")

  out=$(run_intake "$home" "$fakebin" --install-check) || fail "check install failed"
  [ "$out" = 'installed: state/issue-intake.check.sh' ] \
    || fail "check install output was unexpected: $out"
  [ "$(file_mode "$home/state/issue-intake.check.sh")" = 700 ] \
    || fail "installed check mode was not 0700"
  [ "$(file_mode "$home/state/issue-intake.check-trust")" = 600 ] \
    || fail "installed check trust mode was not 0600"
  grep -F -- 'fm-issue-intake.sh --check' "$home/state/issue-intake.check.sh" >/dev/null \
    || fail "installed check did not invoke issue intake check mode"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-check-register.sh" issue-intake >/dev/null \
    || fail "installed check was not registerable"
  pass "issue intake installs one authenticated watcher check"
}

test_check_mode_wakes_only_for_new_work() {
  local home fakebin first second
  home="$TMP_ROOT/check-mode"
  mkdir -p "$home/bodies"
  write_config "$home"
  fakebin=$(make_fake_tools "$home")

  first=$(run_intake "$home" "$fakebin" --check) || fail "first check-mode run failed"
  [ "$first" = 'issue intake: 2 new GitHub issue(s) queued' ] \
    || fail "check mode did not print one landed-work line: $first"
  second=$(run_intake "$home" "$fakebin" --check) || fail "second check-mode run failed"
  [ -z "$second" ] || fail "no-op check mode printed a wake line: $second"
  pass "issue intake watcher check wakes only when new work lands"
}

test_dedupes_and_enforces_authorization
test_dry_run_does_not_mutate
test_malformed_config_refuses_before_github
test_malformed_class_gate_config_refuses_before_github
test_class_gate_dispatches_only_allowed_trusted_work
test_malformed_repository_names_refuse
test_case_alias_repositories_refuse
test_repository_task_ids_do_not_flatten_names
test_missing_seen_record_recovers_without_duplicate
test_install_check_registers_single_shim
test_check_mode_wakes_only_for_new_work
