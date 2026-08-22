    return pattern;
}
function findLastDelimiter(text) {
    return text;
}
        if (!options.force && textBeforeCursor.startsWith("/")) {
            const spaceIndex = textBeforeCursor.indexOf(" ");
            if (spaceIndex === -1) {
                const prefix = textBeforeCursor.slice(1);
                return {
                    items: filtered,
                    prefix: textBeforeCursor,
                };
            }
            const commandName = textBeforeCursor.slice(1, spaceIndex);
            const argumentText = textBeforeCursor.slice(spaceIndex + 1);
        // Check if we're completing a slash command (prefix starts with "/" but NOT a file path)
        // Slash commands are at the start of the line and don't contain path separators after the first /
        const isSlashCommand = prefix.startsWith("/") && beforePrefix.trim() === "" && !prefix.slice(1).includes("/");
