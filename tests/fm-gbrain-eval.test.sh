#!/usr/bin/env bash
# Behavior tests for bin/fm-gbrain-eval.py through the public executable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVAL="$ROOT/bin/fm-gbrain-eval.py"
RECALL="$ROOT/bin/fm-recall.sh"
GOLD="$ROOT/tests/fixtures/recall/probe-expected.tsv"
TMP_ROOT=$(fm_test_tmproot fm-gbrain-eval)
OUTER_STATUS_BEFORE=$(git -C "$ROOT" status --short --untracked-files=all)
fm_git_identity fmtest fmtest@example.invalid
GOLD_BEFORE=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$GOLD")

FAKE_PID=""
stop_fake_server() {
  if [ -n "$FAKE_PID" ]; then
    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
  fi
  FAKE_PID=""
}
trap 'stop_fake_server; fm_test_cleanup' EXIT

run_e() {
  set +e
  OUT=$(python3 "$EVAL" "$@" 2>&1)
  RC=$?
  set -e
}

seed_probe_corpus() {
  local root=$1
  mkdir -p "$root/data/decisions"
  : > "$root/data/done-archive.md"
  python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]) / "data"
documents = [
    ("ov-kb-feeder", "2026-08-31", "Feeder export engineering review", "The exporter plan connects a feeder to the vault. Atomic writes and push guards protect the destination."),
    ("ov-kb-graphify", "2026-08-31", "Graphify project installation", "The review selects a hook-free shape and records exact install commands."),
    ("ov-kb-agentsmd", "2026-08-31", "Agents md token budget", "The plan covers eviction and the agentsmd backpass gate."),
    ("ov-fm-lock-clear", "2026-08-31", "Session lock clear design", "Same-process replacement can deadlock. Reclaim needs a live ownership check."),
    ("kb-graphify-tv", "2026-08-31", "Graphify hook-free install", "Install the project using the exact commands from the review."),
    ("knowledge-stack-scout", "2026-08-31", "Knowledge stack survey", "Compare graphify installation with a feeder vault exporter and its atomic push guards."),
    ("kb-feeder-vault-ship", "2026-08-31", "Feeder vault exporter", "Ship the export plan with atomic output and push guards."),
    ("fm-lock-clear-reclaim", "2026-08-31", "Session lock reclaim fix", "Clear the replacement deadlock using the accepted design."),
    ("kb-agentsmd-backpass", "2026-08-31", "Agentsmd backpass budget gate", "Apply the token budget and eviction design."),
    ("decisions/agentsmd-budget-2026-08-31", "2026-08-31", "Agentsmd budget decision", "The backpass gate checks the token budget before accepting instructions."),
    ("fm-fork-value-audit", "2026-09-01", "Fork material value audit", "Keep useful fork-only material and drop redundant code before the upstream merge. The drop set includes pr-check migration, f13 measure, spec-compile, and f4 ladder."),
    ("fm-refuse-hooks-audit", "2026-09-01", "Fork hook value audit", "Determine which fork-only material to keep or drop before the upstream merge."),
    ("ov-merge-slices", "2026-09-01", "Upstream merge slice plan", "The engineering review assigns risk tiers to each slice."),
    ("fm-drop-prcheck-migrate", "2026-09-02", "Fork drop pr-check migration", "Execute the approved drop set and migrate the check."),
    ("fm-drop-f13-measure-gate", "2026-09-02", "Fork drop f13 measure gate", "Execute the approved drop set and remove the measure gate."),
    ("fm-drop-spec-compile-trio", "2026-09-02", "Fork drop spec-compile trio", "Execute the approved drop set for the compilation tools."),
    ("fm-drop-f4-stop-ladder", "2026-09-02", "Fork drop f4 stop ladder", "Execute the approved drop set for the stopping path."),
    ("decisions/fm-fork-drop-set-2026-09-01", "2026-09-01", "Fork drop set decision", "Approve pr-check migration, f13 measure removal, the spec-compile trio, and the f4 ladder removal."),
    ("ov-s3-refresh", "2026-09-03", "Slice 3 delivery refresh", "The delivery plan still governs after session death and covers the exact-sync merge-local path."),
    ("ov-s3-s6-plan", "2026-09-03", "Slice 3 delivery plan", "This plan governs delivery after session death. Use exact-sync and merge-local for the staged merge."),
    ("ov-s3-pointer", "2026-09-03", "Slice 3 plan pointer", "Keep the governing delivery plan accessible after session death."),
    ("fm-merge-slice-3", "2026-09-03", "Slice 3 delivery merge", "Run the exact-sync and merge-local delivery steps."),
]
for name, date, title, body in documents:
    decision = name.startswith("decisions/")
    path = root / (name + ".md") if decision else root / name / "report.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    status = "decided" if decision else "reported"
    path.write_text("# %s\ndate: %s\nstatus: %s\n%s\n" % (title, date, status, body), encoding="utf-8")
PY
}

write_recall_wrap() {
  local dest=$1
  cat > "$dest" <<SH
#!/usr/bin/env bash
if [ -n "\${RECALL_ARGV:-}" ]; then
  printf '%s\\n' "\$*" >> "\$RECALL_ARGV"
fi
if [ -n "\${RECALL_SLEEP:-}" ]; then
  sleep "\$RECALL_SLEEP"
fi
exec "$RECALL" "\$@"
SH
  chmod +x "$dest"
}

write_hybrid() {
  local dest=$1
  cat > "$dest" <<'SH'
#!/usr/bin/env bash
if [ -n "${HYBRID_ARGV:-}" ]; then
  printf '%s\n' "$*" >> "$HYBRID_ARGV"
fi
python3 - "$@" <<'PY'
import json, os, sys
argv = sys.argv
query = ""
as_of = ""
exclude = []
ranker = ""
i = 0
while i < len(argv):
    if argv[i] in ("--query", "--title") and i + 1 < len(argv):
        query = argv[i + 1]
        i += 2
        continue
    if argv[i] == "--as-of" and i + 1 < len(argv):
        as_of = argv[i + 1]
        i += 2
        continue
    if argv[i] == "--exclude-id" and i + 1 < len(argv):
        exclude.append(argv[i + 1])
        i += 2
        continue
    if argv[i] == "--ranker" and i + 1 < len(argv):
        ranker = argv[i + 1]
        i += 2
        continue
    i += 1
mode = os.environ.get("HYBRID_MODE", "hybrid")
status = os.environ.get("HYBRID_STATUS", "ok")
if os.environ.get("HYBRID_TIMEOUT_QUERY") and os.environ["HYBRID_TIMEOUT_QUERY"] in query:
    status = "timeout"
    identities = []
else:
    identities = [
        "ov-kb-graphify",
        "ov-kb-graphify",
        "knowledge-stack-scout",
        "kb-graphify-tv",
    ]
print(json.dumps({
    "status": status,
    "retrieval_mode": mode,
    "ranker": "gbrain-%s+term-overlap-3-1" % mode if mode in ("hybrid", "keyword") else "term-overlap-3-1",
    "identities": identities,
    "hits": [{"id": ident} for ident in identities],
    "elapsed_ms": 12,
    "cache": "off",
    "as_of": as_of,
    "exclude": exclude,
    "query": query,
    "ranker_flag": ranker,
}))
PY
SH
  chmod +x "$dest"
}

test_help_and_gold_shape() {
  run_e --help
  expect_code 0 "$RC" 'help'
  assert_contains "$OUT" 'fm-gbrain-eval.py run' 'help names run'
  run_e run --record "$TMP_ROOT" --gold "$TMP_ROOT/bad.tsv" --recall-bin "$RECALL" \
    --hybrid-bin "$RECALL" --out "$TMP_ROOT/out"
  expect_code 2 "$RC" 'missing gold'
  printf '1\t2026-01-01\t\t\tonly one\n' > "$TMP_ROOT/short.tsv"
  run_e run --record "$TMP_ROOT" --gold "$TMP_ROOT/short.tsv" --recall-bin "$RECALL" \
    --hybrid-bin "$RECALL" --out "$TMP_ROOT/out"
  expect_code 2 "$RC" 'short gold'
  pass 'fm-gbrain-eval: help works and gold must be the 13-probe table'
}

test_official_lanes_call_shipped_recall() {
  local home wrap hybrid out
  home="$TMP_ROOT/lanes/home"
  seed_probe_corpus "$home"
  wrap="$TMP_ROOT/lanes/recall"
  hybrid="$TMP_ROOT/lanes/hybrid"
  out="$TMP_ROOT/lanes/out"
  write_recall_wrap "$wrap"
  write_hybrid "$hybrid"
  mkdir -p "$out"
  RECALL_ARGV="$TMP_ROOT/lanes/recall.argv" HYBRID_ARGV="$TMP_ROOT/lanes/hybrid.argv" \
    run_e run --record "$home/data" --gold "$GOLD" --recall-bin "$wrap" \
    --hybrid-bin "$hybrid" --out "$out" --now 2026-09-13 --deadline-ms 4000 --format json
  expect_code 0 "$RC" 'eval run'
  python3 - "$out/summary.json" "$TMP_ROOT/lanes/recall.argv" "$TMP_ROOT/lanes/hybrid.argv" "$out/rows.jsonl" <<'PY' || fail "eval lanes were wrong"
import json,sys
summary=json.load(open(sys.argv[1]))
assert summary["row_count"] > 0
recall=open(sys.argv[2]).read()
hybrid=open(sys.argv[3]).read()
assert "--title" in recall
assert "--exclude-id" in recall
assert "--as-of" in recall
assert "--as-of" in hybrid
assert "--exclude-id" in hybrid
assert "--ranker hybrid" in hybrid or "--ranker\nhybrid" in hybrid.replace(" ", "\n")
assert "--query" in hybrid or "--title" in hybrid
rows=[json.loads(line) for line in open(sys.argv[4]) if line.strip()]
assert set(row["retrieval_mode"] for row in rows if row["arm"]=="overlap")=={"overlap"}, "overlap retrieval_mode drifted"
assert set(row["retrieval_mode"] for row in rows if row["arm"]=="hybrid")=={"hybrid"}, "hybrid retrieval_mode drifted"
dups=[row for row in rows if row["arm"]=="hybrid" and row["identities"].count("ov-kb-graphify")>1]
assert not dups, "duplicate chunks were not collapsed"
timeouts=[row for row in rows if row["status"]=="timeout"]
# no timeout in this run
assert summary["winner"] in ("overlap","hybrid")
# Gold lists decision priors as decisions/<slug>.md; recall returns the bare slug.
# Probes 8 and 11 must score their decision prior as a hit on the overlap arm.
decision_rows=[row for row in rows if row["arm"]=="overlap" and row["mode"] in ("B","C") and str(row["n"]) in ("8","11")]
assert len(decision_rows)==4, decision_rows
for row in decision_rows:
    assert row["status"]=="ok", row
    assert not any(e.startswith("decisions/") or e.endswith(".md") for e in row["expected"]), row
    assert row["hit@5"]==1, "decision prior not scored as a hit: %r" % row
PY
  GOLD_AFTER=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$GOLD")
  [ "$GOLD_AFTER" = "$GOLD_BEFORE" ] || fail 'gold file changed'
  pass 'fm-gbrain-eval: official lanes call shipped recall and collapse chunks'
}

test_timeout_and_keyword_do_not_win() {
  local home wrap hybrid out
  home="$TMP_ROOT/deg/home"
  seed_probe_corpus "$home"
  wrap="$TMP_ROOT/deg/recall"
  hybrid="$TMP_ROOT/deg/hybrid"
  out="$TMP_ROOT/deg/out"
  write_recall_wrap "$wrap"
  write_hybrid "$hybrid"
  HYBRID_MODE=keyword HYBRID_STATUS=ok \
    run_e run --record "$home/data" --gold "$GOLD" --recall-bin "$wrap" \
    --hybrid-bin "$hybrid" --out "$out" --now 2026-09-13 --deadline-ms 4000 --format json
  expect_code 0 "$RC" 'keyword run'
  printf '%s\n' "$OUT" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["winner"]=="overlap", p
assert "incomplete" in p["reason"] or "degraded" in p["reason"], p
' || fail "keyword hybrid won: $OUT"
  out2="$TMP_ROOT/deg/out-timeout"
  HYBRID_TIMEOUT_QUERY="feeder export plan" \
    run_e run --record "$home/data" --gold "$GOLD" --recall-bin "$wrap" \
    --hybrid-bin "$hybrid" --out "$out2" --now 2026-09-13 --deadline-ms 4000 --format json
  expect_code 0 "$RC" 'timeout run'
  python3 - "$out2/rows.jsonl" "$out2/summary.json" <<'PY' || fail "timeout was dropped"
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
timeouts=[row for row in rows if row["status"]=="timeout"]
assert timeouts, "timeout row missing"
summary=json.load(open(sys.argv[2]))
assert summary["winner"]=="overlap"
assert summary["summary"]["A.hybrid"]["n"]>=1
PY
  out3="$TMP_ROOT/deg/out-overlap-timeout"
  RECALL_SLEEP=2 \
    run_e run --record "$home/data" --gold "$GOLD" --recall-bin "$wrap" \
    --hybrid-bin "$hybrid" --out "$out3" --now 2026-09-13 --deadline-ms 400 --format json
  expect_code 0 "$RC" 'overlap timeout run'
  python3 - "$out3/rows.jsonl" "$out3/summary.json" <<'PY' || fail "overlap timeouts produced a hybrid win"
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
overlap=[row for row in rows if row["arm"]=="overlap"]
assert overlap and all(row["status"]=="timeout" for row in overlap), overlap[:2]
hybrid=[row for row in rows if row["arm"]=="hybrid"]
assert all(row["status"]=="ok" for row in hybrid), hybrid[:2]
summary=json.load(open(sys.argv[2]))
assert summary["summary"]["A.hybrid"]["hit@5"] > summary["summary"]["A.overlap"]["hit@5"], summary["summary"]
assert summary["summary"]["A.overlap"]["complete"] is False, summary["summary"]
assert summary["winner"]=="overlap", summary
assert "overlap" in summary["reason"] and "incomplete" in summary["reason"], summary
PY
  pass 'fm-gbrain-eval: keyword and timeout rows keep overlap'
}

test_verdict_keeps_overlap_on_regression() {
  local d0 d7 d14
  d0="$TMP_ROOT/verdict/day0"
  d7="$TMP_ROOT/verdict/day7"
  d14="$TMP_ROOT/verdict/day14"
  mkdir -p "$d0" "$d7" "$d14"
  python3 - "$d0" "$d7" "$d14" <<'PY'
import json,sys
def summary(hit5_h, hit5_o, mrr_h, mrr_o, complete=True):
    block={}
    for mode in "A","B","C":
        block["%s.overlap"%mode]={"n":8,"hit@1":0.5,"hit@3":0.5,"hit@5":hit5_o,"reciprocal_rank":mrr_o,"complete":True}
        block["%s.hybrid"%mode]={"n":8,"hit@1":0.9,"hit@3":0.9,"hit@5":hit5_h,"reciprocal_rank":mrr_h,"complete":complete}
    return block
for path, hit5_h, winner in (
    (sys.argv[1], 1.0, "hybrid"),
    (sys.argv[2], 1.0, "hybrid"),
    (sys.argv[3], 0.2, "overlap"),
):
    payload={"type":"gbrain-eval-run","run_id":path,"winner":winner,"reason":"fixture",
             "summary":summary(hit5_h, 0.8, 0.9, 0.4)}
    json.dump(payload, open(path+"/summary.json","w"), indent=2, sort_keys=True)
PY
  run_e verdict --day0 "$d0" --day7 "$d7" --day14 "$d14" --out "$TMP_ROOT/verdict/out.json" --format json
  expect_code 0 "$RC" 'verdict'
  printf '%s\n' "$OUT" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["winner"]=="overlap", p
assert p["brief_ranker"]=="overlap", p
assert "I5" in p["note"]
' || fail "verdict switched the brief: $OUT"
  pass 'fm-gbrain-eval: hit@5 regression and I5 note keep overlap'
}

test_outer_repository_stays_clean() {
  local after
  after=$(git -C "$ROOT" status --short --untracked-files=all)
  [ "$after" = "$OUTER_STATUS_BEFORE" ] \
    || fail "fixtures changed the outer repository"$'\n'"before: $OUTER_STATUS_BEFORE"$'\n'"after: $after"
  GOLD_AFTER=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$GOLD")
  [ "$GOLD_AFTER" = "$GOLD_BEFORE" ] || fail 'gold file changed'
  pass 'fm-gbrain-eval: fixtures leave the outer repository and gold file unchanged'
}

test_real_recall_refused_and_keyword() {
  local home wrap out dir token
  home="$TMP_ROOT/real/home"
  seed_probe_corpus "$home"
  wrap="$TMP_ROOT/real/recall"
  write_recall_wrap "$wrap"
  token="$home/config/gbrain-recall.token"
  mkdir -p "$home/config"
  printf '%s\n' 'tok-t17b-throwaway-never-print' > "$token"
  out="$TMP_ROOT/real/out-refused"
  GBRAIN_RECALL=on GBRAIN_RECALL_TOKEN_FILE="$token" \
    GBRAIN_RECALL_URL="http://127.0.0.1:1/mcp" \
    run_e run --record "$home/data" --gold "$GOLD" --recall-bin "$wrap" \
    --hybrid-bin "$RECALL" --out "$out" --now 2026-09-13 --deadline-ms 4000 --format json
  expect_code 0 "$RC" 'refused hybrid'
  python3 - "$out/rows.jsonl" "$out/summary.json" <<'PY' || fail "refused serve did not keep overlap"
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
hybrid=[row for row in rows if row["arm"]=="hybrid"]
overlap=[row for row in rows if row["arm"]=="overlap"]
assert hybrid and all(row["status"]=="unavailable" for row in hybrid), hybrid[:2]
assert overlap and all(row["status"] in ("ok","empty") for row in overlap), overlap[:2]
summary=json.load(open(sys.argv[2]))
assert summary["winner"]=="overlap"
assert "incomplete" in summary["reason"] or "degraded" in summary["reason"]
PY
  dir="$TMP_ROOT/real/fake"
  mkdir -p "$dir"
  python3 - "$dir/body" <<'PY'
import json, sys
payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "structuredContent": {
            "results": [{"slug": "data/ov-kb-graphify/report", "keyword_relaxed": True}]
        },
        "_meta": {"retrieval": {"vector_enabled": False, "degraded": [{"stage": "embed_unavailable"}]}},
    },
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(payload))
PY
  python3 - "$dir" <<'PY' &
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
root = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        body = open(os.path.join(root, "body"), encoding="utf-8").read().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_a):
        return
s = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(root, "port"), "w", encoding="utf-8").write(str(s.server_address[1]))
s.serve_forever()
PY
  FAKE_PID=$!
  i=0
  while [ ! -f "$dir/port" ]; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || fail "eval fake server did not bind"
    sleep 0.05
  done
  out2="$TMP_ROOT/real/out-keyword"
  GBRAIN_RECALL=on GBRAIN_RECALL_TOKEN_FILE="$token" \
    GBRAIN_RECALL_URL="http://127.0.0.1:$(cat "$dir/port")/mcp" \
    run_e run --record "$home/data" --gold "$GOLD" --recall-bin "$wrap" \
    --hybrid-bin "$RECALL" --out "$out2" --now 2026-09-13 --deadline-ms 4000 --format json
  expect_code 0 "$RC" 'keyword hybrid'
  python3 - "$out2/rows.jsonl" "$out2/summary.json" <<'PY' || fail "keyword hybrid did not degrade"
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]
hybrid=[row for row in rows if row["arm"]=="hybrid"]
assert hybrid and all(row["retrieval_mode"]=="keyword" for row in hybrid), hybrid[:2]
assert all(row["available"]=="degraded" for row in hybrid), hybrid[:2]
summary=json.load(open(sys.argv[2]))
assert summary["winner"]=="overlap"
PY
  stop_fake_server
  pass 'fm-gbrain-eval: refused serve and keyword signal keep overlap'
}

test_help_and_gold_shape
test_official_lanes_call_shipped_recall
test_timeout_and_keyword_do_not_win
test_verdict_keeps_overlap_on_regression
test_real_recall_refused_and_keyword
test_outer_repository_stays_clean
