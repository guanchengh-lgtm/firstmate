#!/usr/bin/env python3
# fm-graphify.py - T10 ledger, inventory, nightly plan, citation eval, coverage.
#
# Usage:
#   fm-graphify.py inventory --projects-root DIR --record DIR --registry FILE
#                            [--home DIR] [--extra DIR]...
#   fm-graphify.py plan --record DIR --projects-root DIR --state DIR
#   fm-graphify.py stamp --root DIR --docs-built-at COMMIT
#   fm-graphify.py eval --probes FILE --mode replay --graphify-raw FILE
#                       --t2-raw FILE [--graph FILE]
#   fm-graphify.py cover --root DIR [--graph FILE] [--detect FILE]
#
# This program never installs graphify, never writes a hook or user-scope skill,
# and never publishes a merged graph from an incomplete selected set.
# The Record ledger path is knowledge-system-wayfinder/research/T10-graphify/inputs.tsv.
# inventory prints that TSV to stdout and writes nothing.
# plan prints a line-oriented nightly plan and writes nothing.
# eval scores frozen probes after mapping graphify nodes to documents.
# cover prints one coverage TSV row per extension.
#
# Ledger columns, tab-separated, one header line:
#   repo kind state delivery source_revision identity graph_relpath
#   merge_tag graph_hash publication notes
# kind is record or code.
# state is selected, duplicate, absent, incomplete, or unregistered.
# publication is ready, pending, or none.
# identity is a normalized origin URL or resolved local path, never a worktree
# path and never a disposable treehouse path.
# Shell graphify update is a code rebuild only. A document-source change is
# detail=docs-stale until the host assistant --update --wiki workflow runs.
# stamp records graphify-out/code-only-build.tsv after a shell code rebuild:
# the graph hash that rebuild produced and the commit whose documents the graph
# still reflects. plan consults it only while the graph hash still matches, so
# a host --update --wiki rebuild clears it without knowing it exists.
# A graph whose built_at_commit is empty or unknown to the clone is stale and
# gets a code rebuild.
# A graph that its clone tracks in git is never rewritten by the shell: a code
# change there is docs-stale until the host workflow ships the rebuild through
# that repository's own delivery.
# The merged graph lands under the state directory, never under the Record,
# because the Record checkpoint commits every file below its root.
#
# Exit codes:
#   0  success, including an empty inventory or an unchanged plan
#   2  usage or unreadable required input

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

LEDGER_REL = Path("knowledge-system-wayfinder/research/T10-graphify/inputs.tsv")
COLUMNS = (
    "repo",
    "kind",
    "state",
    "delivery",
    "source_revision",
    "identity",
    "graph_relpath",
    "merge_tag",
    "graph_hash",
    "publication",
    "notes",
)
DOC_EXTS = {
    ".md",
    ".mdx",
    ".qmd",
    ".skill",
    ".txt",
    ".rst",
    ".html",
    ".yaml",
    ".yml",
}
UNSUPPORTED_EXTS = {".pine", ".csv"}
GRAPH_RELPATH = "graphify-out/graph.json"
CODE_ONLY_MARKER = "graphify-out/code-only-build.tsv"
CAPTAIN_ORIGIN_MARK = "github.com/guanchengh-lgtm"
NODE_SRC_RE = re.compile(r"\[src=([^ \]]+)")
COMMON_BASENAMES = {"readme.md", "changelog.md", "license", "license.md"}


def fail_usage(message: str) -> None:
    sys.stderr.write("graphify: %s\n" % message)
    raise SystemExit(2)


def git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
    )


def git_ok(root: Path, *args: str) -> str:
    proc = git(root, *args)
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def normalize_identity(raw: str) -> str:
    value = raw.strip()
    if not value:
        return ""
    if value.startswith("file://"):
        value = value[7:]
    if value.startswith("ssh://"):
        host_path = value[6:].split("@", 1)[-1]
        value = "https://" + host_path
    elif "://" not in value and ":" in value and not value.startswith("/"):
        host, _, path = value.partition(":")
        value = "https://%s/%s" % (host.split("@", 1)[-1], path.lstrip("/"))
    if value.startswith("/"):
        try:
            return str(Path(value).resolve())
        except OSError:
            return value
    value = value.rstrip("/")
    if value.endswith(".git"):
        value = value[:-4]
    return value.lower()


def parse_registry(path: Path) -> list[tuple[str, str]]:
    rows: list[tuple[str, str]] = []
    if not path.is_file():
        fail_usage("registry is not a file: %s" % path)
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0] != "-":
            continue
        name = parts[1]
        mode = "no-mistakes"
        if len(parts) >= 3 and parts[2].startswith("["):
            token = parts[2].lstrip("[").rstrip("]")
            if token and token != "+yolo":
                mode = token
        rows.append((name, mode))
    return rows


def repo_facts(root: Path) -> dict[str, str]:
    top = git_ok(root, "rev-parse", "--show-toplevel")
    if not top or Path(top).resolve() != root.resolve():
        return {}
    common = git_ok(root, "rev-parse", "--git-common-dir")
    head = git_ok(root, "rev-parse", "HEAD")
    origin = git_ok(root, "remote", "get-url", "origin")
    if common and not Path(common).is_absolute() and top:
        common = str((Path(top) / common).resolve())
    elif common:
        common = str(Path(common).resolve())
    primary = "yes" if (root / ".git").is_dir() else "no"
    if origin:
        identity = normalize_identity(origin)
    elif common:
        identity = normalize_identity(str(Path(common).parent))
    else:
        identity = normalize_identity(top)
    return {
        "toplevel": top,
        "common": common,
        "head": head,
        "origin": origin,
        "identity": identity,
        "primary": primary,
    }


def graph_hash(graph: Path) -> str:
    if not graph.is_file():
        return ""
    proc = subprocess.run(
        ["git", "hash-object", str(graph)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def publication_for(state: str, graph: Path) -> str:
    if state != "selected":
        return "none"
    if graph.is_file():
        return "ready"
    return "pending"


def write_tsv(rows: list[dict[str, str]]) -> None:
    sys.stdout.write("\t".join(COLUMNS) + "\n")
    for row in sorted(rows, key=lambda item: (item["kind"], item["repo"])):
        sys.stdout.write("\t".join(row[col] for col in COLUMNS) + "\n")


def empty_row(repo: str, kind: str) -> dict[str, str]:
    return {
        "repo": repo,
        "kind": kind,
        "state": "absent",
        "delivery": "no-mistakes",
        "source_revision": "",
        "identity": "",
        "graph_relpath": GRAPH_RELPATH,
        "merge_tag": repo,
        "graph_hash": "",
        "publication": "none",
        "notes": "",
    }


def classify_extra(identity: str) -> tuple[str, str]:
    lowered = identity.lower()
    if CAPTAIN_ORIGIN_MARK in lowered:
        return "unregistered", "captain-owned-unregistered"
    if lowered.startswith("https://") or lowered.startswith("http://"):
        return "unregistered", "tool-or-upstream-checkout"
    return "unregistered", "local-unregistered"


def cmd_inventory(args: argparse.Namespace) -> int:
    projects_root = Path(args.projects_root)
    record = Path(args.record)
    registry = parse_registry(Path(args.registry))
    extras = [Path(item) for item in args.extra]
    if args.home:
        extras.append(Path(args.home))

    seen_common: dict[str, str] = {}
    seen_identity: dict[str, str] = {}
    rows: list[dict[str, str]] = []

    def remember(name: str, facts: dict[str, str]) -> None:
        if facts.get("common"):
            seen_common[facts["common"]] = name
        if facts.get("identity"):
            seen_identity[facts["identity"]] = name
        if facts.get("toplevel"):
            seen_identity[facts["toplevel"]] = name

    def already_seen(facts: dict[str, str]) -> str:
        common = facts.get("common") or ""
        identity = facts.get("identity") or ""
        top = facts.get("toplevel") or ""
        if common and common in seen_common:
            return "same-git-common:%s" % seen_common[common]
        if identity and identity in seen_identity:
            return "same-identity:%s" % seen_identity[identity]
        if top and top in seen_identity:
            return "same-identity:%s" % seen_identity[top]
        return ""

    if record.exists():
        row = empty_row("record", "record")
        row["delivery"] = "local-only"
        graph = record / row["graph_relpath"]
        row["graph_hash"] = graph_hash(graph)
        if (record / ".git").exists():
            facts = repo_facts(record)
            row["source_revision"] = facts.get("head", "")
            row["identity"] = facts.get("identity", "")
            row["state"] = "selected"
            row["notes"] = "record-root"
            row["publication"] = publication_for("selected", graph)
        else:
            row["state"] = "incomplete"
            row["notes"] = "record-git-absent"
            row["publication"] = "pending"
        rows.append(row)

    for name, delivery in registry:
        clone = projects_root / name
        row = empty_row(name, "code")
        row["delivery"] = delivery
        if name == "fm-vault" and not clone.exists():
            row["state"] = "absent"
            row["notes"] = "retired-absent"
            rows.append(row)
            continue
        if not clone.exists():
            row["notes"] = "clone-absent"
            rows.append(row)
            continue
        facts = repo_facts(clone)
        if not facts:
            row["state"] = "incomplete"
            row["notes"] = "not-git"
            row["publication"] = "pending"
            rows.append(row)
            continue
        row["source_revision"] = facts["head"]
        row["identity"] = facts["identity"]
        graph = clone / row["graph_relpath"]
        row["graph_hash"] = graph_hash(graph)
        note = already_seen(facts)
        if note:
            row["state"] = "duplicate"
            row["notes"] = note
            row["publication"] = "none"
        else:
            row["state"] = "selected"
            row["publication"] = publication_for("selected", graph)
            remember(name, facts)
            if name == "fm-home":
                row["notes"] = "distinct-seed-clone"
        rows.append(row)

    for extra in extras:
        if not extra.exists():
            continue
        facts = repo_facts(extra)
        if not facts:
            continue
        identity = facts["identity"]
        name = extra.name
        note = already_seen(facts)
        if note:
            row = empty_row(name, "code")
            row["state"] = "duplicate"
            row["source_revision"] = facts["head"]
            row["identity"] = identity
            row["notes"] = note
            rows.append(row)
            continue
        state, extra_note = classify_extra(identity)
        row = empty_row(name, "code")
        row["state"] = state
        row["delivery"] = "no-mistakes"
        row["source_revision"] = facts["head"]
        row["identity"] = identity
        row["notes"] = extra_note
        row["publication"] = "none"
        rows.append(row)
        remember(name, facts)

    write_tsv(rows)
    return 0


def load_ledger(record: Path) -> list[dict[str, str]]:
    path = record / LEDGER_REL
    if not path.is_file():
        fail_usage("ledger is not a file: %s" % path)
    rows: list[dict[str, str]] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        fail_usage("ledger is empty")
    header = lines[0].split("\t")
    if header != list(COLUMNS):
        fail_usage("ledger header does not match the T10 column contract")
    for line in lines[1:]:
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != len(COLUMNS):
            fail_usage(
                "ledger row has %d columns, want %d" % (len(cells), len(COLUMNS))
            )
        rows.append(dict(zip(COLUMNS, cells)))
    return rows


def is_doc_path(rel: str) -> bool:
    suffix = Path(rel).suffix.lower()
    return suffix in DOC_EXTS


def changed_paths(root: Path, baseline: str) -> list[str] | None:
    names: list[str] = []
    if not baseline:
        return None
    diff = git(root, "diff", "--name-only", baseline, "HEAD")
    if diff.returncode != 0:
        return None
    names.extend(diff.stdout.splitlines())
    names.extend(git_ok(root, "diff", "--name-only").splitlines())
    names.extend(git_ok(root, "diff", "--name-only", "--cached").splitlines())
    unique = []
    seen = set()
    for name in names:
        if not name or name in seen:
            continue
        if name.startswith("graphify-out/"):
            continue
        seen.add(name)
        unique.append(name)
    return unique


def graph_is_tracked(root: Path, relpath: str) -> bool:
    proc = git(root, "ls-files", "--error-unmatch", "--", relpath)
    return proc.returncode == 0


def read_built_at(graph: Path) -> str:
    if not graph.is_file():
        return ""
    try:
        data = json.loads(graph.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    return str(data.get("built_at_commit") or "")


def docs_built_at(root: Path, graph: Path, built_at: str) -> str:
    marker = root / CODE_ONLY_MARKER
    if not marker.is_file():
        return built_at
    cells = marker.read_text(encoding="utf-8").rstrip("\n").split("\t")
    if len(cells) != 2 or cells[0] != graph_hash(graph):
        return built_at
    return cells[1]


def cmd_stamp(args: argparse.Namespace) -> int:
    root = Path(args.root)
    graph = root / GRAPH_RELPATH
    digest = graph_hash(graph)
    if not digest:
        fail_usage("graph is not a file: %s" % graph)
    marker = root / CODE_ONLY_MARKER
    marker.write_text("%s\t%s\n" % (digest, args.docs_built_at), encoding="utf-8")
    return 0


def cmd_plan(args: argparse.Namespace) -> int:
    record = Path(args.record)
    projects_root = Path(args.projects_root)
    rows = load_ledger(record)
    selected = [row for row in rows if row["state"] == "selected"]
    status = "ok"
    detail = "unchanged"
    steps: list[str] = []
    missing_ready = []
    pending = []
    docs_stale = []
    code_changed = []

    for row in selected:
        if row["kind"] == "record":
            root = record
        else:
            root = projects_root / row["repo"]
        graph = root / row["graph_relpath"]
        if not root.exists() or not graph.is_file():
            if row["publication"] == "ready":
                missing_ready.append(row["repo"])
            else:
                pending.append(row["repo"])
            continue
        if row["publication"] != "ready":
            pending.append(row["repo"])
        built_at = read_built_at(graph)
        doc_baseline = docs_built_at(root, graph, built_at)
        changed = changed_paths(root, built_at)
        doc_changed = changed_paths(root, doc_baseline)
        code = changed is None or any(not is_doc_path(p) for p in changed)
        docs = doc_changed is None or any(is_doc_path(p) for p in doc_changed)
        if code and graph_is_tracked(root, row["graph_relpath"]):
            docs = True
            code = False
        if code:
            code_changed.append(row["repo"])
            steps.append("step=update\t%s" % root)
            if row["kind"] == "code":
                steps.append("step=wiki\t%s" % root)
            steps.append("step=stamp\t%s\t%s" % (root, doc_baseline))
        if docs:
            docs_stale.append(row["repo"])

    ready_selected = []
    for row in selected:
        if row["kind"] == "record":
            root = record
        else:
            root = projects_root / row["repo"]
        graph = root / row["graph_relpath"]
        if graph.is_file() and row["publication"] == "ready":
            ready_selected.append(str(graph))

    if missing_ready:
        status = "failed"
        detail = "missing-input"
    elif docs_stale:
        status = "finding"
        detail = "docs-stale"
    elif pending:
        detail = "pending-inputs"
    elif code_changed:
        detail = "code-updated"

    merged = Path(args.state) / "graphify/merged-graph.json"
    if selected and len(ready_selected) == len(selected) and (
        code_changed or not merged.is_file()
    ):
        steps.append("step=merge\t%s\t%s" % ("\t".join(ready_selected), merged))
        if detail == "unchanged":
            detail = "merge-ready"

    sys.stdout.write("status=%s\n" % status)
    sys.stdout.write("detail=%s\n" % detail)
    for step in steps:
        sys.stdout.write(step + "\n")
    return 0


def expected_ids(disp: str, prior: str) -> list[str]:
    raw = [part for part in (disp.split(",") + prior.split(",")) if part]
    out = []
    for item in raw:
        if item.startswith("decisions/") and item.endswith(".md"):
            out.append(item)
            out.append(item[len("decisions/") : -3])
        else:
            out.append(item)
    return out


def load_probes(path: Path) -> list[dict[str, object]]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        n, date, disp, prior, query = line.rstrip("\n").split("\t")
        rows.append(
            {
                "n": int(n),
                "date": date,
                "disp": [part for part in disp.split(",") if part],
                "prior": [part for part in prior.split(",") if part],
                "query": query,
                "expected": expected_ids(disp, prior),
            }
        )
    return rows


def repo_info(graph: Path) -> dict[str, dict[str, str]]:
    if not graph.is_file():
        return {}
    try:
        data = json.loads(graph.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    info = {}
    for node in data.get("nodes", []):
        src = str(node.get("source_file") or "")
        if not src:
            continue
        info[src] = {
            "repo": str(node.get("repo") or ""),
            "community": str(node.get("community_name") or node.get("community") or ""),
        }
    return info


def document_id(src: str, repo: str) -> tuple[str, str]:
    posix = src.replace("\\", "/")
    base = Path(posix).name.lower()
    if posix.endswith("done-archive.md") or base == "done-archive.md":
        return "", "archive-without-block"
    if base in COMMON_BASENAMES and not repo:
        return "", "ambiguous"
    if posix.startswith("decisions/") and posix.endswith(".md"):
        return posix, ""
    parts = posix.split("/")
    if len(parts) >= 2 and parts[-1] == "report.md":
        return parts[-2], ""
    if posix.endswith(".md"):
        stem = Path(posix).stem
        return stem, ""
    if repo:
        return "%s:%s" % (repo, posix), ""
    return posix, ""


def citations_from_graphify(text: str, graph: Path) -> list[str]:
    info = repo_info(graph)
    seen: OrderedDict[str, str] = OrderedDict()
    for line in text.splitlines():
        match = NODE_SRC_RE.search(line)
        if not match:
            continue
        src = match.group(1)
        repo = info.get(src, {}).get("repo", "")
        doc_id, reason = document_id(src, repo)
        key = doc_id if doc_id else "miss:%s:%s" % (reason, src)
        if key not in seen:
            seen[key] = reason
    return list(seen.keys())


def citations_from_t2(text: str) -> list[str]:
    ids = []
    seen = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        token = stripped.split()[0].rstrip(",")
        if token.startswith("-"):
            token = token.lstrip("-").strip()
        if token and token not in seen:
            seen.add(token)
            ids.append(token)
    return ids


def first_expected_rank(ranked: list[str], expected: list[str]) -> int | None:
    wanted = set(expected)
    position = 0
    for item in ranked:
        position += 1
        if item.startswith("miss:"):
            continue
        if item in wanted:
            return position
    return None


def cmd_eval(args: argparse.Namespace) -> int:
    probes = load_probes(Path(args.probes))
    graph = Path(args.graph) if args.graph else Path(".")
    graphify_raw = Path(args.graphify_raw).read_text(encoding="utf-8")
    t2_raw = Path(args.t2_raw).read_text(encoding="utf-8")
    # Replay mode uses one raw dump for every probe so citation mapping can be
    # tested without invoking graphify or recall.
    g_ids = citations_from_graphify(graphify_raw, graph)
    t_ids = citations_from_t2(t2_raw)
    sys.stdout.write(
        "probe\tsystem\tfirst_expected\thit@1\thit@3\thit@5\tmrr\tcitations\n"
    )
    for probe in probes:
        expected = list(probe["expected"])
        for name, ranked in (("graphify", g_ids), ("t2", t_ids)):
            rank = first_expected_rank(ranked, expected)
            hit1 = "Y" if rank == 1 else "-"
            hit3 = "Y" if rank is not None and rank <= 3 else "-"
            hit5 = "Y" if rank is not None and rank <= 5 else "-"
            mrr = "" if rank is None else ("%.4f" % (1.0 / rank))
            shown = ",".join(ranked[:5])
            sys.stdout.write(
                "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n"
                % (
                    probe["n"],
                    name,
                    "-" if rank is None else str(rank),
                    hit1,
                    hit3,
                    hit5,
                    mrr or "-",
                    shown,
                )
            )
    return 0


def cmd_cover(args: argparse.Namespace) -> int:
    root = Path(args.root)
    graph_path = Path(args.graph) if args.graph else root / "graphify-out/graph.json"
    detect_path = Path(args.detect) if args.detect else None
    tracked = git_ok(root, "ls-files")
    files = [line for line in tracked.splitlines() if line]
    represented: set[str] = set()
    nodes = 0
    edges = 0
    if graph_path.is_file():
        try:
            data = json.loads(graph_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = {}
        nodes = len(data.get("nodes") or [])
        edges = len(data.get("links") or data.get("edges") or [])
        for node in data.get("nodes") or []:
            src = str(node.get("source_file") or "")
            if src:
                represented.add(src.replace("\\", "/"))
    detected: set[str] = set()
    if detect_path and detect_path.is_file():
        try:
            detect = json.loads(detect_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            detect = {}
        files_map = detect.get("files") or {}
        for group in files_map.values():
            for item in group:
                detected.add(str(item).replace("\\", "/"))

    by_ext: dict[str, list[str]] = {}
    for rel in files:
        ext = Path(rel).suffix.lower() or "(none)"
        by_ext.setdefault(ext, []).append(rel)

    revision = git_ok(root, "rev-parse", "HEAD")
    sys.stdout.write(
        "repo\tsource_revision\textension\tinventory_files\tdetected_files\t"
        "extraction_attempted_files\trepresented_source_files\tzero_node_files\t"
        "unsupported_files\tpolicy_skipped_files\terror_files\tsource_bytes\t"
        "graph_nodes\tgraph_edges\tgraph_bytes\twiki_pages\tmeasured_at\n"
    )
    repo = root.name
    graph_bytes = graph_path.stat().st_size if graph_path.is_file() else 0
    wiki_pages = 0
    wiki = root / "graphify-out/wiki"
    if wiki.is_dir():
        wiki_pages = len(list(wiki.glob("*.md")))
    for ext, rels in sorted(by_ext.items()):
        inventory = len(rels)
        unsupported = inventory if ext in UNSUPPORTED_EXTS else 0
        detected_n = 0
        represented_n = 0
        zero_node = 0
        source_bytes = 0
        for rel in rels:
            path = root / rel
            if path.is_file():
                source_bytes += path.stat().st_size
            posix = rel.replace("\\", "/")
            if posix in detected or str(path) in detected:
                detected_n += 1
            if posix in represented:
                represented_n += 1
            elif ext not in UNSUPPORTED_EXTS and ext != "(none)":
                zero_node += 1
        attempted = detected_n if ext not in UNSUPPORTED_EXTS else 0
        if ext in UNSUPPORTED_EXTS:
            detected_n = 0
            represented_n = 0
            zero_node = 0
            attempted = 0
        sys.stdout.write(
            "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\tunknown\n"
            % (
                repo,
                revision,
                ext,
                inventory,
                detected_n,
                attempted,
                represented_n,
                zero_node,
                unsupported,
                0,
                0,
                source_bytes,
                nodes,
                edges,
                graph_bytes,
                wiki_pages,
            )
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fm-graphify.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    inv = sub.add_parser("inventory")
    inv.add_argument("--projects-root", required=True)
    inv.add_argument("--record", required=True)
    inv.add_argument("--registry", required=True)
    inv.add_argument("--home")
    inv.add_argument("--extra", action="append", default=[])

    plan = sub.add_parser("plan")
    plan.add_argument("--record", required=True)
    plan.add_argument("--projects-root", required=True)
    plan.add_argument("--state", required=True)

    stamp = sub.add_parser("stamp")
    stamp.add_argument("--root", required=True)
    stamp.add_argument("--docs-built-at", required=True)

    ev = sub.add_parser("eval")
    ev.add_argument("--probes", required=True)
    ev.add_argument("--mode", choices=("replay",), default="replay")
    ev.add_argument("--graphify-raw", required=True)
    ev.add_argument("--t2-raw", required=True)
    ev.add_argument("--graph")

    cov = sub.add_parser("cover")
    cov.add_argument("--root", required=True)
    cov.add_argument("--graph")
    cov.add_argument("--detect")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return int(exc.code or 2)
    if args.cmd == "inventory":
        return cmd_inventory(args)
    if args.cmd == "plan":
        return cmd_plan(args)
    if args.cmd == "stamp":
        return cmd_stamp(args)
    if args.cmd == "eval":
        return cmd_eval(args)
    if args.cmd == "cover":
        return cmd_cover(args)
    fail_usage("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
