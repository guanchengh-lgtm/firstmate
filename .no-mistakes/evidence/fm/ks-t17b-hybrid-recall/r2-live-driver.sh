#!/usr/bin/env bash
# Round 2 live driver: real bin/fm-recall.sh, fm-brief.sh, fm-gbrain-eval.py and
# fm-session-start.sh against a fake loopback gbrain serve. Throwaway token only.
set -u
ROOT=$1
RECALL="$ROOT/bin/fm-recall.sh"
TOKEN='tok-r2-throwaway-never-print'
W=$(mktemp -d /tmp/nm-t17b-r2.XXXXXX)
PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done; rm -rf "$W"' EXIT
ALL="$W/all-output.txt"; : > "$ALL"

serve() { # <dir> ; reads <dir>/body, <dir>/mode ; writes port, recv
  local dir=$1
  mkdir -p "$dir"; : > "$dir/recv"
  python3 - "$dir" <<'PY' &
import json, os, sys, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = sys.argv[1]
def mode():
    try: return open(os.path.join(root, "mode")).read().strip()
    except OSError: return "ok"
class H(BaseHTTPRequestHandler):
    def _log(self, body=b""):
        rec = {"verb": self.command, "path": self.path,
               "auth": self.headers.get("Authorization") or "",
               "body": body.decode("utf-8", "replace")}
        with open(os.path.join(root, "recv"), "a") as h: h.write(json.dumps(rec) + "\n")
    def do_GET(self):
        self._log(); self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._log(body)
        m = mode()
        if m == "redirect":
            self.send_response(307); self.send_header("Location", "http://127.0.0.1:%d/followed" % self.server.server_address[1])
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if m == "hang":
            import time; time.sleep(3)
        data = open(os.path.join(root, "body")).read().encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *_a): return
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(root, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  PIDS+=($!)
  local i=0
  while [ ! -f "$dir/port" ]; do i=$((i+1)); [ "$i" -lt 100 ] || { echo "serve did not bind"; exit 9; }; sleep 0.05; done
}

body() { # <file> <keyword:0|1> slug...
  python3 - "$@" <<'PY'
import json, sys
out, kw, slugs = sys.argv[1], sys.argv[2] == "1", sys.argv[3:]
rows = [{"slug": s, **({"keyword_relaxed": True} if kw else {})} for s in slugs]
meta = {"vector_enabled": False, "degraded": [{"stage": "embed_unavailable"}]} if kw else {"vector_enabled": True}
json.dump({"jsonrpc": "2.0", "id": 1, "result": {"structuredContent": {"results": rows}, "_meta": {"retrieval": meta}}}, open(out, "w"))
PY
}

report() { # <home> <id> <title>
  mkdir -p "$1/data/$2"
  printf '# %s\ndate: 2026-09-01\nstatus: reported\n%s body text.\n' "$3" "$3" > "$1/data/$2/report.md"
}

show() { # <json> <err> <rc>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
print("exit=%s" % sys.argv[3])
raw = open(sys.argv[1]).read()
try: p = json.loads(raw)
except ValueError:
    print("stdout (not JSON):", raw[:300]); p = None
if p:
    for k in ("status", "ranker", "retrieval_mode", "item_retrieval_modes", "hybrid_resolved", "identities", "diagnostics"):
        if k in p: print("%s: %s" % (k, p[k]))
err = open(sys.argv[2]).read().strip()
if err: print("stderr:", err[:400])
if "Traceback" in err: print("!!! TRACEBACK")
PY
}

run() { # <label> <home> args...
  local label=$1 home=$2; shift 2
  echo; echo "=== $label"
  echo "\$ fm-recall.sh --json --now 2026-09-06 $*" | sed "s#$W#<tmp>#g"
  local rc=0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_RECALL_TIMEOUT=5 \
    "$RECALL" --json --now 2026-09-06 "$@" > "$W/o.json" 2> "$W/o.err" || rc=$?
  cat "$W/o.json" "$W/o.err" >> "$ALL"
  show "$W/o.json" "$W/o.err" "$rc"
}
posts() { grep -c '"verb": "POST"' "$1/recv" || true; }

# ---------------------------------------------------------------- recall
H="$W/home"; mkdir -p "$H/config"
report "$H" alpha "Sprocket widget"; report "$H" beta "Sprocket gadget"; report "$H" delta "Sprocket lathe"
printf '%s\n' "$TOKEN" > "$H/config/gbrain-recall.token"
S="$W/serve"; mkdir -p "$S"; body "$S/body" 0 data/delta/report data/beta/report data/not-in-record/report
serve "$S"; PORT=$(cat "$S/port")

run "R1 switch absent (shipped default): auto stays overlap, no socket" "$H" --title sprocket --surface pointers --recall-url "http://127.0.0.1:$PORT/mcp"
echo "POSTs seen by serve: $(posts "$S")"

printf 'GBRAIN_PORT=%s\nGBRAIN_RECALL=on' "$PORT" > "$H/config/gbrain.env"
run "R2 gbrain.env switch on, LAST LINE WITHOUT NEWLINE (E2): hybrid-first, overlap fill, unknown slug dropped" "$H" --title sprocket --surface pointers
echo "POSTs seen by serve: $(posts "$S")"
python3 - "$S/recv" "$TOKEN" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r = recs[-1]; b = json.loads(r["body"])
print("wire: %s %s | method: %s | tool: %s | arguments: %s" % (r["verb"], r["path"], b.get("method"), b["params"]["name"], sorted(b["params"]["arguments"])))
print("bearer header equals token file value:", r["auth"] == "Bearer " + sys.argv[2])
print("token inside body or path:", sys.argv[2] in r["body"] + r["path"])
print("non-POST calls (GET /health etc.):", sum(1 for x in recs if x["verb"] != "POST"))
PY

printf 'GBRAIN_PORT=%s\r\nGBRAIN_RECALL=on \r\n' "$PORT" > "$H/config/gbrain.env"
run "R2b gbrain.env with CRLF and trailing space on the value (E2)" "$H" --title sprocket --surface pointers

printf 'GBRAIN_PORT=%s\nGBRAIN_RECALL=on\n' "$PORT" > "$H/config/gbrain.env"
before=$(posts "$S")
run "R3 --ranker overlap with switch on: never opens a socket" "$H" --title sprocket --surface pointers --ranker overlap
echo "new POSTs: $(( $(posts "$S") - before ))"

run "R4 brief surface with switch on: same heading, caps, pointer shape" "$H" --title sprocket --surface brief
python3 - "$W/o.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); print("pointer_count=%s estimated_tokens=%s" % (p.get("pointer_count"), p.get("estimated_tokens"))); print(p["rendered"])
PY

body "$S/body" 1 data/delta/report
run "R5 keyword-degraded serve: mode keyword" "$H" --title sprocket --surface pointers
body "$S/body" 0 data/delta/report data/beta/report data/not-in-record/report

run "R6a serve down (closed port), auto keeps overlap" "$H" --title sprocket --surface pointers --recall-url http://127.0.0.1:1/mcp
run "R6b serve down, --ranker hybrid never falls back" "$H" --title sprocket --surface pointers --ranker hybrid --recall-url http://127.0.0.1:1/mcp
echo hang > "$S/mode"
run "R6c serve hangs 3 s, hybrid budget 150 ms: overlap kept inside deadline" "$H" --title sprocket --surface pointers --hybrid-ms 150
echo ok > "$S/mode"

before=$(posts "$S")
run "A1 adversarial: non-loopback URL, token must not leave loopback" "$H" --title sprocket --surface pointers --recall-url http://192.0.2.1:9/mcp
echo redirect > "$S/mode"
run "A2 adversarial: loopback serve answers 307 redirect" "$H" --title sprocket --surface pointers
echo "requests that followed the redirect: $(grep -c '/followed' "$S/recv" || true)"
echo ok > "$S/mode"
run "A3 adversarial: out-of-range port" "$H" --title sprocket --surface pointers --recall-url http://127.0.0.1:99999/mcp
run "A4 adversarial: non-numeric port" "$H" --title sprocket --surface pointers --recall-url http://127.0.0.1:abc/mcp
printf '\xff\xfe\xfa' > "$W/bad.token"
run "A5 adversarial: token file is not UTF-8" "$H" --title sprocket --surface pointers --token-file "$W/bad.token"
run "A6 adversarial: token file missing" "$H" --title sprocket --surface pointers --token-file "$W/none.token"
printf '{"jsonrpc":"2.0","id":1,"result":{"results":[{"slug":"data/delta/report"}]}}' > "$S/body"
run "A7 adversarial: dropped legacy shape result.results is bad-shape" "$H" --title sprocket --surface pointers
printf '[{"slug":"data/delta/report"}]' > "$S/body"
run "A8 adversarial: bare list payload is bad-shape" "$H" --title sprocket --surface pointers
body "$S/body" 0 data/delta/report data/beta/report data/not-in-record/report
python3 - "$W/raw.port" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept(); c.recv(65536); c.sendall(b"NOT-HTTP garbage\r\n\r\n"); c.close()
PY
PIDS+=($!); while [ ! -s "$W/raw.port" ]; do sleep 0.05; done
run "A9 adversarial: listener answers non-HTTP bytes" "$H" --title sprocket --surface pointers --recall-url "http://127.0.0.1:$(cat "$W/raw.port")/mcp"
run "A10 adversarial: invalid --ranker value is refused" "$H" --title sprocket --surface pointers --ranker bogus

python3 -c 'import json,sys; json.dump([{"id":"q%d"%n,"title":"sprocket"} for n in range(5)], open(sys.argv[1],"w"))' "$W/batch.json"
echo; echo "(R7 uses the default 750 ms deadline and 1 s shell timeout: FM_RECALL_TIMEOUT unset)"
echo "=== R7 five-item session batch, default 750 ms / 1 s bounds"
rc=0; FM_HOME="$H" FM_DATA_OVERRIDE="$H/data" "$RECALL" --json --now 2026-09-06 --session-batch "$W/batch.json" --surface brief > "$W/o.json" 2> "$W/o.err" || rc=$?
cat "$W/o.json" "$W/o.err" >> "$ALL"; show "$W/o.json" "$W/o.err" "$rc"

python3 -c 'import json,sys; json.dump([{"id":"a","title":"sprocket"},{"id":"b","title":"sprocket slowpoke"}], open(sys.argv[1],"w"))' "$W/batch2.json"
echo; echo "=== R8 mixed session batch: serve down for all queries -> receipt mode must not say hybrid"
rc=0; FM_HOME="$H" FM_DATA_OVERRIDE="$H/data" FM_RECALL_TIMEOUT=5 "$RECALL" --json --now 2026-09-06 --session-batch "$W/batch2.json" --surface brief --recall-url http://127.0.0.1:1/mcp > "$W/o.json" 2> "$W/o.err" || rc=$?
cat "$W/o.json" "$W/o.err" >> "$ALL"; show "$W/o.json" "$W/o.err" "$rc"

# ---------------------------------------------------------------- brief
echo; echo "################ fm-brief.sh"
B="$W/bhome"; mkdir -p "$B/config"
printf '7500\n' > "$B/config/startup-memory-budget"
for t in "alpha-prior|Widget sprocket plan" "beta-prior|Widget sprocket notes" "zeta-prior|Widget sprocket lathe"; do report "$B" "${t%%|*}" "${t##*|}"; done
printf '# Task\nImplement the widget sprocket plan from prior work.\n' > "$B/task.md"
printf '%s\n' "$TOKEN" > "$B/config/gbrain-recall.token"
SB="$W/bserve"; mkdir -p "$SB"; body "$SB/body" 0 data/zeta-prior/report; serve "$SB"
brief() { # <id>
  local rc=0
  FM_HOME="$B" FM_RECALL_TIMEOUT=5 "$ROOT/bin/fm-brief.sh" "$1" firstmate --mode no-mistakes --task-file "$B/task.md" > "$W/b.out" 2>&1 || rc=$?
  cat "$W/b.out" >> "$ALL"; echo "exit=$rc"
  awk '/^# Recalled pointers$/{f=1} f&&/^- /{print} f&&/^$/{exit}' "$B/data/$1/brief.md"
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print("receipt:", {k:p.get(k) for k in ("ranker","retrieval_mode")})' "$B/data/$1/recall.json"
  cat "$B/data/$1/brief.md" "$B/data/$1/recall.json" >> "$ALL"
}
echo "=== B1 brief, switch absent"; brief brief-off; echo "POSTs: $(posts "$SB")"
printf 'GBRAIN_RECALL=on\nGBRAIN_PORT=%s' "$(cat "$SB/port")" > "$B/config/gbrain.env"
echo "=== B2 brief, switch on in gbrain.env, serve ranks zeta first"; brief brief-on; echo "POSTs: $(posts "$SB")"

# ---------------------------------------------------------------- eval
echo; echo "################ fm-gbrain-eval.py (E1: overlap arm pinned with home switch ON)"
EH="$W/ehome"; mkdir -p "$EH/config"
( set +u; ROOT_FOR_SEED=$ROOT; eval "$(awk '/^seed_probe_corpus\(\)/,/^}/' "$ROOT/tests/fm-gbrain-eval.test.sh")"; seed_probe_corpus "$EH" )
printf '%s\n' "$TOKEN" > "$EH/config/gbrain-recall.token"
SE="$W/eserve"; mkdir -p "$SE"; body "$SE/body" 0 data/ov-kb-graphify/report; serve "$SE"
printf 'GBRAIN_RECALL=on\nGBRAIN_PORT=%s\n' "$(cat "$SE/port")" > "$EH/config/gbrain.env"
cat > "$W/wrap" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/wrap.argv"
exec "$RECALL" "\$@"
SH
chmod +x "$W/wrap"
rc=0
env -u GBRAIN_RECALL -u GBRAIN_RECALL_URL -u FM_RECALL_RANKER python3 "$ROOT/bin/fm-gbrain-eval.py" run --record "$EH/data" \
  --gold "$ROOT/tests/fixtures/recall/probe-expected.tsv" --recall-bin "$W/wrap" --hybrid-bin "$W/wrap" \
  --out "$W/eout" --now 2026-09-13 --deadline-ms 4000 --format json > "$W/e.out" 2> "$W/e.err" || rc=$?
echo "exit=$rc"
cat "$W/e.out" "$W/e.err" "$W/eout/rows.jsonl" "$W/eout/summary.json" "$W/wrap.argv" >> "$ALL" 2>/dev/null
python3 - "$W/eout" "$W/wrap.argv" <<'PY'
import collections, json, sys
rows = [json.loads(l) for l in open(sys.argv[1] + "/rows.jsonl") if l.strip()]
c = collections.Counter((r["arm"], r.get("retrieval_mode"), r["status"]) for r in rows)
for k, v in sorted(c.items()): print("rows arm=%s retrieval_mode=%s status=%s: %d" % (k + (v,)))
argv = [l for l in open(sys.argv[2]) if l.strip()]
print("recall calls with --ranker overlap: %d | with --ranker hybrid: %d | with neither: %d" % (
    sum("--ranker overlap" in a for a in argv), sum("--ranker hybrid" in a for a in argv),
    sum("--ranker" not in a for a in argv)))
s = json.load(open(sys.argv[1] + "/summary.json")); print("summary winner: %s | reason: %s" % (s["winner"], s["reason"]))
PY
echo "POSTs the serve received: $(posts "$SE")  (must equal the hybrid-arm call count; overlap arm posts nothing)"

# ---------------------------------------------------------------- session start
echo; echo "################ fm-session-start.sh (real script, fake harness toolchain from the test helpers)"
(
  set +u
  T="$ROOT/tests/fm-session-start.test.sh"
  . "$ROOT/tests/lib.sh"; . "$ROOT/tests/wake-helpers.sh"
  ROOT_KEEP=$ROOT
  SESSION_START="$ROOT/bin/fm-session-start.sh"; BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
  TMP_ROOT="$W/ss"; mkdir -p "$TMP_ROOT"; SESSION_START_TEST_HARNESS_PID=$$
  for fn in new_world make_fake_toolchain make_fake_ps_harness make_fake_ps_claude run_named_harness_session_start seed_session_recall_world; do
    eval "$(awk -v f="$fn" '$0 ~ "^"f"\\(\\)",/^}/' "$T")"
  done
  trap - EXIT
  for sw in off on; do
    rec=$(new_world "live-$sw"); IFS='|' read -r root home fakebin <<<"$rec"
    make_fake_toolchain "$fakebin"; make_fake_ps_claude "$fakebin"; seed_session_recall_world "$home"
    report "$home" later-widget "Unique widget sprocket recall token lathe"
    printf '%s\n' "$TOKEN" > "$home/config/gbrain-recall.token"
    SS="$W/ssserve-$sw"; mkdir -p "$SS"; body "$SS/body" 0 data/later-widget/report
    echo "=== SS-$sw session start, home switch $sw"
    if [ "$sw" = on ]; then
      python3 - "$SS" <<'PY' &
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
root = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        open(os.path.join(root, "recv"), "a").write('{"verb": "POST"}\n')
        d = open(os.path.join(root, "body")).read().encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def log_message(self, *_a): return
s = ThreadingHTTPServer(("127.0.0.1", 0), H); open(os.path.join(root, "port"), "w").write(str(s.server_address[1])); s.serve_forever()
PY
      spid=$!
      while [ ! -f "$SS/port" ]; do sleep 0.05; done
      printf 'GBRAIN_RECALL=on\nGBRAIN_PORT=%s\n' "$(cat "$SS/port")" > "$home/config/gbrain.env"
    fi
    out=$(run_named_harness_session_start claude "$home" "$root" "$fakebin:$BASE_PATH" 2> "$home/stderr"); rc=$?
    echo "exit=$rc stderr_bytes=$(wc -c < "$home/stderr" | tr -d ' ')"
    printf '%s\n' "$out" | awk '/^RECALLED POINTERS$/{f=1}/^NEXT STEP$/{f=0}f'
    python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print("receipt:", {k:p.get(k) for k in ("surface","selected_item_count","ranker","retrieval_mode")})' "$home/state/.session-recall-receipt.$(cat "$home/state/.lock").json"
    [ "$sw" = on ] && { echo "POSTs: $(grep -c POST "$SS/recv" 2>/dev/null || echo 0)"; kill "$spid" 2>/dev/null; }
    { printf '%s\n' "$out"; cat "$home/stderr" "$home"/state/.session-recall-receipt.*.json; } >> "$ALL"
  done
)

echo; echo "=== token leak check over every stdout, stderr, brief, receipt, eval row and recorded argv"
echo "token occurrences: $(grep -c -F "$TOKEN" "$ALL" || true)"
