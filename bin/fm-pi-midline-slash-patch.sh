#!/usr/bin/env bash
# Reapply the local Pi mid-line slash-command dist patch after a Pi upgrade wipes it.
#
# A global `npm i -g @earendil-works/pi-coding-agent` install replaces `@earendil-works/pi-tui` dist files and drops the mid-line `/` dropdown.
# This helper restores that dropdown against the installed dist without opening an upstream PR (https://github.com/earendil-works/pi/issues/8015).
# It is idempotent: an already-patched dist reports already patched and is not rewritten.
# Missing Pi, or a missing dist directory, prints a clear skip and exits 0.
# A dist whose layout no longer matches the 0.84.x slash gates prints a clear fail and writes nothing, so a version change never half-patches.
# A running Pi process keeps old modules in memory until it restarts.
# This helper does not kill the primary Pi process.
#
# Usage: fm-pi-midline-slash-patch.sh [--help]
# Usage: fm-pi-midline-slash-patch.sh [dist-dir]
# Env: FM_PI_TUI_DIST overrides the dist directory when no argument is given.
# Env: FM_PI_PACKAGE_DIR overrides the `@earendil-works/pi-coding-agent` package root used to find node_modules/@earendil-works/pi-tui/dist when neither an argument nor FM_PI_TUI_DIST is set.
set -eu

usage() {
  echo "usage: fm-pi-midline-slash-patch.sh [--help]" >&2
  echo "usage: fm-pi-midline-slash-patch.sh [dist-dir]" >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

skip_missing() {
  echo "pi-midline-slash: skipped: Pi tui dist not found"
  exit 0
}

resolve_dist() {
  if [ "$#" -eq 1 ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [ -n "${FM_PI_TUI_DIST:-}" ]; then
    printf '%s\n' "$FM_PI_TUI_DIST"
    return 0
  fi
  local pkg root
  if [ -n "${FM_PI_PACKAGE_DIR:-}" ]; then
    pkg=$FM_PI_PACKAGE_DIR
  else
    command -v npm >/dev/null 2>&1 || return 1
    root=$(npm root -g 2>/dev/null) || return 1
    [ -n "$root" ] || return 1
    pkg="$root/@earendil-works/pi-coding-agent"
  fi
  printf '%s\n' "$pkg/node_modules/@earendil-works/pi-tui/dist"
}

DIST=$(resolve_dist "$@") || skip_missing
[ -d "$DIST" ] || skip_missing
DIST=$(cd "$DIST" && pwd -P)

if ! command -v python3 >/dev/null 2>&1; then
  echo "pi-midline-slash: failed: python3 is required to patch the dist"
  exit 1
fi

python3 - "$DIST" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

DIST = Path(sys.argv[1])
FILES = (
    "components/editor.js",
    "autocomplete.js",
    "components/editor.d.ts",
)

CLEAN_MARKERS = {
    "components/editor.js": (
        "this.isAtStartOfMessage()",
        "isAtStartOfMessage() {",
    ),
    "autocomplete.js": (
        'if (!options.force && textBeforeCursor.startsWith("/")) {',
        'prefix.startsWith("/") && beforePrefix.trim() === "" && !prefix.slice(1).includes("/")',
    ),
    "components/editor.d.ts": (
        "private isAtStartOfMessage;",
    ),
}

PATCHED_MARKERS = {
    "components/editor.js": (
        "this.isAtSlashCommandStart()",
        "SLASH_COMMAND_TOKEN_PATTERN",
    ),
    "autocomplete.js": (
        "extractSlashCommandText",
        "slashCommandAllowedHere",
    ),
    "components/editor.d.ts": (
        "private isAtSlashCommandStart;",
    ),
}

REPLACEMENTS = {
    "components/editor.js": (
        (
            'const DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"];\n'
            "function escapeCharacterClass(value) {",
            'const DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"];\n'
            '/** A "/" token at the start of the line or preceded by whitespace, up to the cursor. */\n'
            r"const SLASH_COMMAND_TOKEN_PATTERN = /(?:^|\s)\/[^\s]*$/;"
            "\nfunction escapeCharacterClass(value) {",
        ),
        (
            '            // Auto-trigger for "/" at the start of a line (slash commands)\n'
            '            if (char === "/" && this.isAtStartOfMessage()) {',
            '            // Auto-trigger for "/" at the start of a line or a mid-line command token\n'
            '            if (char === "/" && this.isAtSlashCommandStart()) {',
        ),
        (
            "    // Helper method to check if cursor is at start of message (for slash command detection)\n"
            "    isAtStartOfMessage() {\n"
            "        if (!this.isSlashMenuAllowed())\n"
            "            return false;\n"
            '        const currentLine = this.state.lines[this.state.cursorLine] || "";\n'
            "        const beforeCursor = currentLine.slice(0, this.state.cursorCol);\n"
            '        return beforeCursor.trim() === "" || beforeCursor.trim() === "/";\n'
            "    }\n"
            "    isInSlashCommandContext(textBeforeCursor) {\n"
            '        return this.isSlashMenuAllowed() && textBeforeCursor.trimStart().startsWith("/");\n'
            "    }",
            "    // Cursor sits on a slash command token: start of message, or a whitespace-bounded "
            '"/" later on the line.\n'
            "    isAtSlashCommandStart() {\n"
            "        if (!this.isSlashMenuAllowed())\n"
            "            return false;\n"
            '        const currentLine = this.state.lines[this.state.cursorLine] || "";\n'
            "        const beforeCursor = currentLine.slice(0, this.state.cursorCol);\n"
            "        return SLASH_COMMAND_TOKEN_PATTERN.test(beforeCursor);\n"
            "    }\n"
            "    isInSlashCommandContext(textBeforeCursor) {\n"
            "        if (!this.isSlashMenuAllowed())\n"
            "            return false;\n"
            "        // A slash command at the start of the message stays in context past its arguments.\n"
            '        if (textBeforeCursor.trimStart().startsWith("/"))\n'
            "            return true;\n"
            "        // A mid-line slash command is only in context while the token itself is being typed.\n"
            "        return SLASH_COMMAND_TOKEN_PATTERN.test(textBeforeCursor);\n"
            "    }",
        ),
    ),
    "autocomplete.js": (
        (
            "    return pattern;\n"
            "}\n"
            "function findLastDelimiter(text) {",
            "    return pattern;\n"
            "}\n"
            '/** A "/" token at the start of the line or preceded by whitespace, up to the cursor. */\n'
            r"const MIDLINE_SLASH_COMMAND_TOKEN_PATTERN = /(?:^|\s)(\/[^\s]*)$/;"
            "\n"
            "/**\n"
            " * Returns the slash command text under the cursor, or null when there is none.\n"
            " * A command at the start of the line keeps its arguments so argument completion\n"
            " * still works; a mid-line command is just the whitespace-bounded token.\n"
            " */\n"
            "function extractSlashCommandText(textBeforeCursor) {\n"
            '    if (textBeforeCursor.startsWith("/"))\n'
            "        return textBeforeCursor;\n"
            "    const match = textBeforeCursor.match(MIDLINE_SLASH_COMMAND_TOKEN_PATTERN);\n"
            "    return match ? match[1] : null;\n"
            "}\n"
            "function findLastDelimiter(text) {",
        ),
        (
            '        if (!options.force && textBeforeCursor.startsWith("/")) {\n'
            '            const spaceIndex = textBeforeCursor.indexOf(" ");\n'
            "            if (spaceIndex === -1) {\n"
            "                const prefix = textBeforeCursor.slice(1);",
            "        const slashText = extractSlashCommandText(textBeforeCursor);\n"
            "        if (!options.force && slashText !== null) {\n"
            '            const spaceIndex = slashText.indexOf(" ");\n'
            "            if (spaceIndex === -1) {\n"
            "                const prefix = slashText.slice(1);",
        ),
        (
            "                    prefix: textBeforeCursor,",
            "                    prefix: slashText,",
        ),
        (
            "            const commandName = textBeforeCursor.slice(1, spaceIndex);\n"
            "            const argumentText = textBeforeCursor.slice(spaceIndex + 1);",
            "            const commandName = slashText.slice(1, spaceIndex);\n"
            "            const argumentText = slashText.slice(spaceIndex + 1);",
        ),
        (
            '        // Check if we\'re completing a slash command (prefix starts with "/" but NOT a file path)\n'
            "        // Slash commands are at the start of the line and don't contain path separators after the first /\n"
            '        const isSlashCommand = prefix.startsWith("/") && beforePrefix.trim() === "" && !prefix.slice(1).includes("/");',
            '        // Check if we\'re completing a slash command (prefix starts with "/" but NOT a file path).\n'
            "        // Slash commands sit at the start of the line or after whitespace, and contain no\n"
            "        // further path separator (that would make them a path, not a command).\n"
            '        const slashCommandAllowedHere = beforePrefix.trim() === "" || /\\s$/.test(beforePrefix);\n'
            '        const isSlashCommand = prefix.startsWith("/") && slashCommandAllowedHere && !prefix.slice(1).includes("/");',
        ),
    ),
    "components/editor.d.ts": (
        (
            "    private isAtStartOfMessage;",
            "    private isAtSlashCommandStart;",
        ),
    ),
}


def fail(reason: str) -> None:
    print(f"pi-midline-slash: failed: {reason}")
    raise SystemExit(1)


def has_all(text: str, markers: tuple[str, ...]) -> bool:
    return all(marker in text for marker in markers)


def has_any(text: str, markers: tuple[str, ...]) -> bool:
    return any(marker in text for marker in markers)


def classify(rel: str, text: str) -> str:
    clean = CLEAN_MARKERS[rel]
    patched = PATCHED_MARKERS[rel]
    is_clean = has_all(text, clean) and not has_any(text, patched)
    is_patched = has_all(text, patched) and not has_any(text, clean)
    if is_clean and is_patched:
        return "unknown"
    if is_patched:
        return "patched"
    if is_clean:
        return "clean"
    return "unknown"


def apply_replacements(rel: str, text: str) -> str:
    for old, new in REPLACEMENTS[rel]:
        count = text.count(old)
        if count != 1:
            fail(
                "dist layout changed: "
                f"{rel} no longer matches the 0.84.x slash gates"
            )
        text = text.replace(old, new, 1)
    return text


def main() -> None:
    contents: dict[str, str] = {}
    for rel in FILES:
        path = DIST / rel
        if not path.is_file():
            fail(f"dist layout changed: missing {rel}")
        contents[rel] = path.read_text()

    states = {rel: classify(rel, text) for rel, text in contents.items()}
    unique = set(states.values())
    if unique == {"patched"}:
        print(f"pi-midline-slash: already patched {DIST}")
        return
    if "unknown" in unique or unique != {"clean"}:
        fail(
            "dist layout changed: slash gates are mixed or no longer match 0.84.x"
        )

    patched: dict[str, str] = {}
    for rel, text in contents.items():
        updated = apply_replacements(rel, text)
        if classify(rel, updated) != "patched":
            fail(f"dist layout changed: patched {rel} did not verify")
        patched[rel] = updated

    staged: list[tuple[Path, Path]] = []
    try:
        for rel, text in patched.items():
            dest = DIST / rel
            tmp = dest.with_name(dest.name + ".fm-midline.tmp")
            tmp.write_text(text)
            staged.append((tmp, dest))
        for tmp, dest in staged:
            tmp.replace(dest)
    finally:
        for tmp, _dest in staged:
            if tmp.exists():
                tmp.unlink()

    print(f"pi-midline-slash: patched {DIST}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - surface any patch I/O error
        fail(str(exc))
PY
