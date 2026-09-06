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
#   fm-record.sh pre-commit
#
# Setup records activation in $FM_HOME/.record-enabled. A home with neither
# this marker nor data/.git is an explicit disabled no-op. After activation, a missing scanner, wrong root, extra remote, detached
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
INDEX_LOCK_HELD=0
HASH_TOOL=
GIT_DIR_ABS=
RECORD_WORK=
CAND_WORK=
CAND_INDEX=
HEALTH_TMP=
START_HEAD=
CAPTURED_HEAD=
PUSH_HEAD=

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
  if [ -f "$GIT_DIR_ABS/record-health" ]; then
    sed -n '/^delivery=/p; /^last_push_at=/p; /^pending=/p; /^failure_class=/p; /^pending_since=/p; /^pending_age_seconds=/p' "$GIT_DIR_ABS/record-health"
  fi
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
    out=$(shasum -a 256 -- "$1" 2>/dev/null) || return 1
  else
    out=$(sha256sum -- "$1" 2>/dev/null) || return 1
  fi
  printf '%s\n' "${out%% *}"
}

physical_dir() {
  cd -P -- "$1" 2>/dev/null && pwd -P
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
  if [ "$INDEX_LOCK_HELD" -eq 1 ] && [ -d "$GIT_DIR_ABS/record-publication" ] &&
    { [ ! -f "$GIT_DIR_ABS/record-publication/before" ] || [ ! -f "$GIT_DIR_ABS/record-publication/lock-id" ]; }; then
    rm -rf "$GIT_DIR_ABS/record-publication"
  fi
  if [ -n "$HEALTH_TMP" ]; then
    rm -f "$HEALTH_TMP"
  fi
  if [ "$INDEX_LOCK_HELD" -eq 1 ]; then
    rm -f "$GIT_DIR_ABS/index.lock"
  fi
  if [ -n "${CAND_WORK:-}" ] && [ -d "${CAND_WORK%/*}" ]; then
    rm -rf "${CAND_WORK%/*}"
  fi
  if [ -n "${CAND_INDEX:-}" ]; then
    rm -f "$CAND_INDEX" "${CAND_INDEX}.lock"
  fi
  release_lock
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
  local state=$1 dest tmp
  shift
  [ -n "$GIT_DIR_ABS" ] && [ -d "$GIT_DIR_ABS" ] || return 0
  dest="$GIT_DIR_ABS/record-health"
  tmp="$dest.tmp.$$"
  HEALTH_TMP=$tmp
  python3 - "$dest" "$state" "$(pending_commit_count)" "$@" > "$tmp" <<'PYHEALTH' || return 1
import datetime, pathlib, sys, time
path, state, pending = sys.argv[1:4]
old = {}
if pathlib.Path(path).is_file():
    old = dict(line.split("=", 1) for line in pathlib.Path(path).read_text().splitlines() if "=" in line)
now = int(time.time())
values = dict(arg.split("=", 1) for arg in sys.argv[4:])
values.update(state=state, updated_at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), pending=pending)
for key in ("last_push_at", "delivery", "failure_class", "pending_since"):
    if key in old:
        values[key] = old[key]
if state == "pushed":
    values.update(last_push_at=values["updated_at"], delivery="pushed", failure_class="none", pending_since="0")
elif state in ("push-pending", "diverged"):
    values.update(delivery=state, failure_class=values.get("class", "diverged" if state == "diverged" else "offline"))
if int(pending) > 0:
    if values.get("pending_since", "0") == "0":
        values["pending_since"] = str(now)
    if values.get("delivery") not in ("push-pending", "diverged"):
        values["delivery"] = "pending"
else:
    values["pending_since"] = "0"
values["pending_age_seconds"] = str(max(0, now - int(values["pending_since"]))) if values["pending_since"] != "0" else "0"
for key, value in values.items():
    print(key + "=" + value)
PYHEALTH
  mv -f "$tmp" "$dest" || return 1
  HEALTH_TMP=
}

read_health_file() {
  local dest="$GIT_DIR_ABS/record-health"
  if [ -f "$dest" ]; then
    cat "$dest"
  fi
}

binding_state() {
  if [ ! -e "$DATA/.git" ] && [ ! -L "$DATA/.git" ] &&
    [ ! -e "$FM_HOME/.record-enabled" ] && [ ! -L "$FM_HOME/.record-enabled" ]; then
    printf 'absent\n'
    return 0
  fi
  printf 'present\n'
}

validate_lfs_destinations() {
  local source rc routing_keys config_args=(--includes)
  routing_keys='^(lfs\.(url|pushurl|gitprotocol|remote\.(autodetect|searchall)|standalonetransferagent|customtransfer\..*|transfer\.enablehrefrewrite)|remote\.(lfsdefault|lfspushdefault|.*\.(lfsurl|lfspushurl)))$'
  for source in git lfsconfig; do
    if [ "$source" = lfsconfig ]; then
      if [ -e "$RECORD_WORK/.lfsconfig" ] || [ -L "$RECORD_WORK/.lfsconfig" ]; then
        config_args=(--file "$RECORD_WORK/.lfsconfig")
      elif git --git-dir="$GIT_DIR_ABS" cat-file -e :.lfsconfig 2>/dev/null; then
        config_args=(--blob :.lfsconfig)
      elif git --git-dir="$GIT_DIR_ABS" cat-file -e HEAD:.lfsconfig 2>/dev/null; then
        config_args=(--blob HEAD:.lfsconfig)
      else
        continue
      fi
    fi
    rc=0
    git --git-dir="$GIT_DIR_ABS" config "${config_args[@]}" --name-only --get-regexp "$routing_keys" \
      >/dev/null 2>&1 || rc=$?
    case "$rc" in
      1) ;;
      0) die 8 "LFS destination overrides are unsupported; use the bound origin" ;;
      *) die 8 "cannot validate the Record LFS destination" ;;
    esac
  done
}

validate_push_destinations() {
  local origin_url push_urls url
  origin_url=$(sed -n '1p' "$GIT_DIR_ABS/record-origin")
  push_urls=$(git --git-dir="$GIT_DIR_ABS" remote get-url --push --all origin) \
    || die 8 "cannot resolve the Record push destination"
  [ -n "$push_urls" ] || die 8 "Record push destination is empty"
  while IFS= read -r url; do
    [ "$url" = "$origin_url" ] || die 8 "push URL does not match the Record binding"
  done <<< "$push_urls"
  validate_lfs_destinations
}

validate_hook_path() {
  local hook_dir
  hook_dir=$(git -C "$RECORD_WORK" --git-dir="$GIT_DIR_ABS" rev-parse --path-format=absolute --git-path hooks) \
    || die 8 "cannot resolve the Record hook directory"
  [ "$hook_dir" = "$GIT_DIR_ABS/hooks" ] && [ ! -L "$hook_dir" ] \
    || die 8 "Record hooks must use the repository's .git/hooks directory"
}

validate_home_roots() {
  python3 - "$FM_HOME" "$DATA" "$STATE" <<'PYROOT' || die 8 "Record data and state roots must be exactly this home's directories"
import os, sys
home, data, state = map(os.path.realpath, sys.argv[1:])
if data != os.path.join(home, "data") or state != os.path.join(home, "state"):
    sys.exit(1)
if os.path.islink(sys.argv[2]) or os.path.islink(sys.argv[3]):
    sys.exit(1)
PYROOT
}

validate_private_git_dir() {
  python3 - "$GIT_DIR_ABS" <<'PYMODE' || die 8 "Record Git directory must allow access only to its owner"
import os, stat, sys
info = os.stat(sys.argv[1])
if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
    sys.exit(1)
PYMODE
}

validate_binding() {
  local toplevel physical_data physical_home physical_top origin_url remotes branch
  validate_home_roots
  require_hash_tool
  [ ! -L "$DATA" ] || die 8 "Record root must not be a symlink"
  [ -d "$DATA" ] || die 8 "Record root is not a directory"
  [ ! -L "$DATA/.git" ] || die 8 "Record Git directory must not be a symlink"
  [ -d "$DATA/.git" ] || die 8 "Record Git metadata must be a directory"
  GIT_DIR_ABS=$(physical_dir "$DATA/.git") || die 8 "cannot resolve the Record Git directory"
  validate_private_git_dir
  physical_data=$(physical_dir "$DATA") || die 8 "cannot resolve Record root"
  physical_home=$(physical_dir "$FM_HOME") || die 8 "cannot resolve FM_HOME"
  [ "$physical_data" = "$physical_home/data" ] \
    || die 8 "Record root must be exactly this home's data/ directory"
  RECORD_WORK=$physical_data
  toplevel=$(git --git-dir="$GIT_DIR_ABS" --work-tree="$physical_data" rev-parse --show-toplevel) \
    || die 8 "Record root is not a Git repository"
  physical_top=$(physical_dir "$toplevel") || die 8 "cannot resolve Git top level"
  [ "$physical_top" = "$physical_data" ] \
    || die 8 "Git top level is not the Record root"
  [ -f "$GIT_DIR_ABS/record-origin" ] || die 8 "Record origin binding is missing"
  [ -f "$GIT_DIR_ABS/record-branch" ] || die 8 "Record branch binding is missing"
  origin_url=$(sed -n '1p' "$GIT_DIR_ABS/record-origin")
  [ -n "$origin_url" ] || die 8 "Record origin binding is empty"
  remotes=$(git --git-dir="$GIT_DIR_ABS" remote)
  [ "$remotes" = origin ] || die 8 "Record must have exactly one remote named origin"
  [ "$(git --git-dir="$GIT_DIR_ABS" remote get-url origin)" = "$origin_url" ] \
    || die 8 "origin URL does not match the Record binding"
  validate_push_destinations
  validate_hook_path
  validate_setup_hooks
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

is_prohibited() {
  case "$1" in
    .git | .git/* | */.git | */.git/* | .obsidian/workspace*.json | .DS_Store | */.DS_Store | \
      .record-tmp-* | */.record-tmp-* | search-anomaly-signal/.serpapi.env | .env | */.env) return 0 ;;
  esac
  return 1
}

is_ignored() {
  case "$1" in .record-state | .record-state/*) return 0 ;; esac
  is_prohibited "$1"
}

validate_path_separators() {
  case "$1" in *$'\n'* | *$'\t'* | *$'\r'*) die 8 "Record path contains unsupported separators" ;; esac
}

list_data_relpaths() {
  local out=$1 path rel rc
  find "$RECORD_WORK" \( -name .git -type d -prune \) -o \( -print0 \) > "$out.raw" 2>/dev/null || return 1
  while IFS= read -r -d '' path; do
    rel=${path#"$RECORD_WORK"/}
    [ "$rel" != "$path" ] || continue
    validate_path_separators "$rel"
    rc=0
    is_ignored "$rel" || rc=$?
    case "$rc" in
      0) continue ;;
      1) ;;
      *) return 1 ;;
    esac
    printf '%s\n' "$rel" || return 1
  done < "$out.raw" > "$out"
}

list_state_sources() {
  local out=$1 path entry
  : > "$out" || return 1
  [ -d "$STATE" ] || return 0
  find "$STATE" -mindepth 1 -maxdepth 1 \( -name '*.status' -o -name '*.meta' -o -name '*.inbox' \) \
    -print0 > "$out.raw" 2>/dev/null || return 1
  while IFS= read -r -d '' path; do
    validate_path_separators "$path"
    case "$path" in
      *.inbox)
        [ -d "$path" ] && [ ! -L "$path" ] || return 1
        find "$path" \( -name .seq.lock -o -name '.seq.lock.*' -o -name .ring-state -o -name .escalated \
          -o -name '.staging.*' -o -name '.dedup.*' -o -name '.lock-probe.*' \) -prune -o \
          \( -type f -o -type l \) -print0 > "$out.inbox" 2>/dev/null || return 1
        while IFS= read -r -d '' entry; do
          validate_path_separators "$entry"
          printf '%s\n' "$entry" || return 1
        done < "$out.inbox"
        ;;
      *)
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
        printf '%s\n' "$path" || return 1
        ;;
    esac
  done < "$out.raw" > "$out"
}

path_mode() {
  if stat -f %Lp "$1" >/dev/null 2>&1; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

inventory_line() { # <kind> <abs> <rel>
  local kind=$1 abs=$2 rel=$3 mode digest target
  if [ -L "$abs" ]; then
    target=$(readlink "$abs" 2>/dev/null) || return 1
    validate_path_separators "$target"
    mode=$(path_mode "$abs") || return 1
    printf 'l\t%s\t-\t%s\t%s\n' "$mode" "$target" "$rel"
    return 0
  fi
  if [ -f "$abs" ]; then
    [ ! -p "$abs" ] || die 8 "special file is not a Record candidate"
    mode=$(path_mode "$abs") || return 1
    digest=$(sha256_file "$abs") || return 1
    printf 'f\t%s\t%s\t-\t%s\n' "$mode" "$digest" "$rel"
    return 0
  fi
  if [ -d "$abs" ]; then
    return 0
  fi
  die 8 "unsupported Record file type"
}

build_inventory() { # <outfile>
  local out=$1 rel abs path
  if ! list_data_relpaths "$out.data" || ! list_state_sources "$out.state" ||
    ! LC_ALL=C sort -o "$out.data" "$out.data" || ! LC_ALL=C sort -o "$out.state" "$out.state"; then
    return 4
  fi
  : > "$out" || return 4
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    abs="$RECORD_WORK/$rel"
    if [ -L "$abs" ]; then
      validate_symlink "$abs"
    fi
    inventory_line data "$abs" "data:$rel" >> "$out" || die 4 "cannot inventory Record content"
  done < "$out.data"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rel=${path#"$STATE"/}
    inventory_line state "$path" "state:$rel" >> "$out" || die 4 "cannot inventory state content"
  done < "$out.state"
}

validate_symlink() { # <abs>
  local abs=$1 target resolved
  target=$(readlink "$abs" 2>/dev/null) || die 8 "cannot read Record symlink"
  case "$target" in
    /*) die 8 "absolute symlink is not portable" ;;
  esac
  [ -e "$abs" ] || die 8 "broken Record symlink"
  resolved=$(cd "$(dirname "$abs")" && cd -P -- "$(dirname "$target")" && pwd -P) 2>/dev/null \
    || die 8 "symlink resolves outside the Record"
  case "$resolved" in
    "$RECORD_WORK" | "$RECORD_WORK"/*) ;;
    *) die 8 "symlink resolves outside the Record" ;;
  esac
}

build_metadata() {
  local out=$1
  list_data_relpaths "$out.data" && list_state_sources "$out.state" || return 4
  python3 - "$RECORD_WORK" "$STATE" "$out" 2>/dev/null <<'PYMETA' || return 4
import json, os, sys
root, state, out = sys.argv[1:]
result = {}
for scope, base in (("data", root), ("state", state)):
    with open(out + "." + scope) as paths:
        for line in paths:
            name = line.rstrip("\n")
            path = os.path.join(base, name)
            info = os.lstat(path)
            result[scope + ":" + os.path.relpath(path, base)] = [info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_ino, os.readlink(path) if os.path.islink(path) else None]
with open(out, "w") as output:
    json.dump(result, output, sort_keys=True)
PYMETA
}

save_clean_metadata() {
  python3 - "$CAND_WORK/../metadata" "$RECORD_WORK/.gitattributes" <<'PYMETA' || return 1
import json, os, sys
path, attr = sys.argv[1:]
with open(path) as source:
    values = json.load(source)
info = os.lstat(attr)
values["data:.gitattributes"] = [info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_ino, None]
with open(path, "w") as output:
    json.dump(values, output, sort_keys=True)
PYMETA
  mv -f "$CAND_WORK/../metadata" "$GIT_DIR_ABS/record-clean-metadata" || return 1
  printf '%s\n' "$CAPTURED_HEAD" > "$GIT_DIR_ABS/record-clean-head"
}

settle_inventory() {
  local first second
  first="$CAND_WORK/../inventory.first"
  second="$CAND_WORK/../inventory.second"
  build_inventory "$first" || return 4
  if [ "$SETTLE_SECONDS" -gt 0 ]; then
    sleep "$SETTLE_SECONDS"
  fi
  build_inventory "$second" || return 4
  if ! cmp -s "$first" "$second"; then
    return 4
  fi
  mv -f "$second" "$1"
  return 0
}

copy_file_atomic() { # <src> <dest>
  local src=$1 dest=$2 tmp dir target
  dir=$(dirname "$dest")
  mkdir -p "$dir" || return 1
  tmp="$dir/.record-tmp-$$.${dest##*/}"
  if [ -L "$src" ]; then
    target=$(readlink "$src") || return 1
    rm -f "$dest" || return 1
    ln -s -- "$target" "$dest" || return 1
    rm -f "$tmp" || return 1
    return 0
  fi
  if ! cp -p -- "$src" "$tmp" || ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
} 2>/dev/null

freeze_candidate() { # <inventory>
  local inv=$1 kind mode digest target rel abs dest actual expected
  mkdir -p "$CAND_WORK/.record-state" || return 4
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
    copy_file_atomic "$abs" "$dest" || return 4
    actual=$(inventory_line candidate "$dest" "$rel") || return 4
    expected=$(printf '%s\t%s\t%s\t%s\t%s' "$kind" "$mode" "$digest" "$target" "$rel")
    [ "$actual" = "$expected" ] || return 4
  done < "$inv"
}

attr_escape() {
  python3 -c 'import json, sys
p = sys.argv[1]
p = "".join("\\" + ch if ch in "\\[]*?" else ch for ch in p)
if p.startswith("!"):
    p = "\\" + p
print(json.dumps(p, ensure_ascii=False))' "$1"
}

binary_attr_lines() {
  local ext
  for ext in jpg jpeg png gif webp pdf zip gz tar mp3 mp4 mov wav webm m4a ogg avi mkv m4v \
    JPG JPEG PNG GIF WEBP PDF ZIP GZ TAR MP3 MP4 MOV WAV WEBM M4A OGG AVI MKV M4V; do
    printf '*.%s filter=lfs diff=lfs merge=lfs -text\n' "$ext"
  done
}

existing_literal_lfs_rules() {
  local file=$1 line committed='' current='' entry
  if git --git-dir="$GIT_DIR_ABS" rev-parse --verify HEAD >/dev/null 2>&1; then
    entry=$(git --git-dir="$GIT_DIR_ABS" ls-tree HEAD -- .gitattributes) || return 1
    if [ -n "$entry" ]; then
      committed=$(git --git-dir="$GIT_DIR_ABS" show HEAD:.gitattributes) || return 1
    fi
  fi
  if [ -f "$file" ]; then
    current=$(cat "$file") || return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      \** | '') ;;
      *' filter=lfs diff=lfs merge=lfs -text') printf '%s\n' "$line" || return 1 ;;
    esac
  done <<< "$committed"$'\n'"$current"
}

update_lfs_attributes() {
  local attr="$CAND_WORK/.gitattributes" tmp rel size ext path
  tmp="$CAND_WORK/../attributes"
  existing_literal_lfs_rules "$attr" > "$tmp" || return 1
  binary_attr_lines >> "$tmp" || return 1
  find "$CAND_WORK" \( -name .git -type d -prune \) -o -type f -print0 > "$tmp.paths" || return 1
  while IFS= read -r -d '' path; do
    rel=${path#"$CAND_WORK"/}
    ext=${rel##*.}
    case "$ext" in
      csv | json | txt | vtt | CSV | JSON | TXT | VTT) ;;
      *) continue ;;
    esac
    size=$(LC_ALL=C wc -c < "$path" | tr -d ' ') || return 1
    if [ "$size" -ge "$TEXT_LFS_BYTES" ]; then
      printf '%s filter=lfs diff=lfs merge=lfs -text\n' "$(attr_escape "$rel")" >> "$tmp" || return 1
    fi
  done < "$tmp.paths"
  LC_ALL=C sort -u -o "$tmp" "$tmp" || return 1
  mv -f "$tmp" "$attr" || return 1
}

stage_candidate() {
  CAND_INDEX="$GIT_DIR_ABS/record-candidate.index"
  rm -f "$CAND_INDEX"
  GIT_INDEX_FILE="$CAND_INDEX" git --git-dir="$GIT_DIR_ABS" --work-tree="$CAND_WORK" add -f -A
}

scan_candidate() {
  local rc=0 payloads="$CAND_WORK/../scan"
  extract_index_payloads "$CAND_INDEX" "$payloads" || return 5
  "$SCRIPT_DIR/fm-record-scan.sh" chain --dir "$payloads" || rc=$?
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
  local reason=$1 branch expected message tree journal before_index
  expected=$(sed -n '1p' "$GIT_DIR_ABS/record-branch")
  branch=$(git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" symbolic-ref -q --short HEAD) \
    || die 8 "Record HEAD changed during the transaction"
  [ "$branch" = "$expected" ] || die 8 "Record branch changed during the transaction"
  (set -C; : > "$GIT_DIR_ABS/index.lock") 2>/dev/null || return 8
  INDEX_LOCK_HELD=1
  [ "$(git --git-dir="$GIT_DIR_ABS" rev-parse --verify HEAD 2>/dev/null || true)" = "$START_HEAD" ] \
    || die 8 "Record HEAD changed during the transaction"
  real_index_is_clean || die 8 "unexpected user staging is present; refusing to overwrite the index"
  if trees_equal; then
    rm -f "$GIT_DIR_ABS/index.lock" || return 8
    INDEX_LOCK_HELD=0
    publish_owned_live_files || return 8
    return 1
  fi
  tree=$(GIT_INDEX_FILE="$CAND_INDEX" git --git-dir="$GIT_DIR_ABS" write-tree) || return 8
  GIT_INDEX_FILE="$CAND_WORK/../publish.index" git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" \
    read-tree --index-output="$GIT_DIR_ABS/index.lock" "$tree" || return 8
  journal="$GIT_DIR_ABS/record-publication"
  mkdir "$journal" || return 8
  if ! cp "$GIT_DIR_ABS/index.lock" "$journal/index"; then
    rm -rf "$journal"
    return 8
  fi
  before_index=missing
  [ ! -f "$GIT_DIR_ABS/index" ] || before_index=$(sha256_file "$GIT_DIR_ABS/index") || return 8
  printf '%s\n' "$START_HEAD" "$tree" "$before_index" > "$journal/before" || return 8
  python3 - "$GIT_DIR_ABS/index.lock" > "$journal/lock-id" <<'PYLOCK' || return 8
import os, sys
info = os.stat(sys.argv[1])
print(info.st_dev, info.st_ino)
PYLOCK
  message="record: ${reason}"
  GIT_INDEX_FILE="$CAND_INDEX" git --git-dir="$GIT_DIR_ABS" --work-tree="$CAND_WORK" \
    commit --quiet --no-verify -m "$message" || return 8
  CAPTURED_HEAD=$(git --git-dir="$GIT_DIR_ABS" rev-parse HEAD) || return 8
  mv -f "$GIT_DIR_ABS/index.lock" "$GIT_DIR_ABS/index" || return 8
  INDEX_LOCK_HELD=0
  rm -rf "$journal" || return 8
  publish_owned_live_files || return 8
  return 0
}

recover_index_publication() {
  local journal="$GIT_DIR_ABS/record-publication" head before tree digest current parent lock_id
  [ -d "$journal" ] || return 0
  if [ ! -f "$journal/before" ] || [ ! -f "$journal/lock-id" ]; then
    [ ! -e "$GIT_DIR_ABS/index.lock" ] || return 8
    rm -rf "$journal"
    return 0
  fi
  before=$(sed -n '1p' "$journal/before")
  tree=$(sed -n '2p' "$journal/before")
  digest=$(sed -n '3p' "$journal/before")
  head=$(git --git-dir="$GIT_DIR_ABS" rev-parse --verify HEAD 2>/dev/null || true)
  if [ "$head" != "$before" ]; then
    [ "$(git --git-dir="$GIT_DIR_ABS" rev-parse 'HEAD^{tree}')" = "$tree" ] || return 8
    parent=$(git --git-dir="$GIT_DIR_ABS" rev-parse --verify HEAD^ 2>/dev/null || true)
    [ "$parent" = "$before" ] || return 8
    [ "$(GIT_INDEX_FILE="$journal/index" git --git-dir="$GIT_DIR_ABS" write-tree)" = "$tree" ] || return 8
    current=missing
    [ ! -f "$GIT_DIR_ABS/index" ] || current=$(sha256_file "$GIT_DIR_ABS/index") || return 8
    if [ "$current" = "$(sha256_file "$journal/index")" ]; then
      rm -rf "$journal"
      return 0
    fi
    [ "$current" = "$digest" ] || return 8
  fi
  if [ -e "$GIT_DIR_ABS/index.lock" ]; then
    lock_id=$(python3 - "$GIT_DIR_ABS/index.lock" <<'PYLOCK'
import os, sys
info = os.stat(sys.argv[1])
print(info.st_dev, info.st_ino)
PYLOCK
    ) || return 8
    [ "$lock_id" = "$(cat "$journal/lock-id")" ] && cmp -s "$journal/index" "$GIT_DIR_ABS/index.lock" || return 8
  else
    (set -C; : > "$GIT_DIR_ABS/index.lock") 2>/dev/null || return 8
  fi
  INDEX_LOCK_HELD=1
  if [ "$head" != "$before" ]; then
    cp "$journal/index" "$GIT_DIR_ABS/index.lock" || return 8
    mv -f "$GIT_DIR_ABS/index.lock" "$GIT_DIR_ABS/index" || return 8
  else
    rm -f "$GIT_DIR_ABS/index.lock" || return 8
  fi
  INDEX_LOCK_HELD=0
  rm -rf "$journal"
}

publish_owned_live_files() {
  local src dest rel
  src="$CAND_WORK/.record-state"
  dest="$RECORD_WORK/.record-state"
  mkdir -p "$dest" || return 1
  if [ -d "$src" ]; then
    find "$src" \( -type f -o -type l \) -print0 > "$CAND_WORK/../publish.sources" || return 1
    find "$dest" \( -type f -o -type l \) -print0 > "$CAND_WORK/../publish.destinations" || return 1
    while IFS= read -r -d '' rel; do
      copy_file_atomic "$rel" "$dest/${rel#"$src"/}" || return 1
    done < "$CAND_WORK/../publish.sources"
    while IFS= read -r -d '' rel; do
      [ -e "$src/${rel#"$dest"/}" ] || rm -f "$rel" || return 1
    done < "$CAND_WORK/../publish.destinations"
  fi
  if [ -f "$CAND_WORK/.gitattributes" ]; then
    copy_file_atomic "$CAND_WORK/.gitattributes" "$RECORD_WORK/.gitattributes" || return 1
  fi
}

push_once() {
  local rc=0 out
  require_lock_libs
  set +e
  out=$(GIT_TERMINAL_PROMPT=0 fm_run_timed "$PUSH_TIMEOUT" \
    git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" \
    push --quiet origin "$PUSH_HEAD:refs/heads/$(sed -n '1p' "$GIT_DIR_ABS/record-branch")" 2>&1)
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
    *'[rejected]'*'(non-fast-forward)'* | *'[rejected]'*'(fetch first)'*)
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
  local remote_ref
  remote_ref="origin/$(sed -n '1p' "$GIT_DIR_ABS/record-branch")"
  if ! git --git-dir="$GIT_DIR_ABS" rev-parse --verify HEAD >/dev/null 2>&1; then
    printf '0\n'
  elif git --git-dir="$GIT_DIR_ABS" rev-parse --verify "$remote_ref" >/dev/null 2>&1; then
    git --git-dir="$GIT_DIR_ABS" rev-list --count "$remote_ref..HEAD"
  else
    git --git-dir="$GIT_DIR_ABS" rev-list --count HEAD
  fi
}

scan_outgoing_commits() {
  local remote_ref commit index="$CAND_WORK/../outgoing.index" payloads="$CAND_WORK/../outgoing" range=$PUSH_HEAD
  remote_ref="origin/$(sed -n '1p' "$GIT_DIR_ABS/record-branch")"
  if git --git-dir="$GIT_DIR_ABS" rev-parse --verify "$remote_ref" >/dev/null 2>&1; then
    range="$remote_ref..$PUSH_HEAD"
  fi
  git --git-dir="$GIT_DIR_ABS" rev-list --reverse "$range" > "$CAND_WORK/../outgoing.commits" || return 5
  while IFS= read -r commit; do
    GIT_INDEX_FILE="$index" git --git-dir="$GIT_DIR_ABS" read-tree "$commit" || return 5
    rm -rf "$payloads" || return 5
    extract_index_payloads "$index" "$payloads" || return 5
    "$SCRIPT_DIR/fm-record-scan.sh" chain --dir "$payloads" || return 5
  done < "$CAND_WORK/../outgoing.commits"
}

run_transaction() { # tick|checkpoint <reason> try|wait|required
  local mode=$1 reason=$2 lock_mode=$3 inv rc=0 sha pending class delivery
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
  recover_index_publication || finish 8 configuration-error detail=index-recovery
  START_HEAD=$(git --git-dir="$GIT_DIR_ABS" rev-parse --verify HEAD 2>/dev/null || true)
  CAPTURED_HEAD=$START_HEAD
  CAND_WORK="$GIT_DIR_ABS/record-candidate/work"
  rm -rf "${CAND_WORK%/*}" || finish 4 unsettled
  mkdir -p "$CAND_WORK" || finish 4 unsettled
  inv="$CAND_WORK/../inventory"
  build_metadata "$CAND_WORK/../metadata" || finish 4 unsettled
  rc=1
  if [ -z "$START_HEAD" ] || [ ! -f "$GIT_DIR_ABS/record-clean-head" ] ||
    [ "$(cat "$GIT_DIR_ABS/record-clean-head")" != "$START_HEAD" ] ||
    ! cmp -s "$CAND_WORK/../metadata" "$GIT_DIR_ABS/record-clean-metadata"; then
    rc=0
    settle_inventory "$inv" || rc=$?
    if [ "$rc" -eq 4 ]; then
      finish 4 unsettled
    fi
    if ! freeze_candidate "$inv"; then
      finish 4 unsettled
    fi
    build_metadata "$CAND_WORK/../metadata.frozen" || finish 4 unsettled
    cmp -s "$CAND_WORK/../metadata" "$CAND_WORK/../metadata.frozen" || finish 4 unsettled
    update_lfs_attributes
    stage_candidate
    rc=0
    scan_candidate || rc=$?
    if [ "$rc" -eq 5 ]; then
      finish 5 scan-blocked
    fi
    rc=0
    commit_candidate "$reason" || rc=$?
    if [ "$rc" -gt 1 ]; then
      if [ "$lock_mode" = required ]; then
        finish 9 configuration-error detail=commit-publication
      fi
      finish 8 configuration-error detail=commit-publication
    fi
    save_clean_metadata || finish 8 configuration-error detail=metadata
  else
    real_index_is_clean || die 8 "unexpected user staging is present; refusing to overwrite the index"
  fi
  sha=$(git --git-dir="$GIT_DIR_ABS" rev-parse --short HEAD)
  if [ "$mode" != tick ]; then
    if [ "$rc" -eq 1 ]; then
      delivery=$(read_health_file | sed -n 's/^delivery=//p')
      case "$delivery" in
        push-pending | diverged)
          emit unchanged commit="$sha" delivery="$delivery"
          exit 0
          ;;
      esac
      finish 0 unchanged commit="$sha"
    fi
    finish 0 committed-local commit="$sha"
  fi
  if [ "$rc" -eq 1 ]; then
    pending=$(pending_commit_count)
    if [ "$pending" = 0 ]; then
      finish 0 unchanged commit="$sha"
    fi
  fi
  class=
  rc=0
  PUSH_HEAD=$(git --git-dir="$GIT_DIR_ABS" rev-parse HEAD)
  scan_outgoing_commits || finish 5 scan-blocked
  validate_push_destinations
  class=$(push_once) || rc=$?
  pending=$(pending_commit_count)
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
.obsidian/workspace*.json
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

validate_setup_hooks() {
  local hook digest
  for hook in pre-commit pre-push post-checkout post-commit post-merge; do
    if [ -e "$GIT_DIR_ABS/hooks/$hook" ] || [ -L "$GIT_DIR_ABS/hooks/$hook" ]; then
      [ ! -L "$GIT_DIR_ABS/hooks/$hook" ] && [ -f "$GIT_DIR_ABS/record-hook-$hook" ] \
        || die 8 "existing Record hook is unknown; leaving it untouched"
      digest=$(sha256_file "$GIT_DIR_ABS/hooks/$hook") || die 8 "cannot validate existing Record hook"
      [ "$digest" = "$(cat "$GIT_DIR_ABS/record-hook-$hook")" ] \
        || die 8 "existing Record hook changed; leaving it untouched"
    fi
  done
}

validate_job_prerequisites() {
  local code_root=$1 tool toplevel
  for tool in gitleaks git-lfs restic rclone; do
    command -v "$tool" >/dev/null 2>&1 || die 8 "Record job requires $tool on PATH"
  done
  [ -x "$code_root/bin/fm-record.sh" ] || die 8 "Record code root must contain executable bin/fm-record.sh"
  [ -d "$code_root/.git" ] && [ ! -L "$code_root/.git" ] \
    || die 8 "Record job requires a primary code checkout, not a disposable worktree"
  toplevel=$(git -C "$code_root" rev-parse --show-toplevel 2>/dev/null) \
    || die 8 "Record code root is not a Git checkout"
  [ "$toplevel" = "$code_root" ] || die 8 "Record code root must be the checkout root"
}

cmd_setup() {
  local init=0 write_plist=0 bootstrap=0 origin='' branch=$EXPECTED_BRANCH code_root=$FM_ROOT attr_tmp hook
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --init) init=1; shift ;;
      --write-plist) write_plist=1; shift ;;
      --bootstrap) bootstrap=1; shift ;;
      --origin) origin=$2; shift 2 ;;
      --branch) branch=$2; shift 2 ;;
      --code-root) code_root=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die 2 "unknown setup argument" ;;
    esac
  done
  refuse_git_overrides
  if [ "$write_plist" -eq 1 ] || [ "$bootstrap" -eq 1 ]; then
    code_root=$(physical_dir "$code_root") || die 8 "cannot resolve the Record code root"
    validate_job_prerequisites "$code_root"
  fi
  validate_home_roots
  require_hash_tool
  [ ! -L "$DATA/.git" ] || die 8 "Record Git directory must not be a symlink"
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
  validate_hook_path
  validate_setup_hooks
  chmod 700 "$GIT_DIR_ABS" || die 8 "cannot protect the Record Git directory"
  printf '%s\n' "${origin:-$(git --git-dir="$GIT_DIR_ABS" remote get-url origin)}" > "$GIT_DIR_ABS/record-origin"
  printf '%s\n' "$branch" > "$GIT_DIR_ABS/record-branch"
  write_gitignore "$RECORD_WORK/.gitignore"
  attr_tmp=$(mktemp "$GIT_DIR_ABS/record-attributes.XXXXXX")
  binary_attr_lines > "$attr_tmp"
  existing_literal_lfs_rules "$RECORD_WORK/.gitattributes" >> "$attr_tmp"
  LC_ALL=C sort -u -o "$attr_tmp" "$attr_tmp"
  mv -f "$attr_tmp" "$RECORD_WORK/.gitattributes"
  git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" lfs install --local >/dev/null
  install_hooks "$GIT_DIR_ABS/hooks" "$(physical_dir "$code_root")"
  for hook in pre-commit pre-push post-checkout post-commit post-merge; do
    sha256_file "$GIT_DIR_ABS/hooks/$hook" > "$GIT_DIR_ABS/record-hook-$hook"
  done
  [ ! -L "$FM_HOME/.record-enabled" ] || die 8 "Record activation marker must not be a symlink"
  printf 'enabled\n' > "$FM_HOME/.record-enabled"
  if [ "$write_plist" -eq 1 ] || [ "$bootstrap" -eq 1 ]; then
    validate_binding
  fi
  if [ "$write_plist" -eq 1 ]; then
    write_record_plist "$(physical_dir "$code_root")"
  fi
  if [ "$bootstrap" -eq 1 ]; then
    bootstrap_record_job "$code_root"
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
    die 8 "existing LaunchAgent is not the Record job; leaving it untouched"
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
  local code_root=$1 plist=${FM_RECORD_PLIST:-$HOME/Library/LaunchAgents/com.firstmate.record-tick.plist}
  [ -f "$plist" ] || die 8 "Record LaunchAgent plist is missing; pass --write-plist"
  grep -Fq 'firstmate-record-tick-v1' "$plist" || die 8 "Record LaunchAgent plist is not owned by setup"
  python3 - "$plist" "$code_root" "$(physical_dir "$FM_HOME")" <<'PY' \
    || die 8 "Record LaunchAgent does not match the validated setup; use --write-plist"
import os
import plistlib
import sys
try:
    with open(sys.argv[1], "rb") as source:
        job = plistlib.load(source)
    if (job["ProgramArguments"] != [sys.argv[2] + "/bin/fm-record.sh", "tick"]
            or job["EnvironmentVariables"]["FM_HOME"] != sys.argv[3]
            or job["EnvironmentVariables"]["PATH"] != os.environ["PATH"]):
        sys.exit(1)
except Exception:
    sys.exit(1)
PY
  launchctl bootout "gui/$UID/com.firstmate.record-tick" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$plist"
}

extract_index_payloads() { # <index> <dest-dir>
  local index=$1 dest=$2 sha path meta oid payload oid_dir size
  mkdir -p "$dest" || return 1
  GIT_INDEX_FILE="$index" git --git-dir="$GIT_DIR_ABS" ls-files -s -z > "$dest/../index.entries" || return 1
  while IFS=$(printf '\t') read -r -d '' meta path; do
    [ -n "$path" ] || continue
    if is_prohibited "$path"; then
      printf 'fm-record: prohibited path in indexed content\n' >&2
      return 1
    fi
    validate_path_separators "$path"
    sha=$(printf '%s\n' "$meta" | awk '{print $2}')
    [ -n "$sha" ] || return 1
    payload="$dest/$path"
    mkdir -p "$(dirname "$payload")" || return 1
    GIT_INDEX_FILE="$index" git --git-dir="$GIT_DIR_ABS" cat-file -p "$sha" > "$payload" || return 1
    case "${meta%% *}" in
      120000)
        python3 - "$payload" <<'PY' || return 1
import os
import sys
path = os.fsencode(sys.argv[1])
try:
    with open(path, "rb") as source:
        target = source.read()
    os.unlink(path)
    os.symlink(target, path)
except (OSError, ValueError):
    print("fm-record: cannot materialize indexed symlink", file=sys.stderr)
    sys.exit(1)
PY
        continue
        ;;
      100644 | 100755) ;;
      *) return 1 ;;
    esac
    if head -n 1 "$payload" | grep -Fq 'git-lfs.github.com/spec/v1'; then
      git lfs pointer --check --file="$payload" >/dev/null 2>&1 || return 1
      oid=$(awk '/^oid sha256:/ { print $2 }' "$payload")
      oid=${oid#sha256:}
      size=$(awk '/^size / { print $2 }' "$payload")
      oid_dir="$GIT_DIR_ABS/lfs/objects/$(printf '%s' "$oid" | cut -c1-2)/$(printf '%s' "$oid" | cut -c3-4)"
      [ -f "$oid_dir/$oid" ] || return 1
      cp -p "$oid_dir/$oid" "$payload" || return 1
      [ "$(sha256_file "$payload")" = "$oid" ] || return 1
      [ "$(wc -c < "$payload" | tr -d ' ')" = "$size" ] || return 1
    fi
  done < "$dest/../index.entries"
}

cmd_pre_commit() {
  local dest rc=0
  [ "$#" -eq 0 ] || die 2 "pre-commit does not accept arguments"
  require_hash_tool
  GIT_DIR_ABS=$(git rev-parse --absolute-git-dir) || die 8 "pre-commit has no git dir"
  validate_private_git_dir
  dest=$(mktemp -d "$GIT_DIR_ABS/record-precommit.XXXXXX")
  CAND_WORK="$dest/work"
  if extract_index_payloads "${GIT_INDEX_FILE:-$GIT_DIR_ABS/index}" "$dest/work"; then
    "$SCRIPT_DIR/fm-record-scan.sh" chain --dir "$dest/work" || rc=$?
  else
    printf 'fm-record: cannot resolve indexed payloads for scanning\n' >&2
    rc=1
  fi
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
      *) die 2 "unknown checkpoint argument" ;;
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
  health)
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
    die 2 "unknown argument; run --help"
    ;;
esac
