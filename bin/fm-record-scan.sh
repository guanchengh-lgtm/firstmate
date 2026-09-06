#!/usr/bin/env bash
# fm-record-scan.sh - the single owner of the Record and feeder credential scan.
#
# Sourced by bin/fm-feeder-export.sh so the exporter keeps its existing
# fail-closed messages, hits-file path, and class names. Executed as a public
# command for Record pre-commit, tick attestation, and tests.
#
# Secret boundary. Every scanned snapshot is checked for a fixed set of
# high-confidence credential shapes. A match refuses the run, naming only a
# safe locator and the pattern class, never the matched bytes. The classes are
# deliberately precise and incomplete; there is no generic password or entropy
# detector, because its false-positive policy is undefined.
#
# The OpenAI class is exactly
# `sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,255}`. It deliberately fails
# closed: a false positive blocks export for review, while a false negative can
# expose a credential.
#
# When executed:
#   fm-record-scan.sh tree <dir>...
#   fm-record-scan.sh class <file>
#   fm-record-scan.sh gitleaks --dir <dir>
#   fm-record-scan.sh chain --dir <dir>
#   fm-record-scan.sh archive-preflight --dir <dir>
#
# Exit codes (CLI):
#   0  clean
#   1  scan error, missing tool, invalid input, or archive refusal
#   2  credential hit (fail closed; no commit or push)
#   3  usage
#
# Gitleaks is invoked with this script's explicit config, --redact=100,
# --ignore-gitleaks-allow, and --max-archive-depth 2. Working-tree allowlists,
# baselines, and GITLEAKS_CONFIG are not inherited.
set -u

export LC_ALL=C

OPENAI_SECRET='sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,255}'
PRIVATE_KEY_HEADER='-----BEGIN ((RSA|EC|DSA|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----'
SECRET_COMBINED="$PRIVATE_KEY_HEADER|gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{20,255}|(AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,255}|[sr]k_live_[A-Za-z0-9]{16,255}|AIza[A-Za-z0-9_-]{35}|$OPENAI_SECRET"

fm_record_scan_die() { # <exit-code> <message>...
  local code=$1
  shift
  printf 'fm-record-scan: %s\n' "$*" >&2
  exit "$code"
}

if ! declare -F die >/dev/null 2>&1; then
  die() {
    fm_record_scan_die "$@"
  }
fi

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
  if secret_pattern_matches "$PRIVATE_KEY_HEADER" "$file"; then
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

if ! declare -F logical_label_for >/dev/null 2>&1; then
  logical_label_for() { # <path>
    printf '%s\n' "$1"
  }
fi

# One scan pass over a whole staged tree. Running grep once per file costs a
# process per record on a corpus of this size, so the scan is batched; it still
# happens before any live mutation, which is the boundary that matters.
scan_tree_for_secrets() { # <dir>...
  local hit class label hits sorted rc
  [ -n "${STAGE:-}" ] || die 1 "credential scan has no stage directory; refusing to publish"
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
  die "${FM_RECORD_SCAN_HIT_CODE:-1}" "refusing to publish: $label matches the $class credential pattern"
}

fm_record_scan_write_gitleaks_config() { # <path>
  cat > "$1" <<'TOML'
title = "firstmate-record"

[extend]
useDefault = true
TOML
  printf "\n[[rules]]\nid = 'firstmate-feeder'\nregex = '%s'\n" "$SECRET_COMBINED" >> "$1"
}

fm_record_scan_archive_preflight() { # <dir>
  local dir=$1
  [ -d "$dir" ] || die 1 "archive preflight directory is missing: $dir"
  python3 - "$dir" "$SECRET_COMBINED" "${2:-/dev/null}" <<'PY'
import gzip
import os
import re
import shutil
import sys
import tarfile
import zipfile
import zlib

root = sys.argv[1]
MAX_DEPTH = 2
pattern = re.compile(sys.argv[2])


def fail(message, code=1):
    print("fm-record-scan: " + message, file=sys.stderr)
    sys.exit(code)


def write_name(name, output):
    if pattern.search(name):
        fail("refusing to publish: [credential-shaped source path redacted] matches the credential filename pattern", 2)
    output.write(name.encode("utf-8", errors="surrogateescape") + b"\n")
    output.write(re.sub(r"[/.!]", "\n", name).encode("utf-8", errors="surrogateescape") + b"\n")


def scan_stream(stream, name, depth, output):
    write_name(name, output)
    header = stream.read(512)
    stream.seek(0)
    lower = name.lower()
    if lower.endswith(".zip") or header.startswith((b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")):
        kind = "zip"
    elif lower.endswith((".tar", ".tgz", ".tar.gz")) or header[257:262] == b"ustar":
        kind = "tar"
    elif lower.endswith(".gz") or header.startswith(b"\x1f\x8b"):
        kind = "tar" if tarfile.is_tarfile(stream) else "gzip"
        stream.seek(0)
    else:
        shutil.copyfileobj(stream, output)
        output.write(b"\n")
        return
    if depth >= MAX_DEPTH:
        fail("archive exceeds bounded scan depth")
    if kind == "zip":
        with zipfile.ZipFile(stream) as archive:
            for entry in archive.infolist():
                if entry.flag_bits & 1:
                    fail("archive is encrypted and cannot be scanned")
                nested = name + "!" + entry.filename
                if entry.is_dir():
                    write_name(nested, output)
                else:
                    with archive.open(entry) as payload:
                        scan_stream(payload, nested, depth + 1, output)
    elif kind == "tar":
        with tarfile.open(fileobj=stream, mode="r:*") as archive:
            for entry in archive:
                nested = name + "!" + entry.name
                if entry.isfile():
                    with archive.extractfile(entry) as payload:
                        scan_stream(payload, nested, depth + 1, output)
                else:
                    write_name(nested, output)
                    write_name(entry.linkname, output)
    else:
        with gzip.GzipFile(fileobj=stream) as payload:
            scan_stream(payload, name[:-3], depth + 1, output)


try:
    with open(sys.argv[3], "wb") as output:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False,
                onerror=lambda error: fail("cannot enumerate scan directory")):
            if ".git" in dirnames:
                dirnames.remove(".git")
            for name in dirnames:
                write_name(os.path.relpath(os.path.join(dirpath, name), root), output)
            for name in filenames:
                path = os.path.join(dirpath, name)
                relative = os.path.relpath(path, root)
                if os.path.islink(path):
                    write_name(relative, output)
                    write_name(os.readlink(path), output)
                elif os.path.isfile(path):
                    with open(path, "rb") as payload:
                        scan_stream(payload, relative, 0, output)
                else:
                    fail("scan source is not a regular file")
except (OSError, EOFError, ValueError, RuntimeError, NotImplementedError, zipfile.BadZipFile, tarfile.TarError, zlib.error):
    fail("archive or scan source is corrupt, unreadable, or unsupported")
PY
}

fm_record_scan_gitleaks_dir() { # <dir>
  local dir=$1 cfg report ignore_dir rc source
  local -a scan_args
  [ -d "$dir" ] || die 1 "gitleaks directory is missing: $dir"
  command -v gitleaks >/dev/null 2>&1 \
    || die 1 "gitleaks is missing; refusing to publish"
  cfg=$(mktemp "${TMPDIR:-/tmp}/fm-record-gitleaks.XXXXXX") \
    || die 1 "cannot create the explicit gitleaks config"
  report=$(mktemp "${TMPDIR:-/tmp}/fm-record-gitleaks-report.XXXXXX") \
    || { rm -f "$cfg"; die 1 "cannot create the gitleaks report file"; }
  ignore_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-record-gitleaks-ignore.XXXXXX") \
    || { rm -f "$cfg" "$report"; die 1 "cannot create the empty gitleaks ignore dir"; }
  fm_record_scan_write_gitleaks_config "$cfg" \
    || { rm -rf "$cfg" "$report" "$ignore_dir"; die 1 "cannot write the explicit gitleaks config"; }
  rc=0
  fm_record_scan_archive_preflight "$dir" "$ignore_dir/payloads" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$cfg" "$report" "$ignore_dir"
    return "$rc"
  fi
  for source in stdin dir; do
    scan_args=("$source" --no-banner --no-color --log-level warn --redact=100
      --ignore-gitleaks-allow --gitleaks-ignore-path "$ignore_dir" --config "$cfg"
      --max-archive-depth 2 --report-format json --report-path "$report")
    if [ "$source" = dir ]; then
      scan_args+=(-- "$dir")
    fi
    rc=0
    env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML \
      gitleaks "${scan_args[@]}" < "$ignore_dir/payloads" >/dev/null 2>"${report}.err" || rc=$?
    if [ "$rc" -eq 0 ] && [ ! -s "${report}.err" ]; then
      continue
    fi
    if [ "$rc" -eq 1 ]; then
      python3 - "$report" "$SECRET_COMBINED" <<'PY' || true
import re
import json
import sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for item in data[:1]:
    rule = item.get("RuleID") or item.get("Rule") or "gitleaks"
    file_path = item.get("File") or item.get("Path") or "unknown"
    if re.search(sys.argv[2], file_path):
        file_path = "[credential-shaped source path redacted]"
    print("fm-record-scan: refusing to publish: %s matches the %s credential pattern" % (file_path, rule), file=sys.stderr)
PY
      rm -rf "$cfg" "$report" "${report}.err" "$ignore_dir"
      return 2
    fi
    rm -rf "$cfg" "$report" "${report}.err" "$ignore_dir"
    die 1 "gitleaks scan failed or was incomplete; refusing to publish"
  done
  rm -rf "$cfg" "$report" "${report}.err" "$ignore_dir"
}

fm_record_scan_chain() { # <dir>
  local dir=$1 rc=0
  fm_record_scan_gitleaks_dir "$dir" || rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  STAGE=${STAGE:-$(mktemp -d "${TMPDIR:-/tmp}/fm-record-scan-stage.XXXXXX")} \
    || die 1 "credential scan could not create its stage directory; refusing to publish"
  FM_RECORD_SCAN_HIT_CODE=2
  scan_tree_for_secrets "$dir"
}

fm_record_scan_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}" >&2
}

fm_record_scan_cli() {
  local cmd=${1:-} dir rc=0
  shift || true
  case "$cmd" in
    -h | --help | '')
      fm_record_scan_usage
      [ "$cmd" = '-h' ] || [ "$cmd" = '--help' ] || exit 3
      exit 0
      ;;
    tree)
      [ "$#" -ge 1 ] || fm_record_scan_die 3 "tree requires at least one directory"
      STAGE=${STAGE:-$(mktemp -d "${TMPDIR:-/tmp}/fm-record-scan-stage.XXXXXX")} \
        || die 1 "credential scan could not create its stage directory; refusing to publish"
      FM_RECORD_SCAN_HIT_CODE=2
      scan_tree_for_secrets "$@"
      ;;
    class)
      [ "$#" -eq 1 ] || fm_record_scan_die 3 "class requires one file"
      [ -f "$1" ] || die 1 "class file is missing: $1"
      if secret_pattern_matches "$SECRET_COMBINED" "$1"; then
        secret_class_of "$1"
        exit 2
      fi
      printf 'none\n'
      ;;
    gitleaks)
      dir=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --dir)
            dir=$2
            shift 2
            ;;
          *)
            fm_record_scan_die 3 "unknown gitleaks argument '$1'"
            ;;
        esac
      done
      [ -n "$dir" ] || fm_record_scan_die 3 "gitleaks requires --dir"
      rc=0
      fm_record_scan_gitleaks_dir "$dir" || rc=$?
      case "$rc" in
        0) exit 0 ;;
        2) exit 2 ;;
        *) exit 1 ;;
      esac
      ;;
    archive-preflight)
      dir=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --dir)
            dir=$2
            shift 2
            ;;
          *)
            fm_record_scan_die 3 "unknown archive-preflight argument '$1'"
            ;;
        esac
      done
      [ -n "$dir" ] || fm_record_scan_die 3 "archive-preflight requires --dir"
      fm_record_scan_archive_preflight "$dir"
      ;;
    chain)
      dir=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --dir)
            dir=$2
            shift 2
            ;;
          *)
            fm_record_scan_die 3 "unknown chain argument '$1'"
            ;;
        esac
      done
      [ -n "$dir" ] || fm_record_scan_die 3 "chain requires --dir"
      rc=0
      fm_record_scan_chain "$dir" || rc=$?
      case "$rc" in
        0) exit 0 ;;
        2) exit 2 ;;
        *) exit 1 ;;
      esac
      ;;
    *)
      fm_record_scan_die 3 "unknown argument '$cmd'; run --help"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  fm_record_scan_cli "$@"
fi
