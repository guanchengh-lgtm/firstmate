#!/usr/bin/env bash
# Check that every closed ticket id and every keep-row title appears in a
# compiled spec as a tag or an explicit refusal.
#
# Usage: fm-spec-compile-check.sh --home <dir>
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>] [--keep-source <report.md>]...
#        fm-spec-compile-check.sh --spec <spec.md> --tickets <dir>
#          --keep-source <report.md> [--keep-source <report.md>]...
#          [--expect-rule <rule-id> --expect-count <count>]
#          [--rules <id,id>]
#
# --home or --spec is required. The helper never reads FM_HOME, FM_ROOT, or
# the current working tree as an implicit input home. A missing flag, a
# missing or empty spec, a missing tickets directory, zero closed D/R
# tickets, a missing keep source, or zero keep-row titles is a structural
# failure, exit 2, never a clean pass.
#
# --home DIR uses DIR/data/wf-map2-loops/spec.md and
# DIR/data/wf-map2-loops/tickets/. Keep sources are the backtick-cited
# data/.../report.md files in that spec, resolved under DIR, unless
# --keep-source names them explicitly. A cited report.md that is missing
# is structural. A cited report with no ### Keep table is skipped.
#
# --spec FILE --tickets DIR requires at least one --keep-source. Paths are
# used as given. --home cannot be combined with --spec or --tickets.
#
# Closed tickets are ordinary D<number>-*.md / R<number>-*.md files whose
# first 40 lines contain a `status: CLOSED` line. Open tickets are ignored.
# A ticket id is present when it appears in the spec body as a whole token
# (D8 does not match D80) or in an explicit-refusal span.
#
# Keep-row titles are the Idea cells of markdown tables under `### Keep`.
# A title is present when the spec body contains its title key (the text
# before the first colon when that left side has two or more words, else
# the stripped idea), or a quoted string of two or more words that is a
# compact prefix of the idea, or an explicit-refusal span names it.
#
# The spec body is the file up to `## 10.` when that heading exists.
# Section 10 is a handwritten location index, not a tag. The paragraph
# that starts with "Explicit refusals" in that section, and any line
# containing `refused:`, is the refusal span.
#
# Default rules:
#   R-ticket-lock  a closed ticket id is missing from the spec body and
#                  is not refused
#   R-keep-lock    a keep-row title is missing from the spec body and
#                  is not refused
#
# Findings exit 1. Clean exit 0. Exact-count regression requires both
# --expect-rule and --expect-count and exits 0 only when that rule count
# and the total finding count both equal the expected count.
# --expect-count 0 is structural.
#
# LIMITS: ticket ids, not lock clauses (D4 late-rec prose is invisible).
# Keep-items outside ### Keep tables are invisible. Paraphrase without
# the title key or a two-word quoted prefix is invisible. Drop-table
# rows are not keep-rows. A citation containing < or > is a placeholder,
# never a file.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
KEEP_ROWS_PY="$SCRIPT_DIR/fm-keep-rows.py"

home=
spec=
tickets=
expect_rule=
expect_count=
rules="R-ticket-lock,R-keep-lock"
keep_sources=()

usage() {
  sed -n '2,59p' "$0" | sed 's/^# \{0,1\}//'
}

structural() {
  printf 'structural: %s\n' "$*" >&2
  exit 2
}

is_known_rule() {
  local want=$1
  case "$want" in
    R-ticket-lock|R-keep-lock) return 0 ;;
    *) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || structural "--home requires a path"
      home=$2
      shift 2
      ;;
    --spec)
      [ "$#" -ge 2 ] || structural "--spec requires a path"
      spec=$2
      shift 2
      ;;
    --tickets)
      [ "$#" -ge 2 ] || structural "--tickets requires a path"
      tickets=$2
      shift 2
      ;;
    --keep-source)
      [ "$#" -ge 2 ] || structural "--keep-source requires a path"
      keep_sources+=("$2")
      shift 2
      ;;
    --expect-rule)
      [ "$#" -ge 2 ] || structural "--expect-rule requires a rule id"
      expect_rule=$2
      shift 2
      ;;
    --expect-count)
      [ "$#" -ge 2 ] || structural "--expect-count requires a count"
      expect_count=$2
      shift 2
      ;;
    --rules)
      [ "$#" -ge 2 ] || structural "--rules requires a value"
      rules=$2
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

[ -n "$rules" ] || structural "empty --rules"
selected=()
IFS=',' read -r -a selected <<< "$rules" || true
cleaned=()
for r in "${selected[@]+"${selected[@]}"}"; do
  r=${r#"${r%%[![:space:]]*}"}
  r=${r%"${r##*[![:space:]]}"}
  [ -n "$r" ] || continue
  is_known_rule "$r" || structural "unknown rule id: $r"
  cleaned+=("$r")
done
[ "${#cleaned[@]}" -gt 0 ] || structural "empty --rules"
selected=("${cleaned[@]}")

if [ -n "$expect_rule" ] || [ -n "$expect_count" ]; then
  [ -n "$expect_rule" ] && [ -n "$expect_count" ] \
    || structural "regression mode needs both --expect-rule and --expect-count"
  case "$expect_count" in
    ''|*[!0-9]*) structural "expect-count must be > 0" ;;
  esac
  [ "$((10#$expect_count))" -gt 0 ] || structural "expect-count must be > 0"
  is_known_rule "$expect_rule" || structural "unknown expect-rule $expect_rule"
  found_selected=0
  for r in "${selected[@]+"${selected[@]}"}"; do
    if [ "$r" = "$expect_rule" ]; then
      found_selected=1
      break
    fi
  done
  [ "$found_selected" -eq 1 ] \
    || structural "--expect-rule $expect_rule is not in the selected rule set"
fi

if [ -n "$home" ]; then
  [ -z "$spec" ] && [ -z "$tickets" ] \
    || structural "--home cannot be combined with --spec or --tickets"
  spec="${home%/}/data/wf-map2-loops/spec.md"
  tickets="${home%/}/data/wf-map2-loops/tickets"
elif [ -n "$spec" ] || [ -n "$tickets" ]; then
  [ -n "$spec" ] || structural "missing --spec"
  [ -n "$tickets" ] || structural "missing --tickets"
  [ "${#keep_sources[@]}" -gt 0 ] || structural "empty keep-row input"
else
  structural "missing --home or --spec"
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-spec-compile-check.XXXXXX") || structural "could not create temp dir"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM
KEEP_LIST="$TMP_DIR/keep-sources.txt"
: > "$KEEP_LIST"
for k in "${keep_sources[@]+"${keep_sources[@]}"}"; do
  printf '%s\n' "$k" >> "$KEEP_LIST"
done

RULES_CSV=$(IFS=','; printf '%s' "${selected[*]}")
[ -f "$KEEP_ROWS_PY" ] || structural "missing keep-row parser $KEEP_ROWS_PY"

python3 - "$KEEP_ROWS_PY" "$spec" "$tickets" "${home:-}" "$KEEP_LIST" "$RULES_CSV" "${expect_rule:-}" "${expect_count:-}" <<'PY'
import os
import re
import sys

keep_rows_path, spec_path, tickets_dir, home, keep_list_path, rules_csv, expect_rule, expect_count = sys.argv[1:9]
selected = [r for r in rules_csv.split(",") if r]


def structural(msg):
    print("structural: %s" % msg, file=sys.stderr)
    sys.exit(2)


def is_ordinary_file(path):
    return os.path.isfile(path) and not os.path.islink(path)


def is_ordinary_dir(path):
    return os.path.isdir(path) and not os.path.islink(path)


def read_text(path, label):
    if not os.path.exists(path):
        structural("missing %s %s" % (label, path))
    if not is_ordinary_file(path):
        structural("%s is not a regular file: %s" % (label, path))
    if os.path.getsize(path) == 0:
        structural("empty %s %s" % (label, path))
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.strip():
        structural("empty %s %s" % (label, path))
    return text


def strip_md(text):
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"\*([^*]+)\*", r"\1", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = text.replace("**", "").replace("*", "").replace("`", "")
    return re.sub(r"\s+", " ", text).strip()


def compact(text):
    text = strip_md(text)
    text = text.replace("…", " ").replace("...", " ")
    text = re.sub(r'["“”\'‘’]+', "", text)
    text = re.sub(r"[,;:()~]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def title_key(idea):
    stripped = strip_md(idea)
    if ":" in stripped:
        left = stripped.split(":", 1)[0].strip()
        if len(left.split()) >= 2:
            return left
    return stripped


def load_keep_rows(path):
    if not os.path.isfile(path) or os.path.islink(path):
        structural("missing keep-row parser %s" % path)
    ns = {}
    with open(path, encoding="utf-8") as fh:
        exec(compile(fh.read(), path, "exec"), ns)
    fn = ns.get("keep_rows")
    if not callable(fn):
        structural("keep-row parser missing keep_rows")
    return fn


keep_rows = load_keep_rows(keep_rows_path)


def split_body_and_refusals(spec):
    match = re.search(r"^## 10\b", spec, re.M)
    if match:
        body = spec[: match.start()]
        rest = spec[match.start() :]
    else:
        body = spec
        rest = ""
    refusals = []
    rm = re.search(r"(?im)^.*explicit refusals.*", rest)
    if rm:
        chunk = rest[rm.start() :]
        stop = re.search(r"\n## |\n---\s*\n", chunk[1:])
        if stop:
            chunk = chunk[: stop.start() + 1]
        refusals.append(chunk)
    for line in spec.splitlines():
        if re.search(r"(?i)refused:", line):
            refusals.append(line)
    return body, "\n".join(refusals)


def quoted_strings(text):
    return re.findall(r'"([^"]+)"', text)


def keep_present(idea, body, refusals):
    key = title_key(idea)
    stripped = strip_md(idea)
    if key and key in body:
        return True
    if key and key in refusals:
        return True
    if stripped and stripped in refusals:
        return True
    idea_compact = compact(idea)
    for blob in (body, refusals):
        for quoted in quoted_strings(blob):
            qn = compact(quoted)
            if len(qn.split()) < 2:
                continue
            if idea_compact.startswith(qn) or qn.startswith(idea_compact):
                return True
    return False


def token_present(tid, text):
    return re.search(r"(?<![A-Za-z0-9])" + re.escape(tid) + r"(?![A-Za-z0-9])", text) is not None


def is_closed(text):
    for line in text.splitlines()[:40]:
        if re.match(r"(?i)^status:\s*CLOSED\b", line.strip()):
            return True
    return False


def cited_reports(spec):
    found = re.findall(r"`(data/[^`]*report\.md)`", spec)
    return sorted(set(path for path in found if "<" not in path and ">" not in path))


spec_text = read_text(spec_path, "spec")
if not is_ordinary_dir(tickets_dir):
    if not os.path.exists(tickets_dir):
        structural("missing tickets directory %s" % tickets_dir)
    structural("tickets path is not a directory: %s" % tickets_dir)

closed = []
seen_ids = set()
for name in sorted(os.listdir(tickets_dir)):
    match = re.match(r"^([DR][0-9]+)-.+\.md$", name)
    if not match:
        continue
    path = os.path.join(tickets_dir, name)
    if not is_ordinary_file(path):
        structural("ticket is not a regular file: %s" % path)
    text = read_text(path, "ticket")
    tid = match.group(1)
    if is_closed(text) and tid not in seen_ids:
        seen_ids.add(tid)
        closed.append(tid)

if not closed:
    structural("empty ticket input")

explicit_keeps = []
with open(keep_list_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            explicit_keeps.append(line)

keep_ideas = []
if explicit_keeps:
    for path in explicit_keeps:
        text = read_text(path, "keep source")
        keep_ideas.extend(keep_rows(text))
    if not keep_ideas:
        structural("empty keep-row input")
elif home:
    if not is_ordinary_dir(home):
        structural("home is not a directory: %s" % home)
    cited = cited_reports(spec_text)
    if not cited:
        structural("empty keep-row input")
    for rel in cited:
        path = os.path.join(home, rel)
        if not os.path.exists(path):
            structural("missing keep source %s" % path)
        text = read_text(path, "keep source")
        keep_ideas.extend(keep_rows(text))
    if not keep_ideas:
        structural("empty keep-row input")
else:
    structural("empty keep-row input")

body, refusals = split_body_and_refusals(spec_text)
findings = []
if "R-ticket-lock" in selected:
    for tid in closed:
        if not (token_present(tid, body) or token_present(tid, refusals)):
            findings.append("R-ticket-lock-missing: %s" % tid)
if "R-keep-lock" in selected:
    seen = set()
    for idea in keep_ideas:
        key = title_key(idea)
        if key in seen:
            continue
        seen.add(key)
        if not keep_present(idea, body, refusals):
            findings.append("R-keep-lock-missing: %s" % key)

if expect_rule:
    prefix = expect_rule + "-"
    selected_count = sum(1 for item in findings if item.startswith(prefix))
    total = len(findings)
    want = int(expect_count)
    if selected_count != want or total != want:
        print(
            "regression: expected %s finding(s) and %s total, observed %s and %s total"
            % (want, want, selected_count, total),
            file=sys.stderr,
        )
        for item in findings:
            print(item, file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

if findings:
    sys.stdout.write("\n".join(findings) + "\n")
    sys.exit(1)
sys.exit(0)
PY
