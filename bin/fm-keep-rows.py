# Parse Idea cells of markdown tables under ### Keep.
# Contract owner: bin/fm-spec-compile-check.sh header.
import re


def keep_rows(text):
    rows = []
    in_keep = False
    header_seen = False
    past_sep = False
    for line in text.splitlines():
        if re.match(r"^### Keep\s*$", line):
            in_keep = True
            header_seen = False
            past_sep = False
            continue
        if in_keep and re.match(r"^#{1,3} ", line):
            in_keep = False
            header_seen = False
            past_sep = False
            continue
        if not in_keep:
            continue
        stripped = line.strip()
        if stripped.startswith("|"):
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            if not cells:
                continue
            if all(re.match(r"^[-: ]+$", c or "-") for c in cells):
                past_sep = True
                continue
            if not header_seen:
                header_seen = True
                continue
            if past_sep and cells[0]:
                rows.append(cells[0])
            continue
        if header_seen and stripped == "":
            in_keep = False
            header_seen = False
            past_sep = False
    return rows
