#!/usr/bin/env python3
# fm-record-links.py - the single owner of Record Related footer grammar,
# classification, citation extraction, resolution, rendering, apply, and lint.
#
# Usage:
#   fm-record-links.py propose --root <Record> --out <directory> [--state-root <dir>]
#   fm-record-links.py apply --root <isolated-copy> --plan <manifest>
#                          [--state-root <dir>]
#   fm-record-links.py lint --root <Record> --json [--state-root <dir>]
#
# --state-root defaults to <root>/../state when that directory exists.
# Propose writes only under --out. Apply writes footer-only edits under --root.
# Apply never commits, pushes, or touches a live home except that isolated root.
# Lint is advisory forever and never rewrites.
#
# Footer grammar (terminal nonblank line, outside fences and blockquotes):
#   Related: supersedes: [[decisions/old.md]]; cites: [[other/report.md]],
#   [[knowledge-system-wayfinder/CONTEXT.md]]; relates: [[playbook/example.md]]
# Fixed key order is supersedes, cites, relates. Keys are lowercase, once each,
# and separated by "; ". Each value is none or one or more [[RelPath]] targets
# separated by ", ". none means no established relation of that type was
# recorded. RelPath is Record-relative POSIX, actual filename case, with .md,
# and with no leading slash, data/ wrapper, . or .. segment, anchor, query,
# alias, or URL encoding. Targets are sorted unique per key. Repeated targets
# across keys are allowed only when both relations were explicit. The renderer
# is the only writer of that line. Do not infer an inverse footer on the target.
#
# Classification is first-match: skip non-regular, symlink, or .git; generated
# under wiki/ or graphify-out/; raw under raw/, transcripts/, snapshots/,
# assets/, vendor/, or a fixtures/ directory; owner-exempt basenames
# backlog.md, product-ideas.md, secondmates.md, projects.md; raw for AGENTS.md
# or a path under copied/ or archive/; active-writer when
# --state-root/<task-id>/status exists, its last status token is
# working|blocked|paused|needs-decision, and the file lives under <task-id>/;
# already-linked when a terminal Related: line exists (canonical or malformed);
# eligible authored shapes brief.md, report.md, ov-report.md, measure.md,
# verifier-brief.md, files under decisions/, playbook/, or
# knowledge-system-wayfinder/, plus root captain.md, captain-shared.md,
# learnings.md, RECORD.md, CONTEXT.md; otherwise needs-review.
# Do not silently rewrite needs-review, raw, generated, owner-exempt, or
# active-writer. A malformed terminal Related: line is already-linked plus a
# question or lint finding and is not replaced.
#
# Confidence: automatic cites need a Markdown link, wikilink, or backtick/prose
# path that uniquely resolves to a contained Record .md and is not a copied
# example, command, template, negated instruction, or do-not-cite passage.
# Unprefixed relative paths try the source directory first. data/ or this
# process's absolute Record root prefix normalize to Record-relative. Two
# interpretations that resolve to different documents become a question.
# :line and heading locators are stripped for resolution only. Standalone ids
# are candidates until they resolve to one named document with supporting
# context; they never auto-map to the first report.md.
# supersedes is automatic only for an explicit affirmative replacement naming
# an existing target. An anchored Supersedes: field with exact targets is high
# confidence. A later AMENDED block may supply evidence only when the
# replacement is explicit and chronology is unambiguous. Clause-only,
# negation, contradictory amendment, missing target, or ambiguous ordering is
# a question. Reject a self target for every key and supersede cycles before
# proposing automatic edges. Do not infer from age, mtime, title similarity,
# shared folder, or a generic related mention, and do not change either
# document's status.
# relates is automatic only for an explicit related/see-also association or a
# same-task pair (<id>/brief.md <-> <id>/report.md).
# Manual well-formed footers stay authoritative. Eligible footer-absent files
# with no supported citations still receive all three none values.
#
# propose walks regular non-symlink *.md under --root, skips .git, and writes
# byte-identical artifacts on rerun against the same snapshot:
#   manifest.json  stable sort_keys, compact separators (",", ":")
#   changes.patch  unified diff of proposed footer-only edits
#   report.md      human dry-run
# The manifest records source commit (git rev-parse HEAD, else null), sorted
# source paths and hashes, this script's sha256, classification counts,
# before/after footer bytes, proposed typed edges, original citation line/text,
# reason and confidence for every candidate, and separate lists: unresolved,
# ambiguous ids, excluded, existing footers, unknown metadata, partial
# replacements, cycles, path shadows, slug collisions.
#
# apply refuses a planned source hash that does not match the current file,
# a symlink escape, an unsafe target, or an altered plan. Footer-only means
# the previous bytes are unchanged, followed by a newline if the file did
# not end with one, then the Related line and a trailing newline. A rerun
# against the already-applied tree produces zero file changes.
#
# lint --json is the T12 entry point. Ordinary findings exit 0 with
# status=ok. Unreadable root, incomplete scan, or bad argv is
# status=unavailable and a nonzero exit, never ok with zero issues.
# Usage and invalid invocation exit 2. Apply refuse and lint unavailable
# exit 1. propose/apply success and lint with findings or a clean scan exit 0.
#
# JSON lint fields: scanned, eligible, exempt, generated, raw, active_writer,
# needs_review, already_linked, missing, invalid, unresolved, typed edge
# totals, orphan count, and a bounded findings list.
#
# Consumer smoke: gbrain 0.47.9.0 import then extract all --source db, and
# graphify extract_markdown with the extract module's active scan-root set to
# the Record copy, should resolve the same four footer targets used in the
# T9 review fixture. Those packages are not CI dependencies.
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from collections import OrderedDict

FOOTER_KEYS = ("supersedes", "cites", "relates")
CLASSIFICATIONS = (
    "eligible",
    "already-linked",
    "owner-exempt",
    "generated",
    "raw",
    "active-writer",
    "needs-review",
)
ACTIVE_TOKENS = frozenset(("working", "blocked", "paused", "needs-decision"))
OWNER_EXEMPT = frozenset(
    ("backlog.md", "product-ideas.md", "secondmates.md", "projects.md")
)
AUTHORED_NAMES = frozenset(
    ("brief.md", "report.md", "ov-report.md", "measure.md", "verifier-brief.md")
)
ROOT_AUTHORED = frozenset(
    ("captain.md", "captain-shared.md", "learnings.md", "RECORD.md", "CONTEXT.md")
)
GENERATED_TOP = frozenset(("wiki", "graphify-out"))
RAW_TOP = frozenset(("raw", "transcripts", "snapshots", "assets", "vendor"))
RAW_ANY = frozenset(("fixtures", "copied", "archive"))
JSON_SEP = (",", ":")
FINDINGS_BOUND = 200
WIKI_ILLEGAL = frozenset("#?|&^[]%\\\r\n\t")
NONE = "none"
RELATED_PREFIX = "Related:"
CANONICAL_FOOTER = re.compile(
    r"^Related: supersedes: (.+); cites: (.+); relates: (.+)$"
)
WIKI_ONE = re.compile(r"^\[\[(.+)\]\]$")
WIKI_FIND = re.compile(r"(?<!!)\[\[([^\]\n]+)\]\]")
MD_LINK = re.compile(r"(?<!!)\[([^\]\n]*)\]\(([^)\n]+)\)")
INLINE_CODE = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
BLOCKQUOTE = re.compile(r"^ {0,3}>")
PATH_RE = re.compile(
    r"(?<![\w/])(?:data/|\.\.?/)?"
    r"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.md"
    r"(?:[:#][A-Za-z0-9_.:#-]+)?"
)
ABS_MD = re.compile(r"(?<![\w/])(/(?:[^\s,;`]+)\.md)(?:[:#][A-Za-z0-9_.:#-]+)?")
LOCATOR = re.compile(r"(?::\d+|#[^\s|]+)$")
SUPERSEDES_FIELD = re.compile(r"(?im)^[ \t]*(?:\*\*)?Supersedes:(?:\*\*)?[ \t]*(.*)$")
AMENDED = re.compile(
    r"(?im)\bAMENDED\b(?:[ \t]+(\d{4}-\d{2}-\d{2}))?(?:[ \t]+(later|earlier))?"
)
SEE_ALSO = re.compile(
    r"(?im)^[ \t]*(?:\*\*)?(?:See also|Related)"
    r"(?![ \t]*:[ \t]*supersedes)(?:\*\*)?[ \t]*:[ \t]*(.*)$"
)
ID_TOKEN = re.compile(r"(?<![\w/.-])[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+(?![\w/.-])")
YAML_ID = re.compile(r"(?m)^id:[ \t]*(\S+)[ \t]*$")
YAML_FIELD = re.compile(r"(?m)^(id|date|type|status):[ \t]*(.*)$")
NEGATE_CITE = re.compile(
    r"(?i)\b(do not cite|don't cite|do-not-cite|never cite|not a citation)\b"
)
NEGATE_SUPERSEDE = re.compile(
    r"(?i)\b(does not|doesn't|do not|don't|never|not)\s+supersede"
)
COMMAND_LINE = re.compile(
    r"(?i)^\s*(?:\$\s*)?(?:sudo\s+)?(?:fm-|git\s|python3?\s|bin/)"
)
TEMPLATE_MARK = re.compile(r"<[^>\n]+>|\{[A-Z][A-Z0-9_]*\}")


class UsageError(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


class ApplyRefuse(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


class LintUnavailable(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


class RelPath(object):
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value

    def __str__(self):
        return self.value

    def __eq__(self, other):
        return isinstance(other, RelPath) and self.value == other.value

    def __lt__(self, other):
        return self.value < other.value

    def __hash__(self):
        return hash(self.value)


class Footer(object):
    __slots__ = FOOTER_KEYS

    def __init__(self, supersedes, cites, relates):
        self.supersedes = supersedes
        self.cites = cites
        self.relates = relates

    def as_dict(self):
        out = OrderedDict()
        for key in FOOTER_KEYS:
            value = getattr(self, key)
            out[key] = None if value is None else [item.value for item in value]
        return out

    def edges(self):
        for key in FOOTER_KEYS:
            value = getattr(self, key)
            if value:
                for item in value:
                    yield key, item.value


class Evidence(object):
    __slots__ = ("key", "target", "reason", "confidence", "path", "line", "text")

    def __init__(self, key, target, reason, confidence, path, line, text):
        self.key = key
        self.target = target
        self.reason = reason
        self.confidence = confidence
        self.path = path
        self.line = line
        self.text = text

    def as_dict(self):
        return {
            "confidence": self.confidence,
            "key": self.key,
            "line": self.line,
            "path": self.path,
            "reason": self.reason,
            "target": self.target,
            "text": self.text,
        }


class Question(object):
    __slots__ = ("path", "line", "text", "why")

    def __init__(self, path, line, text, why):
        self.path = path
        self.line = line
        self.text = text
        self.why = why

    def as_dict(self):
        return {
            "line": self.line,
            "path": self.path,
            "text": self.text,
            "why": self.why,
        }


class Finding(object):
    __slots__ = ("path", "kind", "detail")

    def __init__(self, path, kind, detail):
        self.path = path
        self.kind = kind
        self.detail = detail

    def as_dict(self):
        return {"detail": self.detail, "kind": self.kind, "path": self.path}


def usage():
    lines = []
    with open(__file__, encoding="utf-8") as handle:
        next(handle)
        for line in handle:
            if not line.startswith("#"):
                break
            lines.append(line[2:] if line.startswith("# ") else line[1:])
    sys.stderr.write("".join(lines))


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def posix_rel(path):
    return path.replace(os.sep, "/")


def parts_of(relpath):
    return [part for part in relpath.split("/") if part]


def default_state_root(root):
    candidate = os.path.join(os.path.dirname(os.path.abspath(root)), "state")
    if os.path.isdir(candidate) and not os.path.islink(candidate):
        return candidate
    return None


def git_head(root):
    try:
        result = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    text = result.stdout.decode("utf-8", errors="replace").strip()
    return text or None


def dump_json(payload):
    return json.dumps(
        payload, sort_keys=True, separators=JSON_SEP, ensure_ascii=False
    ) + "\n"


def parse_relpath(raw):
    if not raw or not isinstance(raw, str):
        return None
    text = raw.strip()
    if not text.endswith(".md"):
        return None
    if text.startswith("/") or text.startswith("data/"):
        return None
    if any(ch in WIKI_ILLEGAL for ch in text):
        return None
    if "#" in text or "?" in text or "|" in text or "%" in text:
        return None
    segments = parts_of(text)
    if not segments or any(part in (".", "..", "") for part in segments):
        return None
    return RelPath("/".join(segments))


def parse_value(raw):
    text = raw.strip()
    if text == NONE:
        return None
    items = [item.strip() for item in text.split(", ")]
    if not items or any(not item for item in items):
        raise ValueError("empty footer value")
    paths = []
    seen = set()
    for item in items:
        match = WIKI_ONE.match(item)
        if match is None:
            raise ValueError("footer value is not a wikilink")
        rel = parse_relpath(match.group(1))
        if rel is None:
            raise ValueError("footer wikilink is not a RelPath")
        if rel.value in seen:
            raise ValueError("duplicate footer target")
        if paths and rel.value < paths[-1].value:
            raise ValueError("footer targets are not sorted")
        seen.add(rel.value)
        paths.append(rel)
    return tuple(paths)


def parse_footer(line):
    if line.endswith("\n"):
        line = line[:-1]
    if line.endswith("\r"):
        line = line[:-1]
    match = CANONICAL_FOOTER.match(line)
    if match is None:
        return None
    try:
        values = [parse_value(match.group(i)) for i in range(1, 4)]
    except ValueError:
        return None
    return Footer(values[0], values[1], values[2])


def render_value(value):
    if value is None:
        return NONE
    return ", ".join("[[%s]]" % item.value for item in value)


def render_footer(footer):
    parts = [
        "%s: %s" % (key, render_value(getattr(footer, key))) for key in FOOTER_KEYS
    ]
    return RELATED_PREFIX + " " + "; ".join(parts)


def merge_targets(*groups):
    seen = set()
    out = []
    for group in groups:
        if not group:
            continue
        for item in group:
            if item.value not in seen:
                seen.add(item.value)
                out.append(item)
    if not out:
        return None
    return tuple(sorted(out))


def fence_mask(text):
    out = []
    marker = None
    marker_len = 0
    for line in text.splitlines(True):
        match = FENCE_OPEN.match(line)
        if match:
            mark = match.group(1)
            if marker is None:
                marker = mark[0]
                marker_len = len(mark)
                out.append("\n" if line.endswith("\n") else "")
                continue
            if mark[0] == marker and len(mark) >= marker_len:
                marker = None
                marker_len = 0
                out.append("\n" if line.endswith("\n") else "")
                continue
        if marker is not None:
            out.append("\n" if line.endswith("\n") else "")
        else:
            out.append(line)
    return "".join(out)


def line_kind_map(text):
    kinds = []
    marker = None
    marker_len = 0
    for line in text.splitlines():
        match = FENCE_OPEN.match(line)
        if match:
            mark = match.group(1)
            if marker is None:
                marker = mark[0]
                marker_len = len(mark)
                kinds.append("fence")
                continue
            if mark[0] == marker and len(mark) >= marker_len:
                marker = None
                marker_len = 0
                kinds.append("fence")
                continue
        if marker is not None:
            kinds.append("fence")
        elif BLOCKQUOTE.match(line):
            kinds.append("quote")
        else:
            kinds.append("body")
    return kinds


def related_lines(text):
    kinds = line_kind_map(text)
    found = []
    for index, line in enumerate(text.splitlines()):
        if kinds[index] != "body":
            continue
        if line.startswith(RELATED_PREFIX):
            found.append((index + 1, line))
    return found


def last_nonblank(text):
    lines = text.splitlines()
    for index in range(len(lines) - 1, -1, -1):
        if lines[index].strip():
            return index + 1, lines[index]
    return None, None


def terminal_related(text):
    lineno, line = last_nonblank(text)
    if line is None or not line.startswith(RELATED_PREFIX):
        return None, None, None
    kinds = line_kind_map(text)
    if kinds[lineno - 1] != "body":
        return None, None, None
    return lineno, line, parse_footer(line)


def strip_terminal_related(text):
    lineno, line, footer = terminal_related(text)
    if lineno is None:
        return text, None, None
    lines = text.splitlines(True)
    del lines[lineno - 1]
    while lines and lines[-1].strip() == "":
        lines.pop()
    body = "".join(lines)
    if body and not body.endswith("\n"):
        body += "\n"
    return body, line, footer


def split_frontmatter(text):
    if not text.startswith("---\n") and text != "---":
        return None, text
    rest = text[4:]
    close = rest.find("\n---\n")
    if close == -1:
        if rest.endswith("\n---"):
            return rest[:-4], ""
        return None, text
    return rest[:close], rest[close + 5 :]


def unknown_metadata(text, path):
    header, _body = split_frontmatter(text)
    if header is None:
        return None
    fields = {}
    for match in YAML_FIELD.finditer(header):
        fields[match.group(1)] = match.group(2).strip().strip("\"'")
    missing = [name for name in ("id", "date", "type", "status") if name not in fields]
    unknown = [
        name
        for name, value in fields.items()
        if value in ("", "null", "unknown", "~")
    ]
    if not missing and not unknown:
        date = fields.get("date")
        if date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            unknown.append("date")
    if missing or unknown:
        return {
            "missing": missing,
            "path": path,
            "unknown": unknown,
        }
    return None


def yaml_id(text):
    header, _body = split_frontmatter(text)
    if header is None:
        return None
    match = YAML_ID.search(header)
    if match is None:
        return None
    return match.group(1).strip().strip("\"'")


def last_status_token(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return None
    token = lines[-1].split()[0]
    token = token.split("[", 1)[0].rstrip(":")
    return token or None


def classify_relpath(relpath, text, state_root):
    parts = parts_of(relpath)
    if not parts or ".git" in parts:
        return None, "git or empty path"
    if parts[0] in GENERATED_TOP:
        return "generated", "under %s/" % parts[0]
    if parts[0] in RAW_TOP or any(part in RAW_ANY for part in parts):
        return "raw", "byte-preserved or generated-adjacent path"
    name = parts[-1]
    if name in OWNER_EXEMPT:
        return "owner-exempt", "ledger or registry basename"
    if name == "AGENTS.md" or "copied" in parts or "archive" in parts:
        return "raw", "copied or archived evidence"
    if state_root and len(parts) >= 2:
        task_id = parts[0]
        status_path = os.path.join(state_root, task_id, "status")
        if os.path.isfile(status_path) and not os.path.islink(status_path):
            try:
                status_text = read_text(status_path)
            except OSError:
                status_text = ""
            token = last_status_token(status_text)
            if token in ACTIVE_TOKENS:
                return "active-writer", "live status %s" % token
    lineno, line, footer = terminal_related(text)
    if lineno is not None:
        if footer is not None:
            reason = "canonical footer"
        else:
            reason = "malformed terminal Related"
        return "already-linked", reason
    if name in AUTHORED_NAMES:
        return "eligible", "authored %s" % name
    if parts[0] in ("decisions", "playbook", "knowledge-system-wayfinder"):
        return "eligible", "authored tree %s/" % parts[0]
    if relpath in ROOT_AUTHORED:
        return "eligible", "fleet memory document"
    return "needs-review", "unclassified ownership"


def read_text(path):
    with open(path, "rb") as handle:
        data = handle.read()
    return data.decode("utf-8", errors="replace")


def contained_regular(root, relpath):
    root_real = os.path.realpath(root)
    current = root_real
    for part in parts_of(relpath):
        current = os.path.join(current, part)
        try:
            info = os.lstat(current)
        except OSError:
            return None
        if stat.S_ISLNK(info.st_mode):
            return None
        if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            return None
    if not stat.S_ISREG(os.lstat(current).st_mode):
        return None
    if not current.endswith(".md"):
        return None
    real = os.path.realpath(current)
    if real != current:
        return None
    if not (real == root_real or real.startswith(root_real + os.sep)):
        return None
    return posix_rel(os.path.relpath(real, root_real))


def strip_locator(value):
    text = value.strip().strip("<>")
    text = LOCATOR.sub("", text)
    return text


def normalize_raw(raw, root):
    text = strip_locator(raw.replace("\\", "/"))
    if not text:
        return None
    root_real = os.path.realpath(root)
    prefixes = (root_real + "/", root_real + os.sep)
    for prefix in prefixes:
        if text.startswith(prefix):
            text = text[len(prefix) :]
            break
    else:
        if text.startswith(root_real) and (
            len(text) == len(root_real) or text[len(root_real)] in "/#"
        ):
            text = text[len(root_real) :].lstrip("/")
    if text.startswith("./"):
        text = text[2:]
    if text.startswith("data/"):
        text = text[5:]
    return text or None


def join_norm(base_dir, rel):
    parts = parts_of(base_dir) + parts_of(rel)
    out = []
    for part in parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not out:
                return None
            out.pop()
            continue
        out.append(part)
    return "/".join(out) if out else None


def resolve_one(candidate, root, inventory):
    if not candidate:
        return None
    contained = contained_regular(root, candidate)
    if contained and contained in inventory:
        return RelPath(contained)
    rel = parse_relpath(candidate)
    if rel is not None and rel.value in inventory:
        return rel
    return None


def resolve_target(raw, source, root, inventory):
    questions = []
    normalized = normalize_raw(raw, root)
    if normalized is None:
        return None, ["unresolvable citation"], None
    if normalized.startswith("/"):
        return None, ["outside Record"], None
    source_dir = "/".join(parts_of(source)[:-1])
    local = join_norm(source_dir, normalized)
    rooted = join_norm("", normalized)
    if local is None and rooted is None:
        return None, ["unsafe path"], None
    resolved = []
    seen = set()
    for candidate in (local, rooted):
        hit = resolve_one(candidate, root, inventory)
        if hit is None or hit.value in seen:
            continue
        seen.add(hit.value)
        resolved.append(hit)
    shadow = None
    if (
        local
        and rooted
        and local != rooted
        and local in inventory
        and rooted in inventory
    ):
        shadow = {"local": local, "path": source, "target": rooted}
    if not resolved:
        return None, ["missing target"], shadow
    if len(resolved) > 1:
        return None, ["ambiguous path interpretations"], shadow
    return resolved[0], questions, shadow


def slugify(name):
    stem = name[:-3] if name.endswith(".md") else name
    return re.sub(r"[^a-z0-9]+", "", stem.lower())


def mask_spans(text, spans):
    chars = list(text)
    for start, end in spans:
        for index in range(start, min(end, len(chars))):
            if chars[index] != "\n":
                chars[index] = " "
    return "".join(chars)


def citation_context_ok(line):
    if NEGATE_CITE.search(line):
        return False, "do-not-cite passage"
    if COMMAND_LINE.search(line):
        return False, "command"
    if TEMPLATE_MARK.search(line):
        return False, "template"
    lowered = line.lower()
    if "for example" in lowered or lowered.lstrip().startswith("e.g."):
        return False, "copied example"
    return True, ""


def extract_paths(text, source, root, inventory):
    unfenced = fence_mask(text)
    kinds = line_kind_map(text)
    lines = text.splitlines()
    inline = list(INLINE_CODE.finditer(unfenced))
    link_text = mask_spans(unfenced, [(m.start(), m.end()) for m in inline])
    wiki = list(WIKI_FIND.finditer(link_text))
    md_links = list(MD_LINK.finditer(link_text))
    after_links = mask_spans(link_text, [(m.start(), m.end()) for m in wiki + md_links])
    code_again = list(INLINE_CODE.finditer(after_links))
    prose_text = mask_spans(after_links, [(m.start(), m.end()) for m in code_again])
    hits = []

    def add(kind, raw, start):
        lineno = unfenced.count("\n", 0, start) + 1
        if lineno <= len(kinds) and kinds[lineno - 1] != "body":
            return
        line = lines[lineno - 1] if lineno <= len(lines) else raw
        hits.append((kind, raw, lineno, line))

    for match in wiki:
        add("wikilink", match.group(1).split("|", 1)[0], match.start())
    for match in md_links:
        dest = match.group(2).strip()
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", dest):
            continue
        add("markdown", dest, match.start())
    for match in inline:
        for raw in PATH_RE.findall(match.group(1)):
            add("backtick", raw, match.start())
        for raw in ABS_MD.findall(match.group(1)):
            add("backtick", raw, match.start())
    for match in PATH_RE.finditer(prose_text):
        add("prose", match.group(0), match.start())
    for match in ABS_MD.finditer(prose_text):
        add("prose", match.group(1), match.start())

    ids = []
    known = set()
    for path in inventory:
        known.add(os.path.basename(path)[:-3] if path.endswith(".md") else path)
        parts = parts_of(path)
        if len(parts) >= 2 and parts[-1] in ("report.md", "brief.md"):
            known.add(parts[0])
    seen_ids = set()

    def add_id(token, start):
        if token not in known or token in seen_ids:
            return
        if "/" in token or token.endswith(".md"):
            return
        lineno = unfenced.count("\n", 0, start) + 1
        if lineno <= len(kinds) and kinds[lineno - 1] != "body":
            return
        line = lines[lineno - 1] if lineno <= len(lines) else token
        seen_ids.add(token)
        ids.append((token, lineno, line))

    for match in inline:
        add_id(match.group(1).strip(), match.start())
    for match in ID_TOKEN.finditer(prose_text):
        add_id(match.group(0), match.start())
    return hits, ids


def collect_see_also(text):
    unfenced = fence_mask(text)
    kinds = line_kind_map(text)
    found = []
    for match in SEE_ALSO.finditer(unfenced):
        lineno = unfenced.count("\n", 0, match.start()) + 1
        if lineno <= len(kinds) and kinds[lineno - 1] != "body":
            continue
        found.append((lineno, match.group(0), match.group(1)))
    return found


def amended_blocks(text):
    matches = list(AMENDED.finditer(text))
    blocks = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        blocks.append(
            {
                "date": match.group(1),
                "order": match.group(2),
                "span": text[match.start() : end],
                "start": match.start(),
                "line": text.count("\n", 0, match.start()) + 1,
            }
        )
    return blocks


def explicit_paths_in(fragment, source, root, inventory):
    found = []
    for raw in PATH_RE.findall(fragment):
        target, _reasons, _shadow = resolve_target(raw, source, root, inventory)
        if target is not None:
            found.append((target, raw))
    for match in WIKI_FIND.finditer(fragment):
        target, _reasons, _shadow = resolve_target(
            match.group(1), source, root, inventory
        )
        if target is not None:
            found.append((target, match.group(1)))
    for match in MD_LINK.finditer(fragment):
        target, _reasons, _shadow = resolve_target(
            match.group(2), source, root, inventory
        )
        if target is not None:
            found.append((target, match.group(2)))
    return found


def infer_supersedes(path, text, root, inventory):
    evidence = []
    questions = []
    partial = []
    if NEGATE_SUPERSEDE.search(text):
        questions.append(
            Question(
                path, 1, "negated supersession", "negation is not an automatic edge"
            )
        )
        return evidence, questions, partial
    field_targets = []
    for match in SUPERSEDES_FIELD.finditer(text):
        lineno = text.count("\n", 0, match.start()) + 1
        fragment = match.group(1)
        extracted = explicit_paths_in(fragment, path, root, inventory)
        if not extracted:
            questions.append(
                Question(
                    path,
                    lineno,
                    match.group(0),
                    "clause-only or missing supersede target",
                )
            )
            partial.append({"line": lineno, "path": path, "text": match.group(0)})
            continue
        for target, raw in extracted:
            field_targets.append((target, lineno, match.group(0), raw))
    blocks = amended_blocks(text)
    dates = [block["date"] for block in blocks if block["date"]]
    ambiguous = False
    if len(blocks) > 1:
        if len(dates) != len(blocks) or len(set(dates)) != len(dates):
            ambiguous = True
        if any(block["order"] == "later" for block in blocks) and len(set(dates)) <= 1:
            ambiguous = True
    amended_targets = []
    for block in blocks:
        if not re.search(r"(?i)\bsupersedes\b", block["span"]):
            continue
        extracted = explicit_paths_in(block["span"], path, root, inventory)
        if not extracted:
            questions.append(
                Question(
                    path,
                    block["line"],
                    block["span"].splitlines()[0],
                    "AMENDED replacement names no document",
                )
            )
            partial.append(
                {
                    "line": block["line"],
                    "path": path,
                    "text": block["span"].splitlines()[0],
                }
            )
            continue
        amended_targets.append((block, extracted))
    if ambiguous and amended_targets:
        questions.append(
            Question(
                path,
                amended_targets[0][0]["line"],
                "AMENDED",
                "contradictory or unordered amendment chronology",
            )
        )
        partial.append(
            {
                "line": amended_targets[0][0]["line"],
                "path": path,
                "text": "AMENDED",
            }
        )
        amended_targets = []
    elif amended_targets:
        if dates:
            latest = max(
                block["date"]
                for block, _extracted in amended_targets
                if block["date"]
            )
            amended_targets = [
                item for item in amended_targets if item[0]["date"] == latest
            ]
        for block, extracted in amended_targets:
            for target, raw in extracted:
                field_targets.append(
                    (target, block["line"], block["span"].splitlines()[0], raw)
                )
    seen = set()
    for target, lineno, line, raw in field_targets:
        if target.value in seen:
            continue
        seen.add(target.value)
        evidence.append(
            Evidence(
                "supersedes",
                target.value,
                "anchored or explicit replacement",
                "high",
                path,
                lineno,
                line,
            )
        )
    return evidence, questions, partial


def infer_relates(path, text, root, inventory):
    evidence = []
    questions = []
    parts = parts_of(path)
    if len(parts) == 2 and parts[1] in ("brief.md", "report.md"):
        other_name = "report.md" if parts[1] == "brief.md" else "brief.md"
        other = "%s/%s" % (parts[0], other_name)
        if other in inventory:
            evidence.append(
                Evidence(
                    "relates",
                    other,
                    "same-task pair",
                    "high",
                    path,
                    1,
                    "%s <-> %s" % (path, other),
                )
            )
    for lineno, line, fragment in collect_see_also(text):
        extracted = explicit_paths_in(fragment, path, root, inventory)
        if not extracted:
            questions.append(
                Question(path, lineno, line, "related mention has no resolvable target")
            )
            continue
        for target, raw in extracted:
            evidence.append(
                Evidence(
                    "relates",
                    target.value,
                    "explicit related or see-also",
                    "high",
                    path,
                    lineno,
                    line,
                )
            )
    return evidence, questions


def infer_cites(path, text, root, inventory):
    evidence = []
    questions = []
    unresolved = []
    ambiguous = []
    shadows = []
    hits, ids = extract_paths(text, path, root, inventory)
    seen = set()
    for kind, raw, lineno, line in hits:
        ok, why = citation_context_ok(line)
        if not ok:
            questions.append(Question(path, lineno, line, why))
            continue
        target, reasons, shadow = resolve_target(raw, path, root, inventory)
        if shadow:
            shadows.append(shadow)
        if target is None:
            reason = reasons[0] if reasons else "unresolved"
            item = {
                "line": lineno,
                "path": path,
                "reason": reason,
                "text": line,
                "token": raw,
            }
            if reason.startswith("ambiguous"):
                ambiguous.append(item)
            else:
                unresolved.append(item)
            questions.append(Question(path, lineno, line, reason))
            continue
        key = ("cites", target.value)
        if key in seen:
            continue
        seen.add(key)
        evidence.append(
            Evidence(
                "cites",
                target.value,
                "%s citation" % kind,
                "high",
                path,
                lineno,
                line,
            )
        )
    for token, lineno, line in ids:
        ok, why = citation_context_ok(line)
        if not ok:
            continue
        matches = [
            item
            for item in inventory
            if item == token
            or item.endswith("/%s.md" % token)
            or parts_of(item)[:1] == [token]
        ]
        if len(matches) != 1:
            ambiguous.append(
                {
                    "line": lineno,
                    "path": path,
                    "reason": "standalone id is not a unique document",
                    "text": line,
                    "token": token,
                }
            )
            questions.append(
                Question(path, lineno, line, "standalone id is not a unique document")
            )
            continue
        questions.append(
            Question(
                path,
                lineno,
                line,
                "standalone id lacks a named document context",
            )
        )
        ambiguous.append(
            {
                "line": lineno,
                "path": path,
                "reason": "standalone id lacks a named document context",
                "text": line,
                "token": token,
            }
        )
    return evidence, questions, unresolved, ambiguous, shadows


def path_shadows(source, targets, inventory):
    found = []
    source_dir = "/".join(parts_of(source)[:-1])
    for target in targets:
        if not source_dir:
            continue
        local = "%s/%s" % (source_dir, target)
        if local in inventory and local != target:
            found.append({"local": local, "path": source, "target": target})
    return found


def slug_collisions(inventory):
    buckets = {}
    for path in inventory:
        key = slugify(os.path.basename(path))
        buckets.setdefault(key, []).append(path)
    return [
        {"paths": sorted(paths), "slug": slug}
        for slug, paths in sorted(buckets.items())
        if len(paths) > 1
    ]


def supersede_cycles(edges):
    graph = {}
    for source, target in edges:
        graph.setdefault(source, set()).add(target)
    cycles = []
    visiting = set()
    seen = set()
    stack = []

    def visit(node):
        if node in seen:
            return
        if node in visiting:
            if node in stack:
                loop = stack[stack.index(node) :] + [node]
                cycles.append(loop)
            return
        visiting.add(node)
        stack.append(node)
        for nxt in sorted(graph.get(node, ())):
            visit(nxt)
        stack.pop()
        visiting.remove(node)
        seen.add(node)

    for node in sorted(graph):
        visit(node)
    unique = []
    encoded = set()
    for loop in cycles:
        key = tuple(loop)
        if key not in encoded:
            encoded.add(key)
            unique.append(loop)
    return unique


def walk_markdown(root):
    files = []
    incomplete = False

    def onerror(_exc):
        nonlocal incomplete
        incomplete = True

    if os.path.islink(root) or not os.path.isdir(root):
        raise LintUnavailable("Record root is not a readable directory")
    for dirpath, dirnames, filenames in os.walk(
        root, followlinks=False, onerror=onerror
    ):
        dirnames[:] = sorted(name for name in dirnames if name != ".git")
        rel_dir = posix_rel(os.path.relpath(dirpath, root))
        if rel_dir != "." and ".git" in parts_of(rel_dir):
            continue
        for name in sorted(filenames):
            if not name.endswith(".md"):
                continue
            full = os.path.join(dirpath, name)
            rel = posix_rel(os.path.relpath(full, root))
            files.append((rel, full))
    return files, incomplete


def load_inventory(root):
    scanned, incomplete = walk_markdown(root)
    items = []
    for rel, full in scanned:
        try:
            info = os.lstat(full)
        except OSError:
            incomplete = True
            continue
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            continue
        if ".git" in parts_of(rel):
            continue
        try:
            digest = sha256_file(full)
            text = read_text(full)
        except OSError:
            incomplete = True
            continue
        items.append(
            {
                "path": rel,
                "sha256": digest,
                "text": text,
                "full": full,
            }
        )
    items.sort(key=lambda item: item["path"])
    return items, incomplete


def build_footer(evidence):
    grouped = {key: [] for key in FOOTER_KEYS}
    for item in evidence:
        if item.confidence != "high":
            continue
        rel = parse_relpath(item.target)
        if rel is None:
            continue
        grouped[item.key].append(rel)
    return Footer(
        merge_targets(grouped["supersedes"]),
        merge_targets(grouped["cites"]),
        merge_targets(grouped["relates"]),
    )


def apply_bytes(old_text, new_line):
    body = old_text
    if body and not body.endswith("\n"):
        body += "\n"
    elif body.endswith("\n\n"):
        body = body.rstrip("\n") + "\n"
    return body + new_line + "\n"


def propose(root, out_dir, state_root):
    items, incomplete = load_inventory(root)
    if incomplete:
        raise LintUnavailable("incomplete Record scan")
    inventory = [item["path"] for item in items]
    inventory_set = set(inventory)
    classified = []
    proposals = []
    candidates = []
    unresolved = []
    ambiguous = []
    excluded = []
    existing = []
    unknown = []
    partial = []
    shadows = []
    questions_all = []
    counts = {name: 0 for name in CLASSIFICATIONS}
    supersede_edges = []
    for item in items:
        path = item["path"]
        text = item["text"]
        kind, reason = classify_relpath(path, text, state_root)
        if kind is None:
            continue
        counts[kind] += 1
        classified.append({"classification": kind, "path": path, "reason": reason})
        meta = unknown_metadata(text, path)
        if meta:
            unknown.append(meta)
        lineno, line, footer = terminal_related(text)
        if kind == "already-linked":
            existing.append(
                {
                    "canonical": footer is not None,
                    "line": line,
                    "path": path,
                }
            )
            if footer is None:
                questions_all.append(
                    Question(path, lineno, line, "malformed existing Related footer")
                )
            else:
                for key, target in footer.edges():
                    if key == "supersedes":
                        supersede_edges.append((path, target))
            continue
        if kind != "eligible":
            excluded.append({"classification": kind, "path": path, "reason": reason})
            continue
        if related_lines(text) and terminal_related(text)[0] is None:
            first_related = related_lines(text)[0]
            questions_all.append(
                Question(
                    path,
                    first_related[0],
                    first_related[1],
                    "nonterminal Related line",
                )
            )
            continue
        cites, cite_q, unresolved_items, ambiguous_items, cite_shadows = infer_cites(
            path, text, root, inventory_set
        )
        supersedes, super_q, partial_items = infer_supersedes(
            path, text, root, inventory_set
        )
        relates, rel_q = infer_relates(path, text, root, inventory_set)
        questions = cite_q + super_q + rel_q
        unresolved.extend(unresolved_items)
        ambiguous.extend(ambiguous_items)
        partial.extend(partial_items)
        shadows.extend(cite_shadows)
        high = [
            item
            for item in cites + supersedes + relates
            if item.confidence == "high"
        ]
        for item_e in high:
            if item_e.target == path:
                questions.append(
                    Question(path, item_e.line, item_e.text, "self-target")
                )
        high = [item_e for item_e in high if item_e.target != path]
        for item_e in high:
            shadows.extend(path_shadows(path, [item_e.target], inventory_set))
        proposed = build_footer(high)
        new_line = render_footer(proposed)
        proposal = {
            "after_footer_bytes": new_line,
            "before_footer_bytes": None,
            "classification": kind,
            "current_footer": None,
            "edges": [
                {
                    "confidence": item_e.confidence,
                    "key": item_e.key,
                    "line": item_e.line,
                    "reason": item_e.reason,
                    "target": item_e.target,
                    "text": item_e.text,
                }
                for item_e in high
            ],
            "path": path,
            "proposed_footer": new_line,
            "questions": [item_q.as_dict() for item_q in questions],
            "reason": reason,
            "sha256": item["sha256"],
        }
        proposals.append(proposal)
        for item_e in high:
            if item_e.key == "supersedes":
                supersede_edges.append((path, item_e.target))
        questions_all.extend(questions)
    cycle_list = supersede_cycles(supersede_edges)
    cycle_pairs = set()
    for loop in cycle_list:
        for index in range(len(loop) - 1):
            cycle_pairs.add((loop[index], loop[index + 1]))
    filtered = []
    for proposal in proposals:
        kept = []
        dropped = False
        for edge in proposal["edges"]:
            pair = (proposal["path"], edge["target"])
            if edge["key"] == "supersedes" and pair in cycle_pairs:
                dropped = True
                questions_all.append(
                    Question(
                        proposal["path"],
                        edge["line"],
                        edge["text"],
                        "supersession cycle",
                    )
                )
                continue
            kept.append(edge)
        if dropped:
            proposal["edges"] = kept
            rebuilt = build_footer(
                [
                    Evidence(
                        edge["key"],
                        edge["target"],
                        edge["reason"],
                        edge["confidence"],
                        proposal["path"],
                        edge["line"],
                        edge["text"],
                    )
                    for edge in kept
                ]
            )
            proposal["proposed_footer"] = render_footer(rebuilt)
            proposal["after_footer_bytes"] = proposal["proposed_footer"]
        filtered.append(proposal)
    proposals = filtered
    for proposal in proposals:
        for edge in proposal["edges"]:
            candidates.append(dict(edge, path=proposal["path"]))
    for item_q in questions_all:
        candidates.append(
            {
                "confidence": "question",
                "key": None,
                "line": item_q.line,
                "path": item_q.path,
                "reason": item_q.why,
                "target": None,
                "text": item_q.text,
            }
        )
    collisions = slug_collisions(inventory_set)
    def by_path_line_token(item):
        return (item["path"], item["line"], item["token"])

    def by_candidate(item):
        return (
            item.get("path") or "",
            item.get("line") or 0,
            item.get("key") or "",
            item.get("target") or "",
        )

    manifest = {
        "ambiguous_ids": sorted(ambiguous, key=by_path_line_token),
        "candidates": sorted(candidates, key=by_candidate),
        "classification_counts": counts,
        "cycles": cycle_list,
        "excluded": sorted(excluded, key=lambda item: item["path"]),
        "existing_footers": sorted(existing, key=lambda item: item["path"]),
        "files": classified,
        "partial_replacements": sorted(
            partial, key=lambda item: (item["path"], item["line"])
        ),
        "path_shadows": sorted(
            shadows, key=lambda item: (item["path"], item["target"])
        ),
        "proposals": sorted(proposals, key=lambda item: item["path"]),
        "slug_collisions": collisions,
        "source_commit": git_head(root),
        "source_paths": [
            {"path": item["path"], "sha256": item["sha256"]} for item in items
        ],
        "tool_sha256": sha256_file(os.path.abspath(__file__)),
        "unknown_metadata": sorted(unknown, key=lambda item: item["path"]),
        "unresolved": sorted(unresolved, key=by_path_line_token),
    }
    os.makedirs(out_dir, exist_ok=True)
    texts = {item["path"]: item["text"] for item in items}
    patch_chunks = []
    for proposal in manifest["proposals"]:
        path = proposal["path"]
        new_text = apply_bytes(texts[path], proposal["proposed_footer"])
        old_lines = texts[path].splitlines(True)
        if old_lines and not old_lines[-1].endswith("\n"):
            old_lines[-1] += "\n"
        new_lines = new_text.splitlines(True)
        chunk = "".join(
            list(
                difflib.unified_diff(
                    old_lines,
                    new_lines,
                    fromfile="a/%s" % path,
                    tofile="b/%s" % path,
                    n=3,
                )
            )
        )
        if chunk:
            patch_chunks.append(chunk if chunk.endswith("\n") else chunk + "\n")
    report = render_report(manifest)
    write_atomic(
        os.path.join(out_dir, "manifest.json"), dump_json(manifest).encode("utf-8")
    )
    write_atomic(
        os.path.join(out_dir, "changes.patch"), "".join(patch_chunks).encode("utf-8")
    )
    write_atomic(os.path.join(out_dir, "report.md"), report.encode("utf-8"))
    return 0


def render_report(manifest):
    lines = [
        "# Record link proposal",
        "",
        "Source commit: %s" % (manifest["source_commit"] or "null"),
        "Tool: %s" % manifest["tool_sha256"],
        "Scanned: %s" % len(manifest["source_paths"]),
        "",
        "## Classification",
        "",
    ]
    for name in CLASSIFICATIONS:
        count = manifest["classification_counts"].get(name, 0)
        lines.append("- %s: %s" % (name, count))
    lines.extend(["", "## Proposed edits", ""])
    if not manifest["proposals"]:
        lines.append("None.")
    for proposal in manifest["proposals"]:
        lines.append("### %s" % proposal["path"])
        lines.append(proposal["reason"])
        lines.append(proposal["proposed_footer"])
        lines.append("")
    lines.extend(["## Questions", ""])
    questions = [
        item for item in manifest["candidates"] if item.get("confidence") == "question"
    ]
    if not questions:
        lines.append("None.")
    for item in questions:
        lines.append(
            "- %s:%s: %s" % (item.get("path"), item.get("line"), item.get("reason"))
        )
    for title, key in (
        ("Unresolved", "unresolved"),
        ("Ambiguous ids", "ambiguous_ids"),
        ("Excluded", "excluded"),
        ("Existing footers", "existing_footers"),
        ("Unknown metadata", "unknown_metadata"),
        ("Partial replacements", "partial_replacements"),
        ("Cycles", "cycles"),
        ("Path shadows", "path_shadows"),
        ("Slug collisions", "slug_collisions"),
    ):
        lines.extend(["", "## %s" % title, ""])
        value = manifest[key]
        if not value:
            lines.append("None.")
        else:
            lines.append(
                json.dumps(
                    value, sort_keys=True, separators=JSON_SEP, ensure_ascii=False
                )
            )
    lines.append("")
    return "\n".join(lines)


def append_footer_bytes(old, new_line):
    body = old
    if body and not body.endswith(b"\n"):
        body += b"\n"
    elif body.endswith(b"\n\n"):
        body = body.rstrip(b"\n") + b"\n"
    return body + new_line.encode("utf-8") + b"\n"


def write_atomic(path, data):
    tmp = "%s.tmp.%s" % (path, os.getpid())
    with open(tmp, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


def load_manifest(path):
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError) as exc:
        raise ApplyRefuse("altered or unreadable plan: %s" % exc)
    required = (
        "source_paths",
        "proposals",
        "tool_sha256",
        "classification_counts",
    )
    for key in required:
        if key not in payload:
            raise ApplyRefuse("altered plan: missing %s" % key)
    if not isinstance(payload["source_paths"], list) or not isinstance(
        payload["proposals"], list
    ):
        raise ApplyRefuse("altered plan: invalid lists")
    return payload


def apply_plan(root, plan_path, state_root):
    if os.path.islink(root) or not os.path.isdir(root):
        raise ApplyRefuse("apply root is not a safe directory")
    manifest = load_manifest(plan_path)
    wanted = {item["path"]: item["sha256"] for item in manifest["source_paths"]}
    writes = []
    for proposal in manifest["proposals"]:
        path = proposal.get("path")
        footer = proposal.get("proposed_footer")
        if not path or parse_relpath(path) is None:
            raise ApplyRefuse("unsafe proposal path")
        if not footer or parse_footer(footer) is None:
            raise ApplyRefuse("altered plan: proposed footer is not canonical")
        full = os.path.join(root, path)
        contained = contained_regular(root, path)
        if contained != path:
            raise ApplyRefuse("symlink escape or unsafe target: %s" % path)
        try:
            with open(full, "rb") as handle:
                current = handle.read()
        except OSError as exc:
            raise ApplyRefuse("cannot read %s: %s" % (path, exc))
        current_text = current.decode("utf-8", errors="surrogateescape")
        if terminal_related(current_text)[1] == footer:
            continue
        if sha256_bytes(current) != wanted.get(path):
            raise ApplyRefuse("source hash changed: %s" % path)
        writes.append((full, append_footer_bytes(current, footer)))
    for full, data in writes:
        write_atomic(full, data)
    return 0


def lint_root(root, state_root):
    try:
        items, incomplete = load_inventory(root)
    except LintUnavailable:
        raise
    except OSError as exc:
        raise LintUnavailable("unreadable root: %s" % exc)
    if incomplete:
        raise LintUnavailable("incomplete Record scan")
    inventory = {item["path"] for item in items}
    counts = {name: 0 for name in CLASSIFICATIONS}
    findings = []
    missing = 0
    invalid = 0
    unresolved = 0
    edges = {key: 0 for key in FOOTER_KEYS}
    incoming = set()
    outgoing = set()
    ids = {}
    supersede_edges = []
    authored = []
    for item in items:
        path = item["path"]
        text = item["text"]
        kind, reason = classify_relpath(path, text, state_root)
        if kind is None:
            continue
        counts[kind] += 1
        if kind in ("eligible", "already-linked"):
            authored.append(path)
        ident = yaml_id(text)
        if ident:
            ids.setdefault(ident, []).append(path)
        related = related_lines(text)
        lineno, line, footer = terminal_related(text)
        if kind == "eligible":
            if not related:
                missing += 1
                findings.append(
                    Finding(
                        path, "absent", "eligible record has no Related footer"
                    )
                )
            elif lineno is None:
                invalid += 1
                findings.append(
                    Finding(
                        path,
                        "nonterminal",
                        "Related line is not the terminal nonblank line",
                    )
                )
            if len(related) > 1:
                invalid += 1
                findings.append(Finding(path, "multiple", "more than one Related line"))
        linked = kind in ("eligible", "already-linked")
        if linked and lineno is not None and footer is None:
            invalid += 1
            findings.append(
                Finding(path, "invalid", "Related line is not canonical grammar")
            )
        if footer is not None:
            for key, target in footer.edges():
                edges[key] += 1
                outgoing.add(path)
                incoming.add(target)
                if contained_regular(root, target) != target or target not in inventory:
                    unresolved += 1
                    findings.append(
                        Finding(
                            path,
                            "unresolved",
                            "footer target missing or unsafe: %s" % target,
                        )
                    )
                if key == "supersedes":
                    supersede_edges.append((path, target))
                shadows = path_shadows(path, [target], inventory)
                for shadow in shadows:
                    findings.append(
                        Finding(
                            path,
                            "shadow",
                            "local path %s shadows %s" % (shadow["local"], target),
                        )
                    )
    for ident, paths in sorted(ids.items()):
        if len(paths) > 1:
            findings.append(
                Finding(
                    paths[0],
                    "duplicate-id",
                    "id %s is used by %s" % (ident, ", ".join(paths)),
                )
            )
    for loop in supersede_cycles(supersede_edges):
        findings.append(
            Finding(
                loop[0],
                "cycle",
                "supersession cycle %s" % " -> ".join(loop),
            )
        )
    orphans = 0
    for path in authored:
        if path not in outgoing and path not in incoming:
            orphans += 1
    findings.sort(key=lambda item: (item.path, item.kind, item.detail))
    payload = {
        "active_writer": counts["active-writer"],
        "already_linked": counts["already-linked"],
        "edges": edges,
        "eligible": counts["eligible"],
        "exempt": counts["owner-exempt"],
        "findings": [item.as_dict() for item in findings[:FINDINGS_BOUND]],
        "generated": counts["generated"],
        "invalid": invalid,
        "missing": missing,
        "needs_review": counts["needs-review"],
        "orphans": orphans,
        "raw": counts["raw"],
        "scanned": len(items),
        "status": "ok",
        "unresolved": unresolved,
    }
    sys.stdout.write(dump_json(payload))
    return 0


def add_state_root(parser):
    parser.add_argument("--state-root", default=None)


def build_parser():
    parser = argparse.ArgumentParser(add_help=False)
    sub = parser.add_subparsers(dest="command")
    propose_p = sub.add_parser("propose", add_help=False)
    propose_p.add_argument("--root", required=True)
    propose_p.add_argument("--out", required=True)
    add_state_root(propose_p)
    apply_p = sub.add_parser("apply", add_help=False)
    apply_p.add_argument("--root", required=True)
    apply_p.add_argument("--plan", required=True)
    add_state_root(apply_p)
    lint_p = sub.add_parser("lint", add_help=False)
    lint_p.add_argument("--root", required=True)
    lint_p.add_argument("--json", action="store_true")
    add_state_root(lint_p)
    return parser


def resolve_state(args):
    if args.state_root:
        return args.state_root
    return default_state_root(args.root)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        usage()
        return 0 if argv and argv[0] in ("-h", "--help") else 2
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    if args.command is None:
        usage()
        return 2
    state_root = resolve_state(args)
    try:
        if args.command == "propose":
            if not args.root or not args.out:
                raise UsageError("propose requires --root and --out")
            return propose(args.root, args.out, state_root)
        if args.command == "apply":
            if not args.root or not args.plan:
                raise UsageError("apply requires --root and --plan")
            return apply_plan(args.root, args.plan, state_root)
        if args.command == "lint":
            if not args.json:
                raise UsageError("lint requires --json")
            return lint_root(args.root, state_root)
        raise UsageError("unknown command")
    except UsageError as exc:
        sys.stderr.write("fm-record-links: %s\n" % exc.message)
        return 2
    except ApplyRefuse as exc:
        sys.stderr.write("fm-record-links: %s\n" % exc.message)
        return 1
    except LintUnavailable as exc:
        sys.stdout.write(
            dump_json({"error": exc.message, "findings": [], "status": "unavailable"})
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
