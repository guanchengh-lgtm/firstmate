#!/usr/bin/env bash
# Print one bounded PRIOR SESSION fold from this home's prior Pi or Claude JSONL session log.
#
# Format:
#   PRIOR SESSION
#   source: <path>
#   scope: <targeted coverage disclosure>
#   LIVE JOBS
#   OPEN PICKS
#   CAPTAIN LOCK WORDS
#   fold-status: parsed within bound | INCOMPLETE: <reason>
#
# The fold extracts only live jobs, unanswered picks, and captain words that answered a pick or explicitly changed a lock.
# It does not ingest GBrain, Graphify, or Obsidian because those are not the resume floor.
# It does not claim 100% coverage of all chat.
# The source is the prior top-level Pi or Claude session JSONL whose recorded working directory matches this FM_HOME.
# FM_PRIOR_SESSION_LOG selects an exact source for a harness-provided prior path or a test fixture.
# FM_CURRENT_SESSION_LOG excludes a harness-provided current transcript during discovery.
# Without either exact path, discovery excludes the newest matching log as the current session and folds the next newest log.
# The whole rendered section uses the same ceil(UTF-8 bytes / 3) estimate as config/startup-memory-budget.
# Existing captain, shared-captain, and learnings memory is charged first, then this fold receives at most the remaining budget and FM_PRIOR_SESSION_TOKEN_CAP tokens.
# FM_PRIOR_SESSION_TOKEN_CAP defaults to 1200 tokens so a large unused home budget never turns this into a transcript dump.
# Missing, unreadable, unsafe, or malformed input prints INCOMPLETE and exits 2.
# Budget truncation prints INCOMPLETE and exits 0 because the source parsed successfully but the rendered fold is intentionally partial.
#
# Usage: fm-prior-session-fold.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NODE_BIN=${FM_PRIOR_SESSION_NODE:-node}
TOKEN_CAP=${FM_PRIOR_SESSION_TOKEN_CAP:-1200}

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

rule='================================================================================'

incomplete() {
  printf '\n%s\nPRIOR SESSION\n%s\n' "$rule" "$rule"
  printf 'scope: targeted prior-talk fold only; not 100%% of chat; no GBrain, Graphify, or Obsidian ingestion.\n'
  printf 'INCOMPLETE: %s\n' "$1"
  return 2
}

case "$TOKEN_CAP" in
  ''|0|*[!0-9]*|0*)
    incomplete 'invalid FM_PRIOR_SESSION_TOKEN_CAP; expected one positive decimal integer.'
    exit 2
    ;;
esac

if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
  incomplete "startup-memory budget is unavailable: $FM_STARTUP_MEMORY_BUDGET_ERROR"
  exit 2
fi
BUDGET=$FM_STARTUP_MEMORY_BUDGET_VALUE

MEMORY_TOKENS=
for memory_file in captain.md captain-shared.md learnings.md; do
  if ! fm_startup_memory_measure_file "$DATA/$memory_file" >/dev/null; then
    incomplete "startup memory cannot be measured: $FM_STARTUP_MEMORY_BUDGET_ERROR"
    exit 2
  fi
  if [ -n "$MEMORY_TOKENS" ]; then
    MEMORY_TOKENS="$MEMORY_TOKENS,$FM_STARTUP_MEMORY_MEASURE_TOKENS"
  else
    MEMORY_TOKENS=$FM_STARTUP_MEMORY_MEASURE_TOKENS
  fi
done

TMP_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/fm-prior-session-fold.XXXXXX" 2>/dev/null) || {
  incomplete 'could not create bounded parser output.'
  exit 2
}
cleanup() {
  rm -f "$TMP_OUTPUT"
}
trap cleanup EXIT HUP INT TERM

FM_PRIOR_FOLD_HOME="$FM_HOME" \
FM_PRIOR_FOLD_BUDGET="$BUDGET" \
FM_PRIOR_FOLD_MEMORY_TOKENS="$MEMORY_TOKENS" \
FM_PRIOR_FOLD_TOKEN_CAP="$TOKEN_CAP" \
"$NODE_BIN" - > "$TMP_OUTPUT" 2>/dev/null <<'JS'
const fs = require("fs");
const os = require("os");
const path = require("path");

const rule = "=".repeat(80);
const home = fs.realpathSync.native(process.env.FM_PRIOR_FOLD_HOME);
const current = process.env.FM_CURRENT_SESSION_LOG
  ? path.resolve(process.env.FM_CURRENT_SESSION_LOG)
  : "";
const exact = process.env.FM_PRIOR_SESSION_LOG
  ? path.resolve(process.env.FM_PRIOR_SESSION_LOG)
  : "";
const budget = BigInt(process.env.FM_PRIOR_FOLD_BUDGET);
const memoryTokens = process.env.FM_PRIOR_FOLD_MEMORY_TOKENS
  .split(",")
  .filter(Boolean)
  .reduce((sum, value) => sum + BigInt(value), 0n);
const configuredCap = BigInt(process.env.FM_PRIOR_FOLD_TOKEN_CAP);
const remaining = budget > memoryTokens ? budget - memoryTokens : 0n;
const tokenCap = remaining < configuredCap ? remaining : configuredCap;
const maxBytes = Number(tokenCap * 3n);

function incomplete(reason, source = "") {
  const lines = ["", rule, "PRIOR SESSION", rule];
  if (source) lines.push(`source: ${source}`);
  lines.push("scope: targeted prior-talk fold only; not 100% of chat; no GBrain, Graphify, or Obsidian ingestion.");
  lines.push(`INCOMPLETE: ${reason}`);
  process.stdout.write(`${lines.join("\n")}\n`);
  process.exitCode = 2;
}

function ordinaryFile(candidate) {
  try {
    const stat = fs.lstatSync(candidate);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function encodedClaudeProjectDir() {
  return home.replace(/[^A-Za-z0-9]/g, "-");
}

function encodedPiSessionDir() {
  const stripped = home.replace(/^[/\\]/, "");
  return `--${stripped.replace(/[/\\:]/g, "-")}--`;
}

function recordedCwd(candidate) {
  let data;
  try {
    const fd = fs.openSync(candidate, "r");
    const buffer = Buffer.alloc(65536);
    const count = fs.readSync(fd, buffer, 0, buffer.length, 0);
    fs.closeSync(fd);
    data = buffer.subarray(0, count).toString("utf8");
  } catch {
    return "";
  }
  for (const line of data.split("\n")) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line);
      if (typeof record.cwd === "string") return path.resolve(record.cwd);
    } catch {
      return "";
    }
  }
  return "";
}

function directJsonlFiles(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && entry.name.endsWith(".jsonl"))
      .map((entry) => path.join(dir, entry.name));
  } catch {
    return [];
  }
}

function discover() {
  if (exact) {
    if (!ordinaryFile(exact)) {
      incomplete("prior session log is missing, unreadable, or not an ordinary file.", exact);
      return "";
    }
    return exact;
  }

  const piBase = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), ".pi", "agent");
  const piRoot = path.join(piBase, "sessions");
  const claudeBase = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
  const claudeEncoded = encodedClaudeProjectDir();
  const dirs = process.env.FM_PRIOR_SESSION_DIRS
    ? process.env.FM_PRIOR_SESSION_DIRS.split(path.delimiter).filter(Boolean)
    : [
        process.env.PI_CODING_AGENT_SESSION_DIR || path.join(piRoot, encodedPiSessionDir()),
        path.join(claudeBase, "projects", claudeEncoded),
      ];
  const candidates = dirs.flatMap(directJsonlFiles)
    .filter(ordinaryFile)
    .filter((candidate) => !current || path.resolve(candidate) !== current)
    .filter((candidate) => {
      const cwd = recordedCwd(candidate);
      return !cwd || cwd === home;
    })
    .map((candidate) => ({ candidate, mtime: fs.statSync(candidate).mtimeMs }))
    .sort((left, right) => right.mtime - left.mtime);

  if (current) {
    if (!candidates.length) {
      incomplete(`no prior Pi or Claude session log was found for ${home}.`);
      return "";
    }
    return candidates[0].candidate;
  }
  if (candidates.length < 2) {
    incomplete(`no distinct prior Pi or Claude session log was found for ${home}.`);
    return "";
  }
  return candidates[1].candidate;
}

function textParts(content) {
  if (typeof content === "string") return [content];
  if (!Array.isArray(content)) return [];
  return content.flatMap((part) => {
    if (!part || typeof part !== "object") return [];
    if (part.type === "text" && typeof part.text === "string") return [part.text];
    return [];
  });
}

function messageOf(record) {
  if (!record || typeof record !== "object") return null;
  if (record.isMeta === true) return null;
  if (record.type !== "message" && record.type !== "user" && record.type !== "assistant") return null;
  const message = record.message && typeof record.message === "object" ? record.message : record;
  const role = message.role || record.type;
  if (role !== "user" && role !== "assistant") return null;
  const text = textParts(message.content).join("\n").trim();
  if (!text || text.startsWith("\u2063FIRSTMATE_OP:")) return null;
  return { role, text };
}

function snippet(text) {
  const compact = text.replace(/\s+/g, " ").trim();
  return compact.length <= 480 ? compact : `${compact.slice(0, 477)}...`;
}

function addUnique(list, value) {
  if (!value || list.includes(value)) return;
  list.push(value);
  if (list.length > 12) list.shift();
}

const source = discover();
if (!source) process.exit();

const liveJobs = [];
let liveJobsUncertain = false;
let openPicks = [];
const captainWords = [];
const decisionAsk = /captain'?s call|needs-decision|\bpick\b(?!\s+up\b)|\bchoose\b|\bwhich (?:option|path|one|lane|approach)\b|\bdecision\b[^.?!]*\?/i;
const liveJob = /\b(?:underway|under way|in flight|live jobs?|working:|paused:|checks? running|work (?:is )?running)/i;
const aggregateLiveJob = /^live jobs?:/i;
const terminalJob = /\b(?:done:|failed:|cancelled|canceled|merged|finished|completed|checks? green)/i;
const workObject = "(?:work|task|job|PR|pull request|rollout|release|plan|path|option|decision|project|implementation|change|merge|publish|deployment|launch)";
const strongLockWord = new RegExp(
  `^(?:please\\s+)?(?:lock|pause|resume|freeze|unfreeze|approve|approved|reject|cancel|choose|pick)\\s+(?:(?:the|this|that)\\s+)?${workObject}\\b` +
  `|^(?:please\\s+)?(?:approve|reject|cancel|pause|resume|freeze|unfreeze)\\s+(?:it|this|that)\\b` +
  `|^(?:please\\s+)?stop\\s+(?:work|the\\s+${workObject}|this|that|all|shipping|rollout)\\b` +
  `|^(?:please\\s+)?hold\\s+(?:the\\s+${workObject}|this|that|it|work|rollout)\\b` +
  `|\\b(?:put|keep|leave)\\b.{0,80}\\bon hold\\b|\\bgo with\\b|\\bboth paths\\b|\\byolo\\b|\\bship it\\b`,
  "i",
);
const terseAnswer = /^(?:(?:(?:let'?s|let us)\s+)?(?:do|take|use|select|choose|pick)\s+|the\s+|(?:option|path|lane)\s+)?(?:both|all|neither|first|second|third|yes|no|a|b|c|1|2|3)(?:\b|[.):])/i;

function foldMessage(message) {
  const compact = snippet(message.text);
  if (message.role === "assistant") {
    if (liveJob.test(message.text)) {
      if (aggregateLiveJob.test(message.text)) liveJobs.length = 0;
      const wasEmpty = liveJobs.length === 0;
      addUnique(liveJobs, compact);
      if (aggregateLiveJob.test(message.text) || (wasEmpty && liveJobs.length > 0)) {
        liveJobsUncertain = false;
      }
    } else if (terminalJob.test(message.text) && liveJobs.length) {
      liveJobs.length = 0;
      liveJobsUncertain = true;
    }
    if (decisionAsk.test(message.text)) addUnique(openPicks, compact);
    return;
  }

  if (openPicks.length && (strongLockWord.test(message.text)
      || (compact.length <= 240 && terseAnswer.test(compact)))) {
    addUnique(captainWords, compact);
    openPicks.pop();
  } else if (strongLockWord.test(message.text)) {
    addUnique(captainWords, compact);
  }
}

function render(items, truncated) {
  const output = [
    "",
    rule,
    "PRIOR SESSION",
    rule,
    `source: ${source}`,
    "scope: targeted prior-talk fold only; not 100% of chat; no GBrain, Graphify, or Obsidian ingestion.",
  ];
  for (const [title, rows] of items) {
    output.push("", title);
    if (!rows.length) output.push("(none found)");
    else rows.forEach((row) => output.push(`- ${row}`));
  }
  if (truncated) {
    output.push("", "INCOMPLETE: PRIOR SESSION fold truncated to fit remaining startup-memory budget; omitted targeted matches may exist.");
  } else {
    output.push("", "fold-status: parsed within bound.");
  }
  return `${output.join("\n")}\n`;
}

async function main() {
  const readline = require("readline");
  let lineNumber = 0;
  const input = fs.createReadStream(source, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      lineNumber += 1;
      if (!line.trim()) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        incomplete(`prior session log parse failed at JSONL line ${lineNumber}.`, source);
        return;
      }
      const message = messageOf(record);
      if (message) foldMessage(message);
    }
  } catch {
    incomplete("prior session log could not be read.", source);
    return;
  }

  const items = [
    ["LIVE JOBS", liveJobsUncertain
      ? [...liveJobs, "INCOMPLETE: a later terminal update made the earlier live-job snapshot unsafe to reuse."]
      : liveJobs],
    ["OPEN PICKS", openPicks],
    ["CAPTAIN LOCK WORDS", captainWords],
  ];
  let rendered = render(items, false);
  if (Buffer.byteLength(rendered, "utf8") > maxBytes) {
    let changed = true;
    while (changed && Buffer.byteLength(render(items, true), "utf8") > maxBytes) {
      changed = false;
      for (const [, rows] of items) {
        if (rows.length) {
          rows.shift();
          changed = true;
          if (Buffer.byteLength(render(items, true), "utf8") <= maxBytes) break;
        }
      }
    }
    rendered = render(items, true);
    if (Buffer.byteLength(rendered, "utf8") > maxBytes) {
      rendered = "\nPRIOR SESSION\nINCOMPLETE: fold truncated to fit remaining startup-memory budget; targeted matches omitted.\n";
    }
  }
  process.stdout.write(rendered);
}

main().catch(() => incomplete("prior session parser failed.", source));
JS
NODE_STATUS=$?

if [ "$NODE_STATUS" -ne 0 ]; then
  if [ -s "$TMP_OUTPUT" ]; then
    cat "$TMP_OUTPUT"
  else
    incomplete 'prior session parser failed before producing a diagnostic.'
  fi
  exit 2
fi
if [ ! -s "$TMP_OUTPUT" ]; then
  incomplete 'prior session parser produced no result.'
  exit 2
fi
cat "$TMP_OUTPUT"
