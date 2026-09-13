#!/usr/bin/env python3
"""Derived-brain maintenance for a disposable gbrain projection.

This program never points a gbrain brain directory or source at the live
Record. It reads committed Record blobs only, writes a locally committed
projection outside the Record, and publishes only allowlisted generated
pages under wiki/gbrain/ and wiki/views/gbrain/. T12 is the publisher
and scheduler. Ambient writeback stays off. This ship does not switch
the brief ranker.

Usage:
  fm-gbrain-maintain.py project --record R --out DIR
    [--commit OID] [--manifest FILE] [--format text|json]
  fm-gbrain-maintain.py run --fm-home H --record R --now T
    [--gbrain-bin PATH] [--launchctl-bin PATH] [--scan-bin PATH]
    [--transcript-manifest FILE] [--skip-serve] [--deadline-seconds N]
    [--format text|json]
  fm-gbrain-maintain.py install-archive --archive FILE --sha256 HEX
    --dest DIR [--format text|json]
  fm-gbrain-maintain.py write-plist --gbrain-bin PATH --gbrain-home DIR
    --brain DIR [--label NAME] [--port N] [--out FILE] [--format text|json]
  fm-gbrain-maintain.py --help

Exit codes:
  0  clean.
  1  failed projection, maintenance, scan, publication, or install refuse.
  2  usage or unreadable required input.
  3  exclusive maintenance lock is held; services are not touched.

project
  Builds one disposable Git projection from one Record commit.
  Uncommitted Record edits are invisible. Symlinks, LFS pointer bodies,
  hidden paths, raw binaries, raw transcripts, credentials, wiki/gbrain
  source-route copies, and wiki/views/gbrain evaluation output are
  excluded. Reserved Markdown basenames become <name>.record.md.
  Non-Markdown text becomes <name>.md with a metadata wrapper.
  Ordinary Markdown is stored at data/<Record-relative path>.
  Published generated pages map back to conversations/sessions, knowledge,
  and entities. Unknown wiki/gbrain prefixes fail the run.
  Filename or slug collisions fail the run. A missing Record or an empty
  unexpected projection fails the run. The projection is its own Git
  repository with no remote and no shared Git directory.

run
  Acquires one home lock, projects the current Record HEAD, stops only
  the named LaunchAgent unless --skip-serve, replaces the configured
  brain with the candidate, runs pinned gbrain sync --no-pull, ingests
  only primary transcript paths from the manifest, replaces
  record-footer typed edges, exports generated prefixes, scans the
  staged wiki payload, publishes only those files, and restarts the
  named agent on the cleanup path. A second run against a held lock
  exits 3 and does not stop services. Any subprocess or scan failure
  restores the previous accepted generation, keeps the Record wiki
  unchanged, and still restarts the agent when this run stopped it.
  GBRAIN_ALLOW_MASS_RECONCILE is never set. Maintenance commands set
  GBRAIN_SKIP_STARTUP_HOOKS=1.

install-archive
  Verifies SHA-256 and extracts into a new versioned directory.
  A matching prior install is a no-op. A different existing dest is
  refused. This never mutates a global package path in place.

write-plist
  Renders a loopback LaunchAgent plist with no secrets.

Config, when --fm-home is set and flags are omitted, is KEY=VALUE in
$FM_HOME/config/gbrain.env:
  GBRAIN_BIN, GBRAIN_HOME, GBRAIN_BRAIN, GBRAIN_LABEL, GBRAIN_PORT,
  GBRAIN_TRANSCRIPT_MANIFEST, GBRAIN_LAUNCHCTL.
Defaults:
  home state/gbrain/home, brain state/gbrain/brain,
  label com.firstmate.ks-t17-gbrain, port 3131.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile

USAGE_EXIT = 2
FAIL_EXIT = 1
BUSY_EXIT = 3
JSON_DUMP = {"sort_keys": True, "indent": 2}
RESERVED_BASENAMES = frozenset(
    ("schema.md", "index.md", "log.md", "README.md", "RESOLVER.md")
)
TEXT_EXT = frozenset((".txt", ".csv", ".json"))
MARKDOWN_EXT = frozenset((".md", ".mdx"))
GENERATED_PREFIXES = (
    "conversations/sessions/",
    "knowledge/",
    "entities/",
)
WIKI_GBRAIN = "wiki/gbrain/"
WIKI_VIEWS_GBRAIN = "wiki/views/gbrain/"
FORBIDDEN_PUBLISH = frozenset(
    ("playbook", "captain.md", "captain-shared.md", "learnings.md")
)
HIDDEN_SKIP = (".git",)
CREDENTIAL_NAMES = frozenset(
    (".env", "credentials", "credentials.json", "id_rsa", "id_ed25519")
)
CREDENTIAL_EXT = frozenset((".pem", ".key", ".p12", ".pfx"))
LFS_PREFIX = b"version https://git-lfs.github.com/spec/v1"
DEFAULT_LABEL = "com.firstmate.ks-t17-gbrain"
DEFAULT_PORT = 3131
SLUG_RE = re.compile(r"[^a-z0-9]+")


class UsageError(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


class MaintainError(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


class BusyError(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


def die_usage(message):
    sys.stderr.write("gbrain-maintain: %s\n" % message)
    return USAGE_EXIT


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dump_json(payload):
    return json.dumps(payload, **JSON_DUMP) + "\n"


def parse_now(raw):
    text = raw.strip()
    if not text.endswith("Z"):
        raise UsageError(" --now must be RFC3339 UTC ending in Z")
    body = text[:-1]
    if "." in body:
        body = body.split(".", 1)[0]
    try:
        time.strptime(body, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        raise UsageError(" --now must be RFC3339 UTC ending in Z")
    return text


def require_abs(label, path):
    if not path or not os.path.isabs(path):
        raise UsageError("%s must be an absolute path" % label)
    if "\n" in path or "\r" in path:
        raise UsageError("%s must be one line" % label)
    return path


def physical_dir(path):
    return os.path.realpath(path)


def load_kv_env(path):
    values = {}
    if not os.path.isfile(path):
        return values
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            if key and all(ch.isalnum() or ch == "_" for ch in key):
                values[key] = val
    return values


def load_links_module():
    path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "fm-record-links.py"
    )
    spec = importlib.util.spec_from_file_location("fm_record_links", path)
    if spec is None or spec.loader is None:
        raise MaintainError("cannot load fm-record-links.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def slugify(name):
    stem, _ext = os.path.splitext(name)
    slug = SLUG_RE.sub("-", stem.lower()).strip("-")
    return slug or "page"


def is_hidden_path(relpath):
    return any(part.startswith(".") for part in relpath.split("/"))


def is_credential(relpath):
    base = os.path.basename(relpath)
    _stem, ext = os.path.splitext(base)
    if base in CREDENTIAL_NAMES or ext in CREDENTIAL_EXT:
        return True
    return "credentials" in relpath.lower() and relpath.endswith(".json")


def looks_like_transcript(relpath):
    lower = relpath.lower()
    if lower.endswith(".jsonl"):
        return True
    parts = relpath.split("/")
    return "transcripts" in parts or "agent-transcripts" in parts


def is_lfs_pointer(data):
    return data.startswith(LFS_PREFIX)


def is_binary(data):
    if b"\x00" in data:
        return True
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return True
    return False


def git_output(record, args):
    proc = subprocess.run(
        ["git", "-C", record] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip()
        raise MaintainError(err or "git %s failed" % " ".join(args))
    return proc.stdout


def record_commit(record, explicit):
    if not os.path.isdir(os.path.join(record, ".git")):
        raise MaintainError("missing Record git directory")
    oid = explicit or git_output(record, ["rev-parse", "HEAD"]).decode("ascii").strip()
    if not oid:
        raise MaintainError("Record commit is empty")
    git_output(record, ["rev-parse", "--verify", oid + "^{commit}"])
    return oid


def list_committed_entries(record, commit):
    raw = git_output(record, ["ls-tree", "-r", "--full-tree", commit])
    entries = []
    for line in raw.decode("utf-8", "replace").splitlines():
        if not line:
            continue
        meta, path = line.split("\t", 1)
        parts = meta.split()
        if len(parts) < 3:
            continue
        mode, kind, _oid = parts[0], parts[1], parts[2]
        entries.append((mode, kind, path))
    return entries


def cat_blob(record, commit, path):
    return git_output(record, ["show", "%s:%s" % (commit, path)])


def generated_projection_path(relpath):
    if not relpath.startswith(WIKI_GBRAIN):
        return None
    rest = relpath[len(WIKI_GBRAIN) :]
    for prefix in GENERATED_PREFIXES:
        if rest.startswith(prefix) and rest != prefix:
            return rest
    raise MaintainError("unknown generated prefix: %s" % relpath)


def classify_source(relpath, mode, kind):
    if kind != "blob":
        return "exclude", "non-blob"
    if mode == "120000":
        return "exclude", "symlink"
    if is_hidden_path(relpath):
        return "exclude", "hidden"
    if is_credential(relpath):
        return "exclude", "credential"
    if looks_like_transcript(relpath):
        return "exclude", "transcript"
    if relpath.startswith(WIKI_VIEWS_GBRAIN):
        return "exclude", "eval-output"
    if relpath.startswith(WIKI_GBRAIN):
        generated_projection_path(relpath)
        return "generated", "generated"
    _stem, ext = os.path.splitext(os.path.basename(relpath))
    ext = ext.lower()
    if ext in MARKDOWN_EXT or ext in TEXT_EXT:
        return "source", "text"
    return "exclude", "extension"


def projected_source_path(relpath):
    base = os.path.basename(relpath)
    parent = os.path.dirname(relpath)
    _stem, ext = os.path.splitext(base)
    ext = ext.lower()
    if base in RESERVED_BASENAMES:
        name = "%s.record.md" % os.path.splitext(base)[0]
    elif ext in TEXT_EXT:
        name = "%s.md" % os.path.splitext(base)[0]
    else:
        name = base
    rel = "/".join(p for p in (parent, name) if p)
    return "data/%s" % rel


def wrap_text(relpath, data, source_type, source_date):
    digest = sha256_bytes(data)
    try:
        body = data.decode("utf-8")
    except UnicodeDecodeError:
        raise MaintainError("binary reached the text wrapper: %s" % relpath)
    header = (
        "---\n"
        "record_path: %s\n"
        "content_hash: sha256:%s\n"
        "source_date: %s\n"
        "source_type: %s\n"
        "---\n\n" % (relpath, digest, source_date, source_type)
    )
    return header + body


def source_date_from_text(text):
    for line in text.splitlines()[:40]:
        if line.startswith("date:"):
            value = line.split(":", 1)[1].strip().strip('"').strip("'")
            if value:
                return value
    return "date unknown"


def build_projection(record, commit, out_dir):
    if os.path.exists(out_dir):
        if os.path.islink(out_dir) or not os.path.isdir(out_dir):
            raise MaintainError("projection out is not a directory")
        if os.path.isdir(os.path.join(out_dir, ".git")):
            raise MaintainError("refusing to reuse a projection that already has .git")
        if os.listdir(out_dir):
            raise MaintainError("projection out must be empty")
    os.makedirs(out_dir, exist_ok=True)
    pages = []
    excluded = []
    slugs = {}
    projected_paths = {}
    entries = list_committed_entries(record, commit)
    for mode, kind, relpath in entries:
        try:
            action, reason = classify_source(relpath, mode, kind)
        except MaintainError:
            raise
        if action == "exclude":
            excluded.append({"path": relpath, "reason": reason})
            continue
        data = cat_blob(record, commit, relpath)
        if is_lfs_pointer(data):
            excluded.append({"path": relpath, "reason": "lfs-pointer"})
            continue
        if is_binary(data):
            excluded.append({"path": relpath, "reason": "binary"})
            continue
        if action == "generated":
            dest_rel = generated_projection_path(relpath)
            payload = data
            kind_name = "generated"
        else:
            dest_rel = projected_source_path(relpath)
            base = os.path.basename(relpath)
            ext = os.path.splitext(base)[1].lower()
            if ext in TEXT_EXT or base in RESERVED_BASENAMES:
                text = data.decode("utf-8")
                payload = wrap_text(
                    relpath, data, ext.lstrip(".") or "md", source_date_from_text(text)
                ).encode("utf-8")
                kind_name = "wrapped-text"
            else:
                payload = data
                kind_name = "markdown"
        if dest_rel in projected_paths:
            raise MaintainError(
                "projection path collision: %s and %s"
                % (projected_paths[dest_rel], relpath)
            )
        slug = slugify(os.path.basename(dest_rel))
        slug_key = "%s/%s" % (os.path.dirname(dest_rel), slug)
        if slug_key in slugs:
            raise MaintainError(
                "projection slug collision: %s and %s" % (slugs[slug_key], relpath)
            )
        dest = os.path.join(out_dir, dest_rel)
        parent = os.path.dirname(dest)
        os.makedirs(parent, exist_ok=True)
        if os.path.lexists(dest):
            raise MaintainError("projection would overwrite %s" % dest_rel)
        with open(dest, "wb") as handle:
            handle.write(payload)
        projected_paths[dest_rel] = relpath
        slugs[slug_key] = relpath
        pages.append(
            {
                "original": relpath,
                "projected": dest_rel,
                "content_hash": "sha256:%s" % sha256_bytes(payload),
                "kind": kind_name,
            }
        )
    if not pages:
        raise MaintainError("empty or unexpected projection")
    pages.sort(key=lambda row: row["original"])
    excluded.sort(key=lambda row: row["path"])
    return {
        "type": "gbrain-projection",
        "record_commit": commit,
        "pages": pages,
        "excluded": excluded,
    }


def init_projection_git(out_dir, commit):
    try:
        subprocess.run(["git", "-C", out_dir, "init", "-q"], check=True)
        subprocess.run(["git", "-C", out_dir, "add", "-A"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                out_dir,
                "-c",
                "user.name=fm-gbrain",
                "-c",
                "user.email=gbrain@local",
                "commit",
                "-qm",
                "projection %s" % commit,
            ],
            check=True,
        )
        remotes = subprocess.run(
            ["git", "-C", out_dir, "remote"],
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.decode("ascii")
    except subprocess.CalledProcessError as exc:
        raise MaintainError("projection git failed: %s" % exc)
    if remotes.strip():
        raise MaintainError("projection git unexpectedly has a remote")


def atomic_write(path, data):
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            if isinstance(data, str):
                handle.write(data.encode("utf-8"))
            else:
                handle.write(data)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def collect_footer_edges(projection_dir, links):
    edges = []
    for root, dirs, files in os.walk(projection_dir):
        dirs[:] = [name for name in dirs if name != ".git"]
        for name in files:
            if not name.endswith(".md"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, projection_dir).replace(os.sep, "/")
            try:
                text = open(path, "r", encoding="utf-8").read()
            except (OSError, UnicodeDecodeError):
                continue
            _lineno, _line, footer = links.terminal_related(text)
            if footer is None:
                continue
            source = rel[5:] if rel.startswith("data/") else rel
            for link_type in ("supersedes", "cites", "relates"):
                values = getattr(footer, link_type)
                if not values:
                    continue
                for item in values:
                    edges.append(
                        {
                            "from": source,
                            "to": item.value,
                            "link_type": link_type,
                            "link_source": "record-footer",
                        }
                    )
    edges.sort(key=lambda row: (row["from"], row["link_type"], row["to"]))
    return edges


def run_cmd(argv, env, timeout, cwd=None):
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=cwd,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise MaintainError("timeout: %s" % " ".join(argv[:4]))
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip()
        raise MaintainError(err or "exit %s: %s" % (proc.returncode, argv[0]))
    return proc


class ExclusiveLock:
    def __init__(self, path):
        self.path = path
        self.held = False

    def acquire(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        try:
            os.mkdir(self.path)
        except FileExistsError:
            raise BusyError("maintenance lock held")
        atomic_write(os.path.join(self.path, "pid"), str(os.getpid()) + "\n")
        self.held = True

    def release(self):
        if not self.held:
            return
        shutil.rmtree(self.path, ignore_errors=True)
        self.held = False


class HomePaths:
    def __init__(self, fm_home, env):
        self.fm_home = physical_dir(fm_home)
        state = os.path.join(self.fm_home, "state", "gbrain")
        self.lock = os.path.join(state, "maintain.lock")
        self.home = env.get("GBRAIN_HOME") or os.path.join(state, "home")
        self.brain = env.get("GBRAIN_BRAIN") or os.path.join(state, "brain")
        self.candidate = os.path.join(state, "candidate")
        self.previous = os.path.join(state, "previous")
        self.staging = os.path.join(state, "staging")
        self.label = env.get("GBRAIN_LABEL") or DEFAULT_LABEL
        port = env.get("GBRAIN_PORT") or str(DEFAULT_PORT)
        try:
            self.port = int(port)
        except ValueError:
            raise UsageError("GBRAIN_PORT must be an integer")
        self.gbrain_bin = env.get("GBRAIN_BIN") or "gbrain"
        self.launchctl_bin = env.get("GBRAIN_LAUNCHCTL") or "launchctl"
        self.transcript_manifest = env.get(
            "GBRAIN_TRANSCRIPT_MANIFEST"
        ) or os.path.join(state, "transcripts.json")
        self.scan_bin = env.get("GBRAIN_SCAN") or ""
        for label, path in (
            ("GBRAIN_HOME", self.home),
            ("GBRAIN_BRAIN", self.brain),
            ("candidate", self.candidate),
            ("previous", self.previous),
            ("staging", self.staging),
        ):
            if os.path.isabs(path) and self._escapes_into_record(path):
                raise MaintainError("%s points at the Record" % label)

    def _escapes_into_record(self, path):
        record = os.path.join(self.fm_home, "data")
        real = os.path.realpath(path)
        rec = os.path.realpath(record)
        try:
            common = os.path.commonpath([real, rec])
        except ValueError:
            return False
        return common == rec


def gbrain_env(paths, extra=None):
    env = os.environ.copy()
    env["GBRAIN_HOME"] = paths.home
    env["GBRAIN_SKIP_STARTUP_HOOKS"] = "1"
    env.pop("GBRAIN_ALLOW_MASS_RECONCILE", None)
    if extra:
        env.update(extra)
    return env


def wait_pglite_idle(paths, deadline):
    lock = os.path.join(paths.home, ".gbrain", "brain.pglite.lock")
    while os.path.exists(lock):
        if time.time() > deadline:
            raise MaintainError("PGLite lock still held")
        time.sleep(0.05)


def stop_serve(paths, launchctl_bin, skip, deadline):
    if skip:
        return False
    uid = os.getuid()
    subprocess.run(
        [launchctl_bin, "bootout", "gui/%s/%s" % (uid, paths.label)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    wait_pglite_idle(paths, deadline)
    return True


def start_serve(paths, launchctl_bin, skip, plist_path):
    if skip:
        return
    uid = os.getuid()
    argv = [launchctl_bin, "bootstrap", "gui/%s" % uid]
    if plist_path:
        argv.append(plist_path)
    else:
        argv.append(paths.label)
    subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def rotate_trees(current, previous, candidate):
    if os.path.exists(previous):
        shutil.rmtree(previous)
    if os.path.exists(current):
        os.rename(current, previous)
    os.rename(candidate, current)


def restore_previous(current, previous):
    if not os.path.exists(previous):
        return False
    if os.path.exists(current):
        shutil.rmtree(current)
    os.rename(previous, current)
    return True


def load_transcript_manifest(path):
    if not path or not os.path.isfile(path):
        return []
    data = json.loads(open(path, encoding="utf-8").read())
    if isinstance(data, dict):
        data = data.get("files") or data.get("transcripts") or []
    if not isinstance(data, list):
        raise MaintainError("transcript manifest must be a list")
    rows = []
    for item in data:
        if not isinstance(item, dict):
            raise MaintainError("transcript manifest row must be an object")
        rows.append(
            {
                "path": item.get("path") or "",
                "format": item.get("format") or "",
                "source_id": item.get("source_id") or item.get("id") or "",
                "role": item.get("role") or "unclassified",
            }
        )
    return rows


def ingest_primaries(paths, rows, timeout, cwd):
    unclassified = []
    ingested = []
    for row in rows:
        role = row["role"]
        if role == "unclassified":
            unclassified.append(row["path"])
            continue
        if role != "primary":
            continue
        if not row["path"] or not row["format"] or not row["source_id"]:
            raise MaintainError("primary transcript row is incomplete")
        if not os.path.isfile(row["path"]):
            raise MaintainError("primary transcript missing: %s" % row["path"])
        argv = [
            paths.gbrain_bin,
            "transcripts",
            "ingest",
            row["path"],
            "--format",
            row["format"],
            "--source-id",
            row["source_id"],
            "--json",
        ]
        run_cmd(argv, gbrain_env(paths), timeout, cwd=cwd)
        ingested.append(row["path"])
    return ingested, unclassified


def export_generated(paths, export_dir, timeout, cwd):
    if os.path.exists(export_dir):
        shutil.rmtree(export_dir)
    os.makedirs(export_dir)
    run_cmd(
        [paths.gbrain_bin, "export", "--out", export_dir],
        gbrain_env(paths),
        timeout,
        cwd=cwd,
    )
    kept = []
    for root, dirs, files in os.walk(export_dir):
        dirs[:] = [name for name in dirs if name != ".raw"]
        for name in files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, export_dir).replace(os.sep, "/")
            if rel.startswith(".raw/") or "/.raw/" in rel:
                continue
            allowed = any(
                rel == prefix[:-1] or rel.startswith(prefix)
                for prefix in GENERATED_PREFIXES
            )
            if not allowed:
                continue
            kept.append(rel)
    return sorted(kept)


def stage_wiki_payload(export_dir, exported, edges, manifest, receipt, stage_dir):
    if os.path.exists(stage_dir):
        shutil.rmtree(stage_dir)
    wiki = os.path.join(stage_dir, "gbrain")
    views = os.path.join(stage_dir, "views", "gbrain")
    os.makedirs(wiki)
    os.makedirs(views)
    for rel in exported:
        src = os.path.join(export_dir, rel)
        dest = os.path.join(wiki, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(src, dest)
    atomic_write(os.path.join(views, "manifest.json"), dump_json(manifest))
    atomic_write(os.path.join(views, "footer-edges.json"), dump_json({"edges": edges}))
    atomic_write(os.path.join(views, "receipt.json"), dump_json(receipt))


def scan_stage(scan_bin, stage_dir, timeout):
    if not scan_bin:
        raise MaintainError("scan executable is required before publication")
    argv = scan_bin if isinstance(scan_bin, list) else [scan_bin]
    if len(argv) == 1 and argv[0].endswith("fm-record-scan.sh"):
        argv = [argv[0], "chain", "--dir", stage_dir]
    else:
        argv = argv + [stage_dir]
    run_cmd(argv, os.environ.copy(), timeout)


def publish_stage(record, stage_dir):
    dest_gbrain = os.path.join(record, "wiki", "gbrain")
    dest_views = os.path.join(record, "wiki", "views", "gbrain")
    for name in FORBIDDEN_PUBLISH:
        forbidden = os.path.join(stage_dir, name)
        if os.path.exists(forbidden):
            raise MaintainError("publication staged a forbidden path: %s" % name)
    os.makedirs(os.path.join(record, "wiki", "views"), exist_ok=True)
    tmp_g = dest_gbrain + ".next"
    tmp_v = dest_views + ".next"
    if os.path.exists(tmp_g):
        shutil.rmtree(tmp_g)
    if os.path.exists(tmp_v):
        shutil.rmtree(tmp_v)
    shutil.copytree(os.path.join(stage_dir, "gbrain"), tmp_g)
    shutil.copytree(os.path.join(stage_dir, "views", "gbrain"), tmp_v)
    old_g = dest_gbrain + ".prev"
    old_v = dest_views + ".prev"
    if os.path.exists(old_g):
        shutil.rmtree(old_g)
    if os.path.exists(old_v):
        shutil.rmtree(old_v)
    if os.path.exists(dest_gbrain):
        os.rename(dest_gbrain, old_g)
    if os.path.exists(dest_views):
        os.rename(dest_views, old_v)
    os.rename(tmp_g, dest_gbrain)
    os.rename(tmp_v, dest_views)
    if os.path.exists(old_g):
        shutil.rmtree(old_g)
    if os.path.exists(old_v):
        shutil.rmtree(old_v)


def replace_edges(paths, edges_path, timeout, cwd):
    run_cmd(
        [
            paths.gbrain_bin,
            "links",
            "replace",
            "--source",
            "record-footer",
            "--manifest",
            edges_path,
        ],
        gbrain_env(paths),
        timeout,
        cwd=cwd,
    )


class RunState:
    def __init__(self):
        self.stopped = False
        self.replaced = False
        self.published = False
        self.paths = None
        self.launchctl = None
        self.skip_serve = True
        self.plist = None
        self.lock = None


RUN = RunState()


def cleanup_run(_signum=None, _frame=None):
    if RUN.replaced and not RUN.published and RUN.paths is not None:
        restore_previous(RUN.paths.brain, RUN.paths.previous)
    if RUN.stopped and RUN.paths is not None:
        start_serve(RUN.paths, RUN.launchctl, RUN.skip_serve, RUN.plist)
    if RUN.lock is not None:
        RUN.lock.release()
    if _signum is not None:
        raise MaintainError("interrupted")


def cmd_project(args):
    record = physical_dir(require_abs("--record", args.record))
    out = require_abs("--out", args.out)
    commit = record_commit(record, args.commit)
    manifest = build_projection(record, commit, out)
    init_projection_git(out, commit)
    if args.manifest:
        atomic_write(args.manifest, dump_json(manifest))
    if args.format == "json":
        sys.stdout.write(dump_json(manifest))
    else:
        sys.stdout.write(
            "projection pages=%d excluded=%d commit=%s\n"
            % (len(manifest["pages"]), len(manifest["excluded"]), commit)
        )
    return 0


def cmd_run(args):
    parse_now(args.now)
    fm_home = physical_dir(require_abs("--fm-home", args.fm_home))
    record = physical_dir(require_abs("--record", args.record))
    record_real = os.path.realpath(record)
    env = load_kv_env(os.path.join(fm_home, "config", "gbrain.env"))
    if args.gbrain_bin:
        env["GBRAIN_BIN"] = args.gbrain_bin
    if args.launchctl_bin:
        env["GBRAIN_LAUNCHCTL"] = args.launchctl_bin
    if args.transcript_manifest:
        env["GBRAIN_TRANSCRIPT_MANIFEST"] = args.transcript_manifest
    paths = HomePaths(fm_home, env)
    if os.path.commonpath([os.path.realpath(paths.brain), record_real]) == record_real:
        raise MaintainError("brain directory points at the Record")
    scan_bin = args.scan_bin or paths.scan_bin
    if not scan_bin:
        default_scan = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "fm-record-scan.sh"
        )
        scan_bin = default_scan if os.path.isfile(default_scan) else ""
    deadline = time.time() + max(1, args.deadline_seconds)
    lock = ExclusiveLock(paths.lock)
    lock.acquire()
    RUN.lock = lock
    RUN.paths = paths
    RUN.launchctl = paths.launchctl_bin
    RUN.skip_serve = args.skip_serve
    RUN.plist = args.plist
    signal.signal(signal.SIGTERM, cleanup_run)
    stopped = False
    replaced = False
    try:
        os.makedirs(os.path.join(fm_home, "state", "gbrain"), exist_ok=True)
        os.makedirs(paths.home, exist_ok=True)
        if os.path.exists(paths.candidate):
            shutil.rmtree(paths.candidate)
        os.makedirs(paths.candidate)
        commit = record_commit(record, None)
        manifest = build_projection(record, commit, paths.candidate)
        init_projection_git(paths.candidate, commit)
        remaining = max(1, int(deadline - time.time()))
        stopped = stop_serve(paths, paths.launchctl_bin, args.skip_serve, deadline)
        RUN.stopped = stopped
        rotate_trees(paths.brain, paths.previous, paths.candidate)
        replaced = True
        RUN.replaced = True
        remaining = max(1, int(deadline - time.time()))
        run_cmd(
            [paths.gbrain_bin, "sync", "--no-pull"],
            gbrain_env(paths),
            remaining,
            cwd=paths.brain,
        )
        rows = load_transcript_manifest(paths.transcript_manifest)
        ingested, unclassified = ingest_primaries(
            paths, rows, max(1, int(deadline - time.time())), paths.brain
        )
        if any(row["role"] == "primary" for row in rows):
            run_cmd(
                [paths.gbrain_bin, "embed", "--stale"],
                gbrain_env(paths),
                max(1, int(deadline - time.time())),
                cwd=paths.brain,
            )
        links = load_links_module()
        edges = collect_footer_edges(paths.brain, links)
        if os.path.exists(paths.staging):
            shutil.rmtree(paths.staging)
        os.makedirs(paths.staging)
        edges_path = os.path.join(paths.staging, "footer-edges.json")
        atomic_write(edges_path, dump_json({"edges": edges}))
        replace_edges(
            paths, edges_path, max(1, int(deadline - time.time())), paths.brain
        )
        export_dir = os.path.join(paths.staging, "export")
        exported = export_generated(
            paths, export_dir, max(1, int(deadline - time.time())), paths.brain
        )
        receipt = {
            "type": "gbrain-receipt",
            "now": args.now,
            "record_commit": commit,
            "ingested": ingested,
            "unclassified": unclassified,
            "exported": exported,
            "label": paths.label,
        }
        wiki_stage = os.path.join(paths.staging, "wiki")
        stage_wiki_payload(export_dir, exported, edges, manifest, receipt, wiki_stage)
        if not scan_bin:
            raise MaintainError("scan executable is required before publication")
        scan_stage(scan_bin, wiki_stage, max(1, int(deadline - time.time())))
        publish_stage(record, wiki_stage)
        RUN.published = True
        payload = {
            "type": "gbrain-run",
            "status": "ok",
            "record_commit": commit,
            "pages": len(manifest["pages"]),
            "exported": exported,
            "ingested": len(ingested),
            "unclassified": unclassified,
        }
        if args.format == "json":
            sys.stdout.write(dump_json(payload))
        else:
            sys.stdout.write(
                "run ok pages=%d exported=%d ingested=%d\n"
                % (len(manifest["pages"]), len(exported), len(ingested))
            )
        return 0
    except Exception:
        if replaced and not RUN.published:
            restore_previous(paths.brain, paths.previous)
            RUN.replaced = False
        raise
    finally:
        if stopped:
            start_serve(paths, paths.launchctl_bin, args.skip_serve, args.plist)
            RUN.stopped = False
        lock.release()
        RUN.lock = None


def cmd_install_archive(args):
    archive = require_abs("--archive", args.archive)
    dest = require_abs("--dest", args.dest)
    expected = args.sha256.strip().lower()
    if len(expected) != 64 or any(ch not in "0123456789abcdef" for ch in expected):
        raise UsageError("--sha256 must be a 64-character hex digest")
    digest = sha256_file(archive)
    if digest != expected:
        raise MaintainError("archive digest mismatch")
    marker = os.path.join(dest, "INSTALL_SHA256")
    if os.path.exists(dest):
        if os.path.isfile(marker) and open(
            marker, encoding="ascii"
        ).read().strip() == digest:
            if args.format == "json":
                sys.stdout.write(
                    dump_json({"status": "ok", "dest": dest, "sha256": digest})
                )
            else:
                sys.stdout.write("install unchanged %s\n" % dest)
            return 0
        raise MaintainError("refusing to mutate existing dest %s" % dest)
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    tmp = dest + ".extract"
    if os.path.exists(tmp):
        shutil.rmtree(tmp)
    os.makedirs(tmp)
    if tarfile.is_tarfile(archive):
        with tarfile.open(archive) as handle:
            handle.extractall(tmp)
    elif zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as handle:
            handle.extractall(tmp)
    else:
        shutil.rmtree(tmp)
        raise MaintainError("archive is not tar or zip")
    os.rename(tmp, dest)
    atomic_write(marker, digest + "\n")
    if args.format == "json":
        sys.stdout.write(dump_json({"status": "ok", "dest": dest, "sha256": digest}))
    else:
        sys.stdout.write("install ok %s\n" % dest)
    return 0


def cmd_write_plist(args):
    gbrain_bin = require_abs("--gbrain-bin", args.gbrain_bin)
    gbrain_home = require_abs("--gbrain-home", args.gbrain_home)
    brain = require_abs("--brain", args.brain)
    if not os.path.isfile(gbrain_bin) and not args.allow_missing_bin:
        raise UsageError("--gbrain-bin must be an executable path")
    label = args.label or DEFAULT_LABEL
    port = args.port or DEFAULT_PORT
    xml = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>%s</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>serve</string>
    <string>--http</string>
    <string>--bind</string>
    <string>127.0.0.1</string>
    <string>--port</string>
    <string>%s</string>
    <string>--suppress-bootstrap-token</string>
  </array>
  <key>WorkingDirectory</key>
  <string>%s</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>GBRAIN_HOME</key>
    <string>%s</string>
    <key>GBRAIN_SKIP_STARTUP_HOOKS</key>
    <string>1</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
""" % (
        label,
        gbrain_bin,
        port,
        brain,
        gbrain_home,
    )
    if args.out:
        atomic_write(args.out, xml)
    else:
        sys.stdout.write(xml)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", nargs="?")
    parser.add_argument("--help", action="store_true")
    parser.add_argument("--record")
    parser.add_argument("--out")
    parser.add_argument("--commit")
    parser.add_argument("--manifest")
    parser.add_argument("--format", default="text", choices=("text", "json"))
    parser.add_argument("--fm-home")
    parser.add_argument("--now")
    parser.add_argument("--gbrain-bin")
    parser.add_argument("--launchctl-bin")
    parser.add_argument("--scan-bin")
    parser.add_argument("--transcript-manifest")
    parser.add_argument("--skip-serve", action="store_true")
    parser.add_argument("--deadline-seconds", type=int, default=1800)
    parser.add_argument("--plist")
    parser.add_argument("--archive")
    parser.add_argument("--sha256")
    parser.add_argument("--dest")
    parser.add_argument("--gbrain-home")
    parser.add_argument("--brain")
    parser.add_argument("--label")
    parser.add_argument("--port", type=int)
    parser.add_argument("--allow-missing-bin", action="store_true")
    return parser


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return USAGE_EXIT
    if args.help or args.command in (None, "help"):
        sys.stdout.write(__doc__)
        return 0
    try:
        if args.deadline_seconds is not None and args.deadline_seconds <= 0:
            raise UsageError("--deadline-seconds must be positive")
        if args.command == "project":
            if not args.record or not args.out:
                raise UsageError("project requires --record and --out")
            return cmd_project(args)
        if args.command == "run":
            if not args.fm_home or not args.record or not args.now:
                raise UsageError("run requires --fm-home, --record, and --now")
            return cmd_run(args)
        if args.command == "install-archive":
            if not args.archive or not args.sha256 or not args.dest:
                raise UsageError(
                    "install-archive requires --archive, --sha256, and --dest"
                )
            return cmd_install_archive(args)
        if args.command == "write-plist":
            if not args.gbrain_bin or not args.gbrain_home or not args.brain:
                raise UsageError(
                    "write-plist requires --gbrain-bin, --gbrain-home, and --brain"
                )
            return cmd_write_plist(args)
        raise UsageError("unknown command; run --help")
    except UsageError as exc:
        return die_usage(exc.message)
    except BusyError as exc:
        sys.stderr.write("gbrain-maintain: %s\n" % exc.message)
        return BUSY_EXIT
    except MaintainError as exc:
        sys.stderr.write("gbrain-maintain: %s\n" % exc.message)
        return FAIL_EXIT
    except OSError as exc:
        sys.stderr.write("gbrain-maintain: %s\n" % exc)
        return FAIL_EXIT


if __name__ == "__main__":
    sys.exit(main())
