#!/usr/bin/env bash
# Refuse ending a turn that wrote Map 2 spec, tickets, or keep-list files
# while the spec compile-check is red.
#
# Usage: fm-spec-compile-stop-check.sh [--claude]
#          Stop-hook JSON on stdin.
#
# This is the Stop adapter, not the matcher. bin/fm-spec-compile-check.sh
# remains the matcher and must be invoked with an explicit --home (or
# explicit --spec / --tickets / --keep-source). This adapter never reads
# FM_HOME, FM_ROOT, or the current working tree as an implicit compile home.
#
# It runs before primary-scope so child firstmate worktrees are not skipped.
# This-turn writes are taken from the Stop transcript after the last
# non-operational user message: Write / Edit / MultiEdit / NotebookEdit
# file_path values, and Bash command strings. A write counts when the string
# contains a suffix data/wf-map2-loops/spec.md, data/wf-map2-loops/tickets/<name>.md,
# or a data/<id>/report.md the spec cites in backticks. Home is the absolute
# prefix before /data/ in that path. A relative data/... path resolves against
# the payload cwd. No matching write: inert, even if a live spec is red.
# Matcher findings (exit 1) and structural failures (exit 2) both become
# Stop exit 2. --claude is accepted for the same Stop shape as SoT speech
# and does not change the refuse.
#
# LIMITS: matcher LIMITS stay in the matcher header (ticket ids not lock
# clauses, keep rows only under ### Keep, paraphrase, section 10, open
# tickets). Pi / OpenCode / pi-signed Stop payloads have no transcript and
# stay inert. Writes that are not a Stop (an editor save, git checkout) are
# invisible. Bash writes through variables or cd-then-relative names leave
# no literal suffix and are invisible. Missing payload, missing transcript,
# unreadable JSONL, or missing python3 stay inert (exit 0).
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
MATCHER="$SCRIPT_DIR/fm-spec-compile-check.sh"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
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
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE" || exit 0

python3 - "$PAYLOAD_FILE" "$HOMES_FILE" <<'PY' || exit 0
import json
import os
import re
import sys

payload_path, homes_path = sys.argv[1:3]
FILE_TOOLS = {"write", "edit", "multiedit", "notebookedit"}
SHELL_TOOLS = {"bash"}
SPEC_RE = re.compile(r"data/wf-map2-loops/spec\.md")
TICKET_RE = re.compile(r"data/wf-map2-loops/tickets/[^/\s'\"\\]+\.md")
REPORT_RE = re.compile(r"data/[^/\s'\"\\]+/report\.md")
CITED_REPORT = re.compile(r"`(data/[^`]*report\.md)`")
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
    for cre in (SPEC_RE, TICKET_RE, REPORT_RE):
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
        text = "\n".join(texts_of(content))
        if not is_operational(text):
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
    if REPORT_RE.search(n):
        return "report"
    return ""


homes = []
seen = set()
for raw in candidates:
    path = resolve_path(raw)
    if not path:
        continue
    kind = kind_of(path)
    if not kind:
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

try:
    with open(homes_path, "w", encoding="utf-8") as fh:
        for home in homes:
            fh.write(home + "\n")
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

exit 0
