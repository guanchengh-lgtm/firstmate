#!/usr/bin/env python3
"""Paired recall probe runner for the gbrain trial.

This program compares the shipped brief recall executable with the same
owner under --ranker hybrid. It does not implement a third ranker and it
does not rewrite the gold answers. T2 term overlap remains the brief
floor until a later two-week verdict ship. The brief default is --ranker
auto with GBRAIN_RECALL off until I4 flips that switch.

Usage:
  fm-gbrain-eval.py run --record R --gold FILE --recall-bin PATH
    --out DIR --now YYYY-MM-DD [--hybrid-bin PATH]
    [--deadline-ms N] [--run-id ID] [--format text|json]
  fm-gbrain-eval.py verdict --day0 DIR --day7 DIR --day14 DIR --out FILE
    [--format text|json]
  fm-gbrain-eval.py --help

--hybrid-bin defaults to the bin/fm-recall.sh beside this file.

Gold is the locked TSV used by tests/fm-recall.test.sh:
  n, probe_date, dispatched_ids, prior_ids, query
Do not edit that file after seeing results.

Modes:
  A  all 13 probes; expected identities are dispatched plus prior.
  B  probes that have prior evidence; dispatched ids are excluded
     before search; expected identities are the prior set.
  C  mode B plus --as-of probe_date on both arms.

The overlap arm is the shipped recall JSON under --ranker overlap, so
the GBRAIN_RECALL switch never changes it. Its identities are hits[].id
and its retrieval mode is recorded as "overlap". The hybrid arm
is bin/fm-recall.sh --ranker hybrid --surface pointers --now DATE and
reads hits[].id plus retrieval_mode from that payload. Multiple chunks
of one identity collapse to the first rank. A done-archive path is not
rewritten into every expected task id here; the recall owner already
keeps those identities distinct. Timeouts, misses, and degraded rows
stay in the denominator. A keyword-only or hybrid-unverified hybrid row
is not a completed hybrid trial.

Verdict rule:
  Keep overlap when either arm has a timeout, unavailable, or degraded
  row, or when hybrid is keyword-only, tied, or worse on hit@5. Hybrid
  wins only when both arms complete every row, hit@5 is preserved in
  A, B, and C, and reciprocal rank or hit@1/@3 improves.
  This command writes rows and a dated verdict file. It does not switch
  the brief ranker.

Exit codes:
  0  completed run or verdict, including an overlap-preserving result.
  1  failed comparison that could not score the official lanes.
  2  usage or unreadable gold/input.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

USAGE_EXIT = 2
FAIL_EXIT = 1
JSON_DUMP = {"sort_keys": True, "indent": 2}
OFFICIAL_PROBE_COUNT = 13


class UsageError(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


class EvalError(Exception):
    def __init__(self, message):
        Exception.__init__(self, message)
        self.message = message


def dump_json(payload):
    return json.dumps(payload, **JSON_DUMP) + "\n"


def require_abs(label, path):
    if not path or not os.path.isabs(path):
        raise UsageError("%s must be an absolute path" % label)
    return path


def parse_gold(path):
    rows = []
    try:
        handle = open(path, "r", encoding="utf-8")
    except OSError as exc:
        raise UsageError("gold is unreadable: %s" % exc)
    with handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 5:
                raise UsageError("gold row must have five tab fields")
            number, probe_date, dispatched, prior, query = parts
            rows.append(
                {
                    "n": number,
                    "probe_date": probe_date,
                    "dispatched_ids": gold_identities(dispatched),
                    "prior_ids": gold_identities(prior),
                    "query": query,
                }
            )
    if len(rows) != OFFICIAL_PROBE_COUNT:
        raise UsageError("gold must contain exactly %d probes" % OFFICIAL_PROBE_COUNT)
    return rows


def gold_identities(field):
    identities = []
    for item in field.split(","):
        item = item.strip()
        if not item:
            continue
        if item.startswith("decisions/") and item.endswith(".md"):
            item = item[len("decisions/") : -len(".md")]
        identities.append(item)
    return identities


def identities_of(row, mode):
    if mode == "A":
        return row["dispatched_ids"] + row["prior_ids"]
    return list(row["prior_ids"])


def mode_rows(gold, mode):
    if mode == "A":
        return gold
    return [row for row in gold if row["prior_ids"]]


def atomic_write(path, data):
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(data)
    os.replace(tmp, path)


def run_json(argv, timeout_sec, env, arm):
    started = time.monotonic()
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_sec,
            env=env,
            check=False,
        )
    except subprocess.TimeoutExpired:
        elapsed = int((time.monotonic() - started) * 1000)
        return {
            "status": "timeout",
            "identities": [],
            "elapsed_ms": elapsed,
            "mode": "unknown",
            "cache": "off",
            "truncated": False,
        }
    elapsed = int((time.monotonic() - started) * 1000)
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0:
        return {
            "status": "unavailable",
            "identities": [],
            "elapsed_ms": elapsed,
            "mode": "unknown",
            "cache": "off",
            "truncated": False,
            "detail": proc.stderr.decode("utf-8", "replace").strip(),
        }
    try:
        payload = json.loads(text)
    except ValueError:
        return {
            "status": "unavailable",
            "identities": [],
            "elapsed_ms": elapsed,
            "mode": "unknown",
            "cache": "off",
            "truncated": False,
        }
    return normalize_payload(payload, elapsed, arm)


def normalize_payload(payload, elapsed, arm):
    identities = [hit["id"] for hit in payload.get("hits") or []]
    if arm == "overlap":
        mode = "overlap"
    else:
        mode = payload.get("retrieval_mode") or "unknown"
    collapsed = []
    seen = set()
    for ident in identities:
        if ident in seen:
            continue
        seen.add(ident)
        collapsed.append(ident)
    return {
        "status": payload.get("status") or "ok",
        "identities": collapsed,
        "elapsed_ms": payload.get("elapsed_ms", elapsed),
        "mode": mode,
        "cache": payload.get("cache") or "off",
        "truncated": bool(payload.get("truncated")),
        "over_fetch": payload.get("over_fetch"),
    }


def recall_argv(recall_bin, record, query, now):
    env_home = os.path.dirname(record.rstrip("/"))
    argv = [
        recall_bin,
        "--json",
        "--ranker",
        "overlap",
        "--surface",
        "pointers",
        "--title",
        query,
        "--now",
        now,
    ]
    return argv, {
        "FM_HOME": env_home,
        "FM_DATA_OVERRIDE": record,
        "FM_RECALL_TIMEOUT": "5",
    }


def hybrid_argv(hybrid_bin, query, as_of, exclude_ids, now):
    argv = [
        hybrid_bin,
        "--json",
        "--ranker",
        "hybrid",
        "--surface",
        "pointers",
        "--now",
        now,
        "--query",
        query,
    ]
    if as_of:
        argv.extend(["--as-of", as_of])
    for ident in exclude_ids:
        argv.extend(["--exclude-id", ident])
    return argv


def score_identities(identities, expected, status, hybrid_mode, arm):
    degraded = status in ("timeout", "unavailable", "degraded")
    if arm == "hybrid" and hybrid_mode in ("keyword", "hybrid-unverified"):
        degraded = True
        status = "degraded"
    first = 0
    for index, ident in enumerate(identities, start=1):
        if ident in expected:
            first = index
            break
    hits = {
        "hit@1": 1 if first == 1 else 0,
        "hit@3": 1 if 0 < first <= 3 else 0,
        "hit@5": 1 if 0 < first <= 5 else 0,
    }
    reciprocal = 0.0 if first == 0 else 1.0 / float(first)
    available = "degraded" if degraded else "available"
    if status == "timeout":
        available = "degraded"
    return first, hits, reciprocal, available, status


def one_probe(row, mode, now, recall_bin, hybrid_bin, record, deadline_ms):
    expected = identities_of(row, mode)
    exclude = row["dispatched_ids"] if mode in ("B", "C") else []
    as_of = row["probe_date"] if mode == "C" else None
    timeout_sec = max(deadline_ms / 1000.0, 0.05)
    rec_argv, rec_env = recall_argv(recall_bin, record, row["query"], now)
    env = os.environ.copy()
    env.update(rec_env)
    if as_of:
        rec_argv.extend(["--as-of", as_of])
    for ident in exclude:
        rec_argv.extend(["--exclude-id", ident])
    overlap = run_json(rec_argv, timeout_sec, env, "overlap")
    hybrid = run_json(
        hybrid_argv(hybrid_bin, row["query"], as_of, exclude, now),
        timeout_sec,
        env,
        "hybrid",
    )
    rows = []
    for arm, payload in (("overlap", overlap), ("hybrid", hybrid)):
        first, hits, reciprocal, available, status = score_identities(
            payload["identities"], expected, payload["status"], payload["mode"], arm
        )
        rows.append(
            {
                "n": row["n"],
                "mode": mode,
                "arm": arm,
                "query": row["query"],
                "expected": expected,
                "identities": payload["identities"][:10],
                "first_expected_rank": first,
                "hit@1": hits["hit@1"],
                "hit@3": hits["hit@3"],
                "hit@5": hits["hit@5"],
                "reciprocal_rank": reciprocal,
                "elapsed_ms": payload["elapsed_ms"],
                "status": status,
                "available": available,
                "retrieval_mode": payload["mode"],
                "cache": payload["cache"],
                "truncated": payload["truncated"],
                "over_fetch": payload.get("over_fetch"),
            }
        )
    return rows


def summarize(rows):
    summary = {}
    for mode in ("A", "B", "C"):
        for arm in ("overlap", "hybrid"):
            selected = [
                row for row in rows if row["mode"] == mode and row["arm"] == arm
            ]
            count = len(selected) or 1
            complete = all(
                row["available"] == "available" and row["retrieval_mode"] != "keyword"
                for row in selected
            )
            summary["%s.%s" % (mode, arm)] = {
                "n": len(selected),
                "hit@1": sum(row["hit@1"] for row in selected) / float(count),
                "hit@3": sum(row["hit@3"] for row in selected) / float(count),
                "hit@5": sum(row["hit@5"] for row in selected) / float(count),
                "reciprocal_rank": sum(row["reciprocal_rank"] for row in selected)
                / float(count),
                "complete": complete,
            }
    return summary


def decide(summary):
    reasons = []
    for mode in ("A", "B", "C"):
        hybrid = summary["%s.hybrid" % mode]
        overlap = summary["%s.overlap" % mode]
        if not hybrid["complete"]:
            return "overlap", "hybrid %s is incomplete or degraded" % mode
        if not overlap["complete"]:
            return "overlap", "overlap %s is incomplete; no hybrid win" % mode
        if hybrid["hit@5"] < overlap["hit@5"]:
            return "overlap", "hybrid hit@5 regressed in %s" % mode
    improved = False
    tied = True
    for mode in ("A", "B", "C"):
        hybrid = summary["%s.hybrid" % mode]
        overlap = summary["%s.overlap" % mode]
        if (
            hybrid["reciprocal_rank"] > overlap["reciprocal_rank"]
            or hybrid["hit@1"] > overlap["hit@1"]
            or hybrid["hit@3"] > overlap["hit@3"]
        ):
            improved = True
            tied = False
        elif (
            hybrid["reciprocal_rank"] < overlap["reciprocal_rank"]
            or hybrid["hit@1"] < overlap["hit@1"]
            or hybrid["hit@3"] < overlap["hit@3"]
        ):
            tied = False
    if improved and not any(
        summary["%s.hybrid" % mode]["hit@5"] < summary["%s.overlap" % mode]["hit@5"]
        for mode in ("A", "B", "C")
    ):
        return "hybrid", "strict improvement with hit@5 preserved"
    if tied:
        return "overlap", "tie keeps the lower-cost overlap floor"
    reasons.append("hybrid did not strictly improve the official lanes")
    return "overlap", "; ".join(reasons)


def cmd_run(args):
    record = require_abs("--record", args.record)
    gold_path = require_abs("--gold", args.gold)
    recall_bin = require_abs("--recall-bin", args.recall_bin)
    hybrid_bin = args.hybrid_bin or os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-recall.sh")
    )
    hybrid_bin = require_abs("--hybrid-bin", hybrid_bin)
    out_dir = require_abs("--out", args.out)
    if args.deadline_ms <= 0:
        raise UsageError("--deadline-ms must be positive")
    gold = parse_gold(gold_path)
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    for mode in ("A", "B", "C"):
        for row in mode_rows(gold, mode):
            rows.extend(
                one_probe(
                    row,
                    mode,
                    args.now,
                    recall_bin,
                    hybrid_bin,
                    record,
                    args.deadline_ms,
                )
            )
    summary = summarize(rows)
    winner, reason = decide(summary)
    payload = {
        "type": "gbrain-eval-run",
        "run_id": args.run_id or os.path.basename(out_dir.rstrip("/")),
        "now": args.now,
        "gold": gold_path,
        "winner": winner,
        "reason": reason,
        "summary": summary,
        "row_count": len(rows),
    }
    atomic_write(
        os.path.join(out_dir, "rows.jsonl"),
        "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
    )
    atomic_write(os.path.join(out_dir, "summary.json"), dump_json(payload))
    if args.format == "json":
        sys.stdout.write(dump_json(payload))
    else:
        sys.stdout.write("eval %s %s\n" % (winner, reason))
    return 0


def load_summary(run_dir):
    path = os.path.join(run_dir, "summary.json")
    if not os.path.isfile(path):
        raise EvalError("missing summary.json in %s" % run_dir)
    return json.loads(open(path, encoding="utf-8").read())


def cmd_verdict(args):
    day0 = load_summary(require_abs("--day0", args.day0))
    day7 = load_summary(require_abs("--day7", args.day7))
    day14 = load_summary(require_abs("--day14", args.day14))
    winner, reason = decide(day14.get("summary") or {})
    if any(run.get("winner") != "hybrid" for run in (day0, day7, day14)):
        if winner == "hybrid":
            winner, reason = "overlap", "an earlier official run did not support hybrid"
    payload = {
        "type": "gbrain-two-week-verdict",
        "winner": winner,
        "reason": reason,
        "day0": {"run_id": day0.get("run_id"), "winner": day0.get("winner")},
        "day7": {"run_id": day7.get("run_id"), "winner": day7.get("winner")},
        "day14": {"run_id": day14.get("run_id"), "winner": day14.get("winner")},
        "brief_ranker": "overlap",
        "note": "This verdict does not switch the brief. That change is I5.",
    }
    atomic_write(args.out, dump_json(payload))
    if args.format == "json":
        sys.stdout.write(dump_json(payload))
    else:
        sys.stdout.write("verdict %s %s\n" % (winner, reason))
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(__doc__)
        return 0
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command")
    parser.add_argument("--record")
    parser.add_argument("--gold")
    parser.add_argument("--recall-bin")
    parser.add_argument("--hybrid-bin", default="")
    parser.add_argument("--out")
    parser.add_argument("--now", default="2026-09-13")
    parser.add_argument("--deadline-ms", type=int, default=1000)
    parser.add_argument("--run-id")
    parser.add_argument("--day0")
    parser.add_argument("--day7")
    parser.add_argument("--day14")
    parser.add_argument("--format", default="text", choices=("text", "json"))
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return USAGE_EXIT
    try:
        if args.command == "run":
            needed = (
                args.record,
                args.gold,
                args.recall_bin,
                args.out,
            )
            if not all(needed):
                raise UsageError(
                    "run requires --record, --gold, --recall-bin, and --out"
                )
            return cmd_run(args)
        if args.command == "verdict":
            if not args.day0 or not args.day7 or not args.day14 or not args.out:
                raise UsageError("verdict requires --day0, --day7, --day14, and --out")
            return cmd_verdict(args)
        raise UsageError("unknown command; run --help")
    except UsageError as exc:
        sys.stderr.write("gbrain-eval: %s\n" % exc.message)
        return USAGE_EXIT
    except EvalError as exc:
        sys.stderr.write("gbrain-eval: %s\n" % exc.message)
        return FAIL_EXIT
    except OSError as exc:
        sys.stderr.write("gbrain-eval: %s\n" % exc)
        return FAIL_EXIT


if __name__ == "__main__":
    sys.exit(main())
