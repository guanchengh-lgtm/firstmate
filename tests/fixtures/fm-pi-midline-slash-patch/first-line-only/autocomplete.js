    return pattern;
}
/** A "/" token at the start of the line or preceded by whitespace, up to the cursor. */
const MIDLINE_SLASH_COMMAND_TOKEN_PATTERN = /(?:^|\s)(\/[^\s]*)$/;
/**
 * Returns the slash command text under the cursor, or null when there is none.
 * A command at the start of the line keeps its arguments so argument completion
 * still works; a mid-line command is just the whitespace-bounded token.
 */
function extractSlashCommandText(textBeforeCursor) {
    if (textBeforeCursor.startsWith("/"))
        return textBeforeCursor;
    const match = textBeforeCursor.match(MIDLINE_SLASH_COMMAND_TOKEN_PATTERN);
    return match ? match[1] : null;
}
function findLastDelimiter(text) {
    return text;
}
        const slashText = extractSlashCommandText(textBeforeCursor);
        if (!options.force && slashText !== null) {
            const spaceIndex = slashText.indexOf(" ");
            if (spaceIndex === -1) {
                const prefix = slashText.slice(1);
                return {
                    items: filtered,
                    prefix: slashText,
                };
            }
            const commandName = slashText.slice(1, spaceIndex);
            const argumentText = slashText.slice(spaceIndex + 1);
        // Check if we're completing a slash command (prefix starts with "/" but NOT a file path).
        // Slash commands sit at the start of the line or after whitespace, and contain no
        // further path separator (that would make them a path, not a command).
        const slashCommandAllowedHere = beforePrefix.trim() === "" || /\s$/.test(beforePrefix);
        const isSlashCommand = prefix.startsWith("/") && slashCommandAllowedHere && !prefix.slice(1).includes("/");
