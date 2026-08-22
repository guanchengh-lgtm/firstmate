#!/usr/bin/env bash
# Refuse ending a turn that wrote Map 2 spec, tickets, or keep-list files
# while the spec compile-check is red.
#
# Usage: fm-spec-compile-turnend.sh
#          Stop-hook JSON on stdin.
#
# This is the Stop adapter, not the matcher. bin/fm-spec-compile-check.sh
# remains the matcher and must be invoked with an explicit --home (or
# explicit --spec / --tickets / --keep-source). This adapter never reads
# FM_HOME, FM_ROOT, or the current working tree as an implicit compile home.
#
# It runs in child firstmate worktrees. The operating home is the prefix of
# a this-turn write before /data/wf-map2-loops/ or before a cited
# data/.../report.md. No matching write: inert, even if a live spec is red.
# Homes with no Map 2 tree: inert. Helper findings (exit 1) and structural
# failures (exit 2) both become Stop exit 2.
#
# This-turn writes are Write/Edit-shaped file tools and write-shaped shell
# paths in the Stop transcript after the last non-operational user message.
# Operational FIRSTMATE_OP follow-ups do not start a new turn, so a blocked
# Stop's continuation still sees the compile writes.
#
# A keep-list hit is a write of a report.md the spec cites, or a write of a
# path this turn also passed as --keep-source.
#
# LIMITS: matcher LIMITS stay in the matcher header (ticket ids not lock
# clauses, keep rows only under ### Keep, paraphrase, section 10, open
# tickets). Writes with no path in the transcript, MCP write tools, Stop
# payloads without transcript_path, and editors outside the hook are
# invisible. Passive Stop harnesses force one follow-up; they do not
# hard-block. Missing payload, missing transcript, unreadable JSONL, or
# missing python3 stay inert (exit 0).
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
MATCHER="$SCRIPT_DIR/fm-spec-compile-check.sh"

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) echo "usage: $(basename "$0")" >&2; exit 2 ;;
  esac
done

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
[ -x "$MATCHER" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-spec-compile-turnend.XXXXXX") || exit 0
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
WRITE_STEMS = (
    "write", "edit", "patch", "notebook", "create", "replace", "insert",
    "append", "delete", "remove", "rename", "move", "copy",
)
READ_ONLY = {"notebookread", "readnotebook"}
PATH_KEYS = (
    "file_path", "notebook_path", "path", "filePath", "notebookPath",
    "target_file", "file", "old_path", "new_path",
)
WRITE_SHELL = re.compile(
    r"(?:>>|>|tee\s|sed\s+-i|\bcp\b|\bmv\b|\brm\b|\btouch\b|--keep-source)",
    re.I,
)
KEEP_SOURCE_RE = re.compile(r"--keep-source(?:\s+|=)(\S+)")
TICKET_REST = re.compile(r"^tickets/[DR][0-9]+-.+\.md$")
CITED_REPORT = re.compile(r"`(data/[^`]*report\.md)`")
OP_MARK = "\u2063"


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
if not isinstance(cwd, str) or not cwd:
    cwd = os.environ.get("GROK_WORKSPACE_ROOT") or os.environ.get("CLAUDE_PROJECT_DIR") or ""
if not isinstance(cwd, str):
    cwd = ""


def alnum_lower(name):
    return re.sub(r"[^a-z0-9]", "", str(name).lower())


def is_mcp(name):
    return str(name).lower().startswith("mcp__") or alnum_lower(name).startswith("mcp")


def is_write_tool(name):
    if is_mcp(name):
        return False
    n = alnum_lower(name)
    if n in READ_ONLY:
        return False
    return any(stem in n for stem in WRITE_STEMS)


def is_shell_tool(name):
    if is_mcp(name):
        return False
    n = alnum_lower(name)
    return n in ("bash", "shell") or "execcommand" in n


def resolve_path(raw):
    raw = str(raw).strip()
    if not raw:
        return ""
    if os.path.isabs(raw):
        return os.path.normpath(raw)
    if cwd:
        return os.path.normpath(os.path.join(cwd, raw))
    return os.path.normpath(raw)


def slash(path):
    return path.replace("\\", "/")


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
        if t in ("assistant", "user", "tool_result", "toolresult"):
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
        elif isinstance(part, dict):
            if isinstance(part.get("text"), str):
                out.append(part["text"])
            inner = part.get("content")
            if isinstance(inner, str):
                out.append(inner)
    return out


def is_operational(text):
    return OP_MARK in text or "FIRSTMATE_OP:" in text or "turn-end-guard" in text


def collect_tools(content, paths, cmds):
    if not isinstance(content, list):
        return
    for part in content:
        if not isinstance(part, dict):
            continue
        typ = str(part.get("type") or "")
        if typ not in ("tool_use", "toolUse", "toolCall"):
            continue
        name = str(part.get("name") or part.get("tool_name") or "")
        inp = part.get("input") if isinstance(part.get("input"), dict) else {}
        if not inp and isinstance(part.get("arguments"), dict):
            inp = part["arguments"]
        if is_shell_tool(name):
            cmd = inp.get("command") or inp.get("cmd") or ""
            if isinstance(cmd, str) and cmd.strip():
                cmds.append(cmd)
            continue
        if not is_write_tool(name):
            continue
        for key in PATH_KEYS:
            val = inp.get(key)
            if isinstance(val, str) and val.strip():
                paths.append(val.strip())


paths = []
cmds = []
for record in iter_records(transcript):
    blob = message_blob(record)
    role = role_of(blob or {}, record)
    content = blob.get("content") if isinstance(blob, dict) else None
    if role == "user":
        text = "\n".join(texts_of(content))
        if not is_operational(text):
            paths = []
            cmds = []
        continue
    if role == "assistant":
        collect_tools(content, paths, cmds)

keep_flags = []
for cmd in cmds:
    keep_flags.extend(KEEP_SOURCE_RE.findall(cmd))
    if not WRITE_SHELL.search(cmd):
        continue
    for token in cmd.split():
        if "data/wf-map2-loops/" in token or token.endswith("report.md") or "/report.md" in token:
            paths.append(token.strip("\"'"))


def split_map2(path):
    n = slash(path)
    marker = "/data/wf-map2-loops/"
    if n.startswith("data/wf-map2-loops/"):
        return "", n[len("data/wf-map2-loops/"):]
    idx = n.find(marker)
    if idx == -1:
        return None
    return n[:idx], n[idx + len(marker):]


def split_report(path):
    n = slash(path)
    m = re.search(r"^(.*)/data/(.+)/report\.md$", n)
    if m:
        return m.group(1), "data/%s/report.md" % m.group(2)
    m = re.match(r"^data/(.+)/report\.md$", n)
    if m:
        return "", "data/%s/report.md" % m.group(1)
    if n.endswith("/data/report.md"):
        return n[: -len("/data/report.md")], "data/report.md"
    if n == "data/report.md":
        return "", "data/report.md"
    return None


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


resolved_keep_flags = set()
for raw in keep_flags:
    got = resolve_path(raw)
    if got:
        resolved_keep_flags.add(slash(got))
        rel = slash(raw)
        if rel.startswith("data/") and rel.endswith("report.md"):
            resolved_keep_flags.add(rel)

homes = []
seen = set()


def add_home(home):
    if not home or home in seen:
        return
    spec = os.path.join(home, "data", "wf-map2-loops", "spec.md")
    tickets = os.path.join(home, "data", "wf-map2-loops", "tickets")
    if not os.path.exists(spec) and not os.path.isdir(tickets):
        return
    seen.add(home)
    homes.append(home)


for raw in paths:
    path = resolve_path(raw)
    if not path:
        continue
    split = split_map2(path)
    if split is not None:
        home, rest = split
        if not home:
            continue
        if rest == "spec.md" or TICKET_REST.match(rest):
            add_home(home)
        continue
    split = split_report(path)
    if split is None:
        continue
    home, rel = split
    if not home:
        continue
    npath = slash(path)
    if rel in cited_reports(home) or npath in resolved_keep_flags or rel in resolved_keep_flags:
        add_home(home)

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
