#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes both invoke this script with no arguments, so the rule set,
# version, bounded execution, and diagnostics ordering cannot drift.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks. CI and
# no-mistakes keep the full-analysis no-argument default.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
# The default (no explicit-path) path also runs the AGENTS.md companion gate
# and bin/fm-lint-workflows.sh, so a malformed GitHub workflow, including a
# self-broken ci.yml, fails locally before merge instead of only failing as CI.
# The AGENTS.md gate validates safe UTF-8 text, enforces its
# calibrated-byte hard ceiling, and compares final content with the accepted
# target base for net-zero growth and new-line why traces.
# Pull request CI supplies FM_LINT_BASE_SHA, local branches use the current
# origin/main or main ancestor, and the main branch uses HEAD^1.
# Growth needs exactly one paired trailer set in the accepted branch range:
#   AGENTS-Budget-Override: v1 base=<blob> target=<blob> before=<count> after=<count>
#   Captain-Instruction: <the captain's exact words for this growth>
# The instruction must be non-empty and must not be one of the finite generic
# approval shapes below; lint does not certify natural language beyond that,
# so blob and count binding is the guard that makes a stale override unusable.
# Both counts are calibrated bytes for the bound AGENTS.md blobs.
# An override never bypasses file safety, the hard ceiling, or why traces.
# firstmate-coding-guidelines owns the why-trace marker grammar.
#
# With no explicit paths, the file set depends on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh. This is
#     what CI always runs, so CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). A branch with zero matching changed files skips ShellCheck and
#     prints a "no changed lint targets" note, then still runs both companion
#     gates.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without either companion gate.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. FM_LINT_JOBS=1
# runs the same shards serially with byte-identical diagnostics and exit selection.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output rc=0
  local -a roots shellcheck_args
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    shellcheck_args=(--norc --external-sources)
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      shellcheck_args+=(--extended-analysis=false)
    fi
    "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "${roots[@]}" > "$output.out" 2>&1 &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Captain-locked calibration, measured once on 2026-08-31 with pinned
# tiktoken==0.14.0 and cl100k_base: 30,567 UTF-8 bytes encoded to 6,270
# `cl100k_base` tokens. The exact calibration is
# floor(30,567 * 6,000 / 6,270) = 29,250 calibrated bytes.
# Runtime enforcement is offline and bytes-only;
# this constant does not claim provider-exact token counts for later content.
AGENTS_CALIBRATED_BYTE_CEILING=29250

fm_lint_agentsmd_error() {
  printf 'fm-lint.sh: AGENTS.md budget: %s\n' "$*" >&2
  return 1
}

fm_lint_agentsmd_link_count() {  # <path>
  local path=$1 links
  links=$(stat -f '%l' "$path" 2>/dev/null) \
    || links=$(stat -c '%h' "$path" 2>/dev/null) \
    || return 1
  case "$links" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$links"
}

fm_lint_agentsmd_read_bits() {  # <path>
  local path=$1 mode digits owner group other
  mode=$(stat -f '%OLp' "$path" 2>/dev/null) \
    || mode=$(stat -c '%a' "$path" 2>/dev/null) \
    || return 1
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  digits=${mode: -3}
  [ "${#digits}" -eq 3 ] || return 1
  owner=${digits:0:1}
  group=${digits:1:1}
  other=${digits:2:1}
  [ $((owner & 4)) -ne 0 ] || [ $((group & 4)) -ne 0 ] || [ $((other & 4)) -ne 0 ]
}

fm_lint_agentsmd_validate_current() {
  local path=$1 links
  [ ! -L "$path" ] || {
    fm_lint_agentsmd_error 'AGENTS.md must not be a symlink.'
    return 1
  }
  [ -e "$path" ] || {
    fm_lint_agentsmd_error 'AGENTS.md is missing.'
    return 1
  }
  [ -f "$path" ] || {
    fm_lint_agentsmd_error 'AGENTS.md must be a regular file.'
    return 1
  }
  links=$(fm_lint_agentsmd_link_count "$path") \
    || {
      fm_lint_agentsmd_error 'could not read AGENTS.md link metadata.'
      return 1
    }
  [ "$links" -eq 1 ] || {
    fm_lint_agentsmd_error 'AGENTS.md must not be hardlinked.'
    return 1
  }
  if [ ! -r "$path" ] || ! fm_lint_agentsmd_read_bits "$path"; then
    fm_lint_agentsmd_error 'AGENTS.md is unreadable.'
    return 1
  fi
  command -v iconv >/dev/null 2>&1 \
    || {
      fm_lint_agentsmd_error 'iconv is required to validate AGENTS.md UTF-8.'
      return 1
    }
  "$PERL_BIN" -e "while (read(STDIN, \$chunk, 8192)) { exit 1 if index(\$chunk, \"\\0\") >= 0 }" \
    < "$path" >/dev/null 2>&1 \
    || {
      fm_lint_agentsmd_error 'AGENTS.md is not valid UTF-8 or contains NUL bytes.'
      return 1
    }
  LC_ALL=C iconv -f UTF-8 -t UTF-8 "$path" >/dev/null 2>&1 \
    || {
      fm_lint_agentsmd_error 'AGENTS.md is not valid UTF-8.'
      return 1
    }
}

fm_lint_agentsmd_bytes() {  # <path>
  local bytes
  bytes=$(LC_ALL=C wc -c < "$1" 2>/dev/null | tr -d '[:space:]') || return 1
  case "$bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$bytes"
}

fm_lint_agentsmd_slug_valid() {  # <slug>
  [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

fm_lint_agentsmd_repo_path_valid() {  # <path>
  local path=$1
  [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  case "/$path/" in
    *'//'*) return 1 ;;
    *'/./'*|*'/../'*) return 1 ;;
  esac
  case "$path" in
    /*|.|..|*/.|*/..) return 1 ;;
  esac
}

fm_lint_agentsmd_repo_file_valid() {  # <path>
  local path=$1 rest component current=$ROOT
  fm_lint_agentsmd_repo_path_valid "$path" || return 1
  rest=$path
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component=${rest%%/*}; rest=${rest#*/} ;;
      *) component=$rest; rest= ;;
    esac
    current=$current/$component
    [ ! -L "$current" ] || return 1
  done
  [ -f "$current" ]
}

fm_lint_agentsmd_why_target_valid() {  # <kind> <target>
  local kind=$1 target=$2 name slug path
  case "$kind" in
    skill)
      case "$target" in
        *'#'*) name=${target%%#*}; slug=${target#*#} ;;
        *) return 1 ;;
      esac
      [ "$slug" = "${slug#*#}" ] || return 1
      fm_lint_agentsmd_slug_valid "$name" || return 1
      fm_lint_agentsmd_slug_valid "$slug" || return 1
      fm_lint_agentsmd_repo_file_valid ".agents/skills/$name/SKILL.md" \
        || fm_lint_agentsmd_repo_file_valid "skills/$name/SKILL.md"
      ;;
    doc)
      case "$target" in
        *'#'*) path=${target%%#*}; slug=${target#*#} ;;
        *) return 1 ;;
      esac
      [ "$slug" = "${slug#*#}" ] || return 1
      fm_lint_agentsmd_slug_valid "$slug" || return 1
      fm_lint_agentsmd_repo_file_valid "$path"
      ;;
    script)
      case "$target" in
        *--help) path=${target%--help} ;;
        *) return 1 ;;
      esac
      [ -n "$path" ] || return 1
      fm_lint_agentsmd_repo_file_valid "$path" && [ -x "$ROOT/$path" ]
      ;;
    lock)
      [[ "$target" =~ ^[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]
      ;;
    *) return 1 ;;
  esac
}

fm_lint_agentsmd_fence_context() {  # <line-number> <normalized-path>
  awk -v target="$1" '
    function candidate(line, first, text, char, count) {
      match(line, /^ */)
      if (RLENGTH > 3) return 0
      text=substr(line, RLENGTH + 1)
      char=substr(text, 1, 1)
      if (char != "`" && char != "~") return 0
      count=0
      while (substr(text, count + 1, 1) == char) count++
      if (count < 3) return 0
      candidate_char=char
      candidate_count=count
      candidate_rest=substr(text, count + 1)
      return 1
    }
    function valid_opening() {
      return candidate_char == "~" || index(candidate_rest, "`") == 0
    }
    function valid_closing() {
      return candidate_char == open_char \
        && candidate_count >= open_count \
        && candidate_rest ~ /^[ \t]*$/
    }
    NR < target {
      if (!candidate($0)) next
      if (open_char == "") {
        if (valid_opening()) {
          open_char=candidate_char
          open_count=candidate_count
        }
      } else if (valid_closing()) {
        open_char=""
        open_count=0
      }
      next
    }
    NR == target {
      if (candidate($0)) {
        if (open_char == "" && valid_opening()) {
          print "delimiter"
          exit
        }
        if (open_char != "" && valid_closing()) {
          print "delimiter"
          exit
        }
      }
      if (open_char != "") print "inside"
      else print "outside"
      exit
    }
  ' "$2"
}

fm_lint_agentsmd_visible_line() {  # <line-number> <normalized-path>
  awk -v target="$1" '
    NR <= target {
      visible=""
      for (i=1; i <= length($0); i++) {
        if (!hidden && substr($0, i, 4) == "<!--") {
          hidden=1
          i += 3
          continue
        }
        if (hidden && substr($0, i, 3) == "-->") {
          hidden=0
          i += 2
          continue
        }
        if (!hidden) visible=visible substr($0, i, 1)
      }
      if (NR == target) {
        print visible
        exit
      }
    }
  ' "$2"
}

fm_lint_agentsmd_visible_owner_present() {  # <line> <target> <kind>
  local line=$1 target=$2 kind=$3
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  "$PERL_BIN" -e '
    my ($line, $target, $kind) = @ARGV;
    if ($kind eq "skill" || $kind eq "lock") {
      exit($line =~ /(?<![A-Za-z0-9_-])\Q$target\E(?![A-Za-z0-9_-])/ ? 0 : 1);
    }
    if ($kind eq "script") {
      exit($line =~ /(?<![A-Za-z0-9_.\/-])\Q$target\E(?:--help)?(?![A-Za-z0-9_\/-]|\.[A-Za-z0-9_.\/-])/ ? 0 : 1);
    }
    exit($line =~ /(?<![A-Za-z0-9_.\/-])\Q$target\E(?![A-Za-z0-9_\/-]|\.[A-Za-z0-9_.\/-])/ ? 0 : 1);
  ' -- "$line" "$target" "$kind"
}

fm_lint_agentsmd_why_marker_is_top_level() {  # <line-number> <normalized-path>
  awk -v target="$1" '
    NR <= target {
      for (i=1; i <= length($0); i++) {
        if (NR == target && substr($0, i, 10) == "<!-- why: ") {
          found=1
          exit (hidden ? 1 : 0)
        }
        if (!hidden && substr($0, i, 4) == "<!--") {
          hidden=1
          i += 3
          continue
        }
        if (hidden && substr($0, i, 3) == "-->") {
          hidden=0
          i += 2
        }
      }
    }
    END {
      if (!found) exit 1
    }
  ' "$2"
}

fm_lint_agentsmd_validate_added_line() {  # <line-number> <content> <normalized-path>
  local line_number=$1 content=$2 normalized_path=$3
  local prefix remainder owner kind target context
  local visible_line visible_target why_prefix='<!-- why: '
  local blank_re heading_re
  blank_re=$'^[ \t]*$'
  heading_re=$'^ {0,3}#{1,6}([ \t]|$)'
  [[ "$content" =~ $blank_re ]] && return 0
  context=$(fm_lint_agentsmd_fence_context "$line_number" "$normalized_path") \
    || {
      fm_lint_agentsmd_error "could not determine Markdown fence context for line $line_number."
      return 1
    }
  [ "$context" = delimiter ] && return 0
  if [ "$context" != inside ] && [[ "$content" =~ $heading_re ]]; then
    return 0
  fi

  case "$content" in
    *'<!-- why: '*) ;;
    *)
      fm_lint_agentsmd_error "line $line_number is added content without a why trace."
      return 1
      ;;
  esac
  fm_lint_agentsmd_why_marker_is_top_level "$line_number" "$normalized_path" \
    || {
      fm_lint_agentsmd_error "line $line_number has a why trace nested inside another HTML comment."
      return 1
    }
  prefix=${content%%"$why_prefix"*}
  remainder=${content#*"$why_prefix"}
  case "$prefix$remainder" in
    *'<!-- why: '*)
      fm_lint_agentsmd_error "line $line_number has more than one why trace."
      return 1
      ;;
  esac
  case "$remainder" in
    *' -->') owner=${remainder%' -->'} ;;
    *)
      fm_lint_agentsmd_error "line $line_number has a malformed trailing why trace."
      return 1
      ;;
  esac
  case "$owner" in
    *:*) kind=${owner%%:*}; target=${owner#*:} ;;
    *)
      fm_lint_agentsmd_error "line $line_number has a malformed why owner."
      return 1
      ;;
  esac
  [ -n "$target" ] || {
    fm_lint_agentsmd_error "line $line_number has an empty why target."
    return 1
  }
  fm_lint_agentsmd_why_target_valid "$kind" "$target" \
    || {
      fm_lint_agentsmd_error "line $line_number has an invalid why target: $kind:$target"
      return 1
    }
  case "$kind" in
    skill|doc) visible_target=${target%%#*} ;;
    script) visible_target=${target%--help} ;;
    lock) visible_target=$target ;;
  esac
  visible_line=$(fm_lint_agentsmd_visible_line "$line_number" "$normalized_path") \
    || {
      fm_lint_agentsmd_error "could not determine visible Markdown content for line $line_number."
      return 1
    }
  fm_lint_agentsmd_visible_owner_present "$visible_line" "$visible_target" "$kind" \
    || {
      fm_lint_agentsmd_error "line $line_number has why metadata without the visible owner pointer $visible_target."
      return 1
    }
}

fm_lint_agentsmd_validate_added_lines() {  # <base-blob>
  local base_blob=$1 line_number content temp_dir diff_rc=0 trace_rc=0
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint-agentsmd.XXXXXX") \
    || {
      fm_lint_agentsmd_error 'could not create the AGENTS.md diff workspace.'
      return 1
    }
  (set -o pipefail
    git cat-file blob "$base_blob" 2>/dev/null \
      | "$PERL_BIN" -0777 -pe 's/\r\n?/\n/g' > "$temp_dir/base"
  ) \
    || {
      rm -rf "$temp_dir"
      fm_lint_agentsmd_error 'could not normalize target base AGENTS.md line endings.'
      return 1
    }
  "$PERL_BIN" -0777 -pe 's/\r\n?/\n/g' < "$ROOT/AGENTS.md" > "$temp_dir/current" \
    || {
      rm -rf "$temp_dir"
      fm_lint_agentsmd_error 'could not normalize final AGENTS.md line endings.'
      return 1
    }
  git diff --no-index --no-ext-diff --no-color --text --unified=0 \
    "$temp_dir/base" "$temp_dir/current" > "$temp_dir/patch" 2>/dev/null \
    || diff_rc=$?
  if [ "$diff_rc" -ne 0 ] && [ "$diff_rc" -ne 1 ]; then
    rm -rf "$temp_dir"
    fm_lint_agentsmd_error 'could not read the zero-context AGENTS.md diff.'
    return 1
  fi
  if ! awk '
      /^@@ / {
        header=$0
        sub(/^.* \+/, "", header)
        sub(/ .*/, "", header)
        split(header, range, ",")
        next_line=range[1] + 0
        in_hunk=1
        next
      }
      in_hunk && /^\+/ {
        print next_line
        print substr($0, 2)
        next_line++
        next
      }
      in_hunk && /^-/ {next}
      in_hunk && /^\\ No newline at end of file$/ {next}
    ' "$temp_dir/patch" > "$temp_dir/added"; then
    rm -rf "$temp_dir"
    fm_lint_agentsmd_error 'could not parse the zero-context AGENTS.md diff.'
    return 1
  fi
  while IFS= read -r line_number; do
    IFS= read -r content || content=
    [ -n "$line_number" ] || continue
    if ! fm_lint_agentsmd_validate_added_line \
      "$line_number" "$content" "$temp_dir/current"; then
      trace_rc=1
      break
    fi
  done < "$temp_dir/added"
  rm -rf "$temp_dir"
  return "$trace_rc"
}

fm_lint_agentsmd_base_history_complete() {  # <base-ref>
  git cat-file -e "$1^{commit}" 2>/dev/null || return 1
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ]
}

fm_lint_agentsmd_instruction_is_generic() {  # <normalized-instruction>
  local instruction=$1
  instruction=$(printf '%s\n' "$instruction" \
    | LC_ALL=C tr -d '`"!.?,;:' \
    | LC_ALL=C tr '-' ' ' \
    | LC_ALL=C awk '{$1=$1; print}')
  case "$instruction" in
    approved|approval|approve|ok|okay|yes|lgtm|'ship it'|'go ahead'|'do it'| \
    'sounds good'|'captain approved'|'approved by captain'|'permission granted'| \
    'approval granted'|'approval received'|'growth approved'|'growth authorized'| \
    authorized|'captain authorized')
      return 0
      ;;
  esac
  return 1
}

fm_lint_agentsmd_validate_override() {  # <base> <base-blob> <target-blob> <before> <after>
  local base=$1 expected_base_blob=$2 expected_target_blob=$3 before=$4 after=$5
  local commit message trailers line value instruction
  local override_count=0 captain_count=0 override_commit='' captain_commit=''
  local override_value='' captain_value=''
  local override_re
  override_re='^v1 base=([0-9a-f]{40}|[0-9a-f]{64}) target=([0-9a-f]{40}|[0-9a-f]{64}) before=([0-9]+) after=([0-9]+)$'

  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    message=$(git show -s --format=%B "$commit" 2>/dev/null) \
      || {
        fm_lint_agentsmd_error 'could not read a commit in the AGENTS.md override range.'
        return 1
      }
    trailers=$(printf '%s\n' "$message" | git interpret-trailers --parse 2>/dev/null) \
      || {
        fm_lint_agentsmd_error 'could not parse AGENTS.md budget override trailers.'
        return 1
      }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'AGENTS-Budget-Override:'*)
          override_count=$((override_count + 1))
          override_commit=$commit
          value=${line#AGENTS-Budget-Override:}
          override_value=${value# }
          ;;
        'Captain-Instruction:'*)
          captain_count=$((captain_count + 1))
          captain_commit=$commit
          value=${line#Captain-Instruction:}
          captain_value=${value# }
          ;;
      esac
    done <<< "$trailers"
  done < <(git rev-list "$base..HEAD" 2>/dev/null)

  git rev-list "$base..HEAD" >/dev/null 2>&1 || {
    fm_lint_agentsmd_error 'could not inspect the current branch range for override trailers.'
    return 1
  }
  [ "$override_count" -eq 1 ] || {
    fm_lint_agentsmd_error "growth requires exactly one AGENTS-Budget-Override trailer; found $override_count."
    return 1
  }
  [ "$captain_count" -eq 1 ] || {
    fm_lint_agentsmd_error "growth requires exactly one paired Captain-Instruction trailer; found $captain_count."
    return 1
  }
  [ "$override_commit" = "$captain_commit" ] || {
    fm_lint_agentsmd_error 'the AGENTS-Budget-Override and Captain-Instruction trailers must be in the same commit.'
    return 1
  }
  [[ "$override_value" =~ $override_re ]] || {
    fm_lint_agentsmd_error 'the AGENTS-Budget-Override trailer does not match the v1 grammar.'
    return 1
  }
  [ "${BASH_REMATCH[1]}" = "$expected_base_blob" ] || {
    fm_lint_agentsmd_error 'the AGENTS-Budget-Override base blob is stale.'
    return 1
  }
  [ "${BASH_REMATCH[2]}" = "$expected_target_blob" ] || {
    fm_lint_agentsmd_error 'the AGENTS-Budget-Override target blob is stale.'
    return 1
  }
  [ "${BASH_REMATCH[3]}" = "$before" ] || {
    fm_lint_agentsmd_error 'the AGENTS-Budget-Override before count is wrong.'
    return 1
  }
  [ "${BASH_REMATCH[4]}" = "$after" ] || {
    fm_lint_agentsmd_error 'the AGENTS-Budget-Override after count is wrong.'
    return 1
  }
  [ -n "$captain_value" ] || {
    fm_lint_agentsmd_error 'the Captain-Instruction trailer must quote the captain exact words.'
    return 1
  }
  instruction=$(printf '%s\n' "$captain_value" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C awk '{$1=$1; print}')
  if fm_lint_agentsmd_instruction_is_generic "$instruction"; then
    fm_lint_agentsmd_error 'the Captain-Instruction trailer is generic; quote the captain exact words.'
    return 1
  fi
}

fm_lint_run_agentsmd_budget() {
  local path=$ROOT/AGENTS.md bytes current_blob head_blob branch base_ref base
  local entry mode type base_blob base_bytes target_blob diff_rc
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0

  fm_lint_agentsmd_validate_current "$path" || return 1
  bytes=$(fm_lint_agentsmd_bytes "$path") \
    || {
      fm_lint_agentsmd_error 'could not count AGENTS.md calibrated bytes.'
      return 1
    }
  [ "$bytes" -le "$AGENTS_CALIBRATED_BYTE_CEILING" ] || {
    fm_lint_agentsmd_error "AGENTS.md uses $bytes calibrated bytes; the hard ceiling is $AGENTS_CALIBRATED_BYTE_CEILING."
    return 1
  }

  command -v git >/dev/null 2>&1 || {
    fm_lint_agentsmd_error 'git is required to prove the AGENTS.md target baseline.'
    return 1
  }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    fm_lint_agentsmd_error 'a Git worktree is required to prove the AGENTS.md target baseline.'
    return 1
  }

  current_blob=$(git hash-object -- AGENTS.md 2>/dev/null) \
    || {
      fm_lint_agentsmd_error 'could not hash the final AGENTS.md content.'
      return 1
    }
  head_blob=$(git rev-parse --verify -q 'HEAD:AGENTS.md' 2>/dev/null) || head_blob=
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=
  base=

  if [ -n "${FM_LINT_BASE_SHA:-}" ] \
    && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ]; then
    fm_lint_agentsmd_error 'FM_LINT_BASE_SHA is CI-only; local lint uses the current target ref.'
    return 1
  elif [ -n "${FM_LINT_BASE_SHA:-}" ]; then
    base=$FM_LINT_BASE_SHA
  elif [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
    fm_lint_agentsmd_error 'FM_LINT_BASE_SHA is required for pull request lint; fetch the exact target base commit.'
    return 1
  elif [ "$branch" = main ]; then
    if git rev-parse --verify -q 'HEAD^1^{commit}' >/dev/null 2>&1; then
      base=HEAD^1
    elif [ "$current_blob" = "$head_blob" ]; then
      printf 'fm-lint.sh: AGENTS.md %s calibrated bytes (ceiling %s)\n' \
        "$bytes" "$AGENTS_CALIBRATED_BYTE_CEILING"
      return 0
    else
      fm_lint_agentsmd_error 'the main-push AGENTS.md baseline is unreadable; fetch parent history.'
      return 1
    fi
  else
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    if [ -z "$base_ref" ]; then
      fm_lint_agentsmd_error 'the target AGENTS.md base is missing; synchronize the target branch.'
      return 1
    fi
    base=$base_ref
  fi

  git cat-file -e "$base^{commit}" >/dev/null 2>&1 \
    || {
      fm_lint_agentsmd_error "target base $base is unreadable; fetch the exact base commit and retry."
      return 1
    }
  git merge-base --is-ancestor "$base" HEAD >/dev/null 2>&1 \
    || {
      fm_lint_agentsmd_error "target base $base is stale or unrelated; fetch the exact target commit or synchronize the branch."
      return 1
    }
  entry=$(git ls-tree "$base" -- AGENTS.md 2>/dev/null) \
    || {
      fm_lint_agentsmd_error "target base $base has no readable AGENTS.md blob."
      return 1
    }
  read -r mode type base_blob _ <<< "$entry"
  if [ "$type" != blob ] || { [ "$mode" != 100644 ] && [ "$mode" != 100755 ]; }; then
    fm_lint_agentsmd_error "target base $base has no regular AGENTS.md blob."
    return 1
  fi
  (set -o pipefail
    git cat-file blob "$base_blob" 2>/dev/null \
      | "$PERL_BIN" -e "while (read(STDIN, \$chunk, 8192)) { exit 1 if index(\$chunk, \"\\0\") >= 0 }"
  ) \
    || {
      fm_lint_agentsmd_error "target base $base has an unreadable or invalid UTF-8 AGENTS.md blob, or it contains NUL bytes."
      return 1
    }
  (set -o pipefail
    git cat-file blob "$base_blob" 2>/dev/null \
      | LC_ALL=C iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
  ) \
    || {
      fm_lint_agentsmd_error "target base $base has an unreadable or invalid UTF-8 AGENTS.md blob, or it contains NUL bytes."
      return 1
    }
  base_bytes=$(git cat-file -s "$base_blob" 2>/dev/null) \
    || {
      fm_lint_agentsmd_error "could not count target base $base calibrated bytes."
      return 1
    }
  case "$base_bytes" in
    ''|*[!0-9]*)
      fm_lint_agentsmd_error "target base $base has an invalid AGENTS.md byte count."
      return 1
      ;;
  esac

  if [ "$current_blob" = "$base_blob" ]; then
    printf 'fm-lint.sh: AGENTS.md %s calibrated bytes (ceiling %s)\n' \
      "$bytes" "$AGENTS_CALIBRATED_BYTE_CEILING"
    return 0
  fi
  fm_lint_agentsmd_base_history_complete "$base" \
    || {
      fm_lint_agentsmd_error "target base $base has shallow or incomplete ancestry; fetch the full target history."
      return 1
    }
  diff_rc=0
  git diff --quiet "$base" -- AGENTS.md >/dev/null 2>&1 || diff_rc=$?
  [ "$diff_rc" -eq 1 ] || {
    fm_lint_agentsmd_error 'could not compare final AGENTS.md content with the target base.'
    return 1
  }
  fm_lint_agentsmd_validate_added_lines "$base_blob" || return 1

  if [ "$bytes" -gt "$base_bytes" ]; then
    target_blob=$current_blob
    fm_lint_agentsmd_validate_override \
      "$base" "$base_blob" "$target_blob" "$base_bytes" "$bytes" || return 1
  fi
  printf 'fm-lint.sh: AGENTS.md %s calibrated bytes (base %s; ceiling %s)\n' \
    "$bytes" "$base_bytes" "$AGENTS_CALIBRATED_BYTE_CEILING"
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
LIST_FILES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prefers origin/main, falls back to main, and returns
# 1 when neither target exists.
fm_lint_changed_base_ref() {
  local remote_oid='' local_oid=''
  remote_oid=$(git rev-parse --verify -q 'origin/main^{commit}' 2>/dev/null) || remote_oid=
  local_oid=$(git rev-parse --verify -q 'main^{commit}' 2>/dev/null) || local_oid=
  if [ -n "$remote_oid" ]; then
    printf 'origin/main\n'
    return 0
  fi
  if [ -n "$local_oid" ]; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' ${ROOTS[@]+"${ROOTS[@]}"}
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_agentsmd_budget || overall_rc=$?
  if [ "$overall_rc" -eq 0 ]; then
    fm_lint_run_workflows || overall_rc=$?
  else
    fm_lint_run_workflows || true
  fi
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

index=1
: > "$WEIGHTS"
for path in ${ROOTS[@]+"${ROOTS[@]}"}; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
  if [ -f "$path" ]; then
    weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  else
    weight=1
  fi
  case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
  printf '%s\t%s\t%s\n' "$weight" "$index" "$path" >> "$WEIGHTS"
  index=$((index + 1))
done

# Largest-first deterministic greedy assignment keeps the two bounded workers
# balanced without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# Replay both stable shards in deterministic order and select the first nonzero
# shard status. ShellCheck processes every root in a shard after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' ${ROOTS[@]+"${ROOTS[@]}"} 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in ${ROOTS[@]+"${ROOTS[@]}"}; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_followed=$((source_directives - source_boundaries))
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_agentsmd_budget || overall_rc=$?
else
  fm_lint_run_agentsmd_budget || true
fi
if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
