#!/usr/bin/env bash
# fm-feeder-export.sh - the one-way mirror from this Firstmate home's records
# into the private feeder vault clone.
#
# Sources are exactly data/decisions/*.md and data/*/report.md under the
# effective home. data/ stays the system of record: the vault is regenerated,
# never read back as generation input, and never a write-back route. This script
# never creates a repository, never chooses a remote, and never force-pushes.
#
# Usage:
#   fm-feeder-export.sh          publish the mirror and push it
#   fm-feeder-export.sh --help   print this header
#
# Configuration (under the effective home, gitignored):
#   config/feeder-vault           REQUIRED. Exactly one non-empty line holding
#                                 the absolute path of the vault clone. The path
#                                 must be normalized (no '.', '..', or '//'),
#                                 must not be '/', and must not be a symlink.
#   config/feeder-vault-excludes  OPTIONAL. One exact normalized source path per
#                                 line, for example data/decisions/x.md or
#                                 data/<task-id>/report.md. Globs are refused.
#                                 Every entry must name a currently selected
#                                 source. An excluded record is omitted whole;
#                                 bytes are never redacted, because redaction
#                                 would make sot_sha256 and mirror fidelity
#                                 ambiguous. Blank lines and '#' comments are
#                                 allowed.
#
# Vault requirements (created once, out of band, never by this script):
#   - The clone root equals the configured path and is the exact Git top level.
#   - <vault>/.feeder-vault is a regular non-symbolic file of exactly two lines:
#         firstmate-feeder-vault-v1
#         remote=<owner>/<name>
#     The pinned identity stops a copied marker from authorizing a different
#     remote: the configured origin must resolve to that exact GitHub repository.
#     <owner>/<name> is the one repository this script is built for,
#     guanchengh-lgtm/fm-vault; any other marked identity is refused.
#   - The checked-out branch is main and tracks origin/main. No other branch is
#     published, and this script never creates or switches a branch.
#   - The repository is private. Private visibility is re-verified with
#     `gh-axi repo view <owner>/<name>` before EVERY push, and an unavailable
#     check refuses the push instead of assuming private.
#   - The vault is one ordinary clone: <vault>/.git is a real directory inside
#     the vault and is also Git's effective common directory, so a linked
#     worktree or a redirected common directory is refused. Inherited Git
#     environment overrides (GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR,
#     GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES)
#     are refused for the same reason.
#   - The wiki directories and the transaction root share one filesystem,
#     because publication is a rename. A split-device layout is refused rather
#     than copied.
#
# Owned paths. This script writes only wiki/decisions and wiki/reports in the
# vault, stages only those two pathspecs, and requires a clean vault worktree
# and index before publication. Transaction artifacts (lock, journal, stage,
# backups) live under <vault>/.git/fm-feeder so they can never appear as vault
# worktree changes, while staying on the vault filesystem for atomic renames.
#
# Transaction. Rendering happens off-path in a fresh stage. Publication is a
# journalled sequence: back up both live directories, install both staged
# directories, verify, stage the two pathspecs, commit when bytes changed, then
# push. An ordinary failure, INT, TERM, or HUP before the committed phase rolls
# both directories and the index back. A hard stop is recovered from the journal
# on the next run: when a journal is present, vault authority is checked, then
# recovery runs under the lock before the ordinary source, remote, and branch
# preflight, so an unrelated refusal cannot strand a partial generation. An
# inconsistent journal refuses with an exact instruction rather than guessing.
#
# The journal durability limit: the journal is closed and revalidated before
# live renames, but it is not explicitly synced to durable storage. A power loss
# can preserve a rename without its journal, so recovery fails closed instead of
# guessing. The vault is a one-way mirror, authoritative records remain in the
# home, and a later run re-exports all records after operator repair.
#
# The source Git metadata limit: the source HEAD and tracked-path set are pinned
# during discovery but are not rechecked before publication. A concurrent commit
# that preserves source bytes and timestamps can publish dates from the earlier
# Git state. Recovery fails closed for inconsistent transaction state. The vault
# is a one-way mirror, authoritative records remain in the home, and a later run
# re-exports all records from the then-current Git state.
#
# The revalidation guards' limit: a concurrent same-user process can replace the
# transaction root with a symlink between check and use and redirect deletion
# outside the vault; such a process already controls local files and execution,
# so this race is outside the threat model.
#
# Remote durability is part of success: a push failure preserves the complete
# local commit, prints the remote name, branch, and commit, and exits non-zero.
# The next run pushes that retained commit even when it produces no new content.
#
# Date limitation. `created` is the best available FIRST-KNOWN date, in this
# order: the Git first-add date, a terminal YYYY-MM-DD suffix on a decision
# filename, the filesystem birth date when the platform exposes one, and finally
# the source modification date. `updated` is the latest Git change date, or the
# source modification date for an untracked source. Records that are private and
# untracked therefore carry a filesystem-derived first-known date, not a true
# authoring date. The export day is never used as a fallback, so an unchanged
# corpus re-exports byte-identically on any later day.
#
# Secret boundary. Every included source snapshot and every generated page is
# scanned for a fixed set of high-confidence credential shapes before any live
# mutation. A match refuses the run, naming only the logical source path and the
# pattern class, never the matched bytes. The classes are deliberately precise
# and incomplete; there is no generic password or entropy detector, because its
# false-positive policy is undefined.
#
# The OpenAI class is exactly
# `sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,255}`. It deliberately fails
# closed: a false positive blocks export for review, while a false negative can
# expose a credential.
#
# Exit codes:
#   0  mirror published and present on the remote
#   1  refusal or failure before or during publication (no partial generation)
#   3  another exporter holds the lock
#   4  a prior transaction needs manual recovery (exact instruction printed)
#   5  local commit is complete but the push did not reach the remote
set -eu

# Byte semantics everywhere: destination identifiers, manifest and index order,
# and every pattern match must be exact bytes rather than locale collation, or a
# UTF-8 locale silently accepts an accented character inside an ASCII range.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

MARKER_NAME=.feeder-vault
MARKER_VERSION=firstmate-feeder-vault-v1
REMOTE_NAME=origin
EXPECTED_REMOTE_REPOSITORY=guanchengh-lgtm/fm-vault
EXPECTED_BRANCH=main
# shellcheck disable=SC2016 # The banner names sot_path literally, backticks included.
BANNER='> Mirror of a firstmate record. Not the system of record. Read `sot_path` before acting.'
EMPTY_INDEX_DATE=2026-08-31
UNAME_S="$(uname)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() { # <exit-code> <message>...
  local code=$1
  shift
  printf 'fm-feeder-export: %s\n' "$*" >&2
  exit "$code"
}

note() {
  printf 'fm-feeder-export: %s\n' "$*" >&2
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '') ;;
  *) die 1 "unknown argument '$1'; run --help" ;;
esac

[ "${GIT_DIR+x}" != x ] || die 1 "Git environment override GIT_DIR must be unset"
[ "${GIT_WORK_TREE+x}" != x ] || die 1 "Git environment override GIT_WORK_TREE must be unset"
[ "${GIT_COMMON_DIR+x}" != x ] || die 1 "Git environment override GIT_COMMON_DIR must be unset"
[ "${GIT_INDEX_FILE+x}" != x ] || die 1 "Git environment override GIT_INDEX_FILE must be unset"
[ "${GIT_OBJECT_DIRECTORY+x}" != x ] || die 1 "Git environment override GIT_OBJECT_DIRECTORY must be unset"
[ "${GIT_ALTERNATE_OBJECT_DIRECTORIES+x}" != x ] \
  || die 1 "Git environment override GIT_ALTERNATE_OBJECT_DIRECTORIES must be unset"

# --- portable primitives ----------------------------------------------------

# One of shasum or sha256sum, selected once by require_hash_tool. Each helper
# branches on it rather than calling through a wrapper, because the list form
# runs under xargs, which can only execute a real program.
HASH_TOOL=

sha256_file() { # <path>
  local out
  if [ "$HASH_TOOL" = shasum ]; then
    out=$(shasum -a 256 -- "$1") || return 1
  else
    out=$(sha256sum -- "$1") || return 1
  fi
  printf '%s\n' "${out%% *}"
}

sha256_stdin() {
  local out
  if [ "$HASH_TOOL" = shasum ]; then
    out=$(shasum -a 256) || return 1
  else
    out=$(sha256sum) || return 1
  fi
  printf '%s\n' "${out%% *}"
}

# Hash a whole file list in one tool invocation, preserving input order. Output
# is one lowercase digest per line.
sha256_list() { # reads NUL-separated paths on stdin
  local -a rc
  if [ "$HASH_TOOL" = shasum ]; then
    xargs -0 shasum -a 256 -- | LC_ALL=C awk '{print $1}'
  else
    xargs -0 sha256sum -- | LC_ALL=C awk '{print $1}'
  fi
  rc=("${PIPESTATUS[@]}")
  [ "${rc[0]}" -eq 0 ] && [ "${rc[1]}" -eq 0 ]
}

require_hash_tool() {
  if command -v shasum > /dev/null 2>&1; then
    HASH_TOOL=shasum
    return 0
  fi
  if command -v sha256sum > /dev/null 2>&1; then
    HASH_TOOL=sha256sum
    return 0
  fi
  die 1 "no SHA-256 tool available; install shasum or sha256sum"
}

path_mtime() { # <path>
  if [ "$UNAME_S" = Darwin ]; then
    stat -f %m -- "$1" 2>/dev/null
  else
    stat -c %Y -- "$1" 2>/dev/null
  fi
}

path_birth() { # <path>; non-zero when the platform exposes no birth time
  local value
  if [ "$UNAME_S" = Darwin ]; then
    value=$(stat -f %B -- "$1" 2>/dev/null) || return 1
  else
    value=$(stat -c %W -- "$1" 2>/dev/null) || return 1
  fi
  case "$value" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$value"
}

epoch_to_utc_date() { # <epoch-seconds>
  if [ "$UNAME_S" = Darwin ]; then
    date -u -r "$1" +%Y-%m-%d 2>/dev/null
  else
    date -u -d "@$1" +%Y-%m-%d 2>/dev/null
  fi
}

is_iso_date() { # <value>
  local normalized
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  if [ "$UNAME_S" = Darwin ]; then
    normalized=$(date -j -u -f '%Y-%m-%d' "$1" '+%Y-%m-%d' 2>/dev/null) || return 1
  else
    normalized=$(date -u -d "$1" '+%Y-%m-%d' 2>/dev/null) || return 1
  fi
  [ "$normalized" = "$1" ]
}

is_sha256_hex() { # <value>
  case "$1" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

has_control_chars() { # <string>; tab counts as a control character
  local stripped
  stripped=$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177' | LC_ALL=C wc -c | tr -d ' ')
  [ "$stripped" != "$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')" ] \
    || printf '%s' "$1" | LC_ALL=C grep -q "$(printf '\302[\200-\237]')"
}

assert_no_nul_bytes() { # <file> <label>
  local size stripped
  size=$(LC_ALL=C wc -c < "$1" | tr -d ' ') \
    || die 1 "cannot inspect $2"
  stripped=$(LC_ALL=C tr -d '\000' < "$1" | LC_ALL=C wc -c | tr -d ' ') \
    || die 1 "cannot inspect $2"
  [ "$size" = "$stripped" ] || die 1 "$2 must not contain NUL bytes"
}

has_yaml_forbidden_chars() { # <string>
  printf '%s' "$1" | LC_ALL=C grep -Eq "$(printf '\357\277[\276\277]')"
}

# The one YAML quoting owner: a single-quoted scalar with every embedded single
# quote doubled. Every variable scalar the pages emit goes through it. It answers
# in YAML_SCALAR rather than on stdout so a page render costs no subshell.
YAML_SCALAR=
yaml_squote() { # <value>
  local value=$1
  value=${value//\'/\'\'}
  YAML_SCALAR="'$value'"
}

normalize_absolute_path() { # <path>
  local path=$1 part out=/
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *'//'*) return 1 ;; esac
  path=${path#/}
  while [ -n "$path" ]; do
    case "$path" in
      */*) part=${path%%/*}; path=${path#*/} ;;
      *) part=$path; path= ;;
    esac
    case "$part" in
      . | ..) return 1 ;;
      *)
        if has_control_chars "$part"; then return 1; fi
        if [ "$out" = / ]; then out="/$part"; else out="$out/$part"; fi
        ;;
    esac
  done
  [ "$out" != / ] || return 1
  printf '%s\n' "$out"
}

physical_dir() { # <path>
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
}

# Resolve a possibly symbolic source path to its physical regular-file target.
canonical_regular_file() { # <path>
  local path=$1 hops=0 target dir base
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    target=$(readlink -- "$path") || return 1
    case "$target" in
      /*) path=$target ;;
      *) path="$(dirname -- "$path")/$target" ;;
    esac
  done
  [ -f "$path" ] || return 1
  dir=$(physical_dir "$(dirname -- "$path")") || return 1
  base=$(basename -- "$path")
  printf '%s\n' "$dir/$base"
}

path_is_ancestor_of() { # <ancestor> <descendant>
  case "$2" in "$1"/*) return 0 ;; esac
  return 1
}

path_identity() { # <regular-file>
  if [ "$UNAME_S" = Darwin ]; then
    stat -f '%d:%i' -- "$1" 2>/dev/null
  else
    stat -c '%d:%i' -- "$1" 2>/dev/null
  fi
}

path_device() { # <path>
  local device
  if [ "$UNAME_S" = Darwin ]; then
    device=$(stat -f %d -- "$1" 2>/dev/null) || return 1
  else
    device=$(stat -c %d -- "$1" 2>/dev/null) || return 1
  fi
  case "$device" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$device"
}

source_identity_is_current() { # <sot-path> <physical> <device:inode>
  local sot=$1 expected_physical=$2 expected_identity=$3 resolved identity
  resolved=$(canonical_regular_file "$FM_HOME/$sot") || return 1
  case "$resolved" in
    "$DATA_PHYSICAL"/*) ;;
    *) return 1 ;;
  esac
  [ "$resolved" = "$expected_physical" ] || return 1
  [ ! -L "$resolved" ] && [ -f "$resolved" ] || return 1
  identity=$(path_identity "$resolved") || return 1
  [ "$identity" = "$expected_identity" ]
}

# --- configuration and vault identity ---------------------------------------

read_single_line_config() { # <path> <label>
  local file=$1 label=$2 lines value
  [ -e "$file" ] || die 1 "missing $label at $file"
  [ ! -L "$file" ] || die 1 "$label at $file must not be a symlink"
  [ -f "$file" ] || die 1 "$label at $file must be a regular file"
  assert_no_nul_bytes "$file" "$label at $file"
  lines=$(LC_ALL=C awk 'END { print NR }' "$file")
  value=$(sed -n '1p' "$file")
  [ -n "$value" ] || die 1 "$label at $file is empty; expected one absolute vault path"
  case "$lines" in
    0 | 1) ;;
    *) die 1 "$label at $file must hold exactly one line" ;;
  esac
  printf '%s\n' "$value"
}

VAULT_CONFIG="$CONFIG/feeder-vault"
EXCLUDES_CONFIG="$CONFIG/feeder-vault-excludes"

require_hash_tool

CONFIGURED_VAULT=$(read_single_line_config "$VAULT_CONFIG" 'feeder vault config')
NORMALIZED_VAULT=$(normalize_absolute_path "$CONFIGURED_VAULT") \
  || die 1 "vault path '$CONFIGURED_VAULT' must be absolute and normalized with no '.', '..', '//', or control characters"
[ ! -L "$NORMALIZED_VAULT" ] || die 1 "vault path $NORMALIZED_VAULT must not be a symlink"
[ -d "$NORMALIZED_VAULT" ] || die 1 "vault path $NORMALIZED_VAULT is not a directory"
VAULT=$(physical_dir "$NORMALIZED_VAULT") || die 1 "cannot resolve vault path $NORMALIZED_VAULT"
[ "$VAULT" = "$NORMALIZED_VAULT" ] \
  || die 1 "vault path $NORMALIZED_VAULT resolves to $VAULT; the configured path must be canonical"
[ "$VAULT" != / ] || die 1 "vault path must not be the filesystem root"

DATA="$FM_HOME/data"
[ -d "$DATA" ] || die 1 "no data directory at $DATA"
DATA_PHYSICAL=$(physical_dir "$DATA") || die 1 "cannot resolve data directory $DATA"
HOME_PHYSICAL=$(physical_dir "$FM_HOME") || die 1 "cannot resolve firstmate home $FM_HOME"
ROOT_PHYSICAL=$(physical_dir "$FM_ROOT") || die 1 "cannot resolve firstmate code root $FM_ROOT"

for guarded in "$HOME_PHYSICAL" "$ROOT_PHYSICAL" "$DATA_PHYSICAL"; do
  [ "$VAULT" != "$guarded" ] || die 1 "vault must not be $guarded"
  ! path_is_ancestor_of "$guarded" "$VAULT" || die 1 "vault must not be inside $guarded"
  ! path_is_ancestor_of "$VAULT" "$guarded" || die 1 "vault must not be an ancestor of $guarded"
done
unset guarded

git -C "$VAULT" rev-parse --show-toplevel > /dev/null 2>&1 \
  || die 1 "vault $VAULT is not a Git repository"
VAULT_TOPLEVEL=$(git -C "$VAULT" rev-parse --show-toplevel)
VAULT_TOPLEVEL_PHYSICAL=$(physical_dir "$VAULT_TOPLEVEL") || die 1 "cannot resolve vault Git top level"
[ "$VAULT_TOPLEVEL_PHYSICAL" = "$VAULT" ] \
  || die 1 "vault $VAULT is not the Git top level ($VAULT_TOPLEVEL_PHYSICAL); refusing to publish into a nested path"

[ ! -L "$VAULT/.git" ] || die 1 "$VAULT/.git must not be a symlink"
[ -d "$VAULT/.git" ] || die 1 "$VAULT/.git must be a directory; the vault must be an ordinary clone"
GIT_DIR_PHYSICAL=$(physical_dir "$VAULT/.git") || die 1 "cannot resolve $VAULT/.git"
[ "$GIT_DIR_PHYSICAL" = "$VAULT/.git" ] || die 1 "$VAULT/.git resolves outside the vault"
GIT_COMMON_DIR=$(git -C "$VAULT" rev-parse --git-common-dir 2>/dev/null) \
  || die 1 "cannot resolve the vault effective Git common directory"
case "$GIT_COMMON_DIR" in
  /*) ;;
  *) GIT_COMMON_DIR="$VAULT/$GIT_COMMON_DIR" ;;
esac
GIT_COMMON_DIR_PHYSICAL=$(physical_dir "$GIT_COMMON_DIR") \
  || die 1 "cannot resolve the vault effective Git common directory"
[ "$GIT_COMMON_DIR_PHYSICAL" = "$GIT_DIR_PHYSICAL" ] \
  || die 1 "vault effective Git common directory $GIT_COMMON_DIR_PHYSICAL must be $VAULT/.git; the vault must be one ordinary clone"

MARKER="$VAULT/$MARKER_NAME"
[ ! -L "$MARKER" ] || die 1 "vault marker $MARKER must not be a symlink"
[ -f "$MARKER" ] || die 1 "vault marker $MARKER is missing; $VAULT is not an authorized feeder vault"
MARKER_SIZE=$(LC_ALL=C wc -c < "$MARKER" | tr -d ' ')
MARKER_TEXT_SIZE=$(LC_ALL=C tr -d '\000' < "$MARKER" | LC_ALL=C wc -c | tr -d ' ')
[ "$MARKER_SIZE" = "$MARKER_TEXT_SIZE" ] \
  || die 1 "vault marker $MARKER must not contain NUL bytes"
MARKER_LINE_COUNT=$(LC_ALL=C awk 'END {print NR}' "$MARKER")
[ "$MARKER_LINE_COUNT" -eq 2 ] \
  || die 1 "vault marker $MARKER must hold exactly two lines: $MARKER_VERSION and remote=<owner>/<name>"
MARKER_HEAD=$(sed -n '1p' "$MARKER")
MARKER_REMOTE_LINE=$(sed -n '2p' "$MARKER")
[ "$MARKER_HEAD" = "$MARKER_VERSION" ] \
  || die 1 "vault marker $MARKER declares '$MARKER_HEAD', expected $MARKER_VERSION"
case "$MARKER_REMOTE_LINE" in
  remote=*/*) ;;
  *) die 1 "vault marker $MARKER must pin its repository as remote=<owner>/<name>" ;;
esac
MARKER_REMOTE=${MARKER_REMOTE_LINE#remote=}
case "$MARKER_REMOTE" in
  */*/* | /* | */) die 1 "vault marker repository '$MARKER_REMOTE' is not a plain <owner>/<name>" ;;
esac
case "$MARKER_REMOTE" in
  *[!A-Za-z0-9._/-]*) die 1 "vault marker repository '$MARKER_REMOTE' has unsupported characters" ;;
esac
[ "$MARKER_REMOTE" = "$EXPECTED_REMOTE_REPOSITORY" ] \
  || die 1 "vault marker must pin $EXPECTED_REMOTE_REPOSITORY"

WIKI="$VAULT/wiki"
DECISIONS_LIVE="$WIKI/decisions"
REPORTS_LIVE="$WIKI/reports"
FEEDER_DIR="$VAULT/.git/fm-feeder"
LOCK="$FEEDER_DIR/lock"
JOURNAL="$FEEDER_DIR/journal"

for owned in "$WIKI" "$DECISIONS_LIVE" "$REPORTS_LIVE" "$FEEDER_DIR" "$LOCK" "$JOURNAL"; do
  [ ! -L "$owned" ] || die 1 "owned path $owned must not be a symlink"
done
unset owned
for owned in "$WIKI" "$DECISIONS_LIVE" "$REPORTS_LIVE"; do
  if [ -e "$owned" ] && [ ! -d "$owned" ]; then
    die 1 "owned path $owned exists and is not a directory"
  fi
done
unset owned

# --- lock -------------------------------------------------------------------

LOCK_HELD=0

acquire_lock() {
  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
    printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$(uname -n)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      > "$LOCK/owner" 2>/dev/null || true
    return 0
  fi
  local owner=''
  if [ -f "$LOCK/owner" ]; then
    owner=$(tr '\n' ' ' < "$LOCK/owner" 2>/dev/null || true)
  fi
  printf 'fm-feeder-export: another exporter holds %s (%s)\n' "$LOCK" "${owner:-owner unknown}" >&2
  printf 'fm-feeder-export: if no exporter is running, remove that directory with: rm -rf %s\n' "$LOCK" >&2
  exit 3
}

prepare_transaction_root() {
  local physical
  if [ ! -e "$FEEDER_DIR" ] && [ ! -L "$FEEDER_DIR" ]; then
    mkdir "$FEEDER_DIR" 2>/dev/null \
      || die 1 "cannot create transaction directory $FEEDER_DIR"
  fi
  [ ! -L "$FEEDER_DIR" ] \
    || die 1 "transaction path $FEEDER_DIR must not be a symlink"
  [ -d "$FEEDER_DIR" ] \
    || die 1 "transaction path $FEEDER_DIR is not a directory"
  physical=$(physical_dir "$FEEDER_DIR") \
    || die 1 "cannot resolve transaction directory $FEEDER_DIR"
  [ "$physical" = "$FEEDER_DIR" ] \
    || die 1 "transaction directory $FEEDER_DIR resolves to $physical"
}

release_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  rm -rf "$LOCK" 2>/dev/null || true
  LOCK_HELD=0
}

# --- transaction state ------------------------------------------------------

TX_PHASE=
STAGE=
BACKUP=
STAGED_PATHS=0
RUN_ID=
PRESERVE_TRANSACTION=0
PUSH_DECISIONS_DIGEST=
PUSH_REPORTS_DIGEST=
JOURNAL_FD_OPEN=0

# Deterministic digest of a mirror directory: the LC_ALL=C sorted relative path
# list paired with each file's digest, hashed once. Destination names are
# validated ASCII identifiers, so the sorted list needs no separator escaping.
dir_digest() { # <dir>; ABSENT when the directory does not exist
  local dir=$1 names nul digests pair result status=0
  if [ ! -d "$dir" ]; then
    printf 'ABSENT\n'
    return 0
  fi
  names=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-names.XXXXXX") || return 1
  nul=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-nul.XXXXXX") || {
    rm -f "$names"
    return 1
  }
  digests=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-digests.XXXXXX") || {
    rm -f "$names" "$nul"
    return 1
  }
  pair=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-pair.XXXXXX") || {
    rm -f "$names" "$nul" "$digests"
    return 1
  }
  if (cd "$dir" && LC_ALL=C find . -type f -print) > "$names" && LC_ALL=C sort -o "$names" "$names"; then
    if [ -s "$names" ]; then
      (
        cd "$dir" || exit 1
        LC_ALL=C awk '{ printf "%s%c", $0, 0 }' "$names" > "$nul" || exit 1
        sha256_list < "$nul"
      ) > "$digests" || status=1
    fi
  else
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    if [ -s "$names" ]; then
      if LC_ALL=C paste "$names" "$digests" > "$pair"; then
        result=$(sha256_stdin < "$pair") || status=1
      else
        status=1
      fi
    else
      result=EMPTY
    fi
  fi
  rm -f "$names" "$nul" "$pair" "$digests"
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$result"
}

git_dir_digest() { # <commit> <repository-relative-dir>
  local commit=$1 prefix=$2 paths names digests pair blob path rel digest result status=0
  paths=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-git-paths.XXXXXX") || return 1
  names=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-git-names.XXXXXX") || {
    rm -f "$paths"
    return 1
  }
  digests=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-git-digests.XXXXXX") || {
    rm -f "$paths" "$names"
    return 1
  }
  pair=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-git-pair.XXXXXX") || {
    rm -f "$paths" "$names" "$digests"
    return 1
  }
  blob=$(mktemp "${TMPDIR:-/tmp}/fm-feeder-git-blob.XXXXXX") || {
    rm -f "$paths" "$names" "$digests" "$pair"
    return 1
  }
  if git -C "$VAULT" ls-tree -r --name-only "$commit" -- "$prefix" > "$paths" 2>/dev/null \
    && LC_ALL=C sort -o "$paths" "$paths"; then
    : > "$names"
    : > "$digests"
    while IFS= read -r path; do
      case "$path" in
        "$prefix"/*) ;;
        *) status=1; break ;;
      esac
      rel=${path#"$prefix"/}
      printf './%s\n' "$rel" >> "$names"
      git -C "$VAULT" cat-file blob "$commit:$path" > "$blob" 2>/dev/null || {
        status=1
        break
      }
      digest=$(sha256_file "$blob") || {
        status=1
        break
      }
      printf '%s\n' "$digest" >> "$digests"
    done < "$paths"
  else
    status=1
  fi
  if [ "$status" -eq 0 ]; then
    if [ -s "$names" ]; then
      if LC_ALL=C paste "$names" "$digests" > "$pair"; then
        result=$(sha256_stdin < "$pair") || status=1
      else
        status=1
      fi
    else
      result=ABSENT
    fi
  fi
  rm -f "$paths" "$names" "$pair" "$digests" "$blob"
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$result"
}

journal_append() { # <line>...
  if [ "$JOURNAL_FD_OPEN" -eq 1 ]; then
    printf '%s\n' "$@" >&3
    return
  fi
  [ ! -L "$JOURNAL" ] && [ -f "$JOURNAL" ] || return 1
  printf '%s\n' "$@" >> "$JOURNAL"
}

create_journal() {
  local temporary
  temporary=$(mktemp "$FEEDER_DIR/.journal.$RUN_ID.XXXXXX") \
    || die 1 "cannot create a temporary transaction journal under $FEEDER_DIR"
  [ ! -L "$temporary" ] && [ -f "$temporary" ] || {
    rm -f "$temporary" 2>/dev/null || true
    die 1 "temporary transaction journal $temporary is not a safe regular file"
  }
  exec 3> "$temporary"
  JOURNAL_FD_OPEN=1
  if ! ln "$temporary" "$JOURNAL" 2>/dev/null; then
    close_journal
    rm -f "$temporary" 2>/dev/null || true
    die 1 "cannot atomically create transaction journal $JOURNAL"
  fi
  if ! rm -f "$temporary"; then
    close_journal
    rm -f "$JOURNAL" 2>/dev/null || true
    die 1 "cannot remove temporary transaction journal $temporary"
  fi
  [ ! -L "$JOURNAL" ] && [ -f "$JOURNAL" ] \
    || die 1 "transaction journal $JOURNAL is not a safe regular file"
}

close_journal() {
  [ "$JOURNAL_FD_OPEN" -eq 1 ] || return 0
  exec 3>&-
  JOURNAL_FD_OPEN=0
}

verify_publication_paths() {
  local owned
  for owned in "$WIKI" "$DECISIONS_LIVE" "$REPORTS_LIVE" "$FEEDER_DIR" "$LOCK" "$JOURNAL" "$STAGE" "$BACKUP"; do
    [ ! -L "$owned" ] || die 1 "publication path $owned must not be a symlink"
  done
  [ -d "$FEEDER_DIR" ] && [ -d "$LOCK" ] && [ -d "$STAGE" ] \
    && [ -d "$BACKUP" ] && [ -f "$JOURNAL" ] \
    || die 1 "transaction publication paths are not safe"
  for owned in "$WIKI" "$DECISIONS_LIVE" "$REPORTS_LIVE"; do
    if [ -e "$owned" ] && [ ! -d "$owned" ]; then
      die 1 "publication path $owned is not a directory"
    fi
  done
}

verify_prepublication_paths() {
  local owned
  for owned in "$WIKI" "$DECISIONS_LIVE" "$REPORTS_LIVE" "$FEEDER_DIR" "$LOCK" "$JOURNAL" "$STAGE"; do
    [ ! -L "$owned" ] || die 1 "publication path $owned must not be a symlink"
  done
  [ -d "$FEEDER_DIR" ] && [ -d "$LOCK" ] && [ -d "$STAGE" ] && [ -f "$JOURNAL" ] \
    || die 1 "transaction publication paths are not safe"
  [ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] \
    || die 1 "transaction backup path $BACKUP already exists or is symbolic"
}

journal_value() { # <key>
  [ ! -L "$JOURNAL" ] && [ -f "$JOURNAL" ] || return 1
  LC_ALL=C awk -v key="$1" -F= '$1 == key { value = substr($0, length(key) + 2) } END { if (value == "") exit 1; print value }' "$JOURNAL"
}

set_phase() { # <phase>
  TX_PHASE=$1
  journal_append "phase=$1"
}

unstage_owned_paths() {
  [ "$STAGED_PATHS" -eq 1 ] || return 0
  git -C "$VAULT" reset -q HEAD -- wiki/decisions wiki/reports > /dev/null 2>&1 || return 1
  STAGED_PATHS=0
}

move_live_aside() { # <name>
  local name=$1 live="$WIKI/$1" aside="$STAGE/rollback-$1"
  [ ! -L "$live" ] || return 1
  if [ -e "$aside" ] || [ -L "$aside" ]; then
    return 1
  fi
  if [ -e "$live" ]; then
    [ -d "$live" ] || return 1
    mv "$live" "$aside" || return 1
  fi
}

restore_from_backup() { # <name>
  local name=$1 live="$WIKI/$1" expected actual
  expected=$(journal_value "${name}_old") || return 1
  if [ -d "$BACKUP/$name" ]; then
    move_live_aside "$name" || return 1
    mv "$BACKUP/$name" "$live" || return 1
  elif [ "$expected" = ABSENT ]; then
    move_live_aside "$name" || return 1
  else
    [ ! -L "$live" ] && [ -d "$live" ] || return 1
    actual=$(dir_digest "$live") || return 1
    [ "$actual" = "$expected" ] || return 1
    return 0
  fi
  actual=$(dir_digest "$live") || return 1
  [ "$actual" = "$expected" ]
}

rollback_transaction() {
  local failed=0 prior_head current_head
  case "$TX_PHASE" in
    '' | committed | finished) return 0 ;;
  esac
  if [ "$TX_PHASE" = commit-intent ]; then
    prior_head=$(journal_value head 2>/dev/null || true)
    current_head=$(git -C "$VAULT" rev-parse HEAD 2>/dev/null || true)
    if [ -z "$prior_head" ] || [ -z "$current_head" ] || [ "$current_head" != "$prior_head" ]; then
      PRESERVE_TRANSACTION=1
      note "the commit-intent transaction is preserved for recovery on the next run"
      return 0
    fi
  fi
  note "rolling back the incomplete publication"
  if ! unstage_owned_paths; then
    PRESERVE_TRANSACTION=1
    note "rollback could not restore the prior clean index; preserving $BACKUP and $JOURNAL"
    return 1
  fi
  case "$TX_PHASE" in
    commit-intent | installed-reports | installed-decisions | moved-reports | moved-decisions | prepared)
      restore_from_backup decisions || failed=1
      restore_from_backup reports || failed=1
      ;;
  esac
  if [ "$failed" -ne 0 ]; then
    PRESERVE_TRANSACTION=1
    note "rollback could not restore both mirror directories; recover manually from $BACKUP and $JOURNAL"
    return 1
  fi
  if ! rm -rf "$BACKUP" 2>/dev/null; then
    PRESERVE_TRANSACTION=1
    note "rollback could not clean the transaction backup; preserving $JOURNAL"
    return 1
  fi
  if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
    PRESERVE_TRANSACTION=1
    note "rollback transaction backup remains; preserving $JOURNAL"
    return 1
  fi
  close_journal
  [ ! -L "$JOURNAL" ] || {
    PRESERVE_TRANSACTION=1
    note "rollback found a symbolic transaction journal; preserving the recovered state"
    return 1
  }
  if ! rm -f "$JOURNAL" 2>/dev/null || [ -e "$JOURNAL" ] || [ -L "$JOURNAL" ]; then
    PRESERVE_TRANSACTION=1
    note "rollback could not remove $JOURNAL; preserving the recovered state"
    return 1
  fi
  if ! rm -rf "$STAGE" 2>/dev/null || [ -e "$STAGE" ] || [ -L "$STAGE" ]; then
    note "rollback left an orphan transaction stage for the next run to clean"
    return 1
  fi
  TX_PHASE=
  return 0
}

on_exit() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    rollback_transaction || status=1
  fi
  if [ "$PRESERVE_TRANSACTION" -eq 0 ]; then
    [ -z "$STAGE" ] || rm -rf "$STAGE" 2>/dev/null || true
  fi
  close_journal
  release_lock
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- journal recovery -------------------------------------------------------

validate_journal_artifact_path() { # <run> <stage|backup> <path>
  local run=$1 kind=$2 path=$3 expected
  case "$run" in
    '' | *[!A-Za-z0-9_-]*) die 4 "journal $JOURNAL has an invalid run identifier; recover manually" ;;
  esac
  expected="$FEEDER_DIR/$kind.$run"
  [ "$path" = "$expected" ] \
    || die 4 "journal $JOURNAL records $kind path $path, expected $expected; recover manually"
  [ ! -L "$path" ] \
    || die 4 "journal $JOURNAL records a symbolic $kind path $path; recover manually"
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    die 4 "journal $JOURNAL records a non-directory $kind path $path; recover manually"
  fi
}

validate_precommit_recovery() { # <head> <stage> <backup>
  local head=$1 stage=$2 backup=$3 current_head old_decisions old_reports
  local new_decisions new_reports committed_decisions committed_reports
  local name operand live aside expected expected_new actual

  current_head=$(git -C "$VAULT" rev-parse HEAD 2>/dev/null) \
    || die 4 "vault HEAD is unreadable during pre-commit recovery; recover manually"
  [ "$current_head" = "$head" ] \
    || die 4 "vault HEAD changed after the interrupted export; recover manually without removing $JOURNAL"

  [ ! -L "$stage" ] && [ -d "$stage" ] \
    || die 4 "journal $JOURNAL has no non-symbolic stage directory for pre-commit recovery"
  [ ! -L "$backup" ] \
    || die 4 "journal $JOURNAL records a symbolic backup directory; recover manually"
  if [ -e "$backup" ] && [ ! -d "$backup" ]; then
    die 4 "journal $JOURNAL records a non-directory backup path; recover manually"
  fi

  old_decisions=$(journal_value decisions_old) \
    || die 4 "journal $JOURNAL lost its prior decision digest"
  old_reports=$(journal_value reports_old) \
    || die 4 "journal $JOURNAL lost its prior report digest"
  [ "$old_decisions" = ABSENT ] || [ "$old_decisions" = EMPTY ] || is_sha256_hex "$old_decisions" \
    || die 4 "journal $JOURNAL has an invalid prior decision digest"
  [ "$old_reports" = ABSENT ] || [ "$old_reports" = EMPTY ] || is_sha256_hex "$old_reports" \
    || die 4 "journal $JOURNAL has an invalid prior report digest"
  new_decisions=$(journal_value decisions_new) \
    || die 4 "journal $JOURNAL lost its new decision digest"
  new_reports=$(journal_value reports_new) \
    || die 4 "journal $JOURNAL lost its new report digest"
  is_sha256_hex "$new_decisions" \
    || die 4 "journal $JOURNAL has an invalid new decision digest"
  is_sha256_hex "$new_reports" \
    || die 4 "journal $JOURNAL has an invalid new report digest"
  committed_decisions=$(git_dir_digest "$current_head" wiki/decisions) \
    || die 4 "cannot verify the prior committed decision generation"
  committed_reports=$(git_dir_digest "$current_head" wiki/reports) \
    || die 4 "cannot verify the prior committed report generation"
  [ "$committed_decisions" = "$old_decisions" ] \
    || { [ "$committed_decisions" = ABSENT ] && [ "$old_decisions" = EMPTY ]; } \
    || die 4 "the recorded prior decision digest does not match vault HEAD; recover manually"
  [ "$committed_reports" = "$old_reports" ] \
    || { [ "$committed_reports" = ABSENT ] && [ "$old_reports" = EMPTY ]; } \
    || die 4 "the recorded prior report digest does not match vault HEAD; recover manually"

  # Inspect every possible restore operand before the first destructive action.
  # This also makes a corrupt second operand refuse before the first is restored.
  for name in decisions reports; do
    operand="$backup/$name"
    live="$WIKI/$name"
    [ ! -L "$operand" ] \
      || die 4 "journal $JOURNAL records a symbolic backup/$name operand; recover manually"
    if [ -e "$operand" ] && [ ! -d "$operand" ]; then
      die 4 "journal $JOURNAL records a non-directory backup/$name operand; recover manually"
    fi
    [ ! -L "$live" ] \
      || die 4 "wiki/$name became symbolic during recovery; recover manually"
    if [ -e "$live" ] && [ ! -d "$live" ]; then
      die 4 "wiki/$name is not a directory during recovery; recover manually"
    fi
    if [ "$name" = decisions ]; then
      expected=$old_decisions
      expected_new=$new_decisions
    else
      expected=$old_reports
      expected_new=$new_reports
    fi
    aside="$stage/recovery-$name"
    [ ! -L "$aside" ] \
      || die 4 "journal $JOURNAL records a symbolic recovery-$name operand; recover manually"
    if [ -e "$aside" ] && [ ! -d "$aside" ]; then
      die 4 "journal $JOURNAL records a non-directory recovery-$name operand; recover manually"
    fi
    if [ -d "$aside" ]; then
      actual=$(dir_digest "$aside") \
        || die 4 "cannot verify the saved failed $name generation before recovery"
      [ "$actual" = "$expected_new" ] \
        || die 4 "the saved failed $name generation does not match the staged generation"
      if [ -d "$operand" ] || [ "$expected" = ABSENT ]; then
        [ ! -e "$live" ] \
          || die 4 "wiki/$name and its recovery operand both exist; recover manually"
      fi
    fi
    if [ "$expected" = ABSENT ]; then
      [ ! -e "$operand" ] \
        || die 4 "wiki/$name was absent before the run but has an unexpected backup operand"
      if [ -d "$live" ]; then
        actual=$(dir_digest "$live") \
          || die 4 "cannot verify wiki/$name before recovery"
        [ "$actual" = ABSENT ] || [ "$actual" = "$expected_new" ] \
          || die 4 "wiki/$name matches neither the absent prior state nor the staged generation"
      fi
      continue
    fi
    if [ -d "$operand" ]; then
      actual=$(dir_digest "$operand") \
        || die 4 "cannot verify the prior $name generation before recovery"
      [ "$actual" = "$expected" ] \
        || die 4 "the recoverable $name operand does not match the prior committed generation"
      if [ -d "$live" ]; then
        actual=$(dir_digest "$live") \
          || die 4 "cannot verify live wiki/$name before recovery"
        [ "$actual" = "$expected_new" ] \
          || die 4 "live wiki/$name does not match the staged generation; recover manually"
      fi
    elif [ -d "$live" ]; then
      actual=$(dir_digest "$live") \
        || die 4 "cannot verify the prior $name generation before recovery"
      [ "$actual" = "$expected" ] \
        || die 4 "the recoverable $name operand does not match the prior committed generation"
    else
      die 4 "wiki/$name is missing and has no backup in $backup; recover manually"
    fi
  done
}

recover_journal() {
  local version run head phase stage backup
  version=$(journal_value version) || die 4 "journal $JOURNAL has no version; recover manually and remove it"
  [ "$version" = 1 ] || die 4 "journal $JOURNAL declares version $version, which this exporter cannot recover"
  run=$(journal_value run) || die 4 "journal $JOURNAL has no run identifier; recover manually"
  head=$(journal_value head) || die 4 "journal $JOURNAL has no prior HEAD; recover manually"
  phase=$(journal_value phase) || die 4 "journal $JOURNAL has no phase; recover manually"
  stage=$(journal_value stage) || die 4 "journal $JOURNAL has no stage path; recover manually"
  backup=$(journal_value backup) || die 4 "journal $JOURNAL has no backup path; recover manually"
  validate_journal_artifact_path "$run" stage "$stage"
  validate_journal_artifact_path "$run" backup "$backup"
  note "recovering interrupted export run $run from phase $phase"

  if [ "$phase" = commit-intent ]; then
    local intent_head intent_decisions intent_reports
    intent_head=$(git -C "$VAULT" rev-parse HEAD 2>/dev/null) \
      || die 4 "vault HEAD is unreadable while recovering run $run"
    if [ "$intent_head" = "$head" ]; then
      phase=installed-reports
    else
      intent_decisions=$(journal_value decisions_new) \
        || die 4 "journal $JOURNAL lost its expected decision digest"
      intent_reports=$(journal_value reports_new) \
        || die 4 "journal $JOURNAL lost its expected report digest"
      verify_commit_contents "$head" "$intent_head" "$intent_decisions" "$intent_reports" \
        || die 4 "vault HEAD does not contain the direct committed generation for run $run; recover manually"
      journal_append "committed_head=$intent_head" "phase=committed"
      phase=committed
    fi
  fi

  case "$phase" in
    committed)
      local committed_head current_head expect_decisions expect_reports
      committed_head=$(journal_value committed_head) \
        || die 4 "journal $JOURNAL records the committed phase without a commit; recover manually"
      current_head=$(git -C "$VAULT" rev-parse HEAD 2>/dev/null) \
        || die 4 "vault HEAD is unreadable while recovering run $run"
      [ "$current_head" = "$committed_head" ] \
        || die 4 "vault HEAD $current_head does not match the committed run $run ($committed_head); recover manually"
      expect_decisions=$(journal_value decisions_new) || die 4 "journal $JOURNAL lost its expected decision digest"
      expect_reports=$(journal_value reports_new) || die 4 "journal $JOURNAL lost its expected report digest"
      verify_commit_contents "$head" "$committed_head" "$expect_decisions" "$expect_reports" \
        || die 4 "the committed Git tree or HEAD lineage does not match run $run; recover manually"
      [ "$(dir_digest "$DECISIONS_LIVE")" = "$expect_decisions" ] \
        || die 4 "wiki/decisions does not match committed run $run; recover manually from $backup"
      [ "$(dir_digest "$REPORTS_LIVE")" = "$expect_reports" ] \
        || die 4 "wiki/reports does not match committed run $run; recover manually from $backup"
      rm -rf "$backup" "$stage" 2>/dev/null \
        || die 4 "cannot clean committed recovery artifacts; preserving $JOURNAL for retry"
      [ ! -e "$backup" ] && [ ! -L "$backup" ] && [ ! -e "$stage" ] && [ ! -L "$stage" ] \
        || die 4 "committed recovery artifacts remain; preserving $JOURNAL for retry"
      rm -f "$JOURNAL" \
        || die 4 "cannot remove the committed recovery journal; retry after checking $JOURNAL"
      [ ! -e "$JOURNAL" ] && [ ! -L "$JOURNAL" ] \
        || die 4 "the committed recovery journal remains; retry after checking $JOURNAL"
      PUSH_DECISIONS_DIGEST=$expect_decisions
      PUSH_REPORTS_DIGEST=$expect_reports
      note "recovered committed run $run; its commit still needs a push"
      RECOVERED_COMMITTED=1
      ;;
    prepared | moved-decisions | moved-reports | installed-decisions | installed-reports)
      local name live expected aside actual
      validate_precommit_recovery "$head" "$stage" "$backup"
      git -C "$VAULT" reset -q HEAD -- wiki/decisions wiki/reports > /dev/null 2>&1 \
        || die 4 "cannot restore the prior clean index; preserving $backup and $JOURNAL for recovery"
      for name in decisions reports; do
        live="$WIKI/$name"
        expected=$(journal_value "${name}_old") \
          || die 4 "journal $JOURNAL lost its prior $name digest"
        if [ -d "$backup/$name" ]; then
          aside="$stage/recovery-$name"
          if [ ! -d "$aside" ]; then
            if [ -e "$live" ]; then
              [ ! -L "$live" ] && [ -d "$live" ] \
                || die 4 "wiki/$name is not a safe directory during recovery"
              mv "$live" "$aside" \
                || die 4 "cannot move the failed wiki/$name generation aside during recovery"
            fi
          fi
          mv "$backup/$name" "$live" \
            || die 4 "cannot restore wiki/$name from $backup during recovery of run $run"
        elif [ "$expected" = ABSENT ]; then
          aside="$stage/recovery-$name"
          if [ ! -d "$aside" ]; then
            if [ -e "$live" ]; then
              [ ! -L "$live" ] && [ -d "$live" ] \
                || die 4 "wiki/$name is not a safe directory during recovery"
              mv "$live" "$aside" \
                || die 4 "cannot move the failed wiki/$name generation aside during recovery"
            fi
          fi
        elif [ ! -d "$live" ]; then
          die 4 "wiki/$name is missing and has no backup in $backup; recover manually"
        fi
        actual=$(dir_digest "$live") \
          || die 4 "cannot verify restored wiki/$name during recovery"
        [ "$actual" = "$expected" ] \
          || die 4 "restored wiki/$name does not match its prior generation; recover manually"
      done
      rm -rf "$backup" 2>/dev/null \
        || die 4 "cannot clean the recovered transaction backup; preserving $JOURNAL for retry"
      [ ! -e "$backup" ] && [ ! -L "$backup" ] \
        || die 4 "the recovered transaction backup remains; preserving $JOURNAL for retry"
      rm -f "$JOURNAL" \
        || die 4 "cannot remove the recovered transaction journal; retry after checking $JOURNAL"
      [ ! -e "$JOURNAL" ] && [ ! -L "$JOURNAL" ] \
        || die 4 "the recovered transaction journal remains; retry after checking $JOURNAL"
      rm -rf "$stage" 2>/dev/null \
        || die 4 "cannot clean the orphan transaction stage; retry the export"
      [ ! -e "$stage" ] && [ ! -L "$stage" ] \
        || die 4 "the orphan transaction stage remains; retry the export"
      if [ -n "$(git -C "$VAULT" status --porcelain 2>/dev/null | head -1)" ]; then
        die 4 "the vault is still dirty after recovering run $run; inspect it with: git -C $VAULT status"
      fi
      note "recovered run $run to its prior generation"
      ;;
    *)
      die 4 "journal $JOURNAL records unknown phase '$phase'; recover manually"
      ;;
  esac
}

RECOVERED_COMMITTED=0
STALE_BACKUPS=

find_transaction_artifacts() { # <name-pattern>
  LC_ALL=C find "$FEEDER_DIR" -maxdepth 1 -mindepth 1 -name "$1" -print 2>/dev/null
}

recover_prior_state() {
  local stale_stage stale_stages
  if [ -e "$JOURNAL" ]; then
    [ ! -L "$JOURNAL" ] || die 4 "journal path $JOURNAL must not be a symlink"
    [ -f "$JOURNAL" ] || die 4 "journal path $JOURNAL is not a regular file"
    recover_journal
  fi

  # A backup with no journal is unexplained transaction state, so it refuses.
  # An orphan stage holds no live generation and this run owns the lock, so it
  # is ordinary debris and is cleared.
  STALE_BACKUPS=$(find_transaction_artifacts 'backup.*') \
    || die 4 "cannot enumerate transaction backups; inspect $FEEDER_DIR before retrying"
  if [ -n "$STALE_BACKUPS" ]; then
    note "backup artifacts remain with no journal:"
    printf '%s\n' "$STALE_BACKUPS" | LC_ALL=C sort | sed -n '1,5p' >&2
    die 4 "remove those directories after confirming wiki/decisions and wiki/reports are intact, then rerun"
  fi
  stale_stages=$(find_transaction_artifacts 'stage.*') \
    || die 4 "cannot enumerate transaction stages; inspect $FEEDER_DIR before retrying"
  while IFS= read -r stale_stage; do
    [ -n "$stale_stage" ] || continue
    [ ! -L "$stale_stage" ] \
      || die 4 "orphan stage path $stale_stage is symbolic; remove only the link after inspection"
    [ -d "$stale_stage" ] \
      || die 4 "orphan stage path $stale_stage is not a directory; inspect it before removal"
    rm -rf "$stale_stage" \
      || die 4 "cannot remove orphan stage directory $stale_stage; inspect it before retrying"
  done <<EOF
$stale_stages
EOF
}

# --- remote identity and privacy --------------------------------------------

repository_identity_from_url() { # <url>
  local url=$1 id
  case "$url" in
    git@github.com:*) id=${url#git@github.com:} ;;
    ssh://git@github.com/*) id=${url#ssh://git@github.com/} ;;
    https://github.com/*) id=${url#https://github.com/} ;;
    *) return 1 ;;
  esac
  id=${id%.git}
  id=${id%/}
  printf '%s\n' "$id"
}

# The pinned identity is part of destructive authority, so it is checked in
# preflight as well as immediately before every push.
verify_remote_matches_marker() {
  local urls url_count url id pushurls pushurl_count processed effective effective_count
  urls=$(git -C "$VAULT" config --get-all "remote.$REMOTE_NAME.url" 2>/dev/null) \
    || die 1 "vault has no '$REMOTE_NAME' remote"
  url_count=$(git -C "$VAULT" config --get-all "remote.$REMOTE_NAME.url" 2>/dev/null \
    | LC_ALL=C awk 'END { print NR + 0 }')
  [ "$url_count" -eq 1 ] \
    || die 1 "vault remote '$REMOTE_NAME' must have exactly one fetch URL"
  url=$(printf '%s\n' "$urls" | sed -n '1p')
  [ -n "$url" ] || die 1 "vault remote '$REMOTE_NAME' has an empty fetch URL"
  id=$(repository_identity_from_url "$url") \
    || die 1 "vault remote '$REMOTE_NAME' is not a GitHub repository URL"
  [ "$id" = "$MARKER_REMOTE" ] \
    || die 1 "vault remote '$REMOTE_NAME' does not match the marker repository $MARKER_REMOTE"

  pushurl_count=$(git -C "$VAULT" config --get-all "remote.$REMOTE_NAME.pushurl" 2>/dev/null \
    | LC_ALL=C awk 'END { print NR + 0 }') || pushurl_count=0
  if [ "$pushurl_count" -eq 0 ]; then
    pushurls=$url
    pushurl_count=1
  else
    pushurls=$(git -C "$VAULT" config --get-all "remote.$REMOTE_NAME.pushurl" 2>/dev/null) \
      || die 1 "cannot inspect vault remote '$REMOTE_NAME' push destinations"
  fi
  processed=0
  while IFS= read -r url; do
    processed=$((processed + 1))
    [ -n "$url" ] || die 1 "vault remote '$REMOTE_NAME' has an empty push URL"
    id=$(repository_identity_from_url "$url") \
      || die 1 "vault remote '$REMOTE_NAME' has a non-GitHub push destination"
    [ "$id" = "$MARKER_REMOTE" ] \
      || die 1 "vault remote '$REMOTE_NAME' has a push destination that does not match $MARKER_REMOTE"
  done <<EOF
$pushurls
EOF
  [ "$processed" -eq "$pushurl_count" ] \
    || die 1 "vault remote '$REMOTE_NAME' has an empty push URL"

  effective=$(git -C "$VAULT" remote get-url --push --all "$REMOTE_NAME" 2>/dev/null) \
    || die 1 "cannot resolve vault remote '$REMOTE_NAME' effective push destinations"
  effective_count=$(git -C "$VAULT" remote get-url --push --all "$REMOTE_NAME" 2>/dev/null \
    | LC_ALL=C awk 'END { print NR + 0 }')
  [ "$effective_count" -gt 0 ] \
    || die 1 "vault remote '$REMOTE_NAME' has no effective push destination"
  processed=0
  while IFS= read -r url; do
    processed=$((processed + 1))
    [ -n "$url" ] || die 1 "vault remote '$REMOTE_NAME' has an empty effective push destination"
    id=$(repository_identity_from_url "$url") \
      || die 1 "vault remote '$REMOTE_NAME' resolves to a non-GitHub push destination"
    [ "$id" = "$MARKER_REMOTE" ] \
      || die 1 "vault remote '$REMOTE_NAME' resolves to an effective push destination that does not match $MARKER_REMOTE"
  done <<EOF
$effective
EOF
  [ "$processed" -eq "$effective_count" ] \
    || die 1 "vault remote '$REMOTE_NAME' has an empty effective push destination"
}

verify_branch_and_upstream() {
  local branch upstream
  branch=$(git -C "$VAULT" symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || die 1 "vault HEAD is detached; refusing to publish"
  [ "$branch" = "$EXPECTED_BRANCH" ] \
    || die 1 "vault branch '$branch' is not the required branch '$EXPECTED_BRANCH'"
  upstream=$(git -C "$VAULT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
    || die 1 "vault branch '$branch' has no upstream; set one before exporting"
  [ "$upstream" = "$REMOTE_NAME/$EXPECTED_BRANCH" ] \
    || die 1 "vault branch '$branch' tracks '$upstream', not '$REMOTE_NAME/$EXPECTED_BRANCH'"
}

assert_clean_vault() {
  local status
  status=$(git -C "$VAULT" status --porcelain 2>/dev/null) \
    || die 1 "cannot inspect the vault worktree and index"
  if [ -n "$status" ]; then
    note "the vault worktree or index is dirty:"
    git -C "$VAULT" status --short >&2 || true
    die 1 "refusing to publish into a dirty vault; commit or discard those changes first"
  fi
}

assert_no_symbolic_owned_paths() {
  local tree links
  for tree in "$DECISIONS_LIVE" "$REPORTS_LIVE"; do
    [ ! -L "$tree" ] || die 1 "owned tree $tree must not be a symlink"
    [ -e "$tree" ] || continue
    [ -d "$tree" ] || die 1 "owned tree $tree is not a directory"
    if ! links=$(LC_ALL=C find "$tree" -type l -print 2>/dev/null); then
      die 1 "cannot inspect symbolic paths under owned tree $tree"
    fi
    [ -z "$links" ] || die 1 "owned tree $tree contains a symbolic path"
  done
}

verify_remote_is_pinned_and_private() {
  local output visibility visibility_count
  verify_remote_matches_marker
  command -v gh-axi > /dev/null 2>&1 \
    || die 1 "gh-axi is unavailable, so the private-visibility check cannot run; refusing to push"
  output=$(gh-axi repo view "$MARKER_REMOTE" 2>/dev/null) \
    || die 1 "cannot read $MARKER_REMOTE visibility; refusing to push"
  visibility_count=$(printf '%s\n' "$output" \
    | LC_ALL=C awk -F: '/^[[:space:]]*visibility:[[:space:]]*/ { count++ } END { print count + 0 }')
  [ "$visibility_count" -ne 0 ] \
    || die 1 "$MARKER_REMOTE reported no visibility field; refusing to push"
  [ "$visibility_count" -eq 1 ] \
    || die 1 "$MARKER_REMOTE reported ambiguous visibility fields; refusing to push"
  visibility=$(printf '%s\n' "$output" \
    | LC_ALL=C awk -F: '/^[[:space:]]*visibility:[[:space:]]*/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 }')
  [ "$visibility" = private ] \
    || die 1 "$MARKER_REMOTE is $visibility, not private; refusing to push"
}

# --- source discovery -------------------------------------------------------

MANIFEST=
CANDIDATE_LIST=
EXCLUDED_DECISIONS=0
EXCLUDED_REPORTS=0

is_excluded() { # <sot-path>
  local rc
  [ -s "$EXCLUDE_LIST" ] || return 1
  if LC_ALL=C grep -Fxq -- "$1" "$EXCLUDE_LIST"; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] && return 1
  die 1 "cannot look up feeder exclusions; refusing to publish"
}

load_excludes() {
  local line trimmed count seen record rc
  : > "$EXCLUDE_LIST"
  [ ! -L "$EXCLUDES_CONFIG" ] || die 1 "exclusion file $EXCLUDES_CONFIG must not be a symlink"
  [ -e "$EXCLUDES_CONFIG" ] || return 0
  [ -f "$EXCLUDES_CONFIG" ] || die 1 "exclusion file $EXCLUDES_CONFIG must be a regular file"
  assert_no_nul_bytes "$EXCLUDES_CONFIG" "exclusion file $EXCLUDES_CONFIG"
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$line
    case "$trimmed" in
      '' | '#'*) continue ;;
    esac
    if has_control_chars "$trimmed"; then
      die 1 "exclusion entry has control characters"
    fi
    case "$trimmed" in
      *'*'* | *'?'* | *'['* | *']'*) die 1 "exclusion entry '$trimmed' looks like a glob; exact paths only" ;;
      /*) die 1 "exclusion entry '$trimmed' must be relative to the home, not absolute" ;;
      *'//'*) die 1 "exclusion entry '$trimmed' is not normalized" ;;
    esac
    case "/$trimmed/" in
      */../*) die 1 "exclusion entry '$trimmed' must not contain a '..' path component" ;;
      */./*) die 1 "exclusion entry '$trimmed' must not contain a '.' path component" ;;
    esac
    case "$trimmed" in
      data/decisions/*.md)
        record=${trimmed#data/decisions/}
        case "$record" in '' | .md | */*) die 1 "exclusion entry '$trimmed' is not a decision record" ;; esac
        ;;
      data/*/report.md)
        record=${trimmed#data/}
        record=${record%/report.md}
        case "$record" in '' | */*) die 1 "exclusion entry '$trimmed' is not a report record" ;; esac
        ;;
      *) die 1 "exclusion entry '$trimmed' matches neither data/decisions/*.md nor data/*/report.md" ;;
    esac
    if seen=$(LC_ALL=C grep -Fxc -- "$trimmed" "$EXCLUDE_LIST" 2>/dev/null); then
      :
    else
      rc=$?
      [ "$rc" -eq 1 ] || die 1 "cannot inspect feeder exclusions; refusing to publish"
    fi
    [ "${seen:-0}" -eq 0 ] || die 1 "exclusion entry '$trimmed' is listed more than once"
    printf '%s\n' "$trimmed" >> "$EXCLUDE_LIST"
  done < "$EXCLUDES_CONFIG"
  count=$(LC_ALL=C awk 'END {print NR}' "$EXCLUDE_LIST")
  [ "$count" -gt 0 ] || return 0
  while IFS= read -r line; do
    [ -e "$FM_HOME/$line" ] \
      || die 1 "exclusion entry '$line' names no current source record"
    LC_ALL=C grep -Fxq -- "$line" "$CANDIDATE_LIST" \
      || die 1 "exclusion entry '$line' is not in the selected source set"
  done < "$EXCLUDE_LIST"
}

discover_candidates() { # [output-file]
  local file parent output=${1:-$CANDIDATE_LIST}
  local decision_sources="$output.decisions" report_sources="$output.reports" symbolic_parents="$output.symbolic-parents"
  [ ! -L "$DATA/decisions" ] || die 1 "source directory data/decisions must not be a symbolic link"
  [ -d "$DATA/decisions" ] || die 1 "source directory data/decisions is not a directory"
  : > "$output"
  LC_ALL=C find "$DATA/decisions" -mindepth 1 -maxdepth 1 -name '*.md' -print0 > "$decision_sources" 2>/dev/null \
    || die 1 "cannot enumerate decision sources"
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -name report.md -print0 > "$report_sources" 2>/dev/null \
    || die 1 "cannot enumerate report sources"
  LC_ALL=C find "$DATA" -mindepth 1 -maxdepth 1 -type l -print0 > "$symbolic_parents" 2>/dev/null \
    || die 1 "cannot enumerate symbolic source directories"
  while IFS= read -r -d '' parent; do
    file="$parent/report.md"
    if [ -e "$file" ] || [ -L "$file" ]; then
      printf '%s\0' "$file" >> "$report_sources"
    fi
  done < "$symbolic_parents"
  while IFS= read -r -d '' file; do
    if has_control_chars "$file"; then die 1 "a decision source path contains control characters"; fi
    printf 'data/decisions/%s\n' "$(basename "$file")" >> "$output"
  done < "$decision_sources"
  while IFS= read -r -d '' file; do
    if has_control_chars "$file"; then die 1 "a report source path contains control characters"; fi
    printf 'data/%s/report.md\n' "$(basename "$(dirname "$file")")" >> "$output"
  done < "$report_sources"
  LC_ALL=C sort -u -o "$output" "$output"
}

validate_identifier() { # <identifier> <label>
  local id=$1 label=$2 lower portable_base
  case "$id" in
    _index) die 1 "$label '$id' is the reserved index name" ;;
  esac
  lower=$(printf '%s' "$id" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  [ "$lower" != _index ] \
    || die 1 "$label '$id' collides with the generated _index page after case-folding"
  case "$id" in
    [A-Za-z0-9]*) ;;
    *) die 1 "$label '$id' must start with an ASCII letter or digit" ;;
  esac
  case "$id" in
    *[!A-Za-z0-9._-]*) die 1 "$label '$id' must match ^[A-Za-z0-9][A-Za-z0-9._-]*$" ;;
  esac
  case "$id" in
    *.) die 1 "$label '$id' is not a portable destination basename" ;;
  esac
  portable_base=${lower%%.*}
  case "$portable_base" in
    con | prn | aux | nul | com[1-9] | lpt[1-9])
      die 1 "$label '$id' is a reserved portable destination basename"
      ;;
  esac
}

# One manifest row per included record:
#   <kind> TAB <sot_path> TAB <physical> TAB <dest_id>
build_manifest() {
  local file sot id physical identity rel lower dup
  : > "$MANIFEST"
  : > "$COLLISION_LIST"
  while IFS= read -r -d '' file; do
    id=$(basename "$file" .md)
    sot="data/decisions/$(basename "$file")"
    if is_excluded "$sot"; then
      EXCLUDED_DECISIONS=$((EXCLUDED_DECISIONS + 1))
      continue
    fi
    validate_identifier "$id" 'decision name'
    [ ! -L "$file" ] || die 1 "source $sot must not be a symbolic link"
    physical=$(canonical_regular_file "$file") \
      || die 1 "source $sot does not resolve to a regular file"
    case "$physical" in
      "$DATA_PHYSICAL"/*) ;;
      *) die 1 "source $sot resolves to $physical, outside $DATA_PHYSICAL" ;;
    esac
    identity=$(path_identity "$physical") || die 1 "cannot identify source $sot"
    printf 'decision\t%s\t%s\t%s\t%s\n' "$sot" "$physical" "$id" "$identity" >> "$MANIFEST"
  done < "$CANDIDATE_LIST.decisions"
  while IFS= read -r -d '' file; do
    rel=$(basename "$(dirname "$file")")
    sot="data/$rel/report.md"
    if is_excluded "$sot"; then
      EXCLUDED_REPORTS=$((EXCLUDED_REPORTS + 1))
      continue
    fi
    validate_identifier "$rel" 'report task identifier'
    [ ! -L "$(dirname "$file")" ] \
      || die 1 "source directory data/$rel must not be a symbolic link"
    physical=$(canonical_regular_file "$file") \
      || die 1 "source $sot does not resolve to a regular file"
    case "$physical" in
      "$DATA_PHYSICAL"/*) ;;
      *) die 1 "source $sot resolves to $physical, outside $DATA_PHYSICAL" ;;
    esac
    identity=$(path_identity "$physical") || die 1 "cannot identify source $sot"
    printf 'report\t%s\t%s\t%s\t%s\n' "$sot" "$physical" "$rel" "$identity" >> "$MANIFEST"
  done < "$CANDIDATE_LIST.reports"

  # Refuse duplicate and case-folded destination collisions, including each
  # generated index, before any destination write.
  {
    LC_ALL=C awk -F'\t' '{ print $1 "/" tolower($4) }' "$MANIFEST"
    printf 'decision/_index\nreport/_index\n'
  } | LC_ALL=C sort > "$COLLISION_LIST"
  dup=$(LC_ALL=C uniq -d < "$COLLISION_LIST" | head -1)
  if [ -n "$dup" ]; then
    lower=${dup#*/}
    die 1 "destination '${dup%%/*}s/$lower' is claimed by more than one source; refusing every colliding record"
  fi
}

# --- snapshot, secrets, dates, rendering ------------------------------------

OPENAI_SECRET='sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,255}'
SECRET_COMBINED="-----BEGIN ((RSA|EC|DSA|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{20,255}|(AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,255}|[sr]k_live_[A-Za-z0-9]{16,255}|AIza[A-Za-z0-9_-]{35}|$OPENAI_SECRET"

secret_pattern_matches() { # <extended-regexp> <file>
  local rc
  if LC_ALL=C grep -Eq -- "$1" "$2" 2>/dev/null; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] && return 1
  die 1 "credential scan failed while reading staged content; refusing to publish"
}

secret_text_matches() { # <text>
  local rc
  if printf '%s\n' "$1" | LC_ALL=C grep -Eq -- "$SECRET_COMBINED" 2>/dev/null; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] && return 1
  die 1 "credential scan failed while checking a source label; refusing to publish"
}

secret_class_of() { # <file>; prints the first matching class name
  local file=$1
  if secret_pattern_matches '-----BEGIN ((RSA|EC|DSA|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----' "$file"; then
    printf '%s\n' private-key
    return 0
  fi
  if secret_pattern_matches 'gh[pousr]_[A-Za-z0-9]{36,255}' "$file"; then
    printf '%s\n' github-classic-token
    return 0
  fi
  if secret_pattern_matches 'github_pat_[A-Za-z0-9_]{20,255}' "$file"; then
    printf '%s\n' github-fine-grained-token
    return 0
  fi
  if secret_pattern_matches '(AKIA|ASIA)[A-Z0-9]{16}' "$file"; then
    printf '%s\n' aws-access-key-id
    return 0
  fi
  if secret_pattern_matches 'xox[baprs]-[A-Za-z0-9-]{10,255}' "$file"; then
    printf '%s\n' slack-token
    return 0
  fi
  if secret_pattern_matches '[sr]k_live_[A-Za-z0-9]{16,255}' "$file"; then
    printf '%s\n' stripe-live-key
    return 0
  fi
  if secret_pattern_matches 'AIza[A-Za-z0-9_-]{35}' "$file"; then
    printf '%s\n' google-api-key
    return 0
  fi
  if secret_pattern_matches "$OPENAI_SECRET" "$file"; then
    printf '%s\n' openai-key
    return 0
  fi
  printf 'unclassified\n'
}

# Resolve a staged file back to the logical record it came from, so a refusal
# names data/... rather than a transient stage path.
logical_label_for() { # <staged-path>
  local path=$1 base kind id
  base=$(basename "$path")
  case "$path" in
    "$STAGE"/snapshot/*)
      kind=${base%%.*}
      id=${base#*.}
      ;;
    "$STAGE"/decisions/*)
      kind=decision
      id=${base%.md}
      ;;
    "$STAGE"/reports/*)
      kind=report
      id=${base%.md}
      ;;
    *)
      printf '%s\n' "$base"
      return 0
      ;;
  esac
  if [ "$id" = _index ]; then
    printf 'the generated %s index\n' "$kind"
    return 0
  fi
  LC_ALL=C awk -F'\t' -v kind="$kind" -v id="$id" \
    '$1 == kind && $4 == id { print $2; found = 1; exit } END { if (!found) print kind "/" id }' "$MANIFEST"
}

# One scan pass over a whole staged tree. Running grep once per file costs a
# process per record on a corpus of this size, so the scan is batched; it still
# happens before any live mutation, which is the boundary that matters.
scan_tree_for_secrets() { # <dir>...
  local hit class label hits sorted rc
  hits="$STAGE/secret-scan-hits"
  sorted="$STAGE/secret-scan-hits.sorted"
  exec 4> "$hits" \
    || die 1 "credential scan could not create its hits file; refusing to publish"
  if LC_ALL=C grep -REl -- "$SECRET_COMBINED" "$@" >&4 2>/dev/null; then
    :
  else
    rc=$?
    if [ "$rc" -ne 1 ]; then
      exec 4>&- || true
      die 1 "credential scan failed while reading staged content; refusing to publish"
    fi
  fi
  exec 4>&- \
    || die 1 "credential scan could not close its hits file; refusing to publish"
  LC_ALL=C sort -o "$sorted" "$hits" \
    || die 1 "credential scan failed while sorting staged content; refusing to publish"
  hit=$(sed -n '1p' "$sorted") \
    || die 1 "credential scan failed while reading its sorted hits; refusing to publish"
  [ -n "$hit" ] || return 0
  class=$(secret_class_of "$hit")
  label=$(logical_label_for "$hit")
  if secret_text_matches "$label"; then
    label='[credential-shaped source path redacted]'
  fi
  die 1 "refusing to publish: $label matches the $class credential pattern"
}

assert_text_payload() { # <file> <logical-label>
  local size stripped
  size=$(LC_ALL=C wc -c < "$1" | tr -d ' ')
  stripped=$(LC_ALL=C tr -d '\000' < "$1" | LC_ALL=C wc -c | tr -d ' ')
  [ "$size" = "$stripped" ] || die 1 "$2 contains NUL bytes; the mirror carries UTF-8 text only"
  if command -v iconv > /dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8 -- "$1" > /dev/null 2>&1 || die 1 "$2 is not valid UTF-8"
  elif command -v python3 > /dev/null 2>&1; then
    python3 -c 'import sys; open(sys.argv[1], encoding="utf-8").read()' "$1" > /dev/null 2>&1 \
      || die 1 "$2 is not valid UTF-8"
  else
    die 1 "no UTF-8 validator available; install iconv or python3"
  fi
}

extract_title() { # <snapshot-file>
  LC_ALL=C awk '
    {
      line = $0
      sub(/\r$/, "", line)
      indent = 0
      while (indent < 4 && substr(line, indent + 1, 1) == " ") indent++
      if (indent > 3 || substr(line, indent + 1, 1) != "#") next
      n = 0
      while (substr(line, indent + n + 1, 1) == "#") n++
      if (n > 6) next
      rest = substr(line, indent + n + 1)
      if (rest !~ /^[ \t]/) next
      sub(/^[ \t]+/, "", rest)
      if (rest ~ /[ \t]+#+[ \t]*$/) sub(/[ \t]+#+[ \t]*$/, "", rest)
      sub(/[ \t]+$/, "", rest)
      if (rest == "") next
      print rest
      exit
    }
  ' "$1"
}

# The tracked-source set is read once, because `git log -- <path>` walks the
# whole history per path and the private records are normally untracked.
load_tracked_sources() {
  : > "$TRACKED_LIST"
  [ "$HOME_IS_GIT" -eq 1 ] || return 0
  git -C "$FM_HOME" ls-files -- 'data/decisions/*.md' 'data/*/report.md' > "$TRACKED_LIST" 2>/dev/null \
    || die 1 "cannot enumerate tracked feeder sources"
}

detect_home_git() {
  local result
  if result=$(git -C "$FM_HOME" rev-parse --git-dir 2>&1); then
    HOME_IS_GIT=1
  else
    case "$result" in
      'fatal: not a git repository'*) HOME_IS_GIT=0; return 0 ;;
      *) die 1 "cannot inspect source-home Git metadata" ;;
    esac
  fi
  if HOME_GIT_HEAD=$(git -C "$FM_HOME" rev-parse --verify HEAD 2>/dev/null); then
    return 0
  fi
  if git -C "$FM_HOME" symbolic-ref -q HEAD > /dev/null 2>&1; then
    HOME_GIT_HEAD=
    return 0
  fi
  die 1 "cannot resolve source-home Git history"
}

git_tracked_source() { # <sot-path>
  local rc
  [ -f "$TRACKED_LIST" ] || die 1 "cannot look up tracked feeder sources; refusing to publish"
  [ -s "$TRACKED_LIST" ] || return 1
  if LC_ALL=C grep -Fxq -- "$1" "$TRACKED_LIST"; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] && return 1
  die 1 "cannot look up tracked feeder sources; refusing to publish"
}

git_source_date() { # <sot-path> <first|last>
  local sot=$1 which=$2 value
  [ "$HOME_IS_GIT" -eq 1 ] || return 1
  [ -n "$HOME_GIT_HEAD" ] || return 1
  if [ "$which" = first ]; then
    value=$(TZ=UTC git -C "$FM_HOME" log --reverse --diff-filter=A \
      --format=%ad --date=format-local:%Y-%m-%d "$HOME_GIT_HEAD" -- "$sot" 2>/dev/null) || return 2
    value=${value%%$'\n'*}
  else
    value=$(TZ=UTC git -C "$FM_HOME" log --format=%ad --date=format-local:%Y-%m-%d -1 \
      "$HOME_GIT_HEAD" -- "$sot" 2>/dev/null) || return 2
  fi
  [ -n "$value" ] || return 1
  is_iso_date "$value" || return 2
  printf '%s\n' "$value"
}

git_source_matches_snapshot() { # <sot-path> <snapshot>
  local sot=$1 snapshot=$2 paths blob="$STAGE/git-source-blob" rc
  [ -n "$HOME_GIT_HEAD" ] || return 1
  paths=$(git -C "$FM_HOME" ls-tree -r --name-only "$HOME_GIT_HEAD" -- "$sot" 2>/dev/null) \
    || return 2
  [ -n "$paths" ] || return 1
  [ "$paths" = "$sot" ] || return 2
  git -C "$FM_HOME" cat-file blob "$HOME_GIT_HEAD:$sot" > "$blob" 2>/dev/null \
    || return 2
  if cmp -s "$blob" "$snapshot"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$blob"
  [ "$rc" -le 1 ] || return 2
  return "$rc"
}

created_date_for() { # <kind> <sot-path> <physical> <dest-id> <snapshot-mtime>
  local kind=$1 sot=$2 physical=$3 id=$4 snapshot_mtime=$5 value suffix epoch rc
  if git_tracked_source "$sot"; then
    if value=$(git_source_date "$sot" first); then
      printf '%s\n' "$value"
      return 0
    else
      rc=$?
      [ "$rc" -eq 1 ] || return "$rc"
    fi
  fi
  if [ "$kind" = decision ] && [ "${#id}" -ge 10 ]; then
    suffix=${id: -10}
    if is_iso_date "$suffix" \
      && { [ "${#id}" -eq 10 ] || [ "${id:$((${#id} - 11)):1}" = - ]; }; then
      printf '%s\n' "$suffix"
      return 0
    fi
  fi
  if epoch=$(path_birth "$physical"); then
    if value=$(epoch_to_utc_date "$epoch") && is_iso_date "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  epoch=$snapshot_mtime
  value=$(epoch_to_utc_date "$epoch") || return 1
  is_iso_date "$value" || return 1
  printf '%s\n' "$value"
}

updated_date_for() { # <sot-path> <snapshot> <snapshot-mtime>
  local sot=$1 snapshot=$2 snapshot_mtime=$3 value epoch rc
  if git_tracked_source "$sot"; then
    if git_source_matches_snapshot "$sot" "$snapshot"; then
      if value=$(git_source_date "$sot" last); then
        printf '%s\n' "$value"
        return 0
      else
        rc=$?
        [ "$rc" -eq 1 ] || return "$rc"
      fi
    else
      rc=$?
      [ "$rc" -eq 1 ] || return "$rc"
    fi
  fi
  epoch=$snapshot_mtime
  value=$(epoch_to_utc_date "$epoch") || return 1
  is_iso_date "$value" || return 1
  printf '%s\n' "$value"
}

render_page() { # <out> <title> <tag> <created> <updated> <sot> <sha> <snapshot>
  local out=$1 title=$2 tag=$3 created=$4 updated=$5 sot=$6 sha=$7 snapshot=$8
  {
    printf -- '---\n'
    yaml_squote "$title"
    printf 'title: %s\n' "$YAML_SCALAR"
    printf 'type: feeder-mirror\n'
    printf 'status: evergreen\n'
    printf 'created: %s\n' "$created"
    printf 'updated: %s\n' "$updated"
    printf 'tags: [feeder, %s]\n' "$tag"
    yaml_squote "$sot"
    printf 'sot_path: %s\n' "$YAML_SCALAR"
    printf 'sot_sha256: %s\n' "$sha"
    printf -- '---\n'
    printf '%s\n' "$BANNER"
    printf '\n'
    cat "$snapshot"
  } > "$out"
}

render_index() { # <out> <title> <record-tag> <page-list> <excluded-count>
  local out=$1 title=$2 record=$3 list=$4 excluded=$5 created updated
  if [ -s "$list" ]; then
    created=$(LC_ALL=C awk -F'\t' '{print $2}' "$list" | LC_ALL=C sort | head -1)
    updated=$(LC_ALL=C awk -F'\t' '{print $3}' "$list" | LC_ALL=C sort | tail -1)
  else
    created=$EMPTY_INDEX_DATE
    updated=$EMPTY_INDEX_DATE
  fi
  {
    printf -- '---\n'
    yaml_squote "$title"
    printf 'title: %s\n' "$YAML_SCALAR"
    printf 'type: feeder-index\n'
    printf 'status: evergreen\n'
    printf 'created: %s\n' "$created"
    printf 'updated: %s\n' "$updated"
    printf 'tags: [feeder, index, %s]\n' "$record"
    printf -- '---\n'
    printf '> Generated navigation for the firstmate feeder mirror. Not the system of record.\n'
    printf '\n'
    LC_ALL=C awk -F'\t' '{ printf "- [[%s]]\n", $1 }' "$list"
    printf '\n'
    printf 'Excluded records: %s\n' "$excluded"
  } > "$out"
}

snapshot_sources() {
  local kind sot physical id identity snapshot sha mtime_before mtime_after
  mkdir -p "$STAGE/snapshot" "$STAGE/decisions" "$STAGE/reports"
  : > "$STAGE/hashes"
  while IFS="$(printf '\t')" read -r kind sot physical id identity; do
    [ -n "$kind" ] || continue
    snapshot="$STAGE/snapshot/$kind.$id"
    source_identity_is_current "$sot" "$physical" "$identity" \
      || die 1 "source $sot changed path, type, containment, or identity before its snapshot"
    mtime_before=$(path_mtime "$physical") || die 1 "cannot read the source update time for $sot"
    cp -- "$physical" "$snapshot" || die 1 "cannot snapshot $sot"
    source_identity_is_current "$sot" "$physical" "$identity" \
      || die 1 "source $sot changed path, type, containment, or identity during its snapshot"
    mtime_after=$(path_mtime "$physical") || die 1 "cannot re-read the source update time for $sot"
    [ "$mtime_before" = "$mtime_after" ] \
      || die 1 "source $sot changed its update time during its snapshot"
    assert_text_payload "$snapshot" "$sot"
    sha=$(sha256_file "$snapshot") || die 1 "cannot hash the snapshot of $sot"
    is_sha256_hex "$sha" || die 1 "computed an unusable digest for $sot"
    printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$sot" "$physical" "$identity" "$mtime_after" >> "$STAGE/hashes"
  done < "$MANIFEST"
}

# The manifest and the snapshot digest list are written in the same order, so
# this reads them in lockstep on two descriptors and asserts the pairing instead
# of paying a lookup per record.
render_pages() {
  local kind sot physical id identity snapshot sha hashed_sot hashed_physical hashed_identity snapshot_mtime
  local title created updated tag out tab
  tab=$(printf '\t')
  : > "$STAGE/decision-pages"
  : > "$STAGE/report-pages"
  exec 3< "$STAGE/hashes"
  while IFS="$tab" read -r kind sot physical id identity; do
    [ -n "$kind" ] || continue
    snapshot="$STAGE/snapshot/$kind.$id"
    IFS="$tab" read -r sha hashed_sot hashed_physical hashed_identity snapshot_mtime <&3 \
      || die 1 "the snapshot digest list ended before the manifest did"
    [ "$hashed_sot" = "$sot" ] && [ "$hashed_physical" = "$physical" ] \
      && [ "$hashed_identity" = "$identity" ] \
      || die 1 "the snapshot digest list does not line up with the manifest"
    is_sha256_hex "$sha" || die 1 "lost the snapshot digest for $sot"
    title=$(extract_title "$snapshot")
    [ -n "$title" ] || title=$id
    if has_control_chars "$title"; then
      die 1 "title of $sot contains control characters"
    fi
    if has_yaml_forbidden_chars "$title"; then
      die 1 "title of $sot contains a YAML-forbidden code point"
    fi
    created=$(created_date_for "$kind" "$sot" "$physical" "$id" "$snapshot_mtime") \
      || die 1 "cannot determine a created date for $sot"
    updated=$(updated_date_for "$sot" "$snapshot" "$snapshot_mtime") \
      || die 1 "cannot determine an updated date for $sot"
    if [ "$kind" = decision ]; then
      tag=lock
      out="$STAGE/decisions/$id.md"
      printf '%s\t%s\t%s\n' "$id" "$created" "$updated" >> "$STAGE/decision-pages"
    else
      tag=report
      out="$STAGE/reports/$id.md"
      printf '%s\t%s\t%s\n' "$id" "$created" "$updated" >> "$STAGE/report-pages"
    fi
    render_page "$out" "$title" "$tag" "$created" "$updated" "$sot" "$sha" "$snapshot" \
      || die 1 "cannot render the staged page for $sot"
  done < "$MANIFEST"
  exec 3<&-

  LC_ALL=C sort -o "$STAGE/decision-pages" "$STAGE/decision-pages"
  LC_ALL=C sort -o "$STAGE/report-pages" "$STAGE/report-pages"
  render_index "$STAGE/decisions/_index.md" 'Feeder decision mirror index' decision \
    "$STAGE/decision-pages" "$EXCLUDED_DECISIONS"
  render_index "$STAGE/reports/_index.md" 'Feeder report mirror index' report \
    "$STAGE/report-pages" "$EXCLUDED_REPORTS"
}

generate_stage() {
  snapshot_sources
  scan_tree_for_secrets "$STAGE/snapshot"
  render_pages
  scan_tree_for_secrets "$STAGE/decisions" "$STAGE/reports"
}

assert_sources_unchanged() {
  local sha sot physical identity snapshot_mtime live_mtime live_sha changed tab
  discover_candidates "$STAGE/live-candidates"
  cmp -s "$CANDIDATE_LIST" "$STAGE/live-candidates" \
    || die 1 "the selected source set changed during this run; refusing to publish an incomplete mirror"
  [ -s "$STAGE/hashes" ] || return 0
  tab=$(printf '\t')
  : > "$STAGE/live-hashes"
  while IFS="$tab" read -r sha sot physical identity snapshot_mtime; do
    source_identity_is_current "$sot" "$physical" "$identity" \
      || die 1 "source $sot changed path, type, containment, or identity before the final hash"
    live_sha=$(sha256_file "$physical") \
      || die 1 "cannot re-read $sot for the stability check"
    source_identity_is_current "$sot" "$physical" "$identity" \
      || die 1 "source $sot changed path, type, containment, or identity during the final hash"
    live_mtime=$(path_mtime "$physical") || die 1 "cannot re-read the source update time for $sot"
    [ "$live_mtime" = "$snapshot_mtime" ] \
      || die 1 "source $sot changed its update time during this run; refusing stale metadata"
    printf '%s\n' "$live_sha" >> "$STAGE/live-hashes"
  done < "$STAGE/hashes"
  LC_ALL=C awk -F'\t' '{ print $1 }' "$STAGE/hashes" > "$STAGE/snapshot-hashes"
  [ "$(LC_ALL=C awk 'END {print NR}' "$STAGE/live-hashes")" \
    = "$(LC_ALL=C awk 'END {print NR}' "$STAGE/snapshot-hashes")" ] \
    || die 1 "cannot re-read every source for the stability check"
  cmp -s "$STAGE/snapshot-hashes" "$STAGE/live-hashes" && return 0
  changed=$(LC_ALL=C awk 'NR == FNR { live[FNR] = $0; next } { if ($1 != live[FNR]) { print $2; exit } }' \
    FS='\n' "$STAGE/live-hashes" FS='\t' "$STAGE/hashes")
  die 1 "${changed:-a source} changed during this run; refusing to publish a page whose provenance hash is stale"
}

# Validate the generated frontmatter of many pages in one pass. Bash 3.2 leaks a
# process-substitution descriptor per call, so a per-page read loop wedges the
# whole export on a corpus this size; one awk pass over the file list avoids that
# and is also the cheaper shape.
page_violations() { # <expected-type>; reads NUL-separated page paths on stdin
  # shellcheck disable=SC2016 # The awk program is literal; $0 and $1 are awk's.
  xargs -0 awk -v want="$1" -v banner="$BANNER" -v q="'" '
    function bad(file, why) { print file ": " why }
    FNR <= 11 { line[FILENAME, FNR] = $0; seen[FILENAME] = 1 }
    END {
      for (file in seen) {
        if (line[file, 1] != "---") { bad(file, "has no frontmatter"); continue }
        if (substr(line[file, 2], 1, 8) != "title: " q) { bad(file, "has no quoted title"); continue }
        if (line[file, 3] != "type: " want) { bad(file, "declares the wrong type"); continue }
        if (line[file, 4] != "status: evergreen") { bad(file, "declares the wrong status"); continue }
        if (line[file, 5] !~ /^created: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { bad(file, "has an invalid created date"); continue }
        if (line[file, 6] !~ /^updated: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { bad(file, "has an invalid updated date"); continue }
        if (substr(line[file, 7], 1, 7) != "tags: [") { bad(file, "has no tags"); continue }
        if (want == "feeder-mirror") {
          if (substr(line[file, 8], 1, 11) != "sot_path: " q) { bad(file, "has no quoted sot_path"); continue }
          if (line[file, 9] !~ /^sot_sha256: [0-9a-f]+$/ || length(line[file, 9]) != 76) { bad(file, "has an invalid sot_sha256"); continue }
          if (line[file, 10] != "---") { bad(file, "has an unterminated frontmatter"); continue }
          if (line[file, 11] != banner) { bad(file, "does not open with the mirror banner"); continue }
        } else if (line[file, 8] != "---") { bad(file, "has an unterminated frontmatter"); continue }
      }
    }
  '
}

validate_generated_pages() { # <dir> <expected-type> <mirror|index>
  local dir=$1 want=$2 scope=$3 violations list="$STAGE/page-list"
  if [ "$scope" = mirror ]; then
    LC_ALL=C find "$dir" -type f -name '*.md' ! -name '_index.md' -print0 > "$list" \
      || die 1 "cannot enumerate the staged pages under $dir"
  else
    printf '%s\0' "$dir/_index.md" > "$list" \
      || die 1 "cannot list the staged index under $dir"
  fi
  violations=$(page_violations "$want" < "$list") \
    || die 1 "cannot validate the staged pages under $dir"
  [ -z "$violations" ] || die 1 "the staged mirror is malformed: $(printf '%s' "$violations" | head -3)"
}

validate_index_links() { # <page-list> <index> <scratch-name>
  local list=$1 index=$2 expected="$STAGE/$3.expected" actual="$STAGE/$3.actual"
  LC_ALL=C awk -F'\t' '{ print $1 }' "$list" > "$expected"
  LC_ALL=C sed -n 's/^- \[\[\([^][]*\)\]\]$/\1/p' "$index" > "$actual"
  cmp -s "$expected" "$actual"
}

validate_stage() {
  local kind sot physical id identity expect_pages actual_pages page snapshot stray

  while IFS="$(printf '\t')" read -r kind sot physical id identity; do
    [ -n "$kind" ] || continue
    if [ "$kind" = decision ]; then page="$STAGE/decisions/$id.md"; else page="$STAGE/reports/$id.md"; fi
    [ -f "$page" ] || die 1 "the staged mirror is missing a page for $sot"
    snapshot="$STAGE/snapshot/$kind.$id"
    tail -n +13 "$page" | cmp -s - "$snapshot" \
      || die 1 "the staged payload for $sot does not match its source snapshot"
  done < "$MANIFEST"

  validate_generated_pages "$STAGE/decisions" feeder-mirror mirror
  validate_generated_pages "$STAGE/reports" feeder-mirror mirror
  validate_generated_pages "$STAGE/decisions" feeder-index index
  validate_generated_pages "$STAGE/reports" feeder-index index

  assert_sources_unchanged

  expect_pages=$(LC_ALL=C awk -F'\t' '$1 == "decision"' "$MANIFEST" | LC_ALL=C awk 'END {print NR}')
  actual_pages=$(LC_ALL=C find "$STAGE/decisions" -type f -name '*.md' | LC_ALL=C awk 'END {print NR}')
  [ "$actual_pages" -eq $((expect_pages + 1)) ] \
    || die 1 "staged wiki/decisions holds $actual_pages files, expected $((expect_pages + 1))"
  [ "$(LC_ALL=C grep -c '^- \[\[' "$STAGE/decisions/_index.md" || true)" -eq "$expect_pages" ] \
    || die 1 "the staged decision index does not link every page exactly once"
  validate_index_links "$STAGE/decision-pages" "$STAGE/decisions/_index.md" decision-index-links \
    || die 1 "the staged decision index does not match the ordered page manifest"

  expect_pages=$(LC_ALL=C awk -F'\t' '$1 == "report"' "$MANIFEST" | LC_ALL=C awk 'END {print NR}')
  actual_pages=$(LC_ALL=C find "$STAGE/reports" -type f -name '*.md' | LC_ALL=C awk 'END {print NR}')
  [ "$actual_pages" -eq $((expect_pages + 1)) ] \
    || die 1 "staged wiki/reports holds $actual_pages files, expected $((expect_pages + 1))"
  [ "$(LC_ALL=C grep -c '^- \[\[' "$STAGE/reports/_index.md" || true)" -eq "$expect_pages" ] \
    || die 1 "the staged report index does not link every page exactly once"
  validate_index_links "$STAGE/report-pages" "$STAGE/reports/_index.md" report-index-links \
    || die 1 "the staged report index does not match the ordered page manifest"

  stray=$(LC_ALL=C find "$STAGE/decisions" "$STAGE/reports" ! -type d ! -name '*.md' -print) \
    || die 1 "cannot enumerate the staged mirror"
  [ -z "$stray" ] || die 1 "the staged mirror holds a non-Markdown file"
  stray=$(LC_ALL=C find "$STAGE/decisions" "$STAGE/reports" -type l -print) \
    || die 1 "cannot enumerate the staged mirror"
  [ -z "$stray" ] || die 1 "the staged mirror holds a symbolic link"
}

# --- publication ------------------------------------------------------------

assert_atomic_publication_filesystem() {
  local transaction_device publication_device name live live_device
  transaction_device=$(path_device "$STAGE") \
    || die 1 "cannot read the transaction stage filesystem identity"
  if [ -e "$WIKI" ]; then
    publication_device=$(path_device "$WIKI") \
      || die 1 "cannot read the wiki publication filesystem identity"
  else
    publication_device=$(path_device "$VAULT") \
      || die 1 "cannot read the vault filesystem identity"
  fi
  [ "$publication_device" = "$transaction_device" ] \
    || die 1 "wiki publication and transaction paths must be on the same filesystem"
  for name in decisions reports; do
    live="$WIKI/$name"
    if [ -e "$live" ]; then
      live_device=$(path_device "$live") \
        || die 1 "cannot read the live wiki/$name filesystem identity"
      [ "$live_device" = "$transaction_device" ] \
        || die 1 "live wiki/$name and transaction paths must be on the same filesystem"
    fi
  done
}

backup_live_path() { # <name>
  local name=$1 live="$WIKI/$1" saved="$BACKUP/$1"
  [ ! -L "$WIKI" ] && [ -d "$WIKI" ] \
    || die 1 "wiki publication directory is not safe"
  [ ! -L "$BACKUP" ] && [ -d "$BACKUP" ] \
    || die 1 "transaction backup directory is not safe"
  [ ! -e "$saved" ] && [ ! -L "$saved" ] \
    || die 1 "transaction backup destination for wiki/$name already exists or is symbolic"
  if [ -e "$live" ]; then
    [ ! -L "$live" ] && [ -d "$live" ] \
      || die 1 "wiki/$name is not a safe live directory"
    mv "$live" "$saved" || die 1 "cannot back up wiki/$name"
  fi
}

install_staged_path() { # <name>
  local name=$1 staged="$STAGE/$1" live="$WIKI/$1"
  [ ! -L "$WIKI" ] && [ -d "$WIKI" ] \
    || die 1 "wiki publication directory is not safe"
  [ ! -L "$STAGE" ] && [ -d "$STAGE" ] \
    || die 1 "transaction stage directory is not safe"
  [ ! -L "$staged" ] && [ -d "$staged" ] \
    || die 1 "staged wiki/$name is not a safe directory"
  [ ! -e "$live" ] && [ ! -L "$live" ] \
    || die 1 "wiki/$name exists before its staged installation"
  mv "$staged" "$live" || die 1 "cannot install wiki/$name"
}

publish() {
  local head new_decisions new_reports old_decisions old_reports

  assert_no_symbolic_owned_paths
  assert_atomic_publication_filesystem
  head=$(git -C "$VAULT" rev-parse HEAD 2>/dev/null) || head=NONE
  new_decisions=$(dir_digest "$STAGE/decisions") || die 1 "cannot digest staged wiki/decisions"
  new_reports=$(dir_digest "$STAGE/reports") || die 1 "cannot digest staged wiki/reports"
  old_decisions=$(dir_digest "$DECISIONS_LIVE") || die 1 "cannot digest live wiki/decisions"
  old_reports=$(dir_digest "$REPORTS_LIVE") || die 1 "cannot digest live wiki/reports"

  create_journal
  journal_append \
    'version=1' \
    "run=$RUN_ID" \
    "head=$head" \
    "stage=$STAGE" \
    "backup=$BACKUP" \
    "decisions_old=$old_decisions" \
    "reports_old=$old_reports" \
    "decisions_new=$new_decisions" \
    "reports_new=$new_reports"
  set_phase prepared
  verify_prepublication_paths
  if [ ! -e "$WIKI" ]; then
    mkdir "$WIKI" || die 1 "cannot atomically create the wiki publication directory"
  fi
  [ ! -L "$WIKI" ] && [ -d "$WIKI" ] \
    || die 1 "wiki publication directory is not safe"
  mkdir "$BACKUP" || die 1 "cannot atomically create the transaction backup directory"
  verify_publication_paths

  backup_live_path decisions
  set_phase moved-decisions
  backup_live_path reports
  set_phase moved-reports
  install_staged_path decisions
  set_phase installed-decisions
  install_staged_path reports
  set_phase installed-reports

  [ "$(dir_digest "$DECISIONS_LIVE")" = "$new_decisions" ] \
    || die 1 "installed wiki/decisions does not match the validated generation"
  [ "$(dir_digest "$REPORTS_LIVE")" = "$new_reports" ] \
    || die 1 "installed wiki/reports does not match the validated generation"

  STAGED_PATHS=1
  git -C "$VAULT" add -- wiki/decisions wiki/reports || die 1 "cannot stage the owned mirror paths"

  if git -C "$VAULT" diff --cached --quiet -- wiki/decisions wiki/reports; then
    STAGED_PATHS=0
    COMMITTED_HEAD=$head
    note "mirror bytes are unchanged; skipping the commit and pushing the current HEAD"
  else
    set_phase commit-intent
    git -C "$VAULT" commit -q -m "$COMMIT_MESSAGE" -- wiki/decisions wiki/reports \
      || die 1 "cannot commit the mirror"
    STAGED_PATHS=0
    COMMITTED_HEAD=$(git -C "$VAULT" rev-parse HEAD) || die 1 "cannot read the new commit"
    verify_commit_contents "$head" "$COMMITTED_HEAD" "$new_decisions" "$new_reports" \
      || die 1 "the committed Git tree or HEAD lineage does not match the validated generation"
  fi

  assert_clean_vault
  [ "$(dir_digest "$DECISIONS_LIVE")" = "$new_decisions" ] \
    || die 1 "wiki/decisions changed after the commit check"
  [ "$(dir_digest "$REPORTS_LIVE")" = "$new_reports" ] \
    || die 1 "wiki/reports changed after the commit check"
  PUSH_DECISIONS_DIGEST=$new_decisions
  PUSH_REPORTS_DIGEST=$new_reports
  journal_append "committed_head=$COMMITTED_HEAD"
  set_phase committed

  rm -rf "$BACKUP" || die 5 "cannot remove the transaction backup; the commit is kept for the next run"
  [ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] \
    || die 5 "the transaction backup remains; the commit and journal are kept for the next run"
  close_journal
  [ ! -L "$JOURNAL" ] \
    || die 5 "the transaction journal became symbolic; the commit is kept for recovery"
  rm -f "$JOURNAL" || die 5 "cannot remove the transaction journal; the commit is kept for the next run"
  [ ! -e "$JOURNAL" ] && [ ! -L "$JOURNAL" ] \
    || die 5 "the transaction journal remains; the commit is kept for the next run"
  TX_PHASE=finished
}

verify_commit_contents() {
  local prior=$1 commit=$2 want_decisions=$3 want_reports=$4 parent
  if [ "$commit" != "$prior" ]; then
    parent=$(git -C "$VAULT" rev-parse "$commit^" 2>/dev/null) || return 1
    [ "$parent" = "$prior" ] || return 1
  fi
  git -C "$VAULT" diff --quiet "$prior" "$commit" -- . \
    ':(exclude)wiki/decisions' ':(exclude)wiki/decisions/**' \
    ':(exclude)wiki/reports' ':(exclude)wiki/reports/**' || return 1
  [ "$(git_dir_digest "$commit" wiki/decisions)" = "$want_decisions" ] || return 1
  [ "$(git_dir_digest "$commit" wiki/reports)" = "$want_reports" ] || return 1
}

assert_no_transaction_artifacts() {
  local leftover
  if [ -e "$JOURNAL" ] || [ -L "$JOURNAL" ]; then
    die 5 "transaction journal remains before push; preserving the local commit for recovery"
  fi
  leftover=$(find_transaction_artifacts 'backup.*') \
    || die 5 "cannot enumerate transaction backups before push; preserving the local commit"
  [ -z "$leftover" ] \
    || die 5 "transaction backup remains before push; preserving the local commit for recovery"
}

push_current_head() {
  local branch
  verify_branch_and_upstream
  branch=$EXPECTED_BRANCH
  verify_remote_is_pinned_and_private
  assert_no_transaction_artifacts
  assert_clean_vault
  [ -n "$PUSH_DECISIONS_DIGEST" ] && [ -n "$PUSH_REPORTS_DIGEST" ] \
    || die 5 "expected mirror digests are unavailable before push; preserving the local commit"
  [ "$(dir_digest "$DECISIONS_LIVE")" = "$PUSH_DECISIONS_DIGEST" ] \
    || die 5 "wiki/decisions changed before push; preserving the local commit"
  [ "$(dir_digest "$REPORTS_LIVE")" = "$PUSH_REPORTS_DIGEST" ] \
    || die 5 "wiki/reports changed before push; preserving the local commit"
  if git -C "$VAULT" push "$REMOTE_NAME" "refs/heads/$branch:refs/heads/$branch" > /dev/null 2>&1; then
    note "pushed $branch to $REMOTE_NAME ($MARKER_REMOTE) at ${COMMITTED_HEAD:-HEAD}"
    return 0
  fi
  printf 'fm-feeder-export: push to remote %s branch %s failed; the local commit %s is preserved\n' \
    "$REMOTE_NAME" "$branch" "$(git -C "$VAULT" rev-parse HEAD)" >&2
  printf 'fm-feeder-export: retry with: bin/fm-feeder-export.sh\n' >&2
  exit 5
}

# --- run --------------------------------------------------------------------

HOME_IS_GIT=0
HOME_GIT_HEAD=
COMMITTED_HEAD=

normal_preflight() {
  detect_home_git
  verify_remote_is_pinned_and_private
  verify_branch_and_upstream
}

HAD_JOURNAL=0
if [ -e "$JOURNAL" ]; then
  HAD_JOURNAL=1
fi

verify_remote_matches_marker

if [ "$HAD_JOURNAL" -eq 0 ]; then
  normal_preflight
  assert_clean_vault
fi

prepare_transaction_root
acquire_lock
recover_prior_state
assert_clean_vault

if [ "$RECOVERED_COMMITTED" -eq 1 ]; then
  push_current_head
  exit 0
fi

if [ "$HAD_JOURNAL" -eq 1 ]; then
  normal_preflight
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
COMMIT_MESSAGE="feeder: refresh mirror $(date -u +%Y-%m-%d)"
STAGE="$FEEDER_DIR/stage.$RUN_ID"
mkdir "$STAGE" || die 1 "cannot create a stage directory under $FEEDER_DIR"
BACKUP="$FEEDER_DIR/backup.$RUN_ID"
MANIFEST="$STAGE/manifest"
CANDIDATE_LIST="$STAGE/candidates"
COLLISION_LIST="$STAGE/collisions"
EXCLUDE_LIST="$STAGE/excludes"
TRACKED_LIST="$STAGE/tracked"

discover_candidates
load_excludes
load_tracked_sources
build_manifest
generate_stage
validate_stage
publish
push_current_head
