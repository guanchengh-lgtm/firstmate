#!/usr/bin/env bash
# fm-graphify.sh - T10 graphify inventory, nightly update, merge, eval, coverage.
#
# Usage:
#   fm-graphify.sh inventory --projects-root DIR --record DIR --registry FILE
#                            [--home DIR] [--extra DIR]...
#   fm-graphify.sh nightly --record DIR --projects-root DIR
#   fm-graphify.sh eval --probes FILE --graphify-raw FILE --t2-raw FILE
#                       [--graph FILE]
#   fm-graphify.sh cover --root DIR [--graph FILE] [--detect FILE]
#   fm-graphify.sh --help
#
# This command is the public T10 invocation. bin/fm-graphify.py owns ledger
# grammar, inventory identity, the nightly plan, citation mapping, and
# coverage rows. This shell runs that owner, then the installed graphify
# binary for update, wiki export, and merge-graphs only.
# It never installs or upgrades graphify, never writes a hook or user-scope
# skill, never exports Obsidian or HTML, and never creates a second scheduler.
# Shell `graphify update` is a code rebuild. Document extraction stays on the
# host assistant `--update --wiki` workflow.
# A missing selected ready graph refuses merge and leaves any prior merged
# graph in place. Pending selected rows skip merge instead of publishing a
# partial union.
#
# The Record ledger is
#   <record>/knowledge-system-wayfinder/research/T10-graphify/inputs.tsv
# Nightly is not-configured when that file is absent. No nightly.env key
# enables or disables the stage.
#
# Exit codes:
#   0   ok, including unchanged and pending-inputs
#   1   finding docs-stale
#   2   usage
#   10  failed missing-input
#   11  failed graphify command
#   12  graphify binary missing when a step needs it
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_OWNER="$SCRIPT_DIR/fm-graphify.py"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

abs_dir() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "graphify: $name directory cannot be resolved: $path" >&2
    return 2
  }
  printf '%s\n' "$resolved"
}

run_python() {
  python3 "$PYTHON_OWNER" "$@"
}

require_graphify() {
  if ! command -v graphify >/dev/null 2>&1; then
    echo "graphify: graphify binary missing" >&2
    return 12
  fi
  return 0
}

run_update() {
  local root=$1
  require_graphify || return $?
  (
    CDPATH='' cd -- "$root" || exit 11
    graphify update .
  ) || return 11
}

run_wiki() {
  local root=$1
  require_graphify || return $?
  (
    CDPATH='' cd -- "$root" || exit 11
    graphify export wiki
  ) || return 11
}

run_merge() {
  require_graphify || return $?
  local out=$1
  shift
  graphify merge-graphs "$@" --out "$out" || return 11
}

cmd_nightly() {
  local record="" projects_root=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --record)
        record=$(abs_dir record "${2:-}") || return 2
        shift 2
        ;;
      --projects-root)
        projects_root=$(abs_dir projects-root "${2:-}") || return 2
        shift 2
        ;;
      *)
        echo "graphify: unknown nightly flag: $1" >&2
        return 2
        ;;
    esac
  done
  [ -n "$record" ] || { echo "graphify: nightly requires --record" >&2; return 2; }
  [ -n "$projects_root" ] || { echo "graphify: nightly requires --projects-root" >&2; return 2; }

  local plan status detail line rc
  plan=$(run_python plan --record "$record" --projects-root "$projects_root") || {
    rc=$?
    [ "$rc" -eq 2 ] && return 2
    return 11
  }
  status=
  detail=
  while IFS= read -r line; do
    case "$line" in
      status=*) status=${line#status=} ;;
      detail=*) detail=${line#detail=} ;;
      step=update$'\t'*)
        run_update "${line#step=update	}" || return $?
        ;;
      step=wiki$'\t'*)
        run_wiki "${line#step=wiki	}" || return $?
        ;;
      step=merge$'\t'*)
        local rest out
        rest=${line#step=merge	}
        out=${rest##*	}
        rest=${rest%	*}
        # shellcheck disable=SC2086
        run_merge "$out" $rest || return $?
        ;;
    esac
  done <<EOF
$plan
EOF
  printf 'status=%s\tdetail=%s\n' "$status" "$detail"
  case "$status" in
    ok) return 0 ;;
    finding) return 1 ;;
    failed)
      case "$detail" in
        missing-input) return 10 ;;
        *) return 11 ;;
      esac
      ;;
    *) return 11 ;;
  esac
}

case "${1:-}" in
  -h | --help | "")
    usage
    exit 0
    ;;
  inventory | eval | cover)
    run_python "$@"
    exit $?
    ;;
  nightly)
    shift
    cmd_nightly "$@"
    exit $?
    ;;
  *)
    echo "graphify: unknown command: $1" >&2
    exit 2
    ;;
esac
