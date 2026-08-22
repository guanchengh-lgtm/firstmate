const DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"];
/** A "/" token at the start of the line or preceded by whitespace, up to the cursor. */
const SLASH_COMMAND_TOKEN_PATTERN = /(?:^|\s)\/[^\s]*$/;
function escapeCharacterClass(value) {
    return value;
}
            // Auto-trigger for "/" at the start of a line or a mid-line command token
            if (char === "/" && this.isAtSlashCommandStart()) {
                this.tryTriggerAutocomplete();
            }
    // Slash menu only allowed on the first line of the editor
    isSlashMenuAllowed() {
        return this.state.cursorLine === 0;
    }
    // Cursor sits on a slash command token: start of message, or a whitespace-bounded "/" later on the line.
    isAtSlashCommandStart() {
        if (!this.isSlashMenuAllowed())
            return false;
        const currentLine = this.state.lines[this.state.cursorLine] || "";
        const beforeCursor = currentLine.slice(0, this.state.cursorCol);
        return SLASH_COMMAND_TOKEN_PATTERN.test(beforeCursor);
    }
    isInSlashCommandContext(textBeforeCursor) {
        if (!this.isSlashMenuAllowed())
            return false;
        // A slash command at the start of the message stays in context past its arguments.
        if (textBeforeCursor.trimStart().startsWith("/"))
            return true;
        // A mid-line slash command is only in context while the token itself is being typed.
        return SLASH_COMMAND_TOKEN_PATTERN.test(textBeforeCursor);
    }
