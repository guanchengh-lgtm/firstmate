#!/usr/bin/env python3
"""Report-only maintenance for the firstmate Record.

This program never edits a hand-owned file.
It reports findings, stages generated files under wiki/views, and consumes
receipts other owners write.
Every verdict comes from --now, never from the wall clock or a file mtime.
It works on a plain Record clone with no live home and no fm-record.sh.

Usage:
  fm-maintain.py lint --record R --now T [--format text|json] [--rules R1,R2]
  fm-maintain.py rollout init --record R --now T [--format text|json]
  fm-maintain.py rollout advance --record R --now T --lint-json FILE
    --scheduled-date YYYY-MM-DD [--coverage local|cloud] [--format text|json]
  fm-maintain.py rollout status --record R [--now T] [--format text|json]
  fm-maintain.py stow-gate --record R --now T [--format text|json]
  fm-maintain.py fold --record R --now T [--format text|json]
  fm-maintain.py views --record R --now T [--stage-dir DIR] [--apply]
    [--format text|json]
  fm-maintain.py measure --record R --now T [--state DIR] [--stage-dir DIR]
    [--apply] [--format text|json]
  fm-maintain.py receipt --record R --now T --host SLUG --stages FILE
    --input-commit SHA --lint-json FILE --rollout-json FILE|-
    --tool-fingerprint STR [--stage-dir DIR] [--apply] [--format text|json]
  fm-maintain.py digest --record R --now T [--max-lines 8] [--line-chars 200]
    [--stale-days 2] [--format text|json]

Common flags:
  --record   absolute Record root (the directory holding backlog.md).
  --now      RFC3339 UTC instant with a Z suffix, e.g. 2026-09-07T03:00:00Z.
             Optional fractional seconds are accepted and truncated.
             Anything else exits 2 with a one-line stderr message.
  --format   text (default) or json.
             json is the stable machine form, always emitted through
             json.dumps(sort_keys=True, indent=2).

Exit codes:
  0  clean.
  1  findings or unknowns; lint and stow-gate return it for rule results,
     views and measure return it when an input changed while they ran.
  2  invalid input, unreadable required input, or execution failure.

Generic scanning skips .git, .record-state, wiki/views, graphify-out, raw, and
transcripts, and reads every file as UTF-8 with errors=replace.
No subcommand prints a transcript body or a matched secret value.

lint
  JSON: {"type":"maintain-lint","now":T,"record_commit":"<sha|null>",
  "rule_fingerprint":"<hex>","results":[{"rule","outcome","locator",
  "fingerprint","reason","owner"}],"summary":{"finding","unknown",
  "acknowledged","pass"}}.
  outcome is finding, unknown, acknowledged, or pass.
  locator is a Record-relative path with an optional :line suffix.
  fingerprint is sha256:<hex> over that result's evidence text.
  owner is backlog, stow, t11-fold, or captain.
  rule_fingerprint is the sha256 of the selected rule ids, versions, and
  thresholds in R1..R5 order, so a rule change or a --rules subset changes
  it and the order given to --rules does not.
  Text: one line per non-pass result "R2 finding <locator> <reason>", then
  "summary: finding=n unknown=n acknowledged=n pass=n".
  Exit 1 when any finding or unknown is present.

Rules, all report-only:
  R1 unbound deferral (owner backlog, backlog.md).
     Task rows match "^- \\[( |x|-)\\] (\\S+) - (.*)$" plus continuation lines
     indented two spaces.
     A whole-word case-insensitive pending, TBD, or later in the row body
     requires a "hold:" token with nonempty trigger text and an evaluator
     token, either "evaluator: <name>" or "(evaluator <name>)".
     Quotes are backtick or double-quote spans; an apostrophe never quotes.
     no hold          -> finding deferral-without-hold
     hold, no eval    -> finding hold-without-evaluator
     word only quoted -> unknown deferral-word-in-quote
     done rows ([x])  -> pass
  R2 old brief without outcome (owner stow, task dirs).
     A task dir is an immediate child of R holding brief.md.
     A real report is a report.md that exists as a regular file with size > 0.
     Dispatch time comes from <task>/launch.json "launched_at", else
     .record-state/<task>.meta "launched_at=", else the first commit that
     added <task>/brief.md, found with one batched git log over the Record.
     An mtime is never an age source.
     no report, age > 14d      -> finding brief-without-report
     no report, age unknown    -> unknown age-unknown
     (a launched_at that is not a string or number, a boolean included,
     is an unknown age)
     no report, age <= 14d     -> pass
     report present            -> pass
     The historical acknowledgement sidecar is <task>/status whose first line
     is exactly "dispatched, never reported" and which carries a line
     "brief-sha256: <hex>" equal to the sha256 of the current brief.md bytes.
     bound sidecar             -> acknowledged sidecar-acknowledged
     sidecar without the hash  -> finding sidecar-unbound
     hash no longer matches    -> finding sidecar-brief-changed
  R3 twin without usable review pointer (owner t11-fold, twin dirs).
     A twin is a dir ending -nm, -verify, or -fable whose base dir exists.
     It needs POINTER.md whose first non-empty line holds exactly one path,
     as a [text](path) link or a bare path, resolving through normpath from
     the twin dir to an existing regular file inside R.
     A bare path carries a "/", or is a dotted file name that exists in
     the directory holding the pointer; URLs, abbreviations such as
     "e.g.", and version strings such as "v1.10" are prose, not paths.
     missing, escaping, or symlinked outside R -> finding pointer-broken
     pointer chain that returns to itself      -> finding pointer-cycle
     more than one path on the first line      -> finding pointer-ambiguous
     no POINTER.md, only the base has report.md -> finding pointer-missing
     no POINTER.md, both or neither have one    -> unknown review-owner-unclear
  R4 handwritten directory table (owner t11-fold, *.md under R).
     Generated files are exempt: anything under wiki/views/ and any file whose
     first three lines contain "<!-- generated by fm-maintain.py".
     A table needs at least three lines including header and separator.
     >= 3 first-column entries resolve and all data rows resolve
                                  -> finding handwritten-directory-table
     decision-ledger.md at the root
                                  -> finding handwritten-directory-table
     some rows resolve, some not  -> unknown mixed-table
     no row resolves              -> pass
     A first-column entry resolves when it names an existing decisions/<x>.md
     or an existing task dir (a child dir holding brief.md), by link target
     or bare id. Any other existing file or dir, for example backlog.md or
     t2/report.md in a data-model table, does not resolve.
  R5 unqualified memory fact (owner captain, captain.md and learnings.md).
     Fact bullets are top-level "- " lines outside fenced blocks.
     A fact is qualified by a YYYY-MM-DD date anywhere in the line, by a
     resolvable pointer (a backticked Record-relative path or a [..](path)
     that exists in R, or an https:// URL), or by a timeless marker
     ([timeless], (timeless), or "tier: timeless").
     qualified   -> pass
     otherwise   -> unknown unclassified-fact, never a finding

rollout
  The live record is <R>/.git/maintain-rollout.json, local and untracked.
  The sanitized durable copy is <R>/wiki/views/maintain-rollout.json; it omits
  filesystem paths.
  Both are JSON objects with mode, clean_dates, rule_fingerprint,
  transition_evidence, last_result, last_cloud_result, created, and updated.
  Modes are report and enforce; a missing pair reads as not-configured.
  init      creates both in report mode, and exits 2 if either record
            already exists.
  advance   reads a lint JSON and applies one scheduled day; a payload with
            no rule_fingerprint, or a local one missing any of R1-R5, exits 2:
            coverage cloud            -> last_cloud_result only, no streak move
            finding or unknown        -> clean_dates reset to []
            changed rule_fingerprint  -> clean_dates reset, new fingerprint
                                         adopted, then a clean day counts as
                                         day one
            scheduled date already in clean_dates -> no change
            date not the day after the last clean date -> reset, then append
            clean day in sequence     -> append
            7 consecutive dates       -> mode latches to enforce and records
                                         transition_evidence {date,
                                         fingerprint, dates}
            enforce never reverts to report.
            A local record missing while the durable copy exists exits 2 with
            rollout-record-missing-after-activation, and so does init.
            A record that is not a JSON object with mode report or enforce
            exits 2 with rollout-record-unreadable.
            Neither present prints mode=not-configured and exits 0 unwritten.
  status    prints mode, clean_dates, rule_fingerprint, transition_evidence,
            and last_result.

stow-gate
  Runs lint fresh, reads the rollout state, prints "mode=<mode>" and the lint
  text.
  Exit 0 in report and not-configured whatever lint found, 1 in enforce when
  lint exited 1, and 2 on a lint or rollout error.

fold
  Consumes the T11 cleanup receipt; it never folds anything itself.
  Finds cleanup-YYYY-MM-DD.md at the Record root and reports the latest date.
  Counts bound R2 sidecars, POINTER.md files, exact duplicate fact lines
  (identical after whitespace normalisation) across captain.md, learnings.md,
  and memory-archive.md, and "duplicate of" marks in memory-archive.md.
  A mark resolves only when its target equals a whole top-level bullet in
  captain.md or learnings.md after whitespace normalisation.
  A duplicate fact and a resolvable mark become proposals carrying every
  locator plus the canonical one (the first copy in captain.md, learnings.md,
  memory-archive.md order, or the matched bullet); an unresolvable mark
  becomes a question. Nothing is deleted.
  JSON: {"type":"maintain-fold","receipt":{"present","date","path"},"counts",
  "proposals":[...],"questions":[...]}.
  Exit 0 unless the input is invalid.

views
  Builds every generated view into a staging dir outside R (mkdtemp by
  default), then with --apply replaces each file under R/wiki/views/ through a
  temp file in the target directory and os.replace.
  Nothing outside wiki/views/ is ever written; a symlink anywhere on a view's
  path makes the run exit 2 before any file lands.
  The staging dir is always reported as stage_dir so a caller can scan it.
  A --stage-dir you name stays yours; an unnamed one belongs to this run and is
  reclaimed once --apply has landed every file.
  Each Markdown view opens with
  "<!-- generated by fm-maintain.py <sub>; source: <sources>; generated: T;
  do not hand-edit -->" and each JSON view carries "generated_by".
  A view whose content matches the landed file once every generated timestamp
  is stripped counts as unchanged and is left alone, so a nightly makes no
  commit churn.
  Before building, the sha256 of every input the views read (backlog.md,
  done-archive.md, captain.md, learnings.md, memory-archive.md,
  vr-reports/INDEX.md, decisions/*.md, each child dir's brief.md, report.md,
  status, launch.json, and recall.json, .record-state/*.meta, and the child
  dir listing) is recorded as the input manifest; it is re-read immediately
  before landing, and on any difference every staged view is discarded,
  nothing is written, changed_input lists the differing paths, and the exit
  is 1. measure applies the same manifest rule.
  Views: decisions.md, completed-tasks.md, brief-only.md, duplicates.md,
  memory-lint.md, video-index.md.
  JSON: {"type":"maintain-views","written":[...],"unchanged":[...],
  "changed_input":[...],"stage_dir":"<path>"}.

measure
  Writes wiki/views/recall-compounding.json and recall-compounding.md under
  the same staging and apply rule.
  Weeks are ISO UTC weeks with an exclusive upper bound; current_week is
  partial and previous_week is complete.
  reuse        counts a task once when brief.md cites an emitted path from
               <task>/recall.json that is absent from preexisting_cited_paths,
               ignoring the "# Recalled pointers" section.
  coverage     splits tasks into observed and unobserved, where unobserved
               means brief.md has no git history in R or R has no .git, each
               with an evidence path. It is reported once, not per week,
               because an unobserved task has no week.
  rediscovery  reads answer_classification from the recall receipt: answered
               needs answer_location and answer_date, not_answered is taken as
               written, and anything else is unknown. A week in which no
               receipt carries the field is not measured. Lexical overlap is
               never an inference source.
  succession   counts an older decision once when an explicit Supersedes or
               Superseded by link resolves at both ends to existing decision
               files; self links and cycles are rejected. The week is the
               newer decision's date.
  injected     sums digest_bytes, bytes, and estimated_tokens from
               <state>/.session-recall-receipt.*.json, placing each file by
               its timestamp_utc or date field. A file mtime is never a week
               source. The estimator label is always ceil(UTF-8 bytes / 3).
  Any counter with no evidence source is the string "not measured", never 0.

receipt
  --stages is a TSV of name<TAB>outcome<TAB>elapsed_seconds<TAB>detail with
  outcome in ok, finding, skipped, failed, not-configured, timeout, or
  interrupted.
  Writes wiki/views/maintenance/<YYYY-MM-DD>-<host>.md with the stage table,
  lint mode, coverage, problem list, input commit, tool fingerprint, and
  per-stage completion, plus the note that the checkpoint and verify
  stages run after this receipt and are recorded locally in
  .git/nightly/last-attempt, then merges its own host key into
  wiki/views/nightly-digest.json:
  {"type":"nightly-digest","hosts":{"<host>":{"date","generated",
  "input_commit","lines":[{"key","observation","consequence","next"}],
  "omitted","complete"}}}.
  Other hosts' entries are preserved; an unreadable digest exits 2 rather than
  overwriting them.
  Keys are stable across repeats: a rule finding collapses into one
  "<rule>:<reason>" line with a count, and every problem stage adds one
  "<stage>:<detail-or-outcome>" line.
  complete is false when any stage failed, timed out, or was interrupted.

digest
  Reads wiki/views/nightly-digest.json and, when present, the local
  .git/nightly/last-attempt written by bin/fm-nightly.sh, with no git and
  no network.
  last-attempt  -> first line "Nightly maintenance: last local run <date>
                   result=<result>; verify <state and equality tokens>"
  missing file  -> "Nightly maintenance: no receipt published yet."
  corrupt JSON  -> "Nightly maintenance: receipt unreadable; run
                   bin/fm-nightly.sh status."
  stale host    -> "Nightly maintenance (<host>): last receipt <date>
                   (stale)." judged per host, and no clean line for it
  incomplete    -> "Nightly <date> (<host>): run incomplete; ..."
  clean         -> "Nightly <date> (<host>): clean."
  otherwise     -> one line per issue, "Nightly <date> (<host>):
                   <observation>; <consequence>; <next>", cut at --line-chars
  over budget   -> last line "Nightly maintenance: <k> more issue(s) omitted;
                   see wiki/views/maintenance/<date>-<host>.md", where k
                   also counts lines the receipt writer already capped and
                   host is the host with the most capped or dropped lines
  Every emitted line, the per-host stale, incomplete, and clean lines
  included, is charged against --max-lines; only the omitted footer is
  free, so at most --max-lines + 1 lines are printed.
  Every line, host name and date included, is sanitized and cut.
  Exit 0 unless the arguments are invalid.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import date as date_type
from datetime import datetime, timedelta, timezone

AGE_LIMIT_DAYS = 14
AGE_LIMIT_SECONDS = AGE_LIMIT_DAYS * 86400
STREAK_DAYS = 7
TABLE_MIN_ROWS = 3
TITLE_CUT = 90
FACT_CUT = 120
RECEIPT_LINE_CAP = 50
VIEWS_DIR = "wiki/views"
SIDECAR_FIRST_LINE = "dispatched, never reported"
TOKEN_ESTIMATOR = "ceil(UTF-8 bytes / 3)"
TWIN_SUFFIXES = ("-nm", "-verify", "-fable")
SKIP_DIR_NAMES = frozenset(
    (".git", ".record-state", "graphify-out", "raw", "transcripts")
)
MEMORY_FILES = ("captain.md", "learnings.md")
FOLD_FILES = ("captain.md", "learnings.md", "memory-archive.md")
STAGE_OUTCOMES = frozenset(
    ("ok", "finding", "skipped", "failed", "not-configured", "timeout", "interrupted")
)
PROBLEM_OUTCOMES = ("finding", "failed", "timeout", "interrupted")
INCOMPLETE_OUTCOMES = ("failed", "timeout", "interrupted")

NOW_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?Z$")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
FENCE_RE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
ROW_RE = re.compile(r"^- \[( |x|-)\] (\S+) - (.*)$")
DEFERRAL_RE = re.compile(r"(?i)\b(pending|tbd|later)\b")
QUOTED_RE = re.compile(r"`[^`]*`|\"[^\"]*\"")
HOLD_RE = re.compile(r"hold:\s*([^)\n]*)")
EVALUATOR_RE = re.compile(r"evaluator:\s*(\S+)|\(evaluator\s+([^)]+)\)")
BULLET_RE = re.compile(r"^(\s*)- +(\S.*)$")
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
BACKTICK_RE = re.compile(r"`([^`]+)`")
BARE_PATH_RE = re.compile(r"[A-Za-z0-9._~/+-]+")
URL_RE = re.compile(r"https?://\S+")
FILE_NAME_RE = re.compile(r".+\.[A-Za-z0-9]{2,}")
TIMELESS_RE = re.compile(r"(?i)\[timeless\]|\(timeless\)|tier:\s*timeless")
BRIEF_SHA_RE = re.compile(r"(?m)^brief-sha256:\s*([0-9a-fA-F]+)\s*$")
LAUNCHED_AT_RE = re.compile(r"(?m)^launched_at=(.+)$")
ADDED_COMMIT_RE = re.compile(r"^([0-9a-f]{7,40}) (\d+)$")
HEADING_RE = re.compile(r"^#{1,6}\s")
ARCHIVED_RE = re.compile(r"^## Archived (\d{4}-\d{2}-\d{2})\s*$")
ARCHIVE_ROW_RE = re.compile(r"^- \[x\] (\S+) - (.*)$")
DECISION_STATUS_RE = re.compile(r"(?im)^\s*status\s*:\s*(\S.*?)\s*$")
DECISION_DATE_RE = re.compile(r"(?im)^\s*date\s*:\s*(\d{4}-\d{2}-\d{2})\s*$")
SUPERSEDES_RE = re.compile(r"(?im)^\s*supersedes\s*:\s*(\S.*?)\s*$")
SUPERSEDED_BY_RE = re.compile(r"(?im)^\s*superseded by\s*:\s*(\S.*?)\s*$")
CLEANUP_RE = re.compile(r"^cleanup-(\d{4}-\d{2}-\d{2})\.md$")
DUPLICATE_OF_RE = re.compile(r"(?i)duplicate of\s+(\S.*?)\s*$")
RECALLED_SECTION_RE = re.compile(r"(?im)^#+\s*Recalled pointers\s*$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
SLUG_RE = re.compile(r"[^a-z0-9]+")
GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0")


class InputError(Exception):
    """An operator input the program refuses, reported as exit 2."""


@dataclass(frozen=True)
class Result:
    rule: str
    outcome: str
    locator: str
    fingerprint: str
    reason: str
    owner: str

    def as_dict(self):
        return {
            "rule": self.rule,
            "outcome": self.outcome,
            "locator": self.locator,
            "fingerprint": self.fingerprint,
            "reason": self.reason,
            "owner": self.owner,
        }


@dataclass(frozen=True)
class Rule:
    id: str
    version: str
    owner: str
    thresholds: dict
    check: object

    def result(self, outcome, locator, reason, evidence):
        return Result(
            rule=self.id,
            outcome=outcome,
            locator=locator,
            fingerprint="sha256:" + sha256_hex(evidence.encode("utf-8")),
            reason=reason,
            owner=self.owner,
        )


@dataclass(frozen=True)
class Week:
    start: datetime

    @staticmethod
    def containing(moment):
        midnight = moment.astimezone(timezone.utc).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        return Week(midnight - timedelta(days=midnight.weekday()))

    @property
    def end(self):
        return self.start + timedelta(days=7)

    @property
    def label(self):
        return self.start.strftime("%G-W%V")

    def contains(self, moment):
        return self.start <= moment < self.end

    def previous(self):
        return Week(self.start - timedelta(days=7))

    def bounds(self):
        return {
            "label": self.label,
            "start": rfc3339(self.start),
            "end_exclusive": rfc3339(self.end),
        }


@dataclass
class Rollout:
    mode: str = "report"
    clean_dates: list = field(default_factory=list)
    rule_fingerprint: str = ""
    transition_evidence: object = None
    last_result: object = None
    last_cloud_result: object = None
    created: str = ""
    updated: str = ""

    def observe_local(self, day, fingerprint, clean):
        """Apply one scheduled local run and name the transition it caused."""
        changed = bool(self.rule_fingerprint) and self.rule_fingerprint != fingerprint
        self.rule_fingerprint = fingerprint
        if changed:
            self.clean_dates = []
        if not clean:
            self.clean_dates = []
            return "fingerprint-reset" if changed else "finding-reset"
        if day in self.clean_dates:
            return "duplicate-date"
        gap = bool(self.clean_dates) and not is_next_day(self.clean_dates[-1], day)
        if gap:
            self.clean_dates = []
        self.clean_dates.append(day)
        if len(self.clean_dates) >= STREAK_DAYS and self.mode == "report":
            self.mode = "enforce"
            self.transition_evidence = {
                "date": day,
                "fingerprint": fingerprint,
                "dates": list(self.clean_dates),
            }
            return "latched-enforce"
        if changed:
            return "fingerprint-reset"
        if gap:
            return "gap-reset"
        return "advanced"

    def as_dict(self, sanitized):
        payload = {
            "type": "maintain-rollout",
            "mode": self.mode,
            "clean_dates": list(self.clean_dates),
            "rule_fingerprint": self.rule_fingerprint or None,
            "transition_evidence": self.transition_evidence,
            "last_result": self.last_result,
            "last_cloud_result": self.last_cloud_result,
            "created": self.created,
            "updated": self.updated,
        }
        if sanitized:
            payload["last_result"] = sanitize_result(self.last_result)
            payload["last_cloud_result"] = sanitize_result(self.last_cloud_result)
        return payload

    @staticmethod
    def from_dict(payload):
        rollout = Rollout()
        if not isinstance(payload, dict):
            raise InputError("rollout record is not a JSON object")
        rollout.mode = payload.get("mode")
        if rollout.mode not in ("report", "enforce"):
            raise InputError("rollout record mode must be report or enforce")
        dates = payload.get("clean_dates")
        rollout.clean_dates = [d for d in dates if isinstance(d, str)] if dates else []
        rollout.rule_fingerprint = payload.get("rule_fingerprint") or ""
        rollout.transition_evidence = payload.get("transition_evidence")
        rollout.last_result = payload.get("last_result")
        rollout.last_cloud_result = payload.get("last_cloud_result")
        rollout.created = payload.get("created") or ""
        rollout.updated = payload.get("updated") or ""
        return rollout


class Record:
    """The read model of one Record root: paths, git history, and task dirs."""

    def __init__(self, root, now):
        self.root = root
        self.real_root = os.path.realpath(root)
        self.now = now
        self.now_ts = int(now.timestamp())
        self._added = None
        self._commit = None
        self._commit_read = False
        self._has_git = None

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def rel(self, target):
        return os.path.relpath(target, self.root).replace(os.sep, "/")

    def git(self, *args):
        try:
            proc = subprocess.run(
                ("git", "-C", self.root) + args,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=GIT_ENV,
            )
        except OSError:
            return None
        if proc.returncode != 0:
            return None
        return proc.stdout.decode("utf-8", errors="replace")

    def has_git(self):
        if self._has_git is None:
            self._has_git = self.git("rev-parse", "--git-dir") is not None
        return self._has_git

    def commit(self):
        if not self._commit_read:
            self._commit_read = True
            out = self.git("rev-parse", "HEAD")
            self._commit = out.strip() if out else None
        return self._commit

    def added_epoch(self, rel):
        """Return the commit time that first added a Record-relative path."""
        if self._added is None:
            self._added = self._load_added()
        return self._added.get(rel)

    def _load_added(self):
        added = {}
        out = self.git(
            "-c",
            "core.quotepath=false",
            "log",
            "--diff-filter=A",
            "--no-renames",
            "--format=%H %ct",
            "--name-only",
        )
        if out is None:
            return added
        stamp = None
        for line in out.splitlines():
            match = ADDED_COMMIT_RE.match(line)
            if match:
                stamp = int(match.group(2))
                continue
            if not line.strip() or stamp is None:
                continue
            added[line.strip()] = stamp
        return added

    def child_dirs(self):
        try:
            names = sorted(os.listdir(self.root))
        except OSError:
            return []
        keep = []
        for name in names:
            if name in SKIP_DIR_NAMES or not os.path.isdir(self.path(name)):
                continue
            keep.append(name)
        return keep

    def task_dirs(self):
        return [
            name
            for name in self.child_dirs()
            if os.path.isfile(self.path(name, "brief.md"))
        ]

    def md_files(self):
        found = []
        views_root = os.path.normpath(self.path(VIEWS_DIR))
        for base, dirs, files in os.walk(self.root):
            dirs[:] = sorted(
                d
                for d in dirs
                if d not in SKIP_DIR_NAMES
                and os.path.normpath(os.path.join(base, d)) != views_root
            )
            for name in sorted(files):
                if name.endswith(".md"):
                    found.append(self.rel(os.path.join(base, name)))
        return found

    def decision_files(self):
        return sorted(
            self.rel(p) for p in glob.glob(self.path("decisions", "*.md"))
        )

    def inside(self, candidate):
        """True when a path stays inside the Record, lexically and after links."""
        for target in (os.path.normpath(candidate), os.path.realpath(candidate)):
            if target == self.real_root:
                continue
            if not target.startswith(self.real_root + os.sep):
                return False
        return True


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def read_bytes(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        return None


def read_text(path):
    data = read_bytes(path)
    if data is None:
        if os.path.lexists(path):
            raise InputError("cannot read %s" % path)
        return ""
    return data.decode("utf-8", errors="replace")


def read_json(path):
    data = read_bytes(path)
    if data is None:
        raise InputError("cannot read %s" % path)
    try:
        return json.loads(data.decode("utf-8", errors="replace"))
    except ValueError:
        raise InputError("cannot parse JSON in %s" % path)


def emit_json(payload):
    sys.stdout.write(json.dumps(payload, sort_keys=True, indent=2) + "\n")


def host_slug(text):
    # The host key becomes a file name under wiki/views/maintenance/.
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", text or ""):
        raise argparse.ArgumentTypeError("host must be a short hostname slug or cloud")
    return text


def rfc3339(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_now(text):
    match = NOW_RE.match(text or "")
    if not match:
        return None
    try:
        parsed = datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return parsed.replace(tzinfo=timezone.utc)


def parse_day(text):
    if not DAY_RE.match(text or ""):
        return None
    try:
        return date_type.fromisoformat(text)
    except ValueError:
        return None


def parse_moment(value):
    """Read an RFC3339 instant, a bare day, or an epoch number as UTC."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return epoch_moment(value)
    if not isinstance(value, str):
        return None
    text = value.strip()
    moment = parse_now(text)
    if moment:
        return moment
    day = parse_day(text)
    if day:
        return datetime(day.year, day.month, day.day, tzinfo=timezone.utc)
    try:
        return epoch_moment(int(text))
    except ValueError:
        return None


def epoch_moment(value):
    try:
        return datetime.fromtimestamp(value, timezone.utc)
    except (OverflowError, ValueError, OSError):
        return None


def is_next_day(previous, day):
    first = parse_day(previous)
    second = parse_day(day)
    if not first or not second:
        return False
    return second - first == timedelta(days=1)


def sanitize_line(text, limit):
    collapsed = " ".join(CONTROL_RE.sub(" ", text or "").split())
    if limit > 0 and len(collapsed) > limit:
        return collapsed[:limit]
    return collapsed


def slug(text, limit=40):
    cleaned = SLUG_RE.sub("-", (text or "").lower()).strip("-")
    return cleaned[:limit]


def sanitize_result(payload):
    if not isinstance(payload, dict):
        return payload
    return {k: v for k, v in payload.items() if k not in ("lint_path", "record")}


def iter_lines_outside_fences(text):
    fence = None
    for index, line in enumerate(text.splitlines(), 1):
        match = FENCE_RE.match(line)
        if match:
            token = match.group(1)[0]
            if fence is None:
                fence = token
                continue
            if token == fence:
                fence = None
                continue
        if fence is None:
            yield index, line


def iter_task_rows(text):
    """Yield (line, state, id, body) rows with their two-space continuations."""
    row = None
    for index, line in iter_lines_outside_fences(text):
        match = ROW_RE.match(line)
        if match:
            if row:
                yield row
            row = [index, match.group(1), match.group(2), match.group(3)]
            continue
        if row and line.startswith("  ") and line.strip():
            row[3] = row[3] + " " + line.strip()
            continue
        if row:
            yield row
            row = None
    if row:
        yield row


def iter_bullets(text):
    """Yield (line, indent, content) for list bullets outside fenced blocks."""
    for index, line in iter_lines_outside_fences(text):
        match = BULLET_RE.match(line)
        if match and not HEADING_RE.match(match.group(2)):
            yield index, len(match.group(1)), match.group(2)


def split_row(line):
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|"):
        body = body[:-1]
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", body)]


def is_separator_row(line):
    body = line.strip()
    return bool(body) and "-" in body and not re.search(r"[^|\-: \t]", body)


def iter_pipe_tables(text):
    """Yield (line, header cells, data rows) for Markdown pipe tables."""
    lines = list(iter_lines_outside_fences(text))
    index = 0
    while index < len(lines) - 1:
        number, line = lines[index]
        following = lines[index + 1]
        if "|" not in line or following[0] != number + 1 or not is_separator_row(
            following[1]
        ):
            index += 1
            continue
        rows = []
        cursor = index + 2
        expected = number + 2
        while cursor < len(lines) and lines[cursor][0] == expected:
            if "|" not in lines[cursor][1]:
                break
            rows.append((lines[cursor][0], split_row(lines[cursor][1])))
            cursor += 1
            expected += 1
        yield number, split_row(line), rows
        index = max(cursor, index + 1)


def quoted_spans(text):
    return [match.span() for match in QUOTED_RE.finditer(text)]


def is_quoted(span, spans):
    return any(start <= span[0] and span[1] <= end for start, end in spans)


def looks_like_path(token, base_dir=None):
    cleaned = token.strip().rstrip(".,;:)")
    if not cleaned or cleaned.startswith("http"):
        return ""
    if "/" not in cleaned:
        if not FILE_NAME_RE.fullmatch(cleaned):
            return ""
        if base_dir is not None and not os.path.exists(os.path.join(base_dir, cleaned)):
            return ""
    if not re.search(r"[A-Za-z]", cleaned):
        return ""
    return cleaned


def first_line_paths(text, base_dir=None):
    """Return the distinct path tokens on a pointer's first non-empty line."""
    line = ""
    for _, candidate in iter_lines_outside_fences(text):
        if candidate.strip():
            line = candidate.strip()
            break
    if not line:
        return []
    paths = [match.group(1) for match in LINK_RE.finditer(line)]
    rest = URL_RE.sub(" ", LINK_RE.sub(" ", line))
    candidates = [match.group(1) for match in BACKTICK_RE.finditer(rest)]
    rest = BACKTICK_RE.sub(" ", rest)
    candidates.extend(match.group(0) for match in BARE_PATH_RE.finditer(rest))
    for candidate in candidates:
        cleaned = looks_like_path(candidate, base_dir)
        if cleaned:
            paths.append(cleaned)
    ordered = []
    for path in paths:
        if path not in ordered:
            ordered.append(path)
    return ordered


def hold_trigger(body):
    match = HOLD_RE.search(body)
    if not match:
        return ""
    trigger = re.sub(r"evaluator:\s*\S+", "", match.group(1)).strip()
    return trigger


def has_evaluator(body):
    return bool(EVALUATOR_RE.search(body))


def rule_unbound_deferral(record, rule):
    results = []
    text = read_text(record.path("backlog.md"))
    for line, state, task_id, body in iter_task_rows(text):
        locator = "backlog.md:%d" % line
        evidence = "%s\n%s" % (task_id, body)
        if state == "x":
            results.append(rule.result("pass", locator, "done-row", evidence))
            continue
        hits = list(DEFERRAL_RE.finditer(body))
        if not hits:
            results.append(rule.result("pass", locator, "no-deferral", evidence))
            continue
        spans = quoted_spans(body)
        if all(is_quoted(hit.span(), spans) for hit in hits):
            results.append(
                rule.result("unknown", locator, "deferral-word-in-quote", evidence)
            )
            continue
        if not hold_trigger(body):
            results.append(
                rule.result("finding", locator, "deferral-without-hold", evidence)
            )
            continue
        if not has_evaluator(body):
            results.append(
                rule.result("finding", locator, "hold-without-evaluator", evidence)
            )
            continue
        results.append(rule.result("pass", locator, "hold-bound", evidence))
    return results


def has_real_report(record, task):
    report = record.path(task, "report.md")
    try:
        return os.path.isfile(report) and os.path.getsize(report) > 0
    except OSError:
        return False


def dispatch_epoch(record, task):
    """Durable dispatch time for a task, never derived from an mtime."""
    launch = read_bytes(record.path(task, "launch.json"))
    if launch is not None:
        try:
            payload = json.loads(launch.decode("utf-8", errors="replace"))
        except ValueError:
            payload = None
        if isinstance(payload, dict):
            moment = parse_moment(payload.get("launched_at"))
            if moment:
                return int(moment.timestamp())
    meta = read_text(record.path(".record-state", "%s.meta" % task))
    match = LAUNCHED_AT_RE.search(meta)
    if match:
        moment = parse_moment(match.group(1))
        if moment:
            return int(moment.timestamp())
    return record.added_epoch("%s/brief.md" % task)


def sidecar_state(record, task, brief_bytes):
    """Classify <task>/status against the R2 acknowledgement binding."""
    text = read_bytes(record.path(task, "status"))
    if text is None:
        return None
    decoded = text.decode("utf-8", errors="replace")
    first = decoded.splitlines()[0] if decoded.splitlines() else ""
    if first.strip() != SIDECAR_FIRST_LINE:
        return None
    match = BRIEF_SHA_RE.search(decoded)
    if not match:
        return ("finding", "sidecar-unbound")
    if brief_bytes is None:
        return ("finding", "sidecar-brief-changed")
    if match.group(1).lower() != sha256_hex(brief_bytes):
        return ("finding", "sidecar-brief-changed")
    return ("acknowledged", "sidecar-acknowledged")


def rule_old_brief(record, rule):
    results = []
    for task in record.task_dirs():
        brief_rel = "%s/brief.md" % task
        brief_bytes = read_bytes(record.path(task, "brief.md"))
        digest = sha256_hex(brief_bytes or b"")
        if has_real_report(record, task):
            results.append(
                rule.result("pass", brief_rel, "report-present", digest)
            )
            continue
        sidecar = sidecar_state(record, task, brief_bytes)
        if sidecar:
            outcome, reason = sidecar
            results.append(
                rule.result(outcome, "%s/status" % task, reason, digest + reason)
            )
            continue
        dispatched = dispatch_epoch(record, task)
        if dispatched is None:
            results.append(rule.result("unknown", brief_rel, "age-unknown", digest))
            continue
        if record.now_ts - dispatched > AGE_LIMIT_SECONDS:
            results.append(
                rule.result("finding", brief_rel, "brief-without-report", digest)
            )
            continue
        results.append(rule.result("pass", brief_rel, "within-age", digest))
    return results


def follow_pointer(record, pointer_path, token):
    """Walk a pointer chain; return a reason code or None when it resolves."""
    seen = {os.path.realpath(pointer_path)}
    current = os.path.dirname(pointer_path)
    while True:
        candidate = os.path.normpath(os.path.join(current, token))
        if not record.inside(candidate) or not os.path.isfile(candidate):
            return "pointer-broken"
        if os.path.basename(candidate) != "POINTER.md":
            return None
        real = os.path.realpath(candidate)
        if real in seen:
            return "pointer-cycle"
        seen.add(real)
        onward = first_line_paths(read_text(candidate), os.path.dirname(candidate))
        if len(onward) > 1:
            return "pointer-ambiguous"
        if not onward:
            return "pointer-broken"
        current = os.path.dirname(candidate)
        token = onward[0]


def rule_twin_pointer(record, rule):
    results = []
    for name in record.child_dirs():
        base = ""
        for suffix in TWIN_SUFFIXES:
            if name.endswith(suffix):
                base = name[: -len(suffix)]
                break
        if not base or not os.path.isdir(record.path(base)):
            continue
        pointer = record.path(name, "POINTER.md")
        pointer_rel = "%s/POINTER.md" % name
        if not os.path.isfile(pointer):
            base_report = os.path.isfile(record.path(base, "report.md"))
            twin_report = os.path.isfile(record.path(name, "report.md"))
            if base_report and not twin_report:
                results.append(
                    rule.result("finding", pointer_rel, "pointer-missing", name)
                )
            elif twin_report and not base_report:
                results.append(
                    rule.result("pass", pointer_rel, "twin-owns-report", name)
                )
            else:
                results.append(
                    rule.result("unknown", pointer_rel, "review-owner-unclear", name)
                )
            continue
        evidence = read_text(pointer)
        paths = first_line_paths(evidence, record.path(name))
        if len(paths) > 1:
            results.append(
                rule.result("finding", pointer_rel, "pointer-ambiguous", evidence)
            )
            continue
        if not paths:
            results.append(
                rule.result("finding", pointer_rel, "pointer-broken", evidence)
            )
            continue
        reason = follow_pointer(record, pointer, paths[0])
        if reason:
            results.append(rule.result("finding", pointer_rel, reason, evidence))
            continue
        results.append(rule.result("pass", pointer_rel, "pointer-resolves", evidence))
    return results


def resolves_to_record_entry(record, md_rel, cell):
    """True when a table's first-column cell names a decision or a task dir."""
    tokens = [match.group(1) for match in LINK_RE.finditer(cell)]
    rest = LINK_RE.sub(" ", cell)
    tokens.extend(match.group(1) for match in BACKTICK_RE.finditer(rest))
    rest = BACKTICK_RE.sub(" ", rest)
    tokens.extend(match.group(0) for match in BARE_PATH_RE.finditer(rest))
    parent = os.path.dirname(record.path(md_rel))
    decisions_dir = os.path.realpath(record.path("decisions"))
    for token in tokens:
        cleaned = token.strip().strip("`").rstrip(".,;:)")
        if not cleaned:
            continue
        candidates = [os.path.normpath(os.path.join(parent, cleaned))]
        stem = cleaned[:-3] if cleaned.endswith(".md") else cleaned
        candidates.append(record.path("decisions", "%s.md" % stem))
        candidates.append(record.path(stem))
        for candidate in candidates:
            if not record.inside(candidate):
                continue
            real = os.path.realpath(candidate)
            if real == record.real_root:
                continue
            if (
                os.path.isfile(candidate)
                and real.endswith(".md")
                and os.path.dirname(real) == decisions_dir
            ):
                return True
            if os.path.isdir(candidate) and os.path.isfile(
                os.path.join(candidate, "brief.md")
            ):
                return True
    return False


def is_generated(text):
    head = text.splitlines()[:3]
    return any("<!-- generated by fm-maintain.py" in line for line in head)


def rule_handwritten_table(record, rule):
    results = []
    for md_rel in record.md_files():
        text = read_text(record.path(md_rel))
        if is_generated(text):
            continue
        if md_rel == "decision-ledger.md":
            results.append(
                rule.result(
                    "finding",
                    "%s:1" % md_rel,
                    "handwritten-directory-table",
                    md_rel,
                )
            )
            continue
        for line, header, rows in iter_pipe_tables(text):
            if len(rows) + 2 < TABLE_MIN_ROWS or not rows:
                continue
            resolved = sum(
                1
                for _, cells in rows
                if cells and resolves_to_record_entry(record, md_rel, cells[0])
            )
            locator = "%s:%d" % (md_rel, line)
            evidence = "%s\n%s" % (md_rel, " | ".join(header))
            if resolved >= TABLE_MIN_ROWS and resolved == len(rows):
                results.append(
                    rule.result(
                        "finding", locator, "handwritten-directory-table", evidence
                    )
                )
            elif 0 < resolved < len(rows):
                results.append(rule.result("unknown", locator, "mixed-table", evidence))
            else:
                results.append(rule.result("pass", locator, "no-directory", evidence))
    return results


def fact_is_qualified(record, line):
    if DATE_RE.search(line) or TIMELESS_RE.search(line) or URL_RE.search(line):
        return True
    tokens = [match.group(1) for match in LINK_RE.finditer(line)]
    tokens.extend(match.group(1) for match in BACKTICK_RE.finditer(line))
    for token in tokens:
        cleaned = looks_like_path(token)
        if not cleaned:
            continue
        candidate = os.path.normpath(record.path(cleaned))
        if record.inside(candidate) and os.path.exists(candidate):
            return True
    return False


def rule_memory_fact(record, rule):
    results = []
    for name in MEMORY_FILES:
        text = read_text(record.path(name))
        for line, indent, content in iter_bullets(text):
            if indent:
                continue
            locator = "%s:%d" % (name, line)
            if fact_is_qualified(record, content):
                results.append(rule.result("pass", locator, "qualified-fact", content))
            else:
                results.append(
                    rule.result("unknown", locator, "unclassified-fact", content)
                )
    return results


RULES = (
    Rule("R1", "1", "backlog", {}, rule_unbound_deferral),
    Rule("R2", "1", "stow", {"age_days": AGE_LIMIT_DAYS}, rule_old_brief),
    Rule("R3", "1", "t11-fold", {"suffixes": list(TWIN_SUFFIXES)}, rule_twin_pointer),
    Rule("R4", "1", "t11-fold", {"min_rows": TABLE_MIN_ROWS}, rule_handwritten_table),
    Rule("R5", "1", "captain", {}, rule_memory_fact),
)
RULES_BY_ID = {rule.id: rule for rule in RULES}


def select_rules(spec):
    if not spec:
        return list(RULES)
    chosen = []
    for token in spec.split(","):
        rule_id = token.strip()
        if not rule_id:
            continue
        if rule_id not in RULES_BY_ID:
            raise InputError("unknown rule id: %s" % rule_id)
        rule = RULES_BY_ID[rule_id]
        if rule not in chosen:
            chosen.append(rule)
    if not chosen:
        raise InputError("--rules selected no rule")
    return chosen


def rule_fingerprint(rules):
    payload = [
        {"id": rule.id, "version": rule.version, "thresholds": rule.thresholds}
        for rule in RULES
        if rule in rules
    ]
    return sha256_hex(json.dumps(payload, sort_keys=True).encode("utf-8"))


def run_rules(record, rules):
    results = []
    for rule in rules:
        results.extend(rule.check(record, rule))
    return results


def summarize(results):
    summary = {"finding": 0, "unknown": 0, "acknowledged": 0, "pass": 0}
    for result in results:
        summary[result.outcome] = summary.get(result.outcome, 0) + 1
    return summary


def lint_payload(record, rules, now_text):
    results = run_rules(record, rules)
    summary = summarize(results)
    return {
        "type": "maintain-lint",
        "now": now_text,
        "record_commit": record.commit(),
        "rule_fingerprint": rule_fingerprint(rules),
        "rules": [rule.id for rule in rules],
        "results": [result.as_dict() for result in results],
        "summary": summary,
    }


def lint_text(payload):
    lines = []
    for result in payload["results"]:
        if result["outcome"] == "pass":
            continue
        lines.append(
            "%s %s %s %s"
            % (
                result["rule"],
                result["outcome"],
                result["locator"],
                result["reason"],
            )
        )
    summary = payload["summary"]
    lines.append(
        "summary: finding=%d unknown=%d acknowledged=%d pass=%d"
        % (
            summary["finding"],
            summary["unknown"],
            summary["acknowledged"],
            summary["pass"],
        )
    )
    return "\n".join(lines) + "\n"


def lint_exit(payload):
    summary = payload["summary"]
    return 1 if summary["finding"] or summary["unknown"] else 0


def command_lint(args, record):
    rules = select_rules(args.rules)
    payload = lint_payload(record, rules, args.now)
    if args.format == "json":
        emit_json(payload)
    else:
        sys.stdout.write(lint_text(payload))
    return lint_exit(payload)


def rollout_local_path(record):
    return record.path(".git", "maintain-rollout.json")


def rollout_durable_path(record):
    return record.path(VIEWS_DIR, "maintain-rollout.json")


def load_rollout(record):
    """Return (rollout|None, error|None) for the local and durable pair."""
    local = rollout_local_path(record)
    durable = rollout_durable_path(record)
    if os.path.exists(local):
        try:
            return Rollout.from_dict(read_json(local)), None
        except InputError:
            return None, "rollout-record-unreadable"
    if os.path.exists(durable):
        try:
            rollout = Rollout.from_dict(read_json(durable))
        except InputError:
            return None, "rollout-record-unreadable"
        return rollout, "rollout-record-missing-after-activation"
    return None, None


def atomic_write(target, text):
    parent = os.path.dirname(target)
    os.makedirs(parent, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=parent, prefix=".fm-maintain.", delete=False
    )
    try:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    finally:
        handle.close()
    os.replace(handle.name, target)


def refuse_symlinked(record, rel):
    """Reject a Record-relative write path when any component is a symlink."""
    current = record.root
    for part in rel.split("/"):
        current = os.path.join(current, part)
        if os.path.islink(current):
            raise InputError("refusing to write through symlink %s" % rel)


def save_rollout(record, rollout):
    local = rollout_local_path(record)
    if not os.path.isdir(os.path.dirname(local)):
        raise InputError("no .git directory in %s" % record.root)
    refuse_symlinked(record, "%s/maintain-rollout.json" % VIEWS_DIR)
    atomic_write(
        local, json.dumps(rollout.as_dict(False), sort_keys=True, indent=2) + "\n"
    )
    atomic_write(
        rollout_durable_path(record),
        json.dumps(rollout.as_dict(True), sort_keys=True, indent=2) + "\n",
    )


def rollout_text(payload, extra=()):
    lines = ["mode=%s" % payload["mode"]]
    lines.extend(extra)
    lines.append("clean_days=%d" % len(payload["clean_dates"]))
    lines.append("clean_dates=%s" % ",".join(payload["clean_dates"]))
    lines.append("rule_fingerprint=%s" % (payload["rule_fingerprint"] or "none"))
    evidence = payload["transition_evidence"]
    lines.append(
        "transition_evidence=%s" % (evidence["date"] if evidence else "none")
    )
    last = payload["last_result"]
    lines.append(
        "last_result=%s"
        % (
            "%s/%s" % (last.get("date"), "clean" if last.get("clean") else "dirty")
            if isinstance(last, dict)
            else "none"
        )
    )
    return "\n".join(lines) + "\n"


def command_rollout_init(args, record):
    if os.path.exists(rollout_local_path(record)):
        raise InputError("rollout record already exists")
    if os.path.exists(rollout_durable_path(record)):
        raise InputError("rollout-record-missing-after-activation")
    rollout = Rollout(created=args.now, updated=args.now)
    save_rollout(record, rollout)
    payload = rollout.as_dict(False)
    if args.format == "json":
        emit_json(payload)
    else:
        sys.stdout.write(rollout_text(payload, ["transition=initialized"]))
    return 0


def command_rollout_advance(args, record):
    day = parse_day(args.scheduled_date)
    if not day:
        raise InputError("--scheduled-date must be YYYY-MM-DD")
    lint = read_json(args.lint_json)
    if not isinstance(lint, dict) or lint.get("type") != "maintain-lint":
        raise InputError("--lint-json is not a maintain-lint payload")
    summary = lint.get("summary")
    if not isinstance(summary, dict):
        raise InputError("--lint-json has no summary")
    fingerprint = lint.get("rule_fingerprint")
    if not isinstance(fingerprint, str) or not fingerprint:
        raise InputError("--lint-json has no rule_fingerprint")
    covered = lint.get("rules")
    if args.coverage == "local" and (
        not isinstance(covered, list)
        or any(rule.id not in covered for rule in RULES)
    ):
        raise InputError("--lint-json does not cover every rule R1-R5")
    clean = not summary.get("finding") and not summary.get("unknown")
    rollout, error = load_rollout(record)
    if error:
        raise InputError(error)
    if rollout is None:
        sys.stdout.write("mode=not-configured\n")
        return 0
    observation = {
        "date": args.scheduled_date,
        "coverage": args.coverage,
        "clean": clean,
        "finding": int(summary.get("finding") or 0),
        "unknown": int(summary.get("unknown") or 0),
        "rule_fingerprint": fingerprint,
        "lint_path": args.lint_json,
    }
    if args.coverage == "cloud":
        rollout.last_cloud_result = observation
        transition = "cloud-recorded"
    else:
        transition = rollout.observe_local(args.scheduled_date, fingerprint, clean)
        rollout.last_result = observation
    rollout.updated = args.now
    save_rollout(record, rollout)
    payload = rollout.as_dict(False)
    payload["transition"] = transition
    if args.format == "json":
        emit_json(payload)
    else:
        sys.stdout.write(rollout_text(payload, ["transition=%s" % transition]))
    return 0


def command_rollout_status(args, record):
    rollout, error = load_rollout(record)
    if rollout is None:
        if args.format == "json":
            emit_json(
                {
                    "type": "maintain-rollout",
                    "mode": "not-configured",
                    "warning": error,
                }
            )
        else:
            sys.stdout.write("mode=not-configured\n")
        return 0
    payload = rollout.as_dict(False)
    if error:
        payload["warning"] = error
    if args.format == "json":
        emit_json(payload)
    else:
        extra = ["warning=%s" % error] if error else []
        sys.stdout.write(rollout_text(payload, extra))
    return 0


def command_stow_gate(args, record):
    rollout, error = load_rollout(record)
    if error:
        raise InputError(error)
    mode = rollout.mode if rollout else "not-configured"
    payload = lint_payload(record, list(RULES), args.now)
    code = lint_exit(payload)
    if args.format == "json":
        emit_json(
            {
                "type": "maintain-stow-gate",
                "mode": mode,
                "lint": payload,
                "gate": "blocked" if mode == "enforce" and code else "open",
            }
        )
    else:
        sys.stdout.write("mode=%s\n" % mode)
        sys.stdout.write(lint_text(payload))
    return code if mode == "enforce" else 0


def normalize_fact(text):
    return " ".join(text.split())


def latest_cleanup_receipt(record):
    dates = []
    try:
        names = os.listdir(record.root)
    except OSError:
        names = []
    for name in sorted(names):
        match = CLEANUP_RE.match(name)
        if match and os.path.isfile(record.path(name)):
            dates.append(match.group(1))
    if not dates:
        return {"present": False, "date": None, "path": None}
    latest = max(dates)
    return {
        "present": True,
        "date": latest,
        "path": "cleanup-%s.md" % latest,
    }


def fold_payload(record):
    facts = {}
    for name in FOLD_FILES:
        for line, indent, content in iter_bullets(read_text(record.path(name))):
            if indent:
                continue
            facts.setdefault(normalize_fact(content), []).append(
                ("%s:%d" % (name, line), content)
            )
    proposals = []
    for text, entries in sorted(facts.items()):
        if len(entries) < 2:
            continue
        proposals.append(
            {
                "kind": "duplicate-fact",
                "canonical": entries[0][0],
                "locators": [locator for locator, _ in entries],
                "text": text[:FACT_CUT],
            }
        )
    questions = []
    archive = read_text(record.path("memory-archive.md"))
    elsewhere = {}
    for name in FOLD_FILES:
        if name == "memory-archive.md":
            continue
        for line, indent, content in iter_bullets(read_text(record.path(name))):
            if not indent:
                elsewhere.setdefault(normalize_fact(content), "%s:%d" % (name, line))
    marks = 0
    for line, _, content in iter_bullets(archive):
        match = DUPLICATE_OF_RE.search(content)
        if not match:
            continue
        marks += 1
        target = normalize_fact(match.group(1).strip().strip("`"))
        locator = "memory-archive.md:%d" % line
        if target and target in elsewhere:
            proposals.append(
                {
                    "kind": "marked-duplicate",
                    "canonical": elsewhere[target],
                    "locators": [locator],
                    "text": target[:FACT_CUT],
                }
            )
        else:
            questions.append(
                {
                    "kind": "marked-duplicate-unresolved",
                    "locators": [locator],
                    "text": target[:FACT_CUT],
                }
            )
    bound = 0
    pointers = 0
    for task in record.child_dirs():
        brief = read_bytes(record.path(task, "brief.md"))
        state = sidecar_state(record, task, brief)
        if state and state[0] == "acknowledged":
            bound += 1
        if os.path.isfile(record.path(task, "POINTER.md")):
            pointers += 1
    return {
        "type": "maintain-fold",
        "receipt": latest_cleanup_receipt(record),
        "counts": {
            "bound_sidecars": bound,
            "pointers": pointers,
            "duplicate_facts": sum(
                1 for p in proposals if p["kind"] == "duplicate-fact"
            ),
            "duplicate_of_marks": marks,
        },
        "proposals": proposals,
        "questions": questions,
    }


def fold_text(payload):
    receipt = payload["receipt"]
    counts = payload["counts"]
    lines = [
        "receipt=%s date=%s"
        % ("present" if receipt["present"] else "absent", receipt["date"] or "none"),
        "counts: bound_sidecars=%d pointers=%d duplicate_facts=%d marks=%d"
        % (
            counts["bound_sidecars"],
            counts["pointers"],
            counts["duplicate_facts"],
            counts["duplicate_of_marks"],
        ),
    ]
    for proposal in payload["proposals"]:
        lines.append(
            "proposal %s %s" % (proposal["kind"], ",".join(proposal["locators"]))
        )
    for question in payload["questions"]:
        lines.append(
            "question %s %s" % (question["kind"], ",".join(question["locators"]))
        )
    return "\n".join(lines) + "\n"


def command_fold(args, record):
    payload = fold_payload(record)
    if args.format == "json":
        emit_json(payload)
    else:
        sys.stdout.write(fold_text(payload))
    return 0


def scrub_generated(value):
    if isinstance(value, dict):
        return {
            key: scrub_generated(item)
            for key, item in value.items()
            if key != "generated"
        }
    if isinstance(value, list):
        return [scrub_generated(item) for item in value]
    return value


def canonical_view(rel, text):
    """Drop generated timestamps so an unchanged view is left untouched."""
    if rel.endswith(".json"):
        try:
            return json.dumps(
                scrub_generated(json.loads(text)), sort_keys=True, indent=2
            )
        except ValueError:
            return text
    kept = [
        line
        for line in text.splitlines()
        if "<!-- generated by fm-maintain.py" not in line
    ]
    return "\n".join(kept)


MANIFEST_FILES = (
    "backlog.md",
    "done-archive.md",
    "captain.md",
    "learnings.md",
    "memory-archive.md",
    "vr-reports/INDEX.md",
)
TASK_INPUTS = ("brief.md", "report.md", "status", "launch.json", "recall.json")


def input_manifest(record):
    """sha256 of every file the views read, keyed by Record-relative path."""
    children = record.child_dirs()
    rels = list(MANIFEST_FILES)
    rels.extend(record.decision_files())
    for name in children:
        rels.extend("%s/%s" % (name, leaf) for leaf in TASK_INPUTS)
    rels.extend(
        sorted(record.rel(p) for p in glob.glob(record.path(".record-state", "*.meta")))
    )
    manifest = {"child-dirs": sha256_hex("\n".join(children).encode("utf-8"))}
    for rel in rels:
        data = read_bytes(record.path(rel))
        manifest[rel] = sha256_hex(data) if data is not None else None
    return manifest


class StagedViews:
    """Stage generated files outside the Record, then land them atomically."""

    def __init__(self, record, stage_dir, owned):
        self.record = record
        self.stage_dir = stage_dir
        self.owned = owned
        self.staged = []
        self.manifest = None

    def bind_inputs(self):
        self.manifest = input_manifest(self.record)

    def add(self, rel, content):
        rel = rel.strip("/")
        if os.path.isabs(rel) or ".." in rel.split("/"):
            raise InputError("refusing to stage %s outside wiki/views" % rel)
        target = os.path.join(self.stage_dir, rel)
        os.makedirs(os.path.dirname(target) or self.stage_dir, exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(content)
        self.staged.append(rel)

    def land(self, apply_changes):
        written = []
        unchanged = []
        for rel in self.staged:
            refuse_symlinked(self.record, "%s/%s" % (VIEWS_DIR, rel))
        if self.manifest is not None:
            current = input_manifest(self.record)
            changed = sorted(
                rel
                for rel in set(current) | set(self.manifest)
                if current.get(rel) != self.manifest.get(rel)
            )
            if changed:
                if self.owned:
                    shutil.rmtree(self.stage_dir, ignore_errors=True)
                return {
                    "written": [],
                    "unchanged": [],
                    "changed_input": changed,
                    "stage_dir": self.stage_dir,
                }
        for rel in self.staged:
            staged_text = read_text(os.path.join(self.stage_dir, rel))
            target = self.record.path(VIEWS_DIR, rel)
            view_rel = "%s/%s" % (VIEWS_DIR, rel)
            if os.path.exists(target) and canonical_view(
                rel, read_text(target)
            ) == canonical_view(rel, staged_text):
                unchanged.append(view_rel)
                continue
            written.append(view_rel)
            if apply_changes:
                atomic_write(target, staged_text)
        if self.owned and apply_changes:
            shutil.rmtree(self.stage_dir, ignore_errors=True)
        return {
            "written": written,
            "unchanged": unchanged,
            "changed_input": [],
            "stage_dir": self.stage_dir,
        }


def open_stage(record, requested):
    """Open the staging dir; an unnamed one is ours to reclaim after --apply."""
    if not requested:
        return StagedViews(record, tempfile.mkdtemp(prefix="fm-maintain-stage."), True)
    stage = os.path.abspath(requested)
    if record.inside(stage):
        raise InputError("--stage-dir must be outside the Record")
    os.makedirs(stage, exist_ok=True)
    return StagedViews(record, stage, False)


def view_header(subcommand, sources, now_text):
    return (
        "<!-- generated by fm-maintain.py %s; source: %s; generated: %s;"
        " do not hand-edit -->\n" % (subcommand, sources, now_text)
    )


def cell(text):
    return (text or "").replace("|", "\\|").replace("\n", " ")


def render_table(header, rows):
    lines = ["| " + " | ".join(cell(c) for c in header) + " |"]
    lines.append("| " + " | ".join("---" for _ in header) + " |")
    for row in rows:
        lines.append("| " + " | ".join(cell(c) for c in row) + " |")
    if not rows:
        lines.append("| " + " | ".join("-" for _ in header) + " |")
    return "\n".join(lines) + "\n"


def decision_title(text):
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return "title unknown"


def decision_date(record, rel, text):
    match = DATE_RE.search(os.path.basename(rel))
    if match:
        return match.group(1)
    match = DECISION_DATE_RE.search(text)
    if match:
        return match.group(1)
    return "date unknown"


def decision_successor(record, text):
    for pattern in (SUPERSEDED_BY_RE, SUPERSEDES_RE):
        match = pattern.search(text)
        if not match:
            continue
        for token in first_line_paths(match.group(1)) or [match.group(1).strip()]:
            resolved = resolve_decision(record, token)
            if resolved:
                return resolved
    return "-"


def resolve_decision(record, token):
    cleaned = (token or "").strip().strip("`").rstrip(".,;:)")
    if not cleaned:
        return ""
    stem = cleaned[:-3] if cleaned.endswith(".md") else cleaned
    for candidate in (
        record.path(cleaned),
        record.path("decisions", "%s.md" % os.path.basename(stem)),
    ):
        if record.inside(candidate) and os.path.isfile(candidate):
            return record.rel(candidate)
    return ""


def view_decisions(record, now_text):
    rows = []
    for rel in record.decision_files():
        text = read_text(record.path(rel))
        match = DECISION_STATUS_RE.search(text)
        rows.append(
            [
                rel,
                decision_date(record, rel, text),
                decision_title(text),
                match.group(1) if match else "status unknown",
                decision_successor(record, text),
            ]
        )
    body = render_table(["file", "date", "title", "status", "successor"], rows)
    return (
        view_header("views", "decisions/*.md", now_text)
        + "\n# Decisions\n\n"
        + body
    )


def view_completed_tasks(record, now_text):
    rows = []
    archived = ""
    for _, line in iter_lines_outside_fences(read_text(record.path("done-archive.md"))):
        heading = ARCHIVED_RE.match(line)
        if heading:
            archived = heading.group(1)
            continue
        row = ARCHIVE_ROW_RE.match(line)
        if not row:
            continue
        task_id = row.group(1)
        report = "%s/report.md" % task_id
        rows.append(
            [
                task_id,
                archived or "date unknown",
                row.group(2).strip()[:TITLE_CUT],
                report if os.path.isfile(record.path(report)) else "-",
            ]
        )
    body = render_table(["id", "archived", "title", "report"], rows)
    return (
        view_header("views", "done-archive.md", now_text)
        + "\n# Completed tasks\n\n"
        + body
    )


def view_brief_only(record, now_text, results):
    rows = []
    for result in results:
        task = result.locator.split("/")[0]
        dispatched = dispatch_epoch(record, task)
        age = (
            "unknown"
            if dispatched is None
            else str((record.now_ts - dispatched) // 86400)
        )
        rows.append([task, age, result.outcome, result.reason])
    body = render_table(["task", "age days", "outcome", "reason"], rows)
    return (
        view_header("views", "task briefs and reports", now_text)
        + "\n# Brief without outcome\n\n"
        + body
    )


def view_duplicates(record, now_text, fold):
    rows = []
    grouped = (("proposal", fold["proposals"]), ("question", fold["questions"]))
    for group, entries in grouped:
        for entry in entries:
            rows.append(
                [group, entry["kind"], ",".join(entry["locators"]), entry["text"]]
            )
    body = render_table(["class", "kind", "locators", "text"], rows)
    return (
        view_header("views", ", ".join(FOLD_FILES), now_text)
        + "\n# Duplicate facts\n\n"
        + body
    )


def view_memory_lint(record, now_text, results):
    rows = [[r.locator, r.outcome, r.reason] for r in results]
    body = render_table(["locator", "outcome", "reason"], rows)
    return (
        view_header("views", ", ".join(MEMORY_FILES), now_text)
        + "\n# Memory lint\n\n"
        + body
    )


def view_video_index(record, now_text):
    index_rel = "vr-reports/INDEX.md"
    text = read_text(record.path(index_rel))
    rows = []
    linked = set()
    tokens = [match.group(1) for match in LINK_RE.finditer(text)]
    tokens.extend(match.group(1) for match in BACKTICK_RE.finditer(text))
    for token in tokens:
        cleaned = looks_like_path(token)
        if not cleaned or cleaned.startswith("http"):
            continue
        candidate = os.path.normpath(record.path("vr-reports", cleaned))
        inside = record.inside(candidate)
        state = "ok" if inside and os.path.exists(candidate) else "broken"
        rows.append([cleaned, state])
        if inside:
            linked.add(record.rel(candidate).split("/")[0])
            linked.add(cleaned.strip("./").split("/")[0])
    unlinked = [
        [name, "not linked"]
        for name in record.child_dirs()
        if name.startswith("vr-") and name not in linked
    ]
    body = render_table(["target", "state"], rows + unlinked)
    return (
        view_header("views", index_rel, now_text)
        + "\n# Video index\n\n"
        + body
    )


def build_views(record, now_text, stage):
    stage.bind_inputs()
    results = run_rules(record, list(RULES))
    r2 = [r for r in results if r.rule == "R2"]
    r5 = [r for r in results if r.rule == "R5"]
    stage.add("decisions.md", view_decisions(record, now_text))
    stage.add("completed-tasks.md", view_completed_tasks(record, now_text))
    stage.add("brief-only.md", view_brief_only(record, now_text, r2))
    stage.add("duplicates.md", view_duplicates(record, now_text, fold_payload(record)))
    stage.add("memory-lint.md", view_memory_lint(record, now_text, r5))
    stage.add("video-index.md", view_video_index(record, now_text))


def views_text(payload):
    lines = [
        "written=%d unchanged=%d stage_dir=%s"
        % (len(payload["written"]), len(payload["unchanged"]), payload["stage_dir"])
    ]
    for rel in payload["written"]:
        lines.append("written %s" % rel)
    for rel in payload["unchanged"]:
        lines.append("unchanged %s" % rel)
    for rel in payload.get("changed_input") or []:
        lines.append("changed-input %s" % rel)
    return "\n".join(lines) + "\n"


def command_views(args, record):
    stage = open_stage(record, args.stage_dir)
    build_views(record, args.now, stage)
    landed = stage.land(args.apply)
    payload = {"type": "maintain-views"}
    payload.update(landed)
    if args.format == "json":
        emit_json(payload)
    else:
        sys.stdout.write(views_text(payload))
    return 1 if landed["changed_input"] else 0


def load_recall_receipt(record, task):
    payload = read_bytes(record.path(task, "recall.json"))
    if payload is None:
        return None
    try:
        parsed = json.loads(payload.decode("utf-8", errors="replace"))
    except ValueError:
        return None
    if not isinstance(parsed, dict) or parsed.get("type") != "recall-receipt":
        return None
    return parsed


def brief_without_recalled_section(record, task):
    text = read_text(record.path(task, "brief.md"))
    match = RECALLED_SECTION_RE.search(text)
    if not match:
        return text
    head = text[: match.start()]
    rest = text[match.end() :]
    for line_match in re.finditer(r"(?m)^#", rest):
        return head + rest[line_match.start() :]
    return head


def reused_emitted_path(record, task, receipt):
    emitted = [p for p in (receipt.get("emitted_paths") or []) if isinstance(p, str)]
    preexisting = set(
        p for p in (receipt.get("preexisting_cited_paths") or []) if isinstance(p, str)
    )
    body = brief_without_recalled_section(record, task)
    for path in emitted:
        if path and path not in preexisting and path in body:
            return path
    return ""


def receipt_moment(record, task, receipt):
    for key in ("timestamp_utc", "date", "generated"):
        moment = parse_moment(receipt.get(key))
        if moment:
            return moment
    added = record.added_epoch("%s/brief.md" % task)
    if added is None:
        return None
    return datetime.fromtimestamp(added, timezone.utc)


def classify_answer(receipt):
    label = receipt.get("answer_classification")
    if label == "answered" and receipt.get("answer_location") and receipt.get(
        "answer_date"
    ):
        return "answered"
    if label == "not_answered":
        return "not_answered"
    return "unknown"


def succession_edges(record):
    """Return resolvable older -> newer decision links, self and cycles cut."""
    edges = {}
    for rel in record.decision_files():
        text = read_text(record.path(rel))
        for pattern, newer_is_self in (
            (SUPERSEDES_RE, True),
            (SUPERSEDED_BY_RE, False),
        ):
            match = pattern.search(text)
            if not match:
                continue
            other = ""
            for token in first_line_paths(match.group(1)) or [match.group(1).strip()]:
                other = resolve_decision(record, token)
                if other:
                    break
            if not other or other == rel:
                continue
            newer, older = (rel, other) if newer_is_self else (other, rel)
            edges[(older, newer)] = True
    return {
        pair: True for pair in edges if (pair[1], pair[0]) not in edges
    }


def week_bucket(record, week, receipts, edges, injected):
    reuse_evidence = []
    reuse_count = 0
    answers = {"answered": 0, "not_answered": 0, "unknown": 0}
    rediscovery_evidence = []
    classified = False
    for task, receipt, moment in receipts:
        if moment is None or not week.contains(moment):
            continue
        classified = classified or "answer_classification" in receipt
        answers[classify_answer(receipt)] += 1
        rediscovery_evidence.append(
            {
                "task": task,
                "evidence": "%s/recall.json" % task,
                "classification": classify_answer(receipt),
            }
        )
        path = reused_emitted_path(record, task, receipt)
        if path:
            reuse_count += 1
            reuse_evidence.append(
                {
                    "task": task,
                    "evidence": "%s/brief.md" % task,
                    "emitted_path": path,
                }
            )
    succession_evidence = []
    for older, newer in sorted(edges):
        text = read_text(record.path(newer))
        day = decision_date(record, newer, text)
        moment = parse_moment(day)
        if moment is None or not week.contains(moment):
            continue
        succession_evidence.append(
            {"older": older, "newer": newer, "date": day}
        )
    bucket = dict(week.bounds())
    bucket["reuse"] = (
        "not measured"
        if not receipts
        else {"tasks": reuse_count, "evidence": reuse_evidence}
    )
    bucket["rediscovery"] = (
        "not measured"
        if not classified
        else {"counts": answers, "evidence": rediscovery_evidence}
    )
    bucket["succession"] = (
        "not measured"
        if not record.decision_files()
        else {
            "decisions": len(succession_evidence),
            "evidence": succession_evidence,
        }
    )
    bucket["injected"] = injected_bucket(week, injected)
    return bucket


def injected_bucket(week, injected):
    if injected is None:
        return "not measured"
    placed = [entry for entry in injected if week.contains(entry["moment"])]
    if not injected:
        return "not measured"
    return {
        "receipts": len(placed),
        "digest_bytes": sum(entry["digest_bytes"] for entry in placed),
        "bytes": sum(entry["bytes"] for entry in placed),
        "estimated_tokens": sum(entry["estimated_tokens"] for entry in placed),
        "evidence": [entry["evidence"] for entry in placed],
    }


def load_injected(state_dir):
    if not state_dir:
        return None
    entries = []
    pattern = os.path.join(state_dir, ".session-recall-receipt.*.json")
    for path in sorted(glob.glob(pattern)):
        try:
            payload = read_json(path)
        except InputError:
            continue
        if not isinstance(payload, dict):
            continue
        moment = None
        for key in ("timestamp_utc", "date"):
            moment = parse_moment(payload.get(key))
            if moment:
                break
        if moment is None:
            continue
        sizes = {}
        for key in ("digest_bytes", "bytes", "estimated_tokens"):
            value = payload.get(key) or 0
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                sizes = None
                break
            sizes[key] = int(value)
        if sizes is None:
            continue
        entry = {"moment": moment, "evidence": os.path.basename(path)}
        entry.update(sizes)
        entries.append(entry)
    return entries


def measure_payload(record, now_text, state_dir):
    receipts = []
    observed = []
    unobserved = []
    for task in record.task_dirs():
        receipt = load_recall_receipt(record, task)
        if receipt:
            receipts.append((task, receipt, receipt_moment(record, task, receipt)))
        evidence = {"task": task, "evidence": "%s/brief.md" % task}
        if record.added_epoch("%s/brief.md" % task) is None:
            evidence["reason"] = (
                "no-git-history" if record.has_git() else "no-record-git"
            )
            unobserved.append(evidence)
        else:
            observed.append(evidence)
    edges = succession_edges(record)
    injected = load_injected(state_dir)
    current = Week.containing(record.now)
    previous = current.previous()
    payload = {
        "type": "maintain-recall-compounding",
        "generated": now_text,
        "generated_by": "fm-maintain.py measure",
        "record_commit": record.commit(),
        "token_estimator": TOKEN_ESTIMATOR,
        "coverage": {"observed": observed, "unobserved": unobserved},
        "current_week": week_bucket(record, current, receipts, edges, injected),
        "previous_week": week_bucket(record, previous, receipts, edges, injected),
    }
    payload["current_week"]["partial"] = True
    payload["previous_week"]["partial"] = False
    return payload


def counter_cell(value, key):
    if isinstance(value, str):
        return value
    if key in value:
        return str(value[key])
    return str(value.get("counts", {}))


def measure_view(payload, now_text):
    rows = []
    for name in ("current_week", "previous_week"):
        bucket = payload[name]
        rows.append(
            [
                name.replace("_", " "),
                bucket["label"],
                counter_cell(bucket["reuse"], "tasks"),
                counter_cell(bucket["rediscovery"], "counts"),
                counter_cell(bucket["succession"], "decisions"),
                counter_cell(bucket["injected"], "estimated_tokens"),
            ]
        )
    body = render_table(
        ["week", "label", "reuse", "rediscovery", "succession", "injected tokens"],
        rows,
    )
    coverage = payload["coverage"]
    return (
        view_header("measure", "recall receipts, decisions, session receipts", now_text)
        + "\n# Recall compounding\n\n"
        + body
        + "\nToken estimator: %s\n" % TOKEN_ESTIMATOR
        + "Coverage: observed=%d unobserved=%d\n"
        % (len(coverage["observed"]), len(coverage["unobserved"]))
    )


def command_measure(args, record):
    stage = open_stage(record, args.stage_dir)
    stage.bind_inputs()
    payload = measure_payload(record, args.now, args.state)
    stage.add(
        "recall-compounding.json",
        json.dumps(payload, sort_keys=True, indent=2) + "\n",
    )
    stage.add("recall-compounding.md", measure_view(payload, args.now))
    landed = stage.land(args.apply)
    if args.format == "json":
        out = {"type": "maintain-measure"}
        out.update(landed)
        out["measures"] = payload
        emit_json(out)
    else:
        sys.stdout.write(views_text(landed))
        sys.stdout.write(
            "weeks: current=%s previous=%s\n"
            % (payload["current_week"]["label"], payload["previous_week"]["label"])
        )
    return 1 if landed["changed_input"] else 0


REASON_LINES = {
    "deferral-without-hold": (
        "a deferred backlog item has no hold trigger",
        "backlog/bind the item to a hold and an evaluator",
    ),
    "hold-without-evaluator": (
        "a held backlog item names no evaluator",
        "backlog/name the evaluator on the hold",
    ),
    "deferral-word-in-quote": (
        "a deferral word appears only in quoted text",
        "backlog/confirm the row is not a real deferral",
    ),
    "brief-without-report": (
        "a dispatched task older than 14 days has no report",
        "stow/report the outcome or acknowledge it",
    ),
    "age-unknown": (
        "a task brief has no durable dispatch time",
        "stow/record the dispatch time or commit the brief",
    ),
    "sidecar-unbound": (
        "an acknowledgement sidecar carries no brief hash",
        "t11-fold/bind the sidecar to the brief hash",
    ),
    "sidecar-brief-changed": (
        "an acknowledged brief changed after the acknowledgement",
        "t11-fold/re-acknowledge or report the task",
    ),
    "pointer-broken": (
        "a twin review pointer does not resolve",
        "t11-fold/repoint the twin at the review artifact",
    ),
    "pointer-cycle": (
        "twin review pointers point at each other",
        "t11-fold/break the pointer cycle",
    ),
    "pointer-ambiguous": (
        "a twin review pointer names more than one path",
        "t11-fold/leave one path on the first line",
    ),
    "pointer-missing": (
        "a twin has no review pointer while the base holds the report",
        "t11-fold/add POINTER.md to the twin",
    ),
    "review-owner-unclear": (
        "neither twin nor base clearly owns the review",
        "t11-fold/name the review owner",
    ),
    "handwritten-directory-table": (
        "a hand-maintained directory table duplicates a generated view",
        "t11-fold/replace the table with the generated view",
    ),
    "mixed-table": (
        "a table mixes resolvable and unresolvable entries",
        "t11-fold/classify the table",
    ),
    "unclassified-fact": (
        "a memory fact carries no date, pointer, or timeless marker",
        "captain/qualify or retire the fact",
    ),
}
STAGE_LINES = {
    "finding": ("the stage reported a problem", "captain/read the stage detail"),
    "failed": ("the stage failed", "captain/re-run the stage and read its detail"),
    "timeout": ("the stage hit its time bound", "captain/re-run with more headroom"),
    "interrupted": ("the run was interrupted", "captain/re-run the nightly"),
}


def parse_stages(path):
    text = read_bytes(path)
    if text is None:
        raise InputError("cannot read %s" % path)
    stages = []
    for number, line in enumerate(
        text.decode("utf-8", errors="replace").splitlines(), 1
    ):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            raise InputError("stage line %d needs 3 tab-separated fields" % number)
        name, outcome, elapsed = fields[0].strip(), fields[1].strip(), fields[2].strip()
        detail = fields[3].strip() if len(fields) > 3 else ""
        if outcome not in STAGE_OUTCOMES:
            raise InputError("stage line %d has unknown outcome %s" % (number, outcome))
        try:
            seconds = float(elapsed or 0)
        except ValueError:
            raise InputError("stage line %d has a non-numeric elapsed time" % number)
        stages.append(
            {
                "name": name,
                "outcome": outcome,
                "elapsed_seconds": seconds,
                "detail": detail,
            }
        )
    return stages


def rule_digest_lines(lint):
    grouped = {}
    for result in lint.get("results") or []:
        if not isinstance(result, dict):
            continue
        if result.get("outcome") not in ("finding", "unknown"):
            continue
        key = "%s:%s" % (result.get("rule"), result.get("reason"))
        grouped.setdefault(key, {"count": 0, "owner": result.get("owner") or "captain"})
        grouped[key]["count"] += 1
    lines = []
    for key in sorted(grouped):
        reason = key.split(":", 1)[1]
        observation, action = REASON_LINES.get(
            reason,
            ("a lint rule reported %s" % reason, "captain/triage the rule output"),
        )
        lines.append(
            {
                "key": key,
                "observation": "%d result(s): %s"
                % (grouped[key]["count"], observation),
                "consequence": "the Record drifts from its generated views",
                "next": action,
            }
        )
    return lines


def stage_digest_lines(stages, has_rule_lines):
    lines = []
    for stage in stages:
        if stage["outcome"] not in PROBLEM_OUTCOMES:
            continue
        if stage["name"] == "lint" and stage["outcome"] == "finding" and has_rule_lines:
            continue
        detail_slug = slug(stage["detail"]) or stage["outcome"]
        observation, action = STAGE_LINES.get(
            stage["outcome"], ("the stage reported a problem", "captain/read the stage")
        )
        lines.append(
            {
                "key": "%s:%s" % (stage["name"], detail_slug),
                "observation": "%s: %s" % (stage["name"], observation),
                "consequence": sanitize_line(stage["detail"], 200)
                or "the nightly result is incomplete",
                "next": action,
            }
        )
    return lines


def receipt_markdown(now_text, host, day, stages, lint, mode, args, lines):
    rows = [
        [
            stage["name"],
            stage["outcome"],
            "%.1f" % stage["elapsed_seconds"],
            sanitize_line(stage["detail"], 200),
        ]
        for stage in stages
    ]
    summary = lint.get("summary") or {}
    problems = render_table(
        ["key", "observation", "consequence", "next"],
        [
            [line["key"], line["observation"], line["consequence"], line["next"]]
            for line in lines
        ],
    )
    complete = not any(stage["outcome"] in INCOMPLETE_OUTCOMES for stage in stages)
    return (
        view_header("receipt", "%s stages" % host, now_text)
        + "\n# Nightly maintenance %s (%s)\n\n" % (day, host)
        + "- input commit: %s\n" % sanitize_line(args.input_commit, 200)
        + "- tool fingerprint: %s\n" % sanitize_line(args.tool_fingerprint, 200)
        + "- lint mode: %s\n" % sanitize_line(mode, 200)
        + "- coverage: %s\n" % host
        + "- checkpoint and verify: run after this receipt; their outcome is"
        " recorded locally in .git/nightly/last-attempt\n"
        + "- lint summary: finding=%s unknown=%s acknowledged=%s pass=%s\n"
        % (
            summary.get("finding", 0),
            summary.get("unknown", 0),
            summary.get("acknowledged", 0),
            summary.get("pass", 0),
        )
        + "- complete: %s\n" % ("yes" if complete else "no")
        + "\n## Stages\n\n"
        + render_table(["stage", "outcome", "seconds", "detail"], rows)
        + "\n## Problems\n\n"
        + problems
    )


def command_receipt(args, record):
    day = args.now[:10]
    if not parse_day(day):
        raise InputError("--now must carry a YYYY-MM-DD date")
    stages = parse_stages(args.stages)
    lint = read_json(args.lint_json)
    if not isinstance(lint, dict) or lint.get("type") != "maintain-lint":
        raise InputError("--lint-json is not a maintain-lint payload")
    mode = "not-configured"
    if args.rollout_json != "-":
        rollout = read_json(args.rollout_json)
        if isinstance(rollout, dict) and rollout.get("mode"):
            mode = rollout["mode"]
    rule_lines = rule_digest_lines(lint)
    lines = rule_lines + stage_digest_lines(stages, bool(rule_lines))
    omitted = max(0, len(lines) - RECEIPT_LINE_CAP)
    lines = lines[:RECEIPT_LINE_CAP]
    complete = not any(stage["outcome"] in INCOMPLETE_OUTCOMES for stage in stages)
    digest_path = record.path(VIEWS_DIR, "nightly-digest.json")
    digest = {"type": "nightly-digest", "hosts": {}}
    if os.path.exists(digest_path):
        existing = read_json(digest_path)
        if not isinstance(existing, dict) or not isinstance(
            existing.get("hosts"), dict
        ):
            raise InputError("nightly-digest.json is not a nightly-digest payload")
        digest = existing
    digest["type"] = "nightly-digest"
    digest["hosts"][args.host] = {
        "date": day,
        "generated": args.now,
        "input_commit": args.input_commit,
        "lines": lines,
        "omitted": omitted,
        "complete": complete,
    }
    receipt_rel = "maintenance/%s-%s.md" % (day, args.host)
    stage = open_stage(record, args.stage_dir)
    stage.add(
        receipt_rel,
        receipt_markdown(args.now, args.host, day, stages, lint, mode, args, lines),
    )
    stage.add(
        "nightly-digest.json", json.dumps(digest, sort_keys=True, indent=2) + "\n"
    )
    landed = stage.land(args.apply)
    payload = {
        "type": "maintain-receipt",
        "receipt": "%s/%s" % (VIEWS_DIR, receipt_rel),
    }
    payload.update(landed)
    payload["complete"] = complete
    payload["lines"] = len(lines)
    payload["omitted"] = omitted
    payload["mode"] = mode
    if args.format == "json":
        emit_json(payload)
    else:
        sys.stdout.write(views_text(landed))
        sys.stdout.write(
            "receipt=%s mode=%s lines=%d omitted=%d complete=%s\n"
            % (
                payload["receipt"],
                mode,
                len(lines),
                omitted,
                "yes" if complete else "no",
            )
        )
    return 0


def last_attempt_line(record):
    """The local run's date, result, and verify tokens, or None when absent."""
    text = read_text(record.path(".git", "nightly", "last-attempt"))
    if not text:
        return None
    fields = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key.strip()] = value.strip()
    verify = [
        token
        for token in fields.get("verify", "").split()
        if token.startswith(("state=", "equal=", "class="))
    ]
    return "Nightly maintenance: last local run %s result=%s; verify %s" % (
        fields.get("date") or "date unknown",
        fields.get("result") or "unknown",
        " ".join(verify) or "not recorded",
    )


def digest_lines(record, args):
    path = record.path(VIEWS_DIR, "nightly-digest.json")
    local_line = last_attempt_line(record)
    if not os.path.exists(path):
        lines = [local_line] if local_line else []
        lines.append("Nightly maintenance: no receipt published yet.")
        return [sanitize_line(line, args.line_chars) for line in lines], 0
    unreadable = [
        "Nightly maintenance: receipt unreadable; run bin/fm-nightly.sh status."
    ]
    try:
        data = json.loads(read_text(path))
    except ValueError:
        return unreadable, 0
    if not isinstance(data, dict) or not isinstance(data.get("hosts"), dict):
        return unreadable, 0
    hosts = [(name, entry) for name, entry in sorted(data["hosts"].items())
             if isinstance(entry, dict)]
    if not hosts:
        return ["Nightly maintenance: no receipt published yet."], 0
    lines = []
    budget = args.max_lines
    omitted_by_host = {name: 0 for name, _ in hosts}

    def emit(name, text):
        nonlocal budget
        if budget <= 0:
            omitted_by_host[name] += 1
            return
        budget -= 1
        lines.append(sanitize_line(text, args.line_chars))

    if local_line:
        emit(hosts[0][0], local_line)
    for name, entry in hosts:
        day = entry.get("date") if isinstance(entry.get("date"), str) else ""
        parsed = parse_day(day)
        stale = parsed is None or (record.now.date() - parsed).days > args.stale_days
        day = day or "date unknown"
        issues = [line for line in (entry.get("lines") or []) if isinstance(line, dict)]
        omitted_by_host[name] += count_or_zero(entry.get("omitted"))
        if stale:
            emit(
                name,
                "Nightly maintenance (%s): last receipt %s (stale)." % (name, day),
            )
        if not entry.get("complete", True):
            emit(
                name,
                "Nightly %s (%s): run incomplete; see %s/maintenance/%s-%s.md"
                % (day, name, VIEWS_DIR, day, name),
            )
        elif not issues and not stale:
            emit(name, "Nightly %s (%s): clean." % (day, name))
        for issue in issues:
            emit(
                name,
                "Nightly %s (%s): %s; %s; %s"
                % (
                    day,
                    name,
                    issue.get("observation", ""),
                    issue.get("consequence", ""),
                    issue.get("next", ""),
                ),
            )
    omitted = sum(omitted_by_host.values())
    if omitted:
        name, entry = max(hosts, key=lambda item: omitted_by_host[item[0]])
        day = entry.get("date") if isinstance(entry.get("date"), str) else ""
        footer = (
            "Nightly maintenance: %d more issue(s) omitted;"
            " see %s/maintenance/%s-%s.md"
        )
        lines.append(
            sanitize_line(
                footer % (omitted, VIEWS_DIR, day or "date unknown", name),
                args.line_chars,
            )
        )
    return lines, omitted


def count_or_zero(value):
    if isinstance(value, bool) or not isinstance(value, int):
        return 0
    return max(0, value)


def command_digest(args, record):
    if args.max_lines < 0 or args.line_chars <= 0 or args.stale_days < 0:
        raise InputError("digest budgets must be non-negative")
    lines, omitted = digest_lines(record, args)
    if args.format == "json":
        emit_json({"type": "maintain-digest", "lines": lines, "omitted": omitted})
    else:
        for line in lines:
            sys.stdout.write(line + "\n")
    return 0


COMMANDS = {
    "lint": command_lint,
    "rollout:init": command_rollout_init,
    "rollout:advance": command_rollout_advance,
    "rollout:status": command_rollout_status,
    "stow-gate": command_stow_gate,
    "fold": command_fold,
    "views": command_views,
    "measure": command_measure,
    "receipt": command_receipt,
    "digest": command_digest,
}


def add_common(parser, now_required=True):
    parser.add_argument("--record", required=True, help="Absolute Record root")
    parser.add_argument(
        "--now",
        required=now_required,
        default="",
        help="RFC3339 UTC instant, e.g. 2026-09-07T03:00:00Z",
    )
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser


def build_parser():
    parser = argparse.ArgumentParser(
        prog="fm-maintain.py",
        description="Report-only maintenance for the firstmate Record.",
    )
    subparsers = parser.add_subparsers(dest="command")

    lint = add_common(subparsers.add_parser("lint", help="Run the report-only rules"))
    lint.add_argument("--rules", default="", help="Comma-separated rule ids")

    rollout = subparsers.add_parser("rollout", help="Enforcement rollout record")
    rollout_subs = rollout.add_subparsers(dest="rollout_command")
    add_common(rollout_subs.add_parser("init", help="Create the rollout record"))
    advance = add_common(
        rollout_subs.add_parser("advance", help="Apply one scheduled day")
    )
    advance.add_argument("--lint-json", required=True, help="lint --format json output")
    advance.add_argument("--scheduled-date", required=True, help="YYYY-MM-DD")
    advance.add_argument("--coverage", choices=("local", "cloud"), default="local")
    add_common(
        rollout_subs.add_parser("status", help="Print the rollout state"),
        now_required=False,
    )

    add_common(subparsers.add_parser("stow-gate", help="Lint under the rollout mode"))
    add_common(subparsers.add_parser("fold", help="Consume the T11 cleanup receipt"))

    views = add_common(subparsers.add_parser("views", help="Build generated views"))
    views.add_argument("--stage-dir", default="", help="Staging dir outside the Record")
    views.add_argument("--apply", action="store_true", help="Land the staged views")

    measure = add_common(
        subparsers.add_parser("measure", help="Measure recall compounding")
    )
    measure.add_argument("--state", default="", help="Home state dir for receipts")
    measure.add_argument("--stage-dir", default="")
    measure.add_argument("--apply", action="store_true")

    receipt = add_common(
        subparsers.add_parser("receipt", help="Publish the nightly receipt")
    )
    receipt.add_argument("--host", required=True, type=host_slug,
                         help="receipt owner key: short hostname or cloud")
    receipt.add_argument("--stages", required=True, help="Stage TSV")
    receipt.add_argument("--input-commit", required=True)
    receipt.add_argument("--lint-json", required=True)
    receipt.add_argument("--rollout-json", required=True, help="rollout JSON or -")
    receipt.add_argument("--tool-fingerprint", required=True)
    receipt.add_argument("--stage-dir", default="")
    receipt.add_argument("--apply", action="store_true")

    digest = add_common(subparsers.add_parser("digest", help="Print the wake digest"))
    digest.add_argument("--max-lines", type=int, default=8)
    digest.add_argument("--line-chars", type=int, default=200)
    digest.add_argument("--stale-days", type=int, default=2)
    return parser


def resolve_command(args):
    if args.command == "rollout":
        if not args.rollout_command:
            raise InputError("rollout needs init, advance, or status")
        return COMMANDS["rollout:%s" % args.rollout_command]
    return COMMANDS[args.command]


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 2
    try:
        handler = resolve_command(args)
        if not os.path.isabs(args.record):
            raise InputError("--record must be an absolute path")
        if not os.path.isdir(args.record):
            raise InputError("no Record directory at %s" % args.record)
        if not os.path.isfile(os.path.join(args.record, "backlog.md")):
            raise InputError("no backlog.md in Record %s" % args.record)
        now = parse_now(args.now) if args.now else None
        if args.now and now is None:
            raise InputError("--now must be RFC3339 UTC with a Z suffix")
        moment = now or datetime.now(timezone.utc)
        return handler(args, Record(os.path.realpath(args.record), moment))
    except InputError as exc:
        sys.stderr.write("fm-maintain: %s\n" % exc)
        return 2
    except BrokenPipeError:
        return 0
    except Exception as exc:
        sys.stderr.write("fm-maintain: execution failure: %s\n" % type(exc).__name__)
        return 2


if __name__ == "__main__":
    sys.exit(main())
