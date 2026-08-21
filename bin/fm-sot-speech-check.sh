#!/usr/bin/env bash
# Refuse captain-facing SoT content claims made without same-session file-read
# evidence.
#
# Usage: fm-sot-speech-check.sh [--claude] [--pretool]
#
# The private registry is $FM_HOME/data/sot-speech.tsv (override with
# FM_SOT_SPEECH_REGISTRY). Each effective row is:
#   sot_file <TAB> content_claim_ERE
# sot_file is relative to FM_HOME and must name an ordinary readable file.
# content_claim_ERE is a JavaScript regex matched against captain-facing text.
# Name-only mentions and a declared-unread sentence stay outside the refusal
# when they do not also state registered content.
#
# Stop mode reads the latest assistant text from transcript_path. PreToolUse
# mode reads every string under tool_input for an AskUserQuestion call. Both
# modes scan the whole session transcript for Read or shell-tool evidence that
# names the exact registered path. A session-start command credits only the
# files that digest actually prints, and only when those files exist.
#
# Missing registry, empty registry, unreadable transcript, missing jq/node, or
# malformed JSONL stay inert (exit 0). Malformed registry rows are structural
# failures and exit 2 before any finding. There is no skip flag.
#
# This check proves only that the registered file was opened in the session. It
# cannot prove a full or correct read, unregistered paraphrase, mixed unread-
# plus-content claims, non-file sources, or coverage on passive harness adapters.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
REGISTRY=${FM_SOT_SPEECH_REGISTRY:-$DATA/sot-speech.tsv}
NODE_BIN=${FM_SOT_SPEECH_NODE:-node}
CLAUDE_MODE=0
PRETOOL_MODE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude) CLAUDE_MODE=1 ;;
    --pretool) PRETOOL_MODE=1 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $(basename "$0") [--claude] [--pretool]" >&2; exit 2 ;;
  esac
  shift
done

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v "$NODE_BIN" >/dev/null 2>&1 || exit 0

# Match only real primary homes. Child task worktrees remain inert.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

[ -e "$REGISTRY" ] || exit 0
[ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] && [ -r "$REGISTRY" ] || {
  echo "SOT_SPEECH_REFUSED: registry is not a readable ordinary file: $REGISTRY" >&2
  exit 2
}

TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '(.transcript_path // .transcriptPath // empty)' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] || exit 0
[ -f "$TRANSCRIPT" ] && [ ! -L "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-sot-speech.XXXXXX") || exit 0
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM
NORMALIZED="$TMP_DIR/registry.tsv"
PAYLOAD_FILE="$TMP_DIR/payload.json"
: > "$NORMALIZED"
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE" || exit 0

trim_space() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

registry_error() {
  echo "SOT_SPEECH_REFUSED: registry invalid - $*" >&2
  exit 2
}

line_no=0
rows=0
while IFS= read -r row || [ -n "$row" ]; do
  line_no=$((line_no + 1))
  trimmed=$(trim_space "$row")
  case "$trimmed" in ''|\#*) continue ;; esac
  tabs=$(awk -F '\t' '{ print NF - 1 }' <<< "$row")
  [ "$tabs" -eq 1 ] || registry_error "line $line_no must contain exactly two tab-separated fields"
  file=${row%%$'\t'*}
  ere=${row#*$'\t'}
  [ -n "$file" ] && [ -n "$ere" ] || registry_error "line $line_no has an empty field"
  [ "$file" = "$(trim_space "$file")" ] && [ "$ere" = "$(trim_space "$ere")" ] \
    || registry_error "line $line_no has surrounding whitespace"
  case "$file" in
    /*|../*|*/../*|*/..) registry_error "line $line_no has an unsafe path: $file" ;;
  esac
  source_path="$FM_HOME/$file"
  [ -f "$source_path" ] && [ ! -L "$source_path" ] && [ -r "$source_path" ] \
    || registry_error "line $line_no source is not a readable ordinary file: $file"
  rows=$((rows + 1))
  printf '%s\t%s\n' "$file" "$ere" >> "$NORMALIZED"
done < "$REGISTRY"
[ "$rows" -gt 0 ] || exit 0

MODE=stop
[ "$PRETOOL_MODE" -eq 0 ] || MODE=pretool
RESULT=$(FM_SOT_SPEECH_HOME="$FM_HOME" FM_SOT_SPEECH_MODE="$MODE" \
  FM_SOT_SPEECH_TRANSCRIPT="$TRANSCRIPT" FM_SOT_SPEECH_REGISTRY_NORMALIZED="$NORMALIZED" \
  FM_SOT_SPEECH_PAYLOAD_FILE="$PAYLOAD_FILE" "$NODE_BIN" - 2>/dev/null <<'JS'
const fs = require("fs");
const path = require("path");

const home = fs.realpathSync.native(process.env.FM_SOT_SPEECH_HOME);
const transcript = process.env.FM_SOT_SPEECH_TRANSCRIPT;
const mode = process.env.FM_SOT_SPEECH_MODE;
const payload = JSON.parse(fs.readFileSync(process.env.FM_SOT_SPEECH_PAYLOAD_FILE, "utf8"));
const STARTUP_FILES = new Set([
  "data/captain.md",
  "data/captain-shared.md",
  "data/learnings.md",
  "data/projects.md",
  "data/secondmates.md",
]);

let rows;
try {
  rows = fs.readFileSync(process.env.FM_SOT_SPEECH_REGISTRY_NORMALIZED, "utf8")
    .split("\n").filter(Boolean).map((line) => {
      const tab = line.indexOf("\t");
      return { relative: line.slice(0, tab), regex: new RegExp(line.slice(tab + 1), "i") };
    });
} catch (err) {
  process.exit(2);
}

function message(record) {
  if (!record || typeof record !== "object" || record.isMeta === true) return null;
  const value = record.message && typeof record.message === "object" ? record.message : record;
  const role = value.role || record.type;
  if (role !== "assistant" && role !== "user") return null;
  return { role, content: value.content };
}

function textParts(content) {
  if (typeof content === "string") return [content];
  if (!Array.isArray(content)) return [];
  return content.flatMap((part) => part && typeof part === "object"
    && part.type === "text" && typeof part.text === "string" ? [part.text] : []);
}

function toolReads(content) {
  if (!Array.isArray(content)) return [];
  const reads = [];
  for (const part of content) {
    if (!part || typeof part !== "object") continue;
    const type = String(part.type || "");
    if (type !== "tool_use" && type !== "toolUse") continue;
    const name = String(part.name || part.tool_name || "").toLowerCase();
    const input = part.input && typeof part.input === "object" ? part.input : {};
    if (name === "read" && typeof input.file_path === "string") reads.push(input.file_path);
    if ((name === "bash" || name.includes("exec_command")) && typeof (input.command || input.cmd) === "string") {
      reads.push(input.command || input.cmd);
    }
  }
  return reads;
}

const sessionReads = [];
let latestAssistantText = "";
let sessionStart = false;
try {
  for (const line of fs.readFileSync(transcript, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let record;
    try { record = JSON.parse(line); } catch (err) { continue; }
    const value = message(record);
    if (!value) continue;
    if (value.role === "assistant") {
      const reads = toolReads(value.content);
      sessionReads.push(...reads);
      if (reads.some((evidence) => /fm-session-start\.sh\b/.test(String(evidence)))) {
        sessionStart = true;
      }
      const text = textParts(value.content).join("\n").trim();
      if (text) latestAssistantText = text;
    }
  }
} catch (err) {
  process.exit(0);
}

function strings(value, output = []) {
  if (typeof value === "string") output.push(value);
  else if (Array.isArray(value)) value.forEach((item) => strings(item, output));
  else if (value && typeof value === "object") Object.values(value).forEach((item) => strings(item, output));
  return output;
}

let speech = latestAssistantText;
if (mode === "pretool") {
  const tool = String(payload.tool_name || payload.toolName || "");
  if (tool !== "AskUserQuestion") process.exit(0);
  speech = strings(payload.tool_input || payload.toolInput || {}).join("\n");
}
if (!speech) process.exit(0);

function fileExists(relative) {
  try {
    const absolute = path.resolve(home, relative);
    const st = fs.lstatSync(absolute);
    return st.isFile() && !st.isSymbolicLink();
  } catch (err) {
    return false;
  }
}

function hasRead(relative) {
  const absolute = path.resolve(home, relative);
  if (sessionReads.some((evidence) => {
    if (typeof evidence !== "string") return false;
    if (evidence === relative || evidence === absolute) return true;
    return evidence.includes(relative) || evidence.includes(absolute);
  })) return true;
  return sessionStart && STARTUP_FILES.has(relative) && fileExists(relative);
}

function declaredUnread() {
  return /\b(unopened|not opened|have not opened|has not opened|unread|not read|have not read|has not read)\b/i.test(speech);
}

for (const row of rows) {
  if (!row.regex.test(speech)) continue;
  if (hasRead(row.relative) || declaredUnread()) continue;
  process.stdout.write(row.relative);
  process.exit(3);
}
JS
)
rc=$?
case "$rc" in
  0) exit 0 ;;
  2) echo "SOT_SPEECH_REFUSED: registry invalid - content_claim_ERE is not a usable JavaScript regex" >&2; exit 2 ;;
  3) : ;;
  *) exit 0 ;;
esac
[ -n "$RESULT" ] || exit 0

REASON="[sot-speech] open $RESULT in this session before stating what it says; otherwise name it only or state that it is unopened without describing its contents. This check proves an open, not reading fidelity."
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '; }
ESCAPED=$(json_escape "$REASON")
if [ "$PRETOOL_MODE" -eq 1 ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
else
  printf '%s\n' "$REASON" >&2
fi
exit 2
