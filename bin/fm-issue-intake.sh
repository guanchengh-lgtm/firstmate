#!/usr/bin/env bash
# fm-issue-intake.sh - import authorized labeled GitHub issues into the backlog.
#
# docs/configuration.md owns the config/issue-intake.json schema and operator
# setup contract.
# This script owns intake mechanics: it reads open issues carrying the configured
# intake label through gh-axi, admits repository-owner issues immediately, and
# admits other authors with the configured approval label or through the trusted
# author class gate configured in docs/configuration.md.
# It creates deterministic collision-resistant queued task identities through the
# compatible tasks-axi backend as issue-<sha256(lowercase-repo)[0:32]>-<number>.
# Each successful intake is recorded as one tab-separated repo, issue number, and
# full URL row in state/issue-intake.seen so later runs are idempotent.
# If the backlog item already exists with the same GitHub URL, the run records the
# identity as seen without counting new work, recovering a prior queue success
# that never landed in the seen file.
# Issues awaiting approval are not recorded as seen because adding the approval
# label later must make them eligible.
# Normal and dry-run summaries count those skips as skipped-awaiting-approval and
# identify each as repo#number:reason, where reason is one of untrusted-author,
# unclassified, or denied-class.
#
# The install-check action writes one mode-0700 state/issue-intake.check.sh shim
# and authenticates it with fm-check-register.sh.
# A successful check run prints one line only when new work landed and otherwise
# stays silent; failures print one wake-worthy line so polling cannot fail hidden.
#
# Usage:
#   fm-issue-intake.sh [--dry-run]
#   fm-issue-intake.sh --check
#   fm-issue-intake.sh --install-check
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/issue-intake.json"
SEEN_FILE="$STATE/issue-intake.seen"
CHECK_ID=issue-intake

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

DRY_RUN=0
CHECK_MODE=0
INSTALL_CHECK=0
LOCK_DIR=
BODY_FILE=
QUEUE_OUTCOME=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  if [ "$CHECK_MODE" -eq 1 ]; then
    printf 'issue intake failed: %s\n' "$*"
  fi
  printf 'fm-issue-intake: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$BODY_FILE" ] || rm -f -- "$BODY_FILE"
  [ -z "$LOCK_DIR" ] || rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

require_commands() {
  local command_name
  for command_name in gh-axi jq; do
    command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
  done
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
}

validate_config() {
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] \
    || fail "config is unavailable or not a regular file: $CONFIG_FILE"
  jq -e '
    type == "object" and
    (has("repos") and has("label")) and
    ((keys - ["approve_label", "deny_classes", "label", "repos", "trusted_authors"]) | length == 0) and
    (.repos | type == "array" and length > 0) and
    (.repos | all(
      type == "string" and
      (. as $nwo | ($nwo | split("/")) as $parts |
        ($parts | length) == 2 and
        (($parts[0] | length) >= 1 and ($parts[0] | length) <= 39) and
        ($parts[0] | test("^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$|^[A-Za-z0-9]$")) and
        (($parts[1] | length) >= 1 and ($parts[1] | length) <= 100) and
        ($parts[1] != "." and $parts[1] != "..") and
        ($parts[1] | test("^[A-Za-z0-9._-]+$")))
    )) and
    ((.repos | map(ascii_downcase) | unique | length) == (.repos | length)) and
    (.label | type == "string" and length > 0 and
      (test("[\u0000-\u001f\u007f]") | not)) and
    ((has("approve_label") | not) or
      (.approve_label | type == "string" and length > 0 and
        (test("[\u0000-\u001f\u007f]") | not))) and
    ((has("trusted_authors") | not) or
      (.trusted_authors | type == "array" and all(
        type == "string" and length > 0 and
        (test("[\u0000-\u001f\u007f]") | not)
      ))) and
    ((has("deny_classes") | not) or
      (.deny_classes | type == "array" and all(
        type == "string" and length > 0 and
        (test("[\u0000-\u001f\u007f]") | not)
      )))
  ' "$CONFIG_FILE" >/dev/null 2>&1 \
    || fail "malformed config: expected repos, label, and optional approve_label, trusted_authors, and deny_classes only"
}

prepare_state() {
  local candidate_lock
  if [ ! -e "$STATE" ]; then
    mkdir -p -- "$STATE" || fail "could not create state directory: $STATE"
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] \
    || fail "state directory is unavailable: $STATE"
  candidate_lock="$STATE/.issue-intake.lock"
  mkdir "$candidate_lock" 2>/dev/null || fail "another issue intake run holds the state lock"
  LOCK_DIR=$candidate_lock
  if [ -e "$SEEN_FILE" ]; then
    [ -f "$SEEN_FILE" ] && [ ! -L "$SEEN_FILE" ] \
      || fail "seen record is not a regular file: $SEEN_FILE"
    [ "$(file_link_count "$SEEN_FILE")" = 1 ] \
      || fail "seen record must have exactly one link: $SEEN_FILE"
  else
    (umask 077; : > "$SEEN_FILE") || fail "could not create seen record: $SEEN_FILE"
  fi
  chmod 0600 "$SEEN_FILE" || fail "could not protect seen record: $SEEN_FILE"
}

seen_contains() {
  local repo=$1 number=$2
  [ -f "$SEEN_FILE" ] || return 1
  awk -F '\t' -v repo="$repo" -v number="$number" '
    $1 == repo && $2 == number { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$SEEN_FILE"
}

record_seen() {
  local repo=$1 number=$2 url=$3
  printf '%s\t%s\t%s\n' "$repo" "$number" "$url" >> "$SEEN_FILE" \
    || fail "could not update seen record"
}

decode_base64() {
  jq -nr --arg encoded "$1" '$encoded | @base64d' \
    || fail "gh-axi returned invalid base64 detail"
}

fetch_issue_numbers() {
  local repo=$1 label=$2 output count count_line parsed_count numbers total
  output=$(gh-axi issue list -R "$repo" --state open --label "$label" --limit 1000) \
    || fail "GitHub issue list failed for $repo"
  count_line=$(printf '%s\n' "$output" | sed -n '/^count: /p' | head -1)
  count=$(printf '%s\n' "$count_line" | sed -n 's/^count: \([0-9][0-9]*\).*/\1/p')
  case "$count" in
    ''|*[!0-9]*) fail "gh-axi returned an unrecognized issue count for $repo" ;;
  esac
  numbers=$(printf '%s\n' "$output" | sed -n 's/^  \([0-9][0-9]*\),.*/\1/p')
  parsed_count=$(printf '%s\n' "$numbers" | awk 'NF { count++ } END { print count + 0 }')
  [ "$parsed_count" -eq "$count" ] \
    || fail "gh-axi issue rows did not match the reported count for $repo"
  case "$count_line" in
    *'showing first'*) fail "more than 1000 matching issues require a narrower intake label" ;;
    *' of '*' total')
      total=$(printf '%s\n' "$count_line" | sed -n 's/^count: [0-9][0-9]* of \([0-9][0-9]*\) total$/\1/p')
      [ -n "$total" ] && [ "$total" -le 1000 ] \
        || fail "more than 1000 matching issues require a narrower intake label"
      ;;
  esac
  printf '%s\n' "$numbers"
}

fetch_issue_detail() {
  local repo=$1 number=$2 output header row parsed_number
  output=$(gh-axi api "/repos/$repo/issues/$number" --jq \
    '[{number: .number, title_b64: (.title | @base64), author: (.user.login // ""), labels_b64: ([.labels[].name] | tojson | @base64), url_b64: (.html_url | @base64)}]') \
    || fail "GitHub issue detail failed for $repo#$number"
  header=$(printf '%s\n' "$output" | head -1)
  [ "$header" = '[1]{number,title_b64,author,labels_b64,url_b64}:' ] \
    || fail "gh-axi returned an unrecognized issue detail header for $repo#$number"
  row=$(printf '%s\n' "$output" | sed -n 's/^  //p')
  IFS=',' read -r parsed_number ISSUE_TITLE_B64 ISSUE_AUTHOR ISSUE_LABELS_B64 ISSUE_URL_B64 extra <<< "$row"
  [ "$parsed_number" = "$number" ] && [ -n "$ISSUE_TITLE_B64" ] \
    && [ -n "$ISSUE_LABELS_B64" ] && [ -n "$ISSUE_URL_B64" ] && [ -z "${extra:-}" ] \
    || fail "gh-axi returned malformed issue detail for $repo#$number"
  ISSUE_TITLE=$(decode_base64 "$ISSUE_TITLE_B64")
  ISSUE_LABELS=$(decode_base64 "$ISSUE_LABELS_B64")
  ISSUE_URL=$(decode_base64 "$ISSUE_URL_B64")
  [ -n "$ISSUE_TITLE" ] && [ -n "$ISSUE_URL" ] \
    || fail "GitHub issue detail was incomplete for $repo#$number"
  case "$ISSUE_TITLE" in
    *$'\n'*|*$'\r'*) fail "GitHub issue title was not one line for $repo#$number" ;;
  esac
  printf '%s\n' "$ISSUE_LABELS" | jq -e 'type == "array" and all(type == "string")' >/dev/null \
    || fail "GitHub issue labels were malformed for $repo#$number"
}

label_present() {
  local labels=$1 expected=$2
  printf '%s\n' "$labels" | jq -e --arg expected "$expected" \
    'any(.[]; ascii_downcase == ($expected | ascii_downcase))' >/dev/null
}

class_label_present() {
  local labels=$1
  printf '%s\n' "$labels" | jq -e '
    any(.[]; . as $label |
      ($label | ascii_downcase | startswith("class:")) and
      (($label | length) > 6))
  ' >/dev/null
}

denied_class_present() {
  local labels=$1 deny_classes=$2
  printf '%s\n' "$labels" | jq -e --argjson deny_classes "$deny_classes" '
    any(.[]; . as $label |
      ($label | ascii_downcase | startswith("class:")) and
      (($label[6:] | ascii_downcase) as $token |
        any($deny_classes[]; ascii_downcase == $token)))
  ' >/dev/null
}

task_id_for_issue() {
  local canonical hash
  canonical=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$canonical" | sha256sum | awk '{print $1}')
  else
    fail "shasum or sha256sum is required"
  fi
  [ -n "$hash" ] || fail "could not derive issue task identity"
  printf 'issue-%s-%s\n' "${hash:0:32}" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

queue_issue() {
  local repo=$1 number=$2 task_id title result existing
  QUEUE_OUTCOME=created
  task_id=$(task_id_for_issue "$repo" "$number")
  title="[$repo#$number] $ISSUE_TITLE"
  BODY_FILE=$(mktemp "$STATE/.issue-intake-body.XXXXXX") \
    || fail "could not create backlog body file"
  chmod 0600 "$BODY_FILE" || fail "could not protect backlog body file"
  printf '%s\n' \
    'GitHub issue intake provenance:' \
    "- Repository: $repo" \
    "- Issue: #$number" \
    "- URL: $ISSUE_URL" > "$BODY_FILE" \
    || fail "could not write backlog body file"
  result=$(tasks_axi add "$task_id" "$title" --kind ship --repo "$repo" \
    --body-file "$BODY_FILE" --queue --json) \
    || fail "tasks-axi could not queue $repo#$number"
  printf '%s\n' "$result" | jq -e --arg id "$task_id" \
    '.ok == true and .action == "add" and .task.id == $id' >/dev/null \
    || fail "tasks-axi returned an invalid add result for $repo#$number"
  if printf '%s\n' "$result" | jq -e '.already == true' >/dev/null; then
    existing=$(tasks_axi show "$task_id" --full 2>/dev/null) \
      || fail "existing backlog item could not be verified for $repo#$number"
    printf '%s\n' "$existing" | grep -F -- "$ISSUE_URL" >/dev/null \
      || fail "existing backlog item conflicts with $repo#$number"
    QUEUE_OUTCOME=recovered
  fi
  rm -f -- "$BODY_FILE"
  BODY_FILE=
}

install_check() {
  local check_file temp_file quoted_home quoted_script
  prepare_state
  check_file="$STATE/$CHECK_ID.check.sh"
  temp_file=$(mktemp "$STATE/.issue-intake-check.XXXXXX") \
    || fail "could not create watcher check"
  quoted_home=$(printf '%q' "$FM_HOME")
  quoted_script=$(printf '%q' "$SCRIPT_DIR/fm-issue-intake.sh")
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Generated by fm-issue-intake.sh --install-check.' \
    "export FM_HOME=$quoted_home" \
    "exec $quoted_script --check" > "$temp_file" \
    || fail "could not write watcher check"
  chmod 0700 "$temp_file" || fail "could not protect watcher check"
  mv -f -- "$temp_file" "$check_file" || fail "could not install watcher check"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null \
    || fail "could not register watcher check"
  printf 'installed: state/%s.check.sh\n' "$CHECK_ID"
}

run_intake() {
  local intake_label approve_label trusted_authors deny_classes
  local repo owner number numbers skip_reason skipped_issues=
  local new_count=0 skipped_count=0 seen_count=0 eligible_count=0
  intake_label=$(jq -r '.label' "$CONFIG_FILE")
  approve_label=$(jq -r '.approve_label // "fm:approved"' "$CONFIG_FILE")
  trusted_authors=$(jq -c '.trusted_authors // []' "$CONFIG_FILE")
  deny_classes=$(jq -c '.deny_classes // []' "$CONFIG_FILE")

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    owner=${repo%%/*}
    numbers=$(fetch_issue_numbers "$repo" "$intake_label")
    while IFS= read -r number; do
      [ -n "$number" ] || continue
      fetch_issue_detail "$repo" "$number"
      if seen_contains "$repo" "$number"; then
        seen_count=$((seen_count + 1))
        continue
      fi
      if [ "$(printf '%s' "$ISSUE_AUTHOR" | tr '[:upper:]' '[:lower:]')" != \
        "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" ] \
        && ! label_present "$ISSUE_LABELS" "$approve_label"; then
        skip_reason=
        if ! label_present "$trusted_authors" "$ISSUE_AUTHOR"; then
          skip_reason=untrusted-author
        elif ! class_label_present "$ISSUE_LABELS"; then
          skip_reason=unclassified
        elif denied_class_present "$ISSUE_LABELS" "$deny_classes"; then
          skip_reason=denied-class
        fi
        if [ -n "$skip_reason" ]; then
          skipped_count=$((skipped_count + 1))
          if [ -n "$skipped_issues" ]; then
            skipped_issues="$skipped_issues,"
          fi
          skipped_issues="$skipped_issues$repo#$number:$skip_reason"
          continue
        fi
      fi
      eligible_count=$((eligible_count + 1))
      if [ "$DRY_RUN" -eq 1 ]; then
        continue
      fi
      queue_issue "$repo" "$number"
      record_seen "$repo" "$number" "$ISSUE_URL"
      if [ "$QUEUE_OUTCOME" = created ]; then
        new_count=$((new_count + 1))
      else
        seen_count=$((seen_count + 1))
      fi
    done <<< "$numbers"
  done < <(jq -r '.repos[]' "$CONFIG_FILE")

  if [ "$CHECK_MODE" -eq 1 ]; then
    if [ "$new_count" -gt 0 ]; then
      printf 'issue intake: %s new GitHub issue(s) queued\n' "$new_count"
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf 'issue intake dry-run: would-ingest=%s skipped-awaiting-approval=%s skipped=[%s] already-seen=%s\n' \
      "$eligible_count" "$skipped_count" "$skipped_issues" "$seen_count"
  else
    printf 'issue intake: new=%s skipped-awaiting-approval=%s skipped=[%s] already-seen=%s\n' \
      "$new_count" "$skipped_count" "$skipped_issues" "$seen_count"
  fi
}

case "$#:${1:-}" in
  0:) ;;
  1:--dry-run) DRY_RUN=1 ;;
  1:--check) CHECK_MODE=1 ;;
  1:--install-check) INSTALL_CHECK=1 ;;
  1:-h|1:--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

require_commands
validate_config

if [ "$INSTALL_CHECK" -eq 1 ]; then
  install_check
  exit 0
fi

if [ "$DRY_RUN" -eq 0 ]; then
  prepare_state
fi
run_intake
