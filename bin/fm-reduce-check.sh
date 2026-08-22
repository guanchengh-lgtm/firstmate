#!/usr/bin/env bash
# Check that every expected wide-work report exists, is non-empty, and is
# cited by the synthesis file. Code writes the keep-list from those reports.
#
# Usage: fm-reduce-check.sh --expect <report.md> [--expect <report.md>]...
#          --cited-by <file> [--keep-list <out>]
#
# --expect and --cited-by are required. The helper never reads FM_HOME,
# FM_ROOT, or the current working tree as an implicit input home. Paths are
# used as given. A missing --expect list, --expect with zero paths, a
# missing --cited-by path, or a missing cited-by file is a structural
# failure, exit 2, never a clean pass.
#
# Default rules:
#   R-reduce-missing  an expected report does not exist, is empty, or is
#                     not a regular file
#   R-reduce-uncited  an expected report's path does not appear in
#                     backticks in --cited-by
#
# A cited-by file may declare a member out with
# `expected-reports: id-a, id-b(failed: <reason>)`. A failed member is
# printed as R-reduce-failed-declared and is not a finding. Member ids
# match the data/<id>/ directory of an --expect path.
#
# Keep-list: stdout (or --keep-list) lists each present expected report's
# id and its ### Keep rows via bin/fm-keep-rows.py, the compile matcher's
# keep-row parser. A model may cite only that list.
#
# Findings exit 1, one line each naming the path. Clean exit 0.
#
# LIMITS: N is the --expect list the caller passed. A citation is backtick
# path presence, not grounding. Empty ### Keep tables still count as
# present. This matcher does not wait or poll. A citation containing < or
# > is a placeholder, never a file. Failed-declared applies only when the
# cited-by expected-reports line names that id.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
KEEP_ROWS_PY="$SCRIPT_DIR/fm-keep-rows.py"

expect_paths=()
cited_by=
keep_list=
seen_cited=0
seen_keep_list=0

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

structural() {
  printf 'structural: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --expect)
      [ "$#" -ge 2 ] || structural "--expect requires a path"
      case "$2" in
        --*) structural "--expect requires a path" ;;
      esac
      expect_paths+=("$2")
      shift 2
      ;;
    --cited-by)
      [ "$#" -ge 2 ] || structural "--cited-by requires a path"
      [ "$seen_cited" -eq 0 ] || structural "duplicate --cited-by"
      cited_by=$2
      seen_cited=1
      shift 2
      ;;
    --keep-list)
      [ "$#" -ge 2 ] || structural "--keep-list requires a path"
      [ "$seen_keep_list" -eq 0 ] || structural "duplicate --keep-list"
      keep_list=$2
      seen_keep_list=1
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      structural "unknown argument: $1"
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || structural "python3 not found"
[ -f "$KEEP_ROWS_PY" ] || structural "missing keep-row parser $KEEP_ROWS_PY"
[ "$seen_cited" -eq 1 ] || structural "missing --cited-by"
[ -n "$cited_by" ] || structural "missing --cited-by"
[ "${#expect_paths[@]}" -gt 0 ] || structural "missing --expect"

EXPECT_LIST=$(mktemp "${TMPDIR:-/tmp}/fm-reduce-expect.XXXXXX") || structural "could not create temp file"
cleanup() { rm -f -- "$EXPECT_LIST"; }
trap cleanup EXIT HUP INT TERM
: > "$EXPECT_LIST"
for p in "${expect_paths[@]}"; do
  printf '%s\n' "$p" >> "$EXPECT_LIST"
done

python3 - "$KEEP_ROWS_PY" "$cited_by" "$EXPECT_LIST" "${keep_list:-}" <<'PY'
import os
import re
import sys

keep_rows_path, cited_by, expect_list_path, keep_list_path = sys.argv[1:5]


def structural(msg):
    print("structural: %s" % msg, file=sys.stderr)
    sys.exit(2)


def is_ordinary_file(path):
    return os.path.isfile(path) and not os.path.islink(path)


def load_keep_rows(path):
    if not is_ordinary_file(path):
        structural("missing keep-row parser %s" % path)
    ns = {}
    with open(path, encoding="utf-8") as fh:
        exec(compile(fh.read(), path, "exec"), ns)
    fn = ns.get("keep_rows")
    if not callable(fn):
        structural("keep-row parser missing keep_rows")
    return fn


keep_rows = load_keep_rows(keep_rows_path)

if not os.path.exists(cited_by):
    structural("missing cited-by %s" % cited_by)
if not is_ordinary_file(cited_by):
    structural("cited-by is not a regular file: %s" % cited_by)
with open(cited_by, encoding="utf-8") as fh:
    cited_text = fh.read()

expect_paths = []
with open(expect_list_path, encoding="utf-8") as fh:
    for line in fh:
        path = line.strip()
        if path:
            expect_paths.append(path)
if not expect_paths:
    structural("missing --expect")

EXPECTED_REPORTS_RE = re.compile(r"(?m)^[ \t]*expected-reports:[ \t]*(.*)$")
EXPECTED_MEMBER_RE = re.compile(
    r"([A-Za-z0-9][A-Za-z0-9._-]*)(?:\(failed:[ \t]*([^)]*)\))?"
)
CITED_RE = re.compile(r"`([^`]+)`")
REPORT_ID_RE = re.compile(r"(?:^|/)data/([^/]+)/report\.md$")


def parse_failed(text):
    match = EXPECTED_REPORTS_RE.search(text)
    if not match:
        return {}
    failed = {}
    for mm in EXPECTED_MEMBER_RE.finditer(match.group(1)):
        tid = mm.group(1)
        reason = mm.group(2)
        if reason is None:
            continue
        failed[tid] = reason.strip()
    return failed


def report_id(path):
    n = path.replace("\\", "/")
    match = REPORT_ID_RE.search(n)
    return match.group(1) if match else ""


def citation_forms(path):
    n = path.replace("\\", "/")
    forms = {n}
    idx = n.find("/data/")
    if idx >= 0:
        forms.add(n[idx + 1 :])
    if n.startswith("data/"):
        forms.add(n)
    return forms


def is_cited(path, text):
    forms = citation_forms(path)
    for raw in CITED_RE.findall(text):
        if "<" in raw or ">" in raw:
            continue
        cn = raw.replace("\\", "/")
        if cn in forms:
            return True
    return False


def present_report(path):
    if not os.path.exists(path):
        return False
    if not is_ordinary_file(path):
        return False
    if os.path.getsize(path) == 0:
        return False
    with open(path, encoding="utf-8") as fh:
        return bool(fh.read().strip())


failed_map = parse_failed(cited_text)
findings = []
failed_lines = []
keep_lines = []
seen_failed = set()

for path in expect_paths:
    rid = report_id(path)
    if rid and rid in failed_map and rid not in seen_failed:
        seen_failed.add(rid)
        reason = failed_map[rid]
        if reason:
            failed_lines.append("R-reduce-failed-declared: %s: %s" % (rid, reason))
        else:
            failed_lines.append("R-reduce-failed-declared: %s" % rid)
        continue
    if rid and rid in failed_map:
        continue
    if not present_report(path):
        findings.append("R-reduce-missing: %s" % path)
        continue
    if not is_cited(path, cited_text):
        findings.append("R-reduce-uncited: %s" % path)
    keep_lines.append("id: %s" % (rid or path))
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    for idea in keep_rows(text):
        keep_lines.append("keep: %s" % idea)

if keep_list_path:
    try:
        with open(keep_list_path, "w", encoding="utf-8") as fh:
            if keep_lines:
                fh.write("\n".join(keep_lines) + "\n")
    except OSError:
        structural("could not write keep-list %s" % keep_list_path)

if findings:
    out = failed_lines + findings
    sys.stdout.write("\n".join(out) + "\n")
    sys.exit(1)

out = failed_lines + keep_lines
if out:
    sys.stdout.write("\n".join(out) + "\n")
sys.exit(0)
PY
