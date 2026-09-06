#!/usr/bin/env bash
# fm-record.sh - the single owner of the Record transaction.
#
# One command prepares the live-state mirror, settles candidate bytes, scans
# them, commits one Git snapshot at $FM_HOME/data, and (tick only) attempts one
# bounded push. Session, stow, completion, and teardown call checkpoint.
# Only tick pushes. The deadman stays a read-only probe.
#
# Usage:
#   fm-record.sh tick
#   fm-record.sh checkpoint --reason session-start|stow|complete|teardown [--required]
#   fm-record.sh health
#   fm-record.sh setup [--init] [--origin URL] [--branch NAME] [--code-root PATH]
#                    [--write-plist] [--bootstrap]
#   fm-record.sh pre-commit [--candidate-index PATH]
#
# An unconfigured home (no $FM_HOME/data/.git) is an explicit disabled no-op.
# After .git exists, a missing scanner, wrong root, extra remote, detached
# HEAD, merge state, missing hook, or missing local LFS setup is a
# configuration-error refusal, not a disabled success.
#
# Exit codes:
#   0  disabled, unchanged, committed-local, or pushed
#   2  usage
#   3  busy (another transaction holds the Record lock)
#   4  unsettled (candidate changed during the settle window)
#   5  scan-blocked
#   6  push-pending (local commit kept)
#   7  diverged (non-fast-forward; no force or rebase)
#   8  configuration-error
#   9  required checkpoint could not obtain a durable local commit
#
# The local lock is $FM_HOME/data/.git/firstmate-record.lock and uses the
# shared process-owned lock owner. Tick is non-blocking. Checkpoint waits
# FM_RECORD_LOCK_WAIT_SECONDS (default 10). The settle window is
# FM_RECORD_SETTLE_SECONDS (default 2). Tick push uses the shared timeout
# owner with FM_RECORD_PUSH_TIMEOUT (default 15) and GIT_TERMINAL_PROMPT=0.
# Health lives under .git/record-health and is not tracked.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

EXPECTED_BRANCH=${FM_RECORD_BRANCH:-main}
SETTLE_SECONDS=${FM_RECORD_SETTLE_SECONDS:-2}
LOCK_WAIT_SECONDS=${FM_RECORD_LOCK_WAIT_SECONDS:-10}
PUSH_TIMEOUT=${FM_RECORD_PUSH_TIMEOUT:-15}
TEXT_LFS_BYTES=1048576

LOCK_LIBS_LOADED=0

require_lock_libs() {
  [ "$LOCK_LIBS_LOADED" -eq 0 ] || return 0
  export FM_HOME
  export FM_STATE_OVERRIDE="$STATE"
  export FM_ROOT_OVERRIDE="$FM_ROOT"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  LOCK_LIBS_LOADED=1
}

LOCK_PATH=
LOCK_HELD=0
HASH_TOOL=
GIT_DIR_ABS=
RECORD_WORK=
CAND_WORK=
CAND_INDEX=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() { # <code> <message>
  local code=$1
  shift
  printf 'fm-record: %s\n' "$*" >&2
  exit "$code"
}

emit() { # <state> [k=v...]
  local state=$1
  shift
  printf 'fm-record: state=%s' "$state"
  if [ "$#" -gt 0 ]; then
    printf ' %s' "$*"
  fi
  printf '\n'
}

finish() { # <code> <state> [k=v...]
  local code=$1 state=$2
  shift 2
  write_health "$state" "$@"
  emit "$state" "$@"
  exit "$code"
}

require_hash_tool() {
  if command -v shasum >/dev/null 2>&1; then
    HASH_TOOL=shasum
  elif command -v sha256sum >/dev/null 2>&1; then
    HASH_TOOL=sha256sum
  else
    die 8 "no sha256 tool; install shasum or sha256sum"
  fi
}

sha256_file() {
  local out
  if [ "$HASH_TOOL" = shasum ]; then
    out=$(shasum -a 256 -- "$1") || return 1
  else
    out=$(sha256sum -- "$1") || return 1
  fi
  printf '%s\n' "${out%% *}"
}

physical_dir() {
  cd -P -- "$1" && pwd -P
}

# shellcheck disable=SC2329 # Invoked from the EXIT trap.
release_lock() {
  if [ "$LOCK_HELD" -eq 1 ] && [ -n "$LOCK_PATH" ]; then
    fm_lock_release "$LOCK_PATH" || true
    LOCK_HELD=0
  fi
}

# shellcheck disable=SC2329 # Invoked from trap EXIT.
on_exit() {
  release_lock
  if [ -n "${CAND_WORK:-}" ] && [ -d "${CAND_WORK:-}" ]; then
    rm -rf "${CAND_WORK%/*}"
  fi
  if [ -n "${CAND_INDEX:-}" ]; then
    rm -f "$CAND_INDEX" "${CAND_INDEX}.lock"
  fi
}

trap on_exit EXIT

refuse_git_overrides() {
  local name
  for name in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; do
    if eval "[ \"\${${name}+x}\" = x ]"; then
      die 8 "Git environment override $name must be unset"
    fi
  done
}

write_health() { # <state> [k=v...]
  local state=$1 dest tmp kv
  shift
  [ -n "$GIT_DIR_ABS" ] && [ -d "$GIT_DIR_ABS" ] || return 0
  dest="$GIT_DIR_ABS/record-health"
  tmp="$dest.tmp.$$"
  {
    printf 'state=%s\n' "$state"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for kv in "$@"; do
      case "$kv" in
        *=*) printf '%s\n' "$kv" ;;
      esac
    done
  } > "$tmp"
  mv -f "$tmp" "$dest"
}

read_health_file() {
  local dest="$GIT_DIR_ABS/record-health"
  if [ -f "$dest" ]; then
    cat "$dest"
  fi
}

binding_state() {
  if [ ! -e "$DATA/.git" ]; then
    printf 'absent\n'
    return 0
  fi
  printf 'present\n'
}

validate_binding() {
  local toplevel physical_data physical_home physical_top origin_url remotes branch
  [ ! -L "$DATA" ] || die 8 "Record root $DATA must not be a symlink"
  [ -d "$DATA" ] || die 8 "Record root $DATA is not a directory"
  [ ! -L "$DATA/.git" ] || die 8 "$DATA/.git must not be a symlink"
  [ -d "$DATA/.git" ] || die 8 "$DATA/.git must be a directory"
  GIT_DIR_ABS=$(physical_dir "$DATA/.git") || die 8 "cannot resolve $DATA/.git"
  physical_data=$(physical_dir "$DATA") || die 8 "cannot resolve Record root"
  physical_home=$(physical_dir "$FM_HOME") || die 8 "cannot resolve FM_HOME"
  [ "$physical_data" = "$physical_home/data" ] \
    || die 8 "Record root must be exactly this home's data/ directory"
  RECORD_WORK=$physical_data
  toplevel=$(git --git-dir="$GIT_DIR_ABS" --work-tree="$physical_data" rev-parse --show-toplevel) \
    || die 8 "Record root is not a Git repository"
  physical_top=$(physical_dir "$toplevel") || die 8 "cannot resolve Git top level"
  [ "$physical_top" = "$physical_data" ] \
    || die 8 "Git top level $physical_top is not the Record root $physical_data"
  [ -f "$GIT_DIR_ABS/record-origin" ] || die 8 "Record origin binding is missing"
  [ -f "$GIT_DIR_ABS/record-branch" ] || die 8 "Record branch binding is missing"
  [ -f "$GIT_DIR_ABS/record-code-root" ] || die 8 "Record code-root binding is missing"
  origin_url=$(sed -n '1p' "$GIT_DIR_ABS/record-origin")
  [ -n "$origin_url" ] || die 8 "Record origin binding is empty"
  remotes=$(git --git-dir="$GIT_DIR_ABS" remote)
  [ "$remotes" = origin ] || die 8 "Record must have exactly one remote named origin"
  [ "$(git --git-dir="$GIT_DIR_ABS" remote get-url origin)" = "$origin_url" ] \
    || die 8 "origin URL does not match the Record binding"
  if [ -f "$GIT_DIR_ABS/MERGE_HEAD" ]; then
    die 8 "Record has an incomplete merge"
  fi
  branch=$(git --git-dir="$GIT_DIR_ABS" --work-tree="$physical_data" symbolic-ref -q --short HEAD) \
    || die 8 "Record HEAD is detached"
  [ "$branch" = "$(sed -n '1p' "$GIT_DIR_ABS/record-branch")" ] \
    || die 8 "Record branch is not the bound branch"
  command -v gitleaks >/dev/null 2>&1 || die 8 "gitleaks is missing"
  git lfs version >/dev/null 2>&1 || die 8 "Git LFS is missing"
  git --git-dir="$GIT_DIR_ABS" config --local --get filter.lfs.required >/dev/null 2>&1 \
    || die 8 "Git LFS is not configured locally for the Record"
  [ -x "$GIT_DIR_ABS/hooks/pre-commit" ] || die 8 "Record pre-commit hook is missing"
  grep -Fq 'firstmate-record-pre-commit' "$GIT_DIR_ABS/hooks/pre-commit" \
    || die 8 "Record pre-commit hook was replaced"
  [ -x "$GIT_DIR_ABS/hooks/pre-push" ] || die 8 "Record pre-push hook is missing"
  grep -Eq 'git-lfs|git lfs' "$GIT_DIR_ABS/hooks/pre-push" \
    || die 8 "Record pre-push hook is not the LFS hook"
}

acquire_record_lock() { # try|wait|required
  local mode=$1 rc=0
  require_lock_libs
  LOCK_PATH="$GIT_DIR_ABS/firstmate-record.lock"
  case "$mode" in
    try)
      if fm_lock_try_acquire "$LOCK_PATH"; then
        LOCK_HELD=1
        return 0
      fi
      return 3
      ;;
    wait | required)
      if fm_lock_try_acquire "$LOCK_PATH"; then
        LOCK_HELD=1
        return 0
      fi
      fm_lock_acquire_wait_bounded "$LOCK_PATH" "$LOCK_WAIT_SECONDS" || rc=$?
      if [ "$rc" -eq 0 ]; then
        LOCK_HELD=1
        return 0
      fi
      if [ "$mode" = required ]; then
        return 9
      fi
      return 3
      ;;
    *)
      die 2 "unknown lock mode $mode"
      ;;
  esac
}

is_ignored() { # <abs-path>
  local rel=$1
  case "$rel" in
    .git | .git/*) return 0 ;;
    .record-state | .record-state/*) return 0 ;;
    .obsidian/workspace.json | .obsidian/workspace-mobile.json | .DS_Store) return 0 ;;
    .record-tmp-* | */.record-tmp-*) return 0 ;;
  esac
  git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" check-ignore -q -- "$rel" 2>/dev/null
}

list_data_relpaths() {
  local path rel
  [ -d "$RECORD_WORK" ] || return 0
  while IFS= read -r -d '' path; do
    rel=${path#"$RECORD_WORK"/}
    [ "$rel" != "$path" ] || continue
    case "$rel" in
      .git | .git/*) continue ;;
      .record-state | .record-state/*) continue ;;
    esac
    if is_ignored "$rel"; then
      continue
    fi
    printf '%s\n' "$rel"
  done < <(find "$RECORD_WORK" \( -name .git -type d -prune \) -o \( -print0 \))
}

list_state_sources() {
  local path base
  [ -d "$STATE" ] || return 0
  for path in "$STATE"/*.status "$STATE"/*.meta; do
    [ -e "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die 8 "state source $path must be a regular file"
    printf '%s\n' "$path"
  done
  for path in "$STATE"/*.inbox; do
    [ -e "$path" ] || continue
    [ -d "$path" ] && [ ! -L "$path" ] || die 8 "state inbox $path must be a directory"
    while IFS= read -r -d '' base; do
      printf '%s\n' "$base"
    done < <(find "$path" \( -type f -o -type l \) -print0)
  done
}

path_mode() {
  if stat -f %Lp "$1" >/dev/null 2>&1; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

inventory_line() { # <kind> <abs> <rel>
  local kind=$1 abs=$2 rel=$3 mode digest target
  if [ -L "$abs" ]; then
    target=$(readlink "$abs") || return 1
    mode=$(path_mode "$abs") || return 1
    printf 'l\t%s\t-\t%s\t%s\n' "$mode" "$target" "$rel"
    return 0
  fi
  if [ -f "$abs" ]; then
    [ ! -p "$abs" ] || die 8 "special file is not a Record candidate: $rel"
    mode=$(path_mode "$abs") || return 1
    digest=$(sha256_file "$abs") || return 1
    printf 'f\t%s\t%s\t-\t%s\n' "$mode" "$digest" "$rel"
    return 0
  fi
  if [ -d "$abs" ]; then
    return 0
  fi
  die 8 "unsupported file type for $rel"
}

build_inventory() { # <outfile>
  local out=$1 rel abs path
  : > "$out"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    abs="$RECORD_WORK/$rel"
    if [ -L "$abs" ]; then
      validate_symlink "$abs" "$rel"
    fi
    inventory_line data "$abs" "data:$rel" >> "$out" || die 4 "cannot inventory $rel"
  done < <(list_data_relpaths | LC_ALL=C sort)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rel=${path#"$STATE"/}
    inventory_line state "$path" "state:$rel" >> "$out" || die 4 "cannot inventory state $rel"
  done < <(list_state_sources | LC_ALL=C sort)
}

validate_symlink() { # <abs> <rel>
  local abs=$1 rel=$2 target resolved
  target=$(readlink "$abs") || die 8 "cannot read symlink $rel"
  case "$target" in
    /*) die 8 "absolute symlink is not portable: $rel" ;;
  esac
  [ -e "$abs" ] || die 8 "broken symlink: $rel"
  resolved=$(cd "$(dirname "$abs")" && cd -P -- "$(dirname "$target")" && pwd -P) \
    || die 8 "symlink $rel resolves outside the Record"
  case "$resolved" in
    "$RECORD_WORK" | "$RECORD_WORK"/*) ;;
    *) die 8 "symlink $rel resolves outside the Record" ;;
  esac
}

settle_inventory() {
  local first second
  first=$(mktemp "${TMPDIR:-/tmp}/fm-record-inv1.XXXXXX")
  second=$(mktemp "${TMPDIR:-/tmp}/fm-record-inv2.XXXXXX")
  build_inventory "$first" || { rm -f "$first" "$second"; return 4; }
  if [ "$SETTLE_SECONDS" -gt 0 ]; then
    sleep "$SETTLE_SECONDS"
  fi
  build_inventory "$second" || { rm -f "$first" "$second"; return 4; }
  if ! cmp -s "$first" "$second"; then
    rm -f "$first" "$second"
    return 4
  fi
  mv -f "$second" "$1"
  rm -f "$first"
  return 0
}

copy_file_atomic() { # <src> <dest>
  local src=$1 dest=$2 tmp dir
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  tmp="$dir/.record-tmp-$$.${dest##*/}"
  if [ -L "$src" ]; then
    rm -f "$dest"
    ln -s -- "$(readlink "$src")" "$dest"
    rm -f "$tmp"
    return 0
  fi
  cp -p -- "$src" "$tmp"
  mv -f "$tmp" "$dest"
}

freeze_candidate() { # <inventory>
  local inv=$1 kind mode digest target rel abs dest
  CAND_WORK="$GIT_DIR_ABS/record-candidate/work"
  rm -rf "$GIT_DIR_ABS/record-candidate"
  mkdir -p "$CAND_WORK/.record-state"
  while IFS=$(printf '\t') read -r kind mode digest target rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      data:*)
        abs="$RECORD_WORK/${rel#data:}"
        dest="$CAND_WORK/${rel#data:}"
        ;;
      state:*)
        abs="$STATE/${rel#state:}"
        dest="$CAND_WORK/.record-state/${rel#state:}"
        ;;
      *)
        continue
        ;;
    esac
    copy_file_atomic "$abs" "$dest"
    if [ "$kind" = f ] && [ -n "$mode" ]; then
      chmod "$mode" "$dest" 2>/dev/null || true
    fi
  done < "$inv"
}

attr_escape() {
  python3 -c 'import sys
p=sys.argv[1]
if any(ch in p for ch in " \t[]*?") or p[:1] in "-#":
    print("\"" + p.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")
else:
    print(p)' "$1"
}

binary_attr_lines() {
  local ext
  for ext in jpg jpeg png gif webp pdf zip gz tar mp3 mp4 mov wav webm m4a ogg avi mkv m4v \
    JPG JPEG PNG GIF WEBP PDF ZIP GZ TAR MP3 MP4 MOV WAV WEBM M4A OGG AVI MKV M4V; do
    printf '*.%s filter=lfs diff=lfs merge=lfs -text\n' "$ext"
  done
}

existing_literal_lfs_paths() {
  local file=$1 line path
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      \"*\"\ filter=lfs*)
        path=${line#\"}
        path=${path%%\"*}
        printf '%s\n' "$path"
        ;;
      *' filter=lfs diff=lfs merge=lfs -text')
        path=${line%% filter=lfs*}
        case "$path" in
          \** | '') ;;
          *) printf '%s\n' "$path" ;;
        esac
        ;;
    esac
  done < "$file"
}

update_lfs_attributes() {
  local attr="$CAND_WORK/.gitattributes" existing tmp rel size ext
  existing=$(mktemp "${TMPDIR:-/tmp}/fm-record-lfs.XXXXXX")
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-record-attr.XXXXXX")
  existing_literal_lfs_paths "$RECORD_WORK/.gitattributes" > "$existing"
  existing_literal_lfs_paths "$attr" >> "$existing"
  binary_attr_lines > "$tmp"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$CAND_WORK/$rel" ] || continue
    ext=${rel##*.}
    case "$ext" in
      csv | json | txt | vtt | CSV | JSON | TXT | VTT) ;;
      *) continue ;;
    esac
    size=$(LC_ALL=C wc -c < "$CAND_WORK/$rel" | tr -d ' ')
    if [ "$size" -ge "$TEXT_LFS_BYTES" ]; then
      printf '%s\n' "$rel" >> "$existing"
    fi
  done < <(find "$CAND_WORK" \( -name .git -type d -prune \) -o -type f -print | sed "s|^$CAND_WORK/||")
  LC_ALL=C sort -u "$existing" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '%s filter=lfs diff=lfs merge=lfs -text\n' "$(attr_escape "$rel")"
  done >> "$tmp"
  mv -f "$tmp" "$attr"
  rm -f "$existing"
}

stage_candidate() {
  CAND_INDEX="$GIT_DIR_ABS/record-candidate.index"
  rm -f "$CAND_INDEX"
  GIT_INDEX_FILE="$CAND_INDEX" git --git-dir="$GIT_DIR_ABS" --work-tree="$CAND_WORK" add -A
}

scan_candidate() {
  local rc=0
  "$SCRIPT_DIR/fm-record-scan.sh" chain --dir "$CAND_WORK" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) return 5 ;;
    *) return 5 ;;
  esac
}

trees_equal() {
  local head cand
  head=$(git --git-dir="$GIT_DIR_ABS" rev-parse 'HEAD^{tree}' 2>/dev/null || true)
  cand=$(GIT_INDEX_FILE="$CAND_INDEX" git --git-dir="$GIT_DIR_ABS" write-tree)
  [ -n "$head" ] && [ "$head" = "$cand" ]
}

real_index_is_clean() {
  git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" diff --cached --quiet
}

commit_candidate() { # <reason>
  local reason=$1 branch expected message
  expected=$(sed -n '1p' "$GIT_DIR_ABS/record-branch")
  branch=$(git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" symbolic-ref -q --short HEAD) \
    || die 8 "Record HEAD changed during the transaction"
  [ "$branch" = "$expected" ] || die 8 "Record branch changed during the transaction"
  real_index_is_clean || die 8 "unexpected user staging is present; refusing to overwrite the index"
  if trees_equal; then
    return 1
  fi
  message="record: ${reason}"
  GIT_INDEX_FILE="$CAND_INDEX" git --git-dir="$GIT_DIR_ABS" --work-tree="$CAND_WORK" \
    commit --quiet --no-verify -m "$message"
  git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" read-tree HEAD
  publish_owned_live_files
  return 0
}

publish_owned_live_files() {
  local src dest rel
  src="$CAND_WORK/.record-state"
  dest="$RECORD_WORK/.record-state"
  mkdir -p "$dest"
  if [ -d "$src" ]; then
    while IFS= read -r -d '' rel; do
      copy_file_atomic "$rel" "$dest/${rel#"$src"/}"
    done < <(find "$src" \( -type f -o -type l \) -print0)
    while IFS= read -r -d '' rel; do
      [ -e "$src/${rel#"$dest"/}" ] || rm -f "$rel"
    done < <(find "$dest" \( -type f -o -type l \) -print0)
  fi
  if [ -f "$CAND_WORK/.gitattributes" ]; then
    copy_file_atomic "$CAND_WORK/.gitattributes" "$RECORD_WORK/.gitattributes"
  fi
}

push_once() {
  local rc=0 out
  require_lock_libs
  set +e
  out=$(GIT_TERMINAL_PROMPT=0 fm_run_timed "$PUSH_TIMEOUT" \
    git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" \
    -c credential.helper= push --quiet origin "HEAD:$(sed -n '1p' "$GIT_DIR_ABS/record-branch")" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    printf 'timeout\n'
    return 6
  fi
  case "$out" in
    *'non-fast-forward'* | *'failed to push some refs'* | *'[rejected]'*)
      printf 'diverged\n'
      return 7
      ;;
    *'Authentication'* | *'authentication'* | *'Permission denied'* | *'403'* | *'401'*)
      printf 'auth\n'
      return 6
      ;;
    *'LFS'* | *'lfs'*)
      printf 'lfs\n'
      return 6
      ;;
    *)
      printf 'offline\n'
      return 6
      ;;
  esac
}

pending_commit_count() {
  git --git-dir="$GIT_DIR_ABS" rev-list --count "origin/$(sed -n '1p' "$GIT_DIR_ABS/record-branch")..HEAD" 2>/dev/null || printf '0\n'
}

run_transaction() { # tick|checkpoint <reason> try|wait|required
  local mode=$1 reason=$2 lock_mode=$3 inv rc=0 sha pending class
  case "$(binding_state)" in
    absent)
      emit disabled
      exit 0
      ;;
  esac
  require_hash_tool
  validate_binding
  acquire_record_lock "$lock_mode" || rc=$?
  case "$rc" in
    0) ;;
    3) finish 3 busy ;;
    9) finish 9 configuration-error detail=required-lock-timeout ;;
    *) finish 8 configuration-error detail=lock ;;
  esac
  inv=$(mktemp "${TMPDIR:-/tmp}/fm-record-inv.XXXXXX")
  rc=0
  settle_inventory "$inv" || rc=$?
  if [ "$rc" -eq 4 ]; then
    rm -f "$inv"
    finish 4 unsettled
  fi
  freeze_candidate "$inv"
  update_lfs_attributes
  stage_candidate
  rc=0
  scan_candidate || rc=$?
  if [ "$rc" -eq 5 ]; then
    rm -f "$inv"
    finish 5 scan-blocked
  fi
  rc=0
  commit_candidate "$reason" || rc=$?
  sha=$(git --git-dir="$GIT_DIR_ABS" rev-parse --short HEAD)
  if [ "$mode" != tick ]; then
    rm -f "$inv"
    if [ "$rc" -eq 1 ]; then
      finish 0 unchanged commit="$sha"
    fi
    finish 0 committed-local commit="$sha"
  fi
  if [ "$rc" -eq 1 ]; then
    pending=$(pending_commit_count)
    if [ "$pending" = 0 ]; then
      rm -f "$inv"
      finish 0 unchanged commit="$sha"
    fi
  fi
  class=
  rc=0
  class=$(push_once) || rc=$?
  pending=$(pending_commit_count)
  rm -f "$inv"
  case "$rc" in
    0) finish 0 pushed commit="$sha" ;;
    7) finish 7 diverged commit="$sha" ;;
    6) finish 6 push-pending commit="$sha" class="${class:-offline}" pending="$pending" ;;
    *) finish 6 push-pending commit="$sha" class=offline pending="$pending" ;;
  esac
}

cmd_health() {
  case "$(binding_state)" in
    absent)
      emit disabled
      exit 0
      ;;
  esac
  validate_binding
  if [ -f "$GIT_DIR_ABS/record-health" ]; then
    state=$(sed -n 's/^state=//p' "$GIT_DIR_ABS/record-health" | head -1)
    emit "${state:-unchanged}"
    read_health_file
  else
    emit unchanged
  fi
  exit 0
}

write_gitignore() {
  cat > "$1" <<'EOF'
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.DS_Store
.record-tmp-*
search-anomaly-signal/.serpapi.env
**/.env
EOF
}

install_hooks() {
  local hook_dir=$1 code_root=$2
  mkdir -p "$hook_dir"
  cat > "$hook_dir/pre-commit" <<EOF
#!/bin/sh
# firstmate-record-pre-commit
exec $(printf '%q' "$code_root/bin/fm-record.sh") pre-commit
EOF
  chmod 755 "$hook_dir/pre-commit"
}

cmd_setup() {
  local init=0 write_plist=0 bootstrap=0 origin='' branch=$EXPECTED_BRANCH code_root=$FM_ROOT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --init) init=1; shift ;;
      --write-plist) write_plist=1; shift ;;
      --bootstrap) bootstrap=1; shift ;;
      --origin) origin=$2; shift 2 ;;
      --branch) branch=$2; shift 2 ;;
      --code-root) code_root=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die 2 "unknown setup argument '$1'" ;;
    esac
  done
  refuse_git_overrides
  [ -d "$DATA" ] || mkdir -p "$DATA"
  if [ "$init" -eq 1 ]; then
    [ -n "$origin" ] || die 2 "setup --init requires --origin"
    if [ -e "$DATA/.git" ]; then
      die 8 "setup --init refuses to replace an existing Record repository"
    fi
    git init --quiet -b "$branch" "$DATA"
    git --git-dir="$DATA/.git" remote add origin "$origin"
  fi
  case "$(binding_state)" in
    absent) die 8 "Record repository is missing; pass --init to create a scratch Record" ;;
  esac
  GIT_DIR_ABS=$(physical_dir "$DATA/.git")
  RECORD_WORK=$(physical_dir "$DATA")
  printf '%s\n' "${origin:-$(git --git-dir="$GIT_DIR_ABS" remote get-url origin)}" > "$GIT_DIR_ABS/record-origin"
  printf '%s\n' "$branch" > "$GIT_DIR_ABS/record-branch"
  printf '%s\n' "$(physical_dir "$code_root")" > "$GIT_DIR_ABS/record-code-root"
  write_gitignore "$RECORD_WORK/.gitignore"
  binary_attr_lines > "$RECORD_WORK/.gitattributes"
  git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" lfs install --local --force >/dev/null
  install_hooks "$GIT_DIR_ABS/hooks" "$(physical_dir "$code_root")"
  if [ "$write_plist" -eq 1 ]; then
    write_record_plist "$(physical_dir "$code_root")"
  fi
  if [ "$bootstrap" -eq 1 ]; then
    bootstrap_record_job
  fi
  emit unchanged detail=setup
  exit 0
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\\&apos;/g"
}

sed_replacement() {
  sed -e 's/[\\&|]/\\&/g'
}

write_record_plist() {
  local code_root=$1 template script stdout_log stderr_log path_value home_value tmp plist logdir
  template="$SCRIPT_DIR/launchd/com.firstmate.record-tick.plist.template"
  plist=${FM_RECORD_PLIST:-$HOME/Library/LaunchAgents/com.firstmate.record-tick.plist}
  logdir=${FM_RECORD_LOG_DIR:-$HOME/Library/Logs}
  if [ -f "$plist" ] && ! grep -Fq 'firstmate-record-tick-v1' "$plist"; then
    die 8 "existing LaunchAgent at $plist is not the Record job; leaving it untouched"
  fi
  mkdir -p "$(dirname "$plist")" "$logdir"
  script=$(printf '%s' "$code_root/bin/fm-record.sh" | xml_escape | sed_replacement)
  stdout_log=$(printf '%s' "$logdir/firstmate-record-tick.stdout.log" | xml_escape | sed_replacement)
  stderr_log=$(printf '%s' "$logdir/firstmate-record-tick.stderr.log" | xml_escape | sed_replacement)
  path_value=$(printf '%s' "${PATH-}" | xml_escape | sed_replacement)
  home_value=$(printf '%s' "$(physical_dir "$FM_HOME")" | xml_escape | sed_replacement)
  tmp="$plist.tmp.$$"
  sed -e "s|__RECORD_SCRIPT__|$script|g" \
    -e "s|__STDOUT_LOG__|$stdout_log|g" \
    -e "s|__STDERR_LOG__|$stderr_log|g" \
    -e "s|__PATH__|$path_value|g" \
    -e "s|__FM_HOME__|$home_value|g" "$template" > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$plist"
}

bootstrap_record_job() {
  local plist=${FM_RECORD_PLIST:-$HOME/Library/LaunchAgents/com.firstmate.record-tick.plist}
  [ -f "$plist" ] || die 8 "Record LaunchAgent plist is missing; pass --write-plist"
  grep -Fq 'firstmate-record-tick-v1' "$plist" || die 8 "Record LaunchAgent plist is not owned by setup"
  launchctl bootout "gui/$UID/com.firstmate.record-tick" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$plist"
}

extract_index_payloads() { # <index> <dest-dir>
  local index=$1 dest=$2 sha path meta oid payload oid_dir
  mkdir -p "$dest"
  while IFS=$(printf '\t') read -r -d '' meta path; do
    [ -n "$path" ] || continue
    sha=$(printf '%s\n' "$meta" | awk '{print $2}')
    [ -n "$sha" ] || continue
    payload="$dest/$path"
    mkdir -p "$(dirname "$payload")"
    GIT_INDEX_FILE="$index" git --git-dir="$GIT_DIR_ABS" cat-file -p "$sha" > "$payload"
    if head -n 1 "$payload" | grep -Fq 'git-lfs.github.com/spec/v1'; then
      oid=$(awk '/^oid sha256:/ { print $2 }' "$payload")
      oid=${oid#sha256:}
      oid_dir="$GIT_DIR_ABS/lfs/objects/$(printf '%s' "$oid" | cut -c1-2)/$(printf '%s' "$oid" | cut -c3-4)"
      if [ -n "$oid" ] && [ -f "$oid_dir/$oid" ]; then
        cp -p "$oid_dir/$oid" "$payload"
      fi
    fi
  done < <(GIT_INDEX_FILE="$index" git --git-dir="$GIT_DIR_ABS" ls-files -s -z)
}

cmd_pre_commit() {
  local candidate='' dest rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --candidate-index)
        candidate=$2
        shift 2
        ;;
      *) die 2 "unknown pre-commit argument '$1'" ;;
    esac
  done
  if [ -n "$candidate" ]; then
    [ "${FM_RECORD_INTERNAL:-}" = 1 ] || die 8 "candidate index is only accepted from an internal Record call"
    GIT_DIR_ABS=${GIT_DIR:-$DATA/.git}
    [ -d "$GIT_DIR_ABS" ] || die 8 "pre-commit candidate has no git dir"
    dest=$(mktemp -d "${TMPDIR:-/tmp}/fm-record-precommit.XXXXXX")
    extract_index_payloads "$candidate" "$dest"
    "$SCRIPT_DIR/fm-record-scan.sh" chain --dir "$dest" || rc=$?
    rm -rf "$dest"
    case "$rc" in
      0) exit 0 ;;
      *) exit 5 ;;
    esac
  fi
  GIT_DIR_ABS=${GIT_DIR:-$DATA/.git}
  [ -d "$GIT_DIR_ABS" ] || die 8 "pre-commit has no git dir"
  dest=$(mktemp -d "${TMPDIR:-/tmp}/fm-record-precommit.XXXXXX")
  extract_index_payloads "${GIT_INDEX_FILE:-$GIT_DIR_ABS/index}" "$dest"
  "$SCRIPT_DIR/fm-record-scan.sh" chain --dir "$dest" || rc=$?
  rm -rf "$dest"
  case "$rc" in
    0) exit 0 ;;
    *)
      printf 'fm-record: state=scan-blocked\n' >&2
      exit 1
      ;;
  esac
}

cmd_tick() {
  case "$(binding_state)" in
    absent)
      emit disabled
      exit 0
      ;;
  esac
  refuse_git_overrides
  run_transaction tick tick try
}

cmd_checkpoint() {
  local reason='' required=0 lock_mode=wait
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason)
        reason=$2
        shift 2
        ;;
      --required)
        required=1
        shift
        ;;
      *) die 2 "unknown checkpoint argument '$1'" ;;
    esac
  done
  case "$reason" in
    session-start | stow | complete | teardown) ;;
    *) die 2 "checkpoint --reason must be session-start, stow, complete, or teardown" ;;
  esac
  case "$(binding_state)" in
    absent)
      emit disabled
      exit 0
      ;;
  esac
  refuse_git_overrides
  [ "$required" -eq 0 ] || lock_mode=required
  run_transaction checkpoint "$reason" "$lock_mode"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  tick)
    shift
    cmd_tick "$@"
    ;;
  checkpoint)
    shift
    cmd_checkpoint "$@"
    ;;
  health | status)
    shift
    case "$(binding_state)" in
      absent)
        emit disabled
        exit 0
        ;;
    esac
    refuse_git_overrides
    cmd_health "$@"
    ;;
  setup)
    shift
    cmd_setup "$@"
    ;;
  pre-commit)
    shift
    cmd_pre_commit "$@"
    ;;
  '')
    usage
    exit 2
    ;;
  *)
    die 2 "unknown argument '$1'; run --help"
    ;;
esac
