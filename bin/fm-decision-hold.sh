#!/usr/bin/env bash
# fm-decision-hold.sh - deterministic mechanics for durable captain decisions and
# product-idea completion attestation.
#
# The semantic policy is owned once by
# .agents/skills/decision-hold-lifecycle/SKILL.md. This script never reads report,
# visual-review, chat, or terminal prose to guess whether a decision or idea exists.
# The invoking agent inventories unresolved decisions and unscheduled product ideas,
# assigns stable decision keys, appends idea ledger rows, and routes dependent work.
# This script supplies deterministic identities, creates and verifies structured
# tasks-axi captain holds, validates the active home's product-idea ledger, records
# completion attestation in the originating task's metadata, and closes a hold only
# after a durable decision record is linked to existing dependent work (`resolve`)
# or bound to an already-Done ship task (`supersede`).
#
# A hold identity is <origin-id>-decision-<decision-key>. Origin ids and decision
# keys must already be privacy-safe slugs. Repeating `hold` with the same identity
# is idempotent. A different decision key creates a different backlog identity.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the decision.
#
# Usage:
#   fm-decision-hold.sh id <origin-id> <decision-key>
#   fm-decision-hold.sh hold <origin-id> <decision-key> \
#     --title <title> --reason <reason> [--repo <repo>]
#   fm-decision-hold.sh complete <origin-id> (--none | <decision-key>...) \
#     (--ideas <PI-id>... | --no-ideas)
#   fm-decision-hold.sh verify <origin-id>
#   fm-decision-hold.sh resolve <origin-id> <decision-key> \
#     --decision-file <path> --routed-to <task-id> [--routed-to <task-id>...]
#   fm-decision-hold.sh supersede <origin-id> <decision-key> \
#     --decision-file data/decisions/<file> --shipped-task <task-id>
#   fm-decision-hold.sh state <hold-id> [--binding]
#
# `complete` is the shared investigation and visual-review completion gate.
# `--none` is an explicit semantic attestation that the just-reviewed surface has
# no unresolved captain decision and cannot be combined with decision keys.
# Exactly one idea attestation is also required: `--ideas` takes one or more
# home-local PI-NNN ids and cannot be combined with `--no-ideas`; `--no-ideas`
# means this pass found no new ideas and does not erase an earlier idea inventory.
# Decision keys and idea ids from later review passes are unioned idempotently.
# `complete` validates the full active-home ledger grammar and every unioned idea
# id against an origin-bound Source. `verify` grandfathers pre-upgrade metadata
# that carries only the earlier completed decision attestation.
# A post-teardown visual review can complete against the surviving report and
# holds without recreating task state.
#
# The active home's data/product-ideas.md is created lazily by `--no-ideas` from
# this template. Its columns are ID | Idea | Status | Source. Status is exactly
# one of: unscheduled; parked (captain <date>); scheduled -> <task-id>;
# shipped (was <task-id>); dropped (<reason>). Source is the home-relative report
# path plus section heading as data/<origin-id>/report.md#<section-heading>, never
# a line number. Ids are PI-NNN and home-local; cross-home displays qualify them
# with the home id, for example sm-tv:PI-003.
# `verify` is read-only and is called by scout teardown so teardown cannot erase a
# source before this gate has succeeded.
#
# `resolve` requires every --routed-to task to exist and to be blocked by the hold.
# It writes the captain decision and routed identities into the hold body, clears
# those dependency edges, and only then marks the hold Done. A failure before the
# final step leaves the captain hold open.
# `supersede` is the retrospective counterpart for a later authority that already
# shipped. It closes one active hold only after binding it to one ordinary decision
# record under data/decisions/ and one already-Done ship task. `state` is the sole
# read-only resolver used by session start and durable-SoT checks; it revalidates
# those live bindings before reporting open, resolved, or superseded.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-product-idea-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-product-idea-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

hold_id() {  # <origin-id> <decision-key>
  validate_slug origin-id "$1"
  validate_slug decision-key "$2"
  printf '%s-decision-%s\n' "$1" "$2"
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

task_show() {  # <id>
  tasks_axi show "$1" --full 2>/dev/null
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

validate_idea_id() {  # <value>
  case "$1" in
    PI-[0-9][0-9][0-9]) : ;;
    *) fail "product idea id must use the home-local PI-NNN form: $1" ;;
  esac
}

create_idea_ledger() {
  local ledger="$DATA/product-ideas.md"
  if [ -e "$ledger" ]; then
    [ -f "$ledger" ] || fail "product idea ledger path is not a regular file: $ledger"
    return 0
  fi
  ( umask 077
    mkdir -p "$DATA" || exit 1
    cat > "$ledger" <<'EOF'
# Product ideas

<!-- Columns: ID | Idea | Status | Source. -->
<!-- Status: unscheduled | parked (captain <date>) | scheduled -> <task-id> | shipped (was <task-id>) | dropped (<reason>). -->
<!-- Source: data/<origin-id>/report.md#<section-heading>; use a report path plus section heading, never a line number. -->
<!-- IDs are home-local PI-NNN values; qualify cross-home displays as <home-id>:PI-NNN, for example sm-tv:PI-003. -->

| ID | Idea | Status | Source |
| --- | --- | --- | --- |
EOF
  ) || fail "cannot create product idea ledger: $ledger"
}

verify_idea_row() {  # <origin-id> <idea-id>
  local origin=$1 idea_id=$2 ledger="$DATA/product-ideas.md" rc
  validate_idea_id "$idea_id"
  [ -f "$ledger" ] \
    || fail "product idea ledger is absent: $ledger; append $idea_id with a source citing data/$origin/report.md#<section-heading>"
  if fm_product_idea_verify_row "$ledger" "$origin" "$idea_id"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 4 ]; then
    fail "product idea $idea_id is missing from $ledger"
  fi
  fail "product idea $idea_id must have one well-formed row whose Source cites data/$origin/report.md#<section-heading> without a line number"
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  [ -f "$meta" ] || { printf '%s' "$open"; return 0; }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

verify_hold_active() {  # <hold-id>
  local id=$1 show state held kind hold_kind
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  [ "$state" = queued ] || fail "captain hold $id is not queued (state=$state)"
  [ "$held" = yes ] || fail "captain hold $id is not active"
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  [ "$hold_kind" = captain ] || fail "backlog item $id is not held for the captain"
}

normalize_decision_path() {  # <path>
  local supplied=$1 relative component prefix old_ifs
  case "$supplied" in
    "$FM_HOME"/data/decisions/*) relative=${supplied#"$FM_HOME"/} ;;
    data/decisions/*) relative=$supplied ;;
    *) fail "decision file must be home-relative under data/decisions/: $supplied" ;;
  esac
  case "$relative" in
    *//*|*/./*|*/../*|*/.|*/..) fail "decision file path is not canonical: $supplied" ;;
  esac
  prefix=$FM_HOME
  old_ifs=$IFS
  IFS=/
  for component in $relative; do
    IFS=$old_ifs
    prefix="$prefix/$component"
    [ ! -L "$prefix" ] || fail "decision file path contains a symlink: $relative"
    IFS=/
  done
  IFS=$old_ifs
  [ -f "$FM_HOME/$relative" ] || fail "decision file is not a regular file: $relative"
  [ -r "$FM_HOME/$relative" ] || fail "decision file is not readable: $relative"
  [ -s "$FM_HOME/$relative" ] || fail "decision file must not be empty: $relative"
  [ "$(LC_ALL=C wc -c < "$FM_HOME/$relative" | tr -d '[:space:]')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes: $relative"
  printf '%s\n' "$relative"
}

verify_shipped_task() {  # <task-id>
  local id=$1 show state kind
  validate_slug shipped-task "$id"
  show=$(task_show "$id") || fail "shipped task $id does not exist in the active home"
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  [ "$state" = "done" ] || fail "shipped task $id is not Done (state=$state)"
  [ "$kind" = ship ] || fail "shipped task $id is not kind ship (kind=$kind)"
}

supersession_fields() {  # <hold-id> <body>
  local id=$1 body=$2 fields
  body=${body#\"}
  body=${body%\"}
  case "$body" in
    'Supersession recorded by fm-decision-hold.\nDecision path: '*)
      fields=${body#'Supersession recorded by fm-decision-hold.\nDecision path: '}
      ;;
    *) return 1 ;;
  esac
  case "$fields" in
    *'\nDecision digest: '*'\nShipped task: '*) : ;;
    *) fail "captain hold $id has an invalid supersession identity record" ;;
  esac
  SUPERSESSION_PATH=${fields%%\\n*}
  fields=${fields#*\\nDecision digest: }
  SUPERSESSION_DIGEST=${fields%%\\n*}
  SUPERSESSION_TASK=${fields#*\\nShipped task: }
  case "$SUPERSESSION_TASK" in *'\n'*) fail "captain hold $id has trailing supersession fields" ;; esac
}

verify_supersession_binding() {  # <hold-id> <body>
  local id=$1 body=$2 relative actual_digest
  supersession_fields "$id" "$body" || return 1
  relative=$(normalize_decision_path "$SUPERSESSION_PATH")
  [ "$relative" = "$SUPERSESSION_PATH" ] || fail "captain hold $id records a non-canonical decision path"
  case "$SUPERSESSION_DIGEST" in
    ''|*[!0-9a-f]*) fail "captain hold $id records an invalid decision digest" ;;
  esac
  [ "${#SUPERSESSION_DIGEST}" -eq 64 ] || fail "captain hold $id records an invalid decision digest"
  actual_digest=$(sha256_file "$FM_HOME/$relative")
  [ "$actual_digest" = "$SUPERSESSION_DIGEST" ] \
    || fail "captain hold $id decision record digest no longer matches"
  verify_shipped_task "$SUPERSESSION_TASK"
}

hold_state() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  validate_slug hold-id "$id"
  show=$(task_show "$id") || fail "captain hold $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  [ "$kind" = captain ] || fail "backlog item $id is not kind captain"
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$hold_kind" = captain ]; then
    printf 'open\n'
    return 0
  fi
  if [ "$state" = "done" ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*)
        printf 'resolved\n'
        return 0
        ;;
      *"Supersession recorded by fm-decision-hold."*)
        verify_supersession_binding "$id" "$body"
        printf 'superseded\n'
        return 0
        ;;
    esac
  fi
  fail "captain hold $id has no valid durable state"
}

verify_hold_resolved() {  # <hold-id>
  local id=$1 show state kind body
  show=$(task_show "$id") || return 1
  state=$(show_field "$show" state)
  kind=$(show_field "$show" kind)
  body=$(show_field "$show" body)
  [ "$state" = "done" ] || return 1
  [ "$kind" = captain ] || return 1
  case "$body" in
    *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
  esac
  return 1
}

verify_hold_durable() {  # <hold-id>
  local id=$1 show state held kind hold_kind body
  show=$(task_show "$id") || fail "captain decision $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  held=$(show_field "$show" held)
  kind=$(show_field "$show" kind)
  hold_kind=$(show_field "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$state" = queued ] && [ "$held" = yes ] && [ "$kind" = captain ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  if [ "$state" = "done" ] && [ "$kind" = captain ]; then
    case "$body" in
      *"Resolution recorded by fm-decision-hold."*"Routed work:"*) return 0 ;;
      *"Supersession recorded by fm-decision-hold."*)
        verify_supersession_binding "$id" "$body"
        return 0
        ;;
    esac
  fi
  fail "captain decision $id is neither actively held nor durably resolved"
}

command_state() {
  local id=${1:-} with_binding=0 state show body
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  if [ "$#" -eq 2 ]; then
    [ "$2" = --binding ] || { usage >&2; exit 2; }
    with_binding=1
  fi
  require_tasks_axi
  state=$(hold_state "$id")
  if [ "$with_binding" -eq 0 ]; then
    printf '%s\n' "$state"
    return 0
  fi
  if [ "$state" = superseded ]; then
    show=$(task_show "$id")
    body=$(show_field "$show" body)
    supersession_fields "$id" "$body" || fail "captain hold $id has no supersession identity record"
    printf '%s\t%s\t%s\n' "$state" "$SUPERSESSION_PATH" "$SUPERSESSION_TASK"
  else
    printf '%s\t-\t-\n' "$state"
  fi
}

command_supersede() {
  local origin=${1:-} key=${2:-} decision_file='' shipped_task='' id show body relative digest current
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --shipped-task) shift; shipped_task=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -n "$shipped_task" ] || fail "--shipped-task is required"
  require_tasks_axi
  relative=$(normalize_decision_path "$decision_file")
  digest=$(sha256_file "$FM_HOME/$relative")
  verify_shipped_task "$shipped_task"
  id=$(hold_id "$origin" "$key")
  if current=$(hold_state "$id" 2>/dev/null) && [ "$current" = superseded ]; then
    show=$(task_show "$id")
    body=$(show_field "$show" body)
    supersession_fields "$id" "$body" || fail "captain hold $id has no supersession identity record"
    [ "$SUPERSESSION_PATH" = "$relative" ] || fail "captain hold $id records a different decision path"
    [ "$SUPERSESSION_DIGEST" = "$digest" ] || fail "captain hold $id records a different decision record"
    [ "$SUPERSESSION_TASK" = "$shipped_task" ] || fail "captain hold $id records a different shipped task"
    printf 'superseded: %s -> %s, %s\n' "$id" "$relative" "$shipped_task"
    return 0
  fi
  verify_hold_active "$id"
  body=$(printf 'Supersession recorded by fm-decision-hold.\nDecision path: %s\nDecision digest: %s\nShipped task: %s' \
    "$relative" "$digest" "$shipped_task")
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not bind later authority to captain hold $id"
  tasks_axi "done" "$id" >/dev/null || fail "could not close superseded captain hold $id"
  [ "$(hold_state "$id")" = superseded ] || fail "captain hold $id did not retain its supersession binding"
  printf 'superseded: %s -> %s, %s\n' "$id" "$relative" "$shipped_task"
}

verify_resolution_identity() {
  local id=$1 hold_body=$2 decision_digest=$3 routed_csv=$4 resolution_prefix resolution_fields recorded_digest recorded_routes
  resolution_prefix='"Resolution recorded by fm-decision-hold.\nDecision digest: '
  case "$hold_body" in
    "$resolution_prefix"*) resolution_fields=${hold_body#"$resolution_prefix"} ;;
    *) fail "captain hold $id has no retry identity record" ;;
  esac
  case "$resolution_fields" in
    *'\nRouted identities: '*'\n\nCaptain decision:'*) : ;;
    *) fail "captain hold $id has an invalid retry identity record" ;;
  esac
  recorded_digest=${resolution_fields%%\\n*}
  resolution_fields=${resolution_fields#*\\nRouted identities: }
  recorded_routes=${resolution_fields%%\\n*}
  [ "$recorded_digest" = "$decision_digest" ] \
    || fail "captain hold $id records a different captain decision"
  [ "$recorded_routes" = "$routed_csv" ] \
    || fail "captain hold $id records different routed work"
}

command_id() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  hold_id "$1" "$2"
}

command_hold() {
  local origin=${1:-} key=${2:-} title='' reason='' repo='' id show state kind existing_title body
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  validate_one_line title "$title"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  id=$(hold_id "$origin" "$key")
  if show=$(task_show "$id"); then
    state=$(show_field "$show" state)
    kind=$(show_field "$show" kind)
    existing_title=$(show_field "$show" title)
    [ "$state" != "done" ] || fail "captain decision $id is already durably resolved; use a new decision key for a new decision"
    [ "$kind" = captain ] || fail "existing backlog identity $id is not kind captain"
    [ "$existing_title" = "$title" ] || fail "existing captain hold $id has a different title"
  else
    if [ -z "$repo" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    body=$(printf 'Origin: %s\nDecision key: %s\nState: awaiting captain decision.' "$origin" "$key")
    tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
      || fail "could not create captain decision item $id"
  fi
  tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
    || fail "could not activate captain hold $id"
  verify_hold_active "$id"
  printf '%s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' key status_file open raw_open key_seen=0 has_meta=0
  local decision_none=0 decision_seen=0 idea_attestation='' idea_supplied='' previous_ideas='' idea_keys='' idea_id
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --none)
        [ "$decision_none" -eq 0 ] || fail "--none may be supplied only once"
        [ -z "$supplied" ] || fail "--none cannot be combined with decision keys"
        decision_none=1
        decision_seen=1
        shift
        ;;
      --no-ideas)
        [ -z "$idea_attestation" ] || fail "--no-ideas cannot be combined with --ideas or repeated"
        idea_attestation=none
        shift
        [ "$#" -eq 0 ] || fail "--no-ideas must follow the decision inventory and cannot take values"
        ;;
      --ideas)
        [ -z "$idea_attestation" ] || fail "--ideas cannot be combined with --no-ideas or repeated"
        idea_attestation=ideas
        shift
        [ "$#" -gt 0 ] || fail "--ideas requires at least one PI-NNN id"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --ideas|--no-ideas) fail "--ideas cannot be combined with --no-ideas or repeated" ;;
            --none) fail "--ideas must follow the decision inventory" ;;
          esac
          validate_idea_id "$1"
          idea_supplied="${idea_supplied}${idea_supplied:+ }$1"
          shift
        done
        ;;
      *)
        [ "$decision_none" -eq 0 ] || fail "--none cannot be combined with decision keys"
        validate_slug decision-key "$1"
        supplied="${supplied}${supplied:+ }$1"
        decision_seen=1
        shift
        ;;
    esac
  done
  [ "$decision_seen" -eq 1 ] || fail "decision attestation is required: use --none or name decision keys"
  [ -n "$idea_attestation" ] || fail "idea attestation is required: use --ideas <PI-id>... or --no-ideas"
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  if [ "$has_meta" = 1 ]; then
    previous_ideas=$(meta_value "$meta" idea_ids)
  fi
  idea_keys=$(sorted_key_union "$previous_ideas" "$idea_supplied")
  if [ "$idea_attestation" = none ]; then
    create_idea_ledger
  fi
  if [ -n "$idea_keys" ]; then
    while IFS= read -r idea_id; do
      [ -n "$idea_id" ] || continue
      verify_idea_row "$origin" "$idea_id"
    done <<EOF
$(printf '%s\n' "$idea_keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key has no captain-held inventory entry"
  done <<EOF
$open
EOF

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    if [ "$(meta_value "$meta" ideas_reviewed)" != 1 ] || [ "$previous_ideas" != "$idea_keys" ]; then
      printf 'ideas_reviewed=1\nidea_ids=%s\n' "$idea_keys" >> "$meta"
    fi

    # Transfer any still-open status decision to its durable backlog owner so the
    # live status fold does not duplicate the same Captain's Call item.
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      list_has_key "$keys" "$key" || continue
      printf 'captain-held [key=%s]: tracked by %s\n' "$key" "$(hold_id "$origin" "$key")" >> "$status_file"
      key_seen=1
    done <<EOF
$raw_open
EOF
  fi
  : "$key_seen"
  printf 'complete: %s decision and product-idea inventories reviewed%s%s\n' \
    "$origin" "${keys:+; decisions=$keys}" "${idea_keys:+; ideas=$idea_keys}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys key open ideas_reviewed idea_keys idea_id
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed unresolved-decision inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      verify_hold_durable "$(hold_id "$origin" "$key")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    list_has_key "$keys" "$key" \
      || fail "open structured decision $origin/$key is outside the reviewed inventory"
    verify_hold_durable "$(hold_id "$origin" "$key")"
  done <<EOF
$open
EOF
  ideas_reviewed=$(meta_value "$meta" ideas_reviewed)
  if [ -n "$ideas_reviewed" ]; then
    [ "$ideas_reviewed" = 1 ] || fail "origin $origin has an invalid product-idea inventory attestation"
    idea_keys=$(meta_value "$meta" idea_ids)
    if [ -n "$idea_keys" ]; then
      while IFS= read -r idea_id; do
        [ -n "$idea_id" ] || continue
        verify_idea_row "$origin" "$idea_id"
      done <<EOF
$(printf '%s\n' "$idea_keys" | tr ',' '\n')
EOF
    fi
  fi
  printf 'verified: %s unresolved-decision inventory\n' "$origin"
}

command_resolve() {
  local origin=${1:-} key=${2:-} decision_file='' id='' decision='' decision_digest='' body='' routed='' routed_csv='' dep show blocked state hold_show hold_body resolution_recorded=0
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --routed-to) shift; validate_slug routed-task "${1:-}"; routed="${routed}${routed:+ }${1:-}" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug origin-id "$origin"
  validate_slug decision-key "$key"
  [ -n "$decision_file" ] || fail "--decision-file is required"
  [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
  decision=$(cat "$decision_file")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  [ -n "$routed" ] || fail "at least one --routed-to task is required"
  routed=$(printf '%s\n' "$routed" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  routed_csv=$(printf '%s\n' "$routed" | tr ' ' ',')
  decision_digest=$(sha256_text "$decision")
  require_tasks_axi
  id=$(hold_id "$origin" "$key")
  if verify_hold_resolved "$id"; then
    hold_show=$(task_show "$id")
    hold_body=$(show_field "$hold_show" body)
    verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
    printf 'resolved: %s\n' "$id"
    return 0
  fi
  verify_hold_active "$id"
  hold_show=$(task_show "$id")
  hold_body=$(show_field "$hold_show" body)
  case "$hold_body" in
    *"Resolution recorded by fm-decision-hold."*)
      verify_resolution_identity "$id" "$hold_body" "$decision_digest" "$routed_csv"
      resolution_recorded=1
      ;;
  esac

  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep does not exist in the active home"
    state=$(show_field "$show" state)
    [ "$state" != "done" ] || [ "$resolution_recorded" = 1 ] \
      || fail "routed task $dep is already done"
    # tasks-axi quotes multi-entry blocked_by as "a,b,c"; strip so edge ids match.
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*) : ;;
      *)
        case "$hold_body" in
          *"Resolution recorded by fm-decision-hold."*"- $dep"*) : ;;
          *) fail "routed task $dep is not durably blocked by $id" ;;
        esac
        ;;
    esac
  done

  body=$(printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: %s\n\nCaptain decision:\n%s\n\nRouted work:\n' "$decision_digest" "$routed_csv" "$decision")
  for dep in $routed; do
    body="${body}- ${dep}"$'\n'
  done
  tasks_axi update "$id" --body "$body" >/dev/null \
    || fail "could not record the captain decision on $id"
  for dep in $routed; do
    show=$(task_show "$dep") || fail "routed task $dep disappeared before routing"
    blocked=$(show_field "$show" blocked_by | tr -d '[:space:]')
    blocked=${blocked#\"}
    blocked=${blocked%\"}
    case ",$blocked," in
      *",$id,"*)
        tasks_axi unblock "$dep" --by "$id" >/dev/null \
          || fail "could not route the recorded decision to $dep"
        ;;
    esac
  done
  tasks_axi "done" "$id" >/dev/null || fail "could not close resolved captain hold $id"
  verify_hold_resolved "$id" || fail "captain hold $id did not retain its durable resolution record"
  printf 'resolved: %s -> %s\n' "$id" "$routed"
}

case "${1:-}" in
  id) shift; command_id "$@" ;;
  hold) shift; command_hold "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  supersede) shift; command_supersede "$@" ;;
  state) shift; command_state "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
