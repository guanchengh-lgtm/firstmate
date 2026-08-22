#!/usr/bin/env bash
# Refuse ending a turn that wrote Map 2 spec, tickets, or keep-list files
# while the spec compile-check is red, or that wrote a spec, ticket, or
# data/decisions file carrying expected-reports: while the reduce-check is red.
#
# Usage: fm-spec-compile-stop-check.sh [--claude]
#          Stop-hook JSON on stdin.
#
# This is the Stop adapter, not the matcher. bin/fm-spec-compile-check.sh
# remains the compile matcher and must be invoked with an explicit --home (or
# explicit --spec / --tickets / --keep-source). bin/fm-reduce-check.sh is the
# reduce matcher and is invoked with explicit --expect paths and --cited-by.
# This adapter never reads FM_HOME, FM_ROOT, or the current working tree as
# an implicit compile or reduce home.
#
# It runs before primary-scope so child firstmate worktrees are not skipped.
# This-turn writes are taken from the Stop transcript after the last
# captain/user turn text (skip isMeta, tool_result-only, empty-text,
# operational FIRSTMATE_OP follow-ups, and harness-injected synthetic user
# rows: task-notification including Stop hook feedback, Request interrupted,
# local-command-stdout): Write / Edit / MultiEdit / NotebookEdit file_path
# values, and Bash command strings. A compile write counts when the string
# contains a suffix data/wf-map2-loops/spec.md, data/wf-map2-loops/tickets/<name>.md,
# or a data/<id>/report.md the spec cites in backticks. A reduce write counts
# when a spec, ticket, or data/decisions/<name>.md file written this turn
# contains an expected-reports: line. Home is the absolute prefix before
# /data/ in that path. Each expected-reports id resolves to
# <home>/data/<id>/report.md. A relative data/... path resolves against the
# payload cwd. No matching write: inert, even if a live spec is red. No
# expected-reports: line in this turn's writes: reduce is inert. Matcher
# findings (exit 1) and structural failures (exit 2) both become Stop exit 2.
# --claude is accepted for the same Stop shape as SoT speech and does not
# change the refuse. This adapter does not wait or poll for reports.
#
# LIMITS: matcher LIMITS stay in the matcher headers (ticket ids not lock
# clauses, keep rows only under ### Keep, paraphrase, section 10, open
# tickets; reduce N is the declared list, citation is backtick presence).
# Pi / OpenCode / pi-signed Stop payloads have no transcript and stay inert.
# Writes that are not a Stop (an editor save, git checkout) are invisible.
# Bash writes through variables or cd-then-relative names leave no literal
# suffix and are invisible. Writes outside spec, wf-map2-loops tickets, cited
# reports, and data/decisions/<name>.md are invisible to this adapter.
# A wrong or absent expected-reports line leaves reduce inert or satisfied.
# Missing payload, missing transcript, unreadable JSONL, or missing python3
# stay inert (exit 0).
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
MATCHER="$SCRIPT_DIR/fm-spec-compile-check.sh"
REDUCE="$SCRIPT_DIR/fm-reduce-check.sh"

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --claude) : ;;
    -h|--help) usage; exit 0 ;;
    *) echo "usage: $(basename "$0") [--claude]" >&2; exit 2 ;;
  esac
done

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ -x "$MATCHER" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-spec-compile-stop-check.XXXXXX") || exit 0
# shellcheck disable=SC2329 # Invoked by trap handlers below.
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM
PAYLOAD_FILE="$TMP_DIR/payload.json"
HOMES_FILE="$TMP_DIR/homes.txt"
JOBS_DIR="$TMP_DIR/reduce-jobs"
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE" || exit 0
mkdir -p "$JOBS_DIR" || exit 0

python3 - "$PAYLOAD_FILE" "$HOMES_FILE" "$JOBS_DIR" <<'PY' || exit 0
import json
import os
import re
import sys

payload_path, homes_path, jobs_dir = sys.argv[1:4]
FILE_TOOLS = {"write", "edit", "multiedit", "notebookedit"}
SHELL_TOOLS = {"bash"}
SPEC_RE = re.compile(r"data/wf-map2-loops/spec\.md")
TICKET_RE = re.compile(r"data/wf-map2-loops/tickets/[^/\s'\"\\]+\.md")
DECISION_RE = re.compile(r"data/decisions/[^/\s'\"\\]+\.md")
REPORT_RE = re.compile(r"data/[^/\s'\"\\]+/report\.md")
CITED_REPORT = re.compile(r"`(data/[^`]*report\.md)`")
EXPECTED_REPORTS_RE = re.compile(r"(?m)^[ \t]*expected-reports:[ \t]*(.*)$")
EXPECTED_MEMBER_RE = re.compile(
    r"([A-Za-z0-9][A-Za-z0-9._-]*)(?:\(failed:[ \t]*([^)]*)\))?"
)
OP_MARK = "\u2063"
PATH_BREAK = set(" \t\n\"'`")


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


try:
    payload = load_json(payload_path)
except (OSError, json.JSONDecodeError, TypeError):
    sys.exit(0)
if not isinstance(payload, dict):
    sys.exit(0)

transcript = payload.get("transcript_path") or payload.get("transcriptPath") or ""
if not isinstance(transcript, str) or not transcript:
    sys.exit(0)
if not os.path.isfile(transcript) or os.path.islink(transcript):
    sys.exit(0)

cwd = payload.get("cwd") or payload.get("CWD") or ""
if not isinstance(cwd, str):
    cwd = ""


def iter_records(path):
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def message_blob(record):
    if not isinstance(record, dict):
        return None
    msg = record.get("message")
    if isinstance(msg, dict):
        return msg
    return record


def role_of(blob, record):
    if isinstance(blob, dict) and blob.get("role"):
        return str(blob["role"]).lower()
    if isinstance(record, dict) and record.get("type"):
        t = str(record["type"]).lower()
        if t in ("assistant", "user"):
            return t
    return ""


def texts_of(content):
    out = []
    if isinstance(content, str):
        out.append(content)
        return out
    if not isinstance(content, list):
        return out
    for part in content:
        if isinstance(part, str):
            out.append(part)
        elif isinstance(part, dict) and isinstance(part.get("text"), str):
            out.append(part["text"])
    return out


def is_operational(text):
    return OP_MARK in text or "FIRSTMATE_OP:" in text or "turn-end-guard" in text


def is_tool_result_only(content):
    if not isinstance(content, list) or not content:
        return False
    for part in content:
        if not isinstance(part, dict):
            return False
        typ = str(part.get("type") or "")
        if typ not in ("tool_result", "toolResult"):
            return False
    return True


def is_synthetic_user_text(text):
    t = text.lstrip()
    if t.startswith("<task-notification"):
        return True
    if t.startswith("<local-command-stdout"):
        return True
    if t.startswith("[Request interrupted by user"):
        return True
    return False


def is_captain_turn(record, content):
    if isinstance(record, dict) and record.get("isMeta") is True:
        return False
    if is_tool_result_only(content):
        return False
    text = "\n".join(texts_of(content))
    if not text.strip():
        return False
    if is_operational(text):
        return False
    if is_synthetic_user_text(text):
        return False
    return True


def collect_tools(content, file_paths, bash_cmds):
    if not isinstance(content, list):
        return
    for part in content:
        if not isinstance(part, dict):
            continue
        typ = str(part.get("type") or "")
        if typ not in ("tool_use", "toolUse", "toolCall"):
            continue
        name = str(part.get("name") or part.get("tool_name") or "").lower()
        inp = part.get("input") if isinstance(part.get("input"), dict) else {}
        if not inp and isinstance(part.get("arguments"), dict):
            inp = part["arguments"]
        if name in SHELL_TOOLS:
            cmd = inp.get("command") or inp.get("cmd") or ""
            if isinstance(cmd, str) and cmd.strip():
                bash_cmds.append(cmd)
            continue
        if name not in FILE_TOOLS:
            continue
        val = inp.get("file_path")
        if isinstance(val, str) and val.strip():
            file_paths.append(val.strip())


def extract_from_text(text):
    found = []
    for cre in (SPEC_RE, TICKET_RE, DECISION_RE, REPORT_RE):
        for match in cre.finditer(text):
            start = match.start()
            i = start
            while i > 0 and text[i - 1] not in PATH_BREAK:
                i -= 1
            found.append(text[i:match.end()])
    return found


file_paths = []
bash_cmds = []
for record in iter_records(transcript):
    blob = message_blob(record)
    role = role_of(blob or {}, record)
    content = blob.get("content") if isinstance(blob, dict) else None
    if role == "user":
        if is_captain_turn(record, content):
            file_paths = []
            bash_cmds = []
        continue
    if role == "assistant":
        collect_tools(content, file_paths, bash_cmds)

candidates = list(file_paths)
for cmd in bash_cmds:
    candidates.extend(extract_from_text(cmd))


def resolve_path(raw):
    raw = str(raw).strip()
    if not raw:
        return ""
    n = raw.replace("\\", "/")
    if os.path.isabs(n):
        return os.path.normpath(n)
    if n.startswith("data/") and cwd:
        return os.path.normpath(os.path.join(cwd, n))
    if cwd and not os.path.isabs(n):
        return os.path.normpath(os.path.join(cwd, n))
    return os.path.normpath(n)


def home_of(path):
    n = path.replace("\\", "/")
    idx = n.find("/data/")
    if idx <= 0:
        return ""
    return n[:idx]


def cited_reports(home):
    spec = os.path.join(home, "data", "wf-map2-loops", "spec.md")
    if not home or not os.path.isfile(spec) or os.path.islink(spec):
        return set()
    try:
        with open(spec, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return set()
    found = CITED_REPORT.findall(text)
    return set(p for p in found if "<" not in p and ">" not in p)


def kind_of(path):
    n = path.replace("\\", "/")
    if SPEC_RE.search(n):
        return "spec"
    if TICKET_RE.search(n):
        return "ticket"
    if DECISION_RE.search(n):
        return "decision"
    if REPORT_RE.search(n):
        return "report"
    return ""


def parse_expected_ids(text):
    match = EXPECTED_REPORTS_RE.search(text)
    if not match:
        return None
    ids = []
    seen_ids = set()
    for mm in EXPECTED_MEMBER_RE.finditer(match.group(1)):
        tid = mm.group(1)
        if tid in seen_ids:
            continue
        seen_ids.add(tid)
        ids.append(tid)
    return ids


homes = []
seen = set()
for raw in candidates:
    path = resolve_path(raw)
    if not path:
        continue
    kind = kind_of(path)
    if not kind or kind == "decision":
        continue
    home = home_of(path)
    if not home:
        continue
    if kind == "report":
        match = REPORT_RE.search(path.replace("\\", "/"))
        rel = match.group(0) if match else ""
        if rel not in cited_reports(home):
            continue
    if home in seen:
        continue
    spec = os.path.join(home, "data", "wf-map2-loops", "spec.md")
    tickets = os.path.join(home, "data", "wf-map2-loops", "tickets")
    if not os.path.exists(spec) and not os.path.isdir(tickets):
        continue
    seen.add(home)
    homes.append(home)

reduce_jobs = []
reduce_seen = set()
for raw in candidates:
    path = resolve_path(raw)
    if not path:
        continue
    kind = kind_of(path)
    if kind not in ("spec", "ticket", "decision"):
        continue
    if not os.path.isfile(path) or os.path.islink(path):
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        continue
    ids = parse_expected_ids(text)
    if ids is None:
        continue
    home = home_of(path)
    if not home:
        continue
    if path in reduce_seen:
        continue
    reduce_seen.add(path)
    expects = [
        os.path.normpath(os.path.join(home, "data", tid, "report.md"))
        for tid in ids
    ]
    reduce_jobs.append((path, expects))

try:
    with open(homes_path, "w", encoding="utf-8") as fh:
        for home in homes:
            fh.write(home + "\n")
    os.makedirs(jobs_dir, exist_ok=True)
    for i, (cited, expects) in enumerate(reduce_jobs):
        with open(os.path.join(jobs_dir, "%04d.txt" % i), "w", encoding="utf-8") as fh:
            fh.write(cited + "\n")
            for p in expects:
                fh.write(p + "\n")
except OSError:
    sys.exit(0)
PY

[ -f "$HOMES_FILE" ] || exit 0

while IFS= read -r home || [ -n "${home:-}" ]; do
  [ -n "$home" ] || continue
  out=$("$MATCHER" --home "$home" 2>&1)
  rc=$?
  if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; then
    printf '%s\n' "$out" >&2
    exit 2
  fi
done < "$HOMES_FILE"

if [ -d "$JOBS_DIR" ]; then
  for job in "$JOBS_DIR"/*.txt; do
    [ -f "$job" ] || continue
    if [ ! -x "$REDUCE" ]; then
      printf 'structural: missing reduce matcher %s\n' "$REDUCE" >&2
      exit 2
    fi
    cited=
    expect_args=()
    while IFS= read -r line || [ -n "${line:-}" ]; do
      if [ -z "${cited}" ]; then
        cited=$line
        continue
      fi
      [ -n "$line" ] || continue
      expect_args+=(--expect "$line")
    done < "$job"
    [ -n "$cited" ] || continue
    if [ "${#expect_args[@]}" -gt 0 ]; then
      out=$("$REDUCE" --cited-by "$cited" "${expect_args[@]}" 2>&1)
    else
      out=$("$REDUCE" --cited-by "$cited" 2>&1)
    fi
    rc=$?
    if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; then
      printf '%s\n' "$out" >&2
      exit 2
    fi
  done
fi

exit 0
