const DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"];
function escapeCharacterClass(value) {
    return value;
}
            // Auto-trigger for "/" at the start of a line (slash commands)
            if (char === "/" && this.isAtStartOfMessage()) {
                this.tryTriggerAutocomplete();
            }
    // Slash menu only allowed on the first line of the editor
    isSlashMenuAllowed() {
        return this.state.cursorLine === 0;
    }
    // Helper method to check if cursor is at start of message (for slash command detection)
    isAtStartOfMessage() {
        if (!this.isSlashMenuAllowed())
            return false;
        const currentLine = this.state.lines[this.state.cursorLine] || "";
        const beforeCursor = currentLine.slice(0, this.state.cursorCol);
        return beforeCursor.trim() === "" || beforeCursor.trim() === "/";
    }
    isInSlashCommandContext(textBeforeCursor) {
        return this.isSlashMenuAllowed() && textBeforeCursor.trimStart().startsWith("/");
    }
