#!/usr/bin/env bash
# fm-record-scan.sh - the single owner of the Record and feeder credential scan.
#
# Sourced by bin/fm-feeder-export.sh so the exporter keeps its existing
# fail-closed messages, hits-file path, and class names. Executed as a public
# command for Record pre-commit, tick attestation, and tests.
# Secret boundary. The feeder and the tree command use the fixed credential
# shapes below. That set is deliberately precise and incomplete; it has no
# generic password or entropy detector because its false-positive policy is
# undefined. The Record chain adds Gitleaks default rules and archive
# inspection; the feeder does not run those additional passes. A match refuses
# the run, naming only a safe locator and the pattern class, never matched bytes.
# The OpenAI class is exactly `sk-(proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,255}`.
# It fails closed: a false positive blocks export; a false negative can leak.
# When executed:
#   fm-record-scan.sh tree <dir>...
#   fm-record-scan.sh gitleaks --dir <dir>
#   fm-record-scan.sh chain --dir <dir>
#   fm-record-scan.sh archive-preflight --dir <dir>
# Exit codes (CLI): 0 clean; 1 scan error, missing tool, invalid input, or
# archive refusal; 2 credential hit (fail closed; no commit or push); 3 usage.
# Gitleaks is invoked with this script's explicit config, --redact=100,
# --ignore-gitleaks-allow, and --max-archive-depth 2. Working-tree allowlists,
# baselines, and GITLEAKS_CONFIG are not inherited. Archive inspection and
# each gitleaks pass use FM_RECORD_SCAN_TIMEOUT_SECONDS (default 60).
# Archive inspection accepts ZIP, TAR, and gzip. Nested archive members
# refuse. Encrypted, corrupt, or unsupported formats refuse. Every payload
# file is hard-linked (copied across devices) into a <dir>.scan.* scratch
# directory under the payload's own Git directory, or next to the payload
# directory when it is not in a repository, as <sha256>.<canonical-ext>: archives keep the
# extension gitleaks opens (.tgz becomes .tar.gz) and every other file
# becomes .txt, so the gitleaks extension allowlist that skips .bin, .pdf,
# .tgz and similar names cannot hide content. Gitleaks scans that scratch
# only, and a hit is mapped back to the payload path before it is reported;
# it never receives an expanded payload stream.
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
  secret_pattern_matches "$PRIVATE_KEY_HEADER" "$file" && { printf '%s\n' private-key; return 0; }
  secret_pattern_matches 'gh[pousr]_[A-Za-z0-9]{36,255}' "$file" && { printf '%s\n' github-classic-token; return 0; }
  secret_pattern_matches 'github_pat_[A-Za-z0-9_]{20,255}' "$file" && { printf '%s\n' github-fine-grained-token; return 0; }
  secret_pattern_matches '(AKIA|ASIA)[A-Z0-9]{16}' "$file" && { printf '%s\n' aws-access-key-id; return 0; }
  secret_pattern_matches 'xox[baprs]-[A-Za-z0-9-]{10,255}' "$file" && { printf '%s\n' slack-token; return 0; }
  secret_pattern_matches '[sr]k_live_[A-Za-z0-9]{16,255}' "$file" && { printf '%s\n' stripe-live-key; return 0; }
  secret_pattern_matches 'AIza[A-Za-z0-9_-]{35}' "$file" && { printf '%s\n' google-api-key; return 0; }
  secret_pattern_matches "$OPENAI_SECRET" "$file" && { printf '%s\n' openai-key; return 0; }
  printf 'unclassified\n'
}

if ! declare -F logical_label_for >/dev/null 2>&1; then
  logical_label_for() { # <path>
    printf '%s\n' "$1"
  }
fi

# Batched tree scan before any live mutation.
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

fm_record_scan_require_timeout() {
  case "${FM_RECORD_SCAN_TIMEOUT_SECONDS:-60}" in
    '' | *[!0-9]* | 0) die 1 "scan timeout must be a positive integer" ;;
  esac
  [ "${FM_RECORD_SCAN_TIMEOUT_SECONDS:-60}" -gt 0 ] 2>/dev/null || die 1 "scan timeout must be positive"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
}

fm_record_scan_redact_locator() { # <text>
  if secret_text_matches "$1"; then
    printf '%s\n' '[credential-shaped path redacted]'
  else
    printf '%s\n' "$1"
  fi
}

fm_record_scan_archive_preflight() { # <dir> <scratch-dir>
  local dir=$1 scratch=$2
  [ -d "$dir" ] || die 1 "archive preflight directory is missing: $dir"
  [ -n "$scratch" ] || die 1 "archive preflight scratch directory is missing"
  fm_record_scan_require_timeout
  mkdir -p "$scratch" || die 1 "cannot create archive scratch directory"
  fm_run_timed "${FM_RECORD_SCAN_TIMEOUT_SECONDS:-60}" python3 - "$dir" "$scratch" "$SECRET_COMBINED" <<'PY'
import gzip, hashlib, os, re, shutil, sys, tarfile, zipfile
root, scratch = map(os.path.realpath, sys.argv[1:3])
pattern = re.compile(sys.argv[3])
ZIP_MAGIC = (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")
REFUSE_EXT = (".xz", ".txz", ".bz2", ".tbz", ".tbz2", ".7z", ".rar", ".zst", ".zstd",
    ".tzst", ".lz4", ".lz", ".lzma", ".br", ".sz", ".s2", ".z", ".zz")
REFUSE_MAGIC = (b"\xfd7zXZ\x00", b"BZh", b"7z\xbc\xaf\x27\x1c", b"Rar!\x1a\x07",
    b"\x28\xb5\x2f\xfd", b"\x04\x22\x4d\x18", b"LZIP", b"\xff\x06\x00\x00sNaPpY", b"\x1f\x9d")
ARCHIVE_EXT = REFUSE_EXT + (".zip", ".tar", ".gz", ".tgz", ".tar.gz")

def fail(message, code=1):
    print("fm-record-scan: " + message, file=sys.stderr)
    sys.exit(code)

def check_name(name):
    if pattern.search(name):
        fail("refusing to publish: [credential-shaped source path redacted] matches the credential filename pattern", 2)

def classify(header, name):
    lower = name.lower()
    if lower.endswith(REFUSE_EXT) or header.startswith(REFUSE_MAGIC):
        return "refuse"
    if header.startswith(ZIP_MAGIC) or lower.endswith(".zip"):
        return "zip"
    if (len(header) > 262 and header[257:262] == b"ustar") or lower.endswith(".tar"):
        return "tar"
    if header.startswith(b"\x1f\x8b") or lower.endswith((".gz", ".tgz", ".tar.gz")):
        return "gzip"
    return None

def member_nested(name, header):
    return name.lower().endswith(ARCHIVE_EXT) or classify(header, name) is not None

def iter_members(kind, path):
    if kind == "zip":
        with zipfile.ZipFile(path) as archive:
            for entry in archive.infolist():
                if entry.flag_bits & 1:
                    fail("archive is encrypted and cannot be scanned")
                if entry.is_dir():
                    continue
                with archive.open(entry) as payload:
                    yield entry.filename, payload.read(512)
        return
    with tarfile.open(path, "r:*" if kind == "tar" else "r:gz") as archive:
        for entry in archive:
            if not entry.isfile():
                continue
            payload = archive.extractfile(entry)
            yield entry.name, payload.read(512) if payload else b""

def test_open(kind, path):
    if kind == "gzip":
        with open(path, "rb") as source:
            if not tarfile.is_tarfile(source):
                with gzip.open(path, "rb") as payload:
                    header = payload.read(512)
                inner = os.path.basename(path)
                if inner.lower().endswith(".gz"):
                    inner = inner[:-3]
                if member_nested(inner, header):
                    fail("nested archive cannot be scanned")
                return
    for name, header in iter_members("tar" if kind == "gzip" else kind, path):
        if member_nested(name, header):
            fail("nested archive cannot be scanned")

def place_link(path, ext):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    dest = os.path.join(scratch, digest.hexdigest() + ext)
    if os.path.exists(dest):
        return
    try:
        os.link(path, dest)
    except OSError:
        shutil.copy2(path, dest)
    links.append(os.path.basename(dest) + "\t" + os.path.relpath(path, root))

try:
    names = []
    links = []
    walk = os.walk(root, followlinks=False, onerror=lambda e: fail("cannot enumerate scan directory"))
    for dirpath, dirnames, filenames in walk:
        if ".git" in dirnames:
            dirnames.remove(".git")
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            relative = os.path.relpath(path, root)
            names.append(relative)
            check_name(relative)
            if os.path.islink(path):
                target = os.readlink(path)
                check_name(target)
                real = os.path.realpath(path)
                if os.path.isabs(target) or not os.path.exists(path) or os.path.commonpath((root, real)) != root:
                    fail("symlink is broken, absolute, or outside the scan root")
                continue
            if os.path.isdir(path):
                continue
            if not os.path.isfile(path):
                fail("scan source is not a regular file")
            with open(path, "rb") as source:
                header = source.read(512)
            kind = classify(header, relative)
            if kind is None:
                place_link(path, ".txt")
                continue
            if kind == "refuse":
                fail("archive format is unsupported and cannot be scanned")
            test_open(kind, path)
            if kind == "zip":
                ext = ".zip"
            elif kind == "tar":
                ext = ".tar"
            else:
                with open(path, "rb") as source:
                    ext = ".tar.gz" if tarfile.is_tarfile(source) else ".gz"
            place_link(path, ext)
    with open(os.path.join(scratch, "names.txt"), "w", encoding="utf-8", errors="surrogateescape") as output:
        output.write("".join(n + "\n" + re.sub(r"[/.!]", "\n", n) + "\n" for n in names))
    with open(os.path.join(scratch, "paths.tsv"), "w", encoding="utf-8", errors="surrogateescape") as output:
        output.write("".join(line + "\n" for line in links))
except (OSError, EOFError, ValueError, RuntimeError, NotImplementedError, zipfile.BadZipFile, tarfile.TarError, gzip.BadGzipFile):
    fail("archive or scan source is corrupt, unreadable, or unsupported")
PY
}

fm_record_scan_gitleaks_cleanup() {
  rm -rf "$cfg" "$report" "${report}.err" "$scratch" "$ignore_dir"
}

fm_record_scan_scratch_dir() { # <payload-dir> <suffix>
  local parent
  parent=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) \
    || parent=$(cd "$(dirname "${1%/}")" && pwd) || return 1
  mktemp -d "$parent/$(basename "${1%/}").$2.XXXXXX"
}

fm_record_scan_payload_path() { # <dir> <scratch> <reported-file>
  local dir=$1 scratch=$2 file=$3 member='' link rel
  case "$file" in "$scratch"/*) file=${file#"$scratch"/} ;; esac
  case "$file" in *!*) member=${file#*!}; file=${file%%!*} ;; esac
  link=$file
  rel=$(awk -F'\t' -v k="$link" '$1 == k { print substr($0, length(k) + 2); exit }' "$scratch/paths.tsv" 2>/dev/null)
  [ -n "$rel" ] && file="$dir/$rel"
  [ -z "$member" ] || file="$file!$member"
  printf '%s\n' "$file"
}

fm_record_scan_gitleaks_dir() { # <dir>
  local dir=$1 cfg report scratch ignore_dir rc file_path rule
  local -a scan_args
  [ -d "$dir" ] || die 1 "gitleaks directory is missing: $dir"
  command -v gitleaks >/dev/null 2>&1 || die 1 "gitleaks is missing; refusing to publish"
  command -v jq >/dev/null 2>&1 || die 1 "jq is missing; refusing to publish"
  cfg=$(mktemp "${TMPDIR:-/tmp}/fm-record-gitleaks.XXXXXX") || die 1 "cannot create the explicit gitleaks config"
  report=$(mktemp "${TMPDIR:-/tmp}/fm-record-gitleaks-report.XXXXXX") \
    || { rm -f "$cfg"; die 1 "cannot create the gitleaks report file"; }
  scratch=$(fm_record_scan_scratch_dir "$dir" scan) \
    || { rm -f "$cfg" "$report"; die 1 "cannot create the archive scratch dir"; }
  ignore_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-record-gitleaks-ignore.XXXXXX") \
    || { rm -rf "$cfg" "$report" "$scratch"; die 1 "cannot create the empty gitleaks ignore dir"; }
  fm_record_scan_write_gitleaks_config "$cfg" \
    || { fm_record_scan_gitleaks_cleanup; die 1 "cannot write the explicit gitleaks config"; }
  rc=0
  fm_record_scan_archive_preflight "$dir" "$scratch" || rc=$?
  [ "$rc" -eq 0 ] || { fm_record_scan_gitleaks_cleanup; return "$rc"; }
  scan_args=(dir --no-banner --no-color --log-level warn --redact=100
    --ignore-gitleaks-allow --gitleaks-ignore-path "$ignore_dir" --config "$cfg"
    --max-archive-depth 2 --report-format json --report-path "$report")
  rc=0
  fm_run_timed "${FM_RECORD_SCAN_TIMEOUT_SECONDS:-60}" \
    env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML gitleaks "${scan_args[@]}" -- "$scratch" \
    >/dev/null 2>"${report}.err" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "${report}.err" ]; then
    fm_record_scan_gitleaks_cleanup
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    file_path=unknown
    rule=gitleaks
    if [ -s "$report" ]; then
      file_path=$(jq -r 'if type=="array" and length>0 then (.[0].File // .[0].Path // "unknown") else "unknown" end' "$report" 2>/dev/null) || file_path=unknown
      rule=$(jq -r 'if type=="array" and length>0 then (.[0].RuleID // .[0].Rule // "gitleaks") else "gitleaks" end' "$report" 2>/dev/null) || rule=gitleaks
      file_path=$(fm_record_scan_payload_path "$dir" "$scratch" "$file_path")
    fi
    printf 'fm-record-scan: refusing to publish: %s matches the %s credential pattern\n' \
      "$(fm_record_scan_redact_locator "$file_path")" "$rule" >&2
    fm_record_scan_gitleaks_cleanup
    return 2
  fi
  fm_record_scan_gitleaks_cleanup
  die 1 "gitleaks scan failed or was incomplete; refusing to publish"
}

fm_record_scan_chain() { # <dir>
  local dir=$1 rc=0
  fm_record_scan_gitleaks_dir "$dir" || rc=$?
  case "$rc" in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
  FM_RECORD_SCAN_HIT_CODE=2
  scan_tree_for_secrets "$dir"
}

fm_record_scan_usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}" >&2
}

fm_record_scan_require_dir() { # <cmd> <args...>
  local cmd=$1
  shift
  dir=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)
        dir=$2
        shift 2
        ;;
      *)
        fm_record_scan_die 3 "unknown $cmd argument '$1'"
        ;;
    esac
  done
  [ -n "$dir" ] || fm_record_scan_die 3 "$cmd requires --dir"
}

fm_record_scan_cli() {
  local cmd=${1:-} dir rc=0 scratch
  shift || true
  case "$cmd" in
    tree | chain)
      if [ -z "${STAGE:-}" ]; then
        STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fm-record-scan-stage.XXXXXX") \
          || die 1 "credential scan could not create its stage directory; refusing to publish"
        trap 'rm -rf -- "$STAGE"' EXIT
      fi
      ;;
  esac
  case "$cmd" in
    -h | --help | '')
      fm_record_scan_usage
      [ "$cmd" = '-h' ] || [ "$cmd" = '--help' ] || exit 3
      exit 0
      ;;
    tree)
      [ "$#" -ge 1 ] || fm_record_scan_die 3 "tree requires at least one directory"
      FM_RECORD_SCAN_HIT_CODE=2
      scan_tree_for_secrets "$@"
      ;;
    gitleaks | chain)
      fm_record_scan_require_dir "$cmd" "$@"
      if [ "$cmd" = gitleaks ]; then
        fm_record_scan_gitleaks_dir "$dir" || rc=$?
      else
        fm_record_scan_chain "$dir" || rc=$?
      fi
      case "$rc" in
        0) exit 0 ;;
        2) exit 2 ;;
        *) exit 1 ;;
      esac
      ;;
    archive-preflight)
      fm_record_scan_require_dir "$cmd" "$@"
      scratch=$(fm_record_scan_scratch_dir "$dir" preflight) \
        || die 1 "cannot create archive scratch directory"
      # Expand now: EXIT must not read an unbound local under set -u.
      # shellcheck disable=SC2064
      trap "rm -rf -- $(printf '%q' "$scratch")" EXIT
      fm_record_scan_archive_preflight "$dir" "$scratch"
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
