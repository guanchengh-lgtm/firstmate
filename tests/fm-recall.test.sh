#!/usr/bin/env bash
# Behavior tests for bin/fm-recall.sh and the public JSON/pointer contract.
#
# Coverage:
#   - valid ranking, empty queries, missing sources, aliases, equal-score
#     ordering, freshness display, held/parked exemption, long titles, and
#     bounded unavailable outcomes
#   - the fixed 13-probe harness over a sanitized synthetic corpus
#   - a corrupted expectation file exits non-zero
# Private captain report bodies are never copied into this fixture.
# Mode B top-three on the private corpus is 7/8 after the age tie-break was
# removed; this harness records that loss and asserts the locked floors only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECALL="$ROOT/bin/fm-recall.sh"
PROBE_TSV="$ROOT/tests/fixtures/recall/probe-expected.tsv"
TMP_ROOT=$(fm_test_tmproot fm-recall)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
FAKE_PIDS=()
stop_fake_mcp() {
  local pid
  for pid in ${FAKE_PIDS[@]+"${FAKE_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  FAKE_PIDS=()
}
trap 'stop_fake_mcp; fm_test_cleanup' EXIT

recall_json() {
  FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" FM_RECALL_TIMEOUT=5 \
    "$RECALL" --json --now 2026-09-06 "${@:2}"
}

write_report() {
  local root=$1 id=$2 title=$3 date=$4 status=$5
  mkdir -p "$root/data/$id"
  {
    printf '# %s\n' "$title"
    printf 'date: %s\n' "$date"
    printf 'status: %s\n' "$status"
    printf '%s body text.\n' "$title"
  } > "$root/data/$id/report.md"
}

write_decision() {
  local root=$1 slug=$2 title=$3
  mkdir -p "$root/data/decisions"
  {
    printf '# %s\n' "$title"
    printf 'date: %s\n' "${slug##*-}"
    printf 'status: decided\n'
    printf '%s body text.\n' "$title"
  } > "$root/data/decisions/$slug.md"
}

seed_probe_corpus() {
  local root=$1
  mkdir -p "$root/data/decisions"
  : > "$root/data/done-archive.md"
  python3 - "$root" <<'PY' || fail "could not create the probe corpus"
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
    path.write_text(f"# {title}\ndate: {date}\nstatus: {status}\n{body}\n", encoding="utf-8")
PY
}

test_valid_input_returns_bounded_pointers() {
  local home out
  home="$TMP_ROOT/valid"
  mkdir -p "$home/data"
  write_report "$home" alpha "Widget sprocket plan" 2026-01-01 reported
  write_report "$home" beta "Unrelated narwhal notes" 2026-01-02 reported
  out=$(recall_json "$home" --title "widget sprocket plan" --surface brief)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["status"]=="ok", p
assert p["pointer_count"]>=1
assert p["hits"][0]["id"]=="alpha"
assert p["hits"][0]["path"]=="data/alpha/report.md"
assert "Recalled pointers" in p["rendered"]
assert "score" not in p["rendered"]
' || fail "recall output assertion failed"
  pass "fm-recall.sh: valid input returns bounded relevant pointers"
}

test_empty_query_is_explicit_empty() {
  local home out
  home="$TMP_ROOT/empty"
  mkdir -p "$home/data"
  write_report "$home" alpha "Widget sprocket plan" 2026-01-01 reported
  out=$(recall_json "$home" --title "" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["status"]=="empty", p
assert p["pointer_count"]==0
assert p["hits"]==[]
' || fail "recall output assertion failed"
  pass "fm-recall.sh: empty query is an explicit empty result"
}

test_missing_corpus_is_unavailable() {
  local home out status
  home="$TMP_ROOT/missing"
  mkdir -p "$home"
  set +e
  out=$(recall_json "$home" --title "widget" --json 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "missing corpus exited 0: $out"
  assert_contains "$out" "recall: unavailable:" "missing corpus did not print unavailable"
  pass "fm-recall.sh: missing corpus is unavailable, never empty success"
}

test_alias_collapses_to_one_canonical_pointer() {
  local home out
  home="$TMP_ROOT/alias"
  mkdir -p "$home/data/twin" "$home/data/canonical"
  printf '%s\n' 'target: canonical' > "$home/data/twin/POINTER.md"
  write_report "$home" canonical "Alias target widget" 2026-01-01 reported
  out=$(recall_json "$home" --title "alias target widget" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p["hits"]]
assert ids.count("canonical")==1, p
assert "twin" not in ids, p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: POINTER.md aliases collapse to one canonical pointer"
}

test_equal_relevance_ignores_date() {
  local home
  home="$TMP_ROOT/tie"
  mkdir -p "$home/data"
  write_report "$home" aaa-old "Shared widget token" 2020-01-01 reported
  write_report "$home" zzz-new "Shared widget token" 2026-09-01 reported
  recall_json "$home" --title "shared widget token" --surface pointers --now 2026-09-06 \
    > "$home/first.json"
  write_report "$home" aaa-old "Shared widget token" 2026-09-01 reported
  write_report "$home" zzz-new "Shared widget token" 2020-01-01 reported
  recall_json "$home" --title "shared widget token" --surface pointers --now 2026-09-06 \
    > "$home/second.json"
  python3 - "$home/first.json" "$home/second.json" <<'PY' || fail "recall fixture or output assertion failed"
import json,sys
a=json.load(open(sys.argv[1],encoding="utf-8"))
b=json.load(open(sys.argv[2],encoding="utf-8"))
assert [h["id"] for h in a["hits"][:2]]==[h["id"] for h in b["hits"][:2]], (a,b)
assert [h["id"] for h in a["hits"][:2]]==["aaa-old","zzz-new"]
PY
  pass "fm-recall.sh: equal relevance keeps identity order when dates change"
}

test_freshness_marks_and_unknown_dates() {
  local home out
  home="$TMP_ROOT/fresh"
  mkdir -p "$home/data"
  write_report "$home" aged "Aged widget" 2026-08-06 reported
  write_report "$home" exact "Exact widget" 2026-08-07 reported
  mkdir -p "$home/data/unknown"
  printf '%s\n' '# Unknown widget' 'status: reported' 'Unknown widget body.' \
    > "$home/data/unknown/report.md"
  out=$(recall_json "$home" --title "widget" --surface pointers --now 2026-09-06)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
by={h["id"]:h for h in p["hits"]}
assert by["aged"]["freshness"]=="check-freshness", by["aged"]
assert "check-freshness" in by["aged"]["line"]
assert by["exact"]["freshness"] is None, by["exact"]
assert "check-freshness" not in by["exact"]["line"]
assert by["unknown"]["date"]=="date unknown"
assert by["unknown"]["freshness"] is None
' || fail "recall output assertion failed"
  pass "fm-recall.sh: freshness marks older-than-30-day dates and never exact-30-day or unknown dates"
}

test_held_and_parked_skip_freshness() {
  local home out
  home="$TMP_ROOT/held"
  mkdir -p "$home/data"
  write_report "$home" held-doc "Held widget" 2020-01-01 reported
  write_report "$home" parked-doc "Parked widget" 2020-01-01 reported
  out=$(recall_json "$home" --title "widget" --surface pointers --now 2026-09-06 \
    --status held-doc=held --status parked-doc=parked)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
by={h["id"]:h for h in p["hits"]}
assert by["held-doc"]["status"]=="held"
assert by["parked-doc"]["status"]=="parked"
assert by["held-doc"]["freshness"] is None
assert by["parked-doc"]["freshness"] is None
assert "check-freshness" not in by["held-doc"]["line"]
' || fail "recall output assertion failed"
  pass "fm-recall.sh: held and parked documents keep state and never receive check-freshness"
}

test_long_title_keeps_usable_path() {
  local home out
  home="$TMP_ROOT/long"
  mkdir -p "$home/data"
  long=$(python3 -c 'print("Widget " + ("title " * 40))')
  write_report "$home" long-doc "$long" 2026-01-01 reported
  out=$(recall_json "$home" --title "widget title" --surface brief)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
line=p["hits"][0]["line"]
assert line.startswith("- data/long-doc/report.md - "), line
assert "check-freshness" in line or ";" in line
shown=line.split(" - ",1)[1]
assert len(shown.split(" (",1)[0])<=90, shown
' || fail "recall output assertion failed"
  pass "fm-recall.sh: long titles keep a usable path inside the pointer line"
}

test_deadline_is_unavailable_not_empty_success() {
  local home out status
  home="$TMP_ROOT/deadline"
  mkdir -p "$home/data"
  i=1
  while [ "$i" -le 80 ]; do
    write_report "$home" "pad-$i" "Padding document $i" 2026-01-01 reported
    i=$((i + 1))
  done
  write_report "$home" real "Widget sprocket" 2026-01-01 reported
  set +e
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_RECALL_TIMEOUT=5 \
    "$RECALL" --json --now 2026-09-06 --title "widget sprocket" --deadline-ms 1 2>&1)
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    assert_contains "$out" "recall: unavailable:" "deadline failure was not unavailable"
  else
    printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["status"] == "ok", p
assert any(h["id"] == "real" for h in p.get("hits") or []), p
' || fail "recall output assertion failed"
  fi
  pass "fm-recall.sh: a tight deadline stays bounded and never pretends to be empty success"
}

test_partial_body_is_diagnosed() {
  local home body out
  home="$TMP_ROOT/partial"
  mkdir -p "$home/data"
  write_report "$home" alpha "Widget sprocket" 2026-01-01 reported
  body="$home/huge-body"
  python3 -c 'open("'"$body"'","w",encoding="utf-8").write("widget " * 20000)'
  out=$(recall_json "$home" --title "widget" --body-file "$body" --json)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p.get("partial_input") is True or any("partial-input" in d for d in p.get("diagnostics") or []), p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: oversized task body emits a partial-input diagnostic"
}

test_thirteen_probe_floors() {
  local home mode n date disp prior query excl probe_start probe_ms
  local -a extra
  load_probe_expectation "$PROBE_TSV" \
    || fail "the committed probe expectation is not a valid 13-row fixture"
  local a3=0 a_den=0 b5=0 b3=0 b_den=0 c3=0 c_den=0
  home="$TMP_ROOT/probes"
  mkdir -p "$home"
  seed_probe_corpus "$home"
  python3 - "$PROBE_TSV" "$TMP_ROOT/probe-rows" <<'PY' || fail "recall fixture or output assertion failed"
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    n, date, disp, prior, query = line.rstrip("\n").split("\t")
    rows.append({"n": n, "date": date, "disp": disp, "prior": prior, "query": query})
json.dump(rows, open(sys.argv[2], "w", encoding="utf-8"))
PY
  python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$TMP_ROOT/probe-rows" >/dev/null
  row_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$TMP_ROOT/probe-rows")
  row_i=0
  while [ "$row_i" -lt "$row_count" ]; do
    eval "$(python3 - "$TMP_ROOT/probe-rows" "$row_i" <<'PY' || fail "recall fixture or output assertion failed"
import json, sys
row = json.load(open(sys.argv[1], encoding="utf-8"))[int(sys.argv[2])]
for key in ("n", "date", "disp", "prior", "query"):
    print("%s=%s" % (key, json.dumps(row[key])))
PY
)"
    for mode in A B C; do
      extra=()
      [ "$mode" = C ] && extra=(--as-of "$date")
      excl=()
      if [ "$mode" != A ]; then
        python3 -c 'import sys; print("\n".join(x for x in sys.argv[1].split(",") if x))' "$disp" \
          > "$TMP_ROOT/probe-excl"
        while IFS= read -r item; do
          [ -n "$item" ] || continue
          excl+=(--exclude-id "$item")
        done < "$TMP_ROOT/probe-excl"
      fi
      probe_start=$(python3 -c 'import time; print(int(time.monotonic()*1000))')
      FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_RECALL_TIMEOUT=5 \
        "$RECALL" --json --now 2026-09-06 --title "$query" --surface pointers --limit 5 \
        ${excl[@]+"${excl[@]}"} ${extra[@]+"${extra[@]}"} > "$TMP_ROOT/probe.json"
      probe_ms=$(python3 -c 'import sys,time; print(int(time.monotonic()*1000)-int(sys.argv[1]))' "$probe_start")
      python3 - "$mode" "$disp" "$prior" "$TMP_ROOT/probe.json" "$n" "$probe_ms" <<'PY' > "$TMP_ROOT/probe-acc"
import json, sys
mode, disp, prior, path, n, elapsed_ms = sys.argv[1:7]
p = json.load(open(path, encoding="utf-8"))
ids = [h["id"] for h in p.get("hits") or []]
raw = (disp + "," + prior) if mode == "A" else prior
expected = []
for item in raw.split(","):
    item = item.strip()
    if not item:
        continue
    expected.append(item[len("decisions/"):-3] if item.startswith("decisions/") else item)
if not expected:
    print("unscored")
    raise SystemExit(0)
rank = None
for i, doc_id in enumerate(ids, 1):
    if doc_id in expected:
        rank = i
        break
print(
    "metric probe=%s mode=%s elapsed_ms=%s rendered_bytes=%s expected_rank=%s top1=%s"
    % (
        n,
        mode,
        elapsed_ms,
        len((p.get("rendered") or "").encode("utf-8")),
        rank or "miss",
        ids[0] if ids else "(none)",
    )
)
print("%s %s %s" % (n, mode, rank or "miss"))
if rank and rank <= 1:
    print("at1")
if rank and rank <= 3:
    print("at3")
if rank and rank <= 5:
    print("at5")
if rank is None:
    print("ids=%s expected=%s status=%s" % (ids, expected, p.get("status")))
PY
      grep '^metric ' "$TMP_ROOT/probe-acc" || true
      if grep -qx unscored "$TMP_ROOT/probe-acc"; then
        [ "$mode" != A ] || fail "mode A row $n had no expected set"
        continue
      fi
      case "$mode" in
        A)
          a_den=$((a_den + 1))
          grep -qx at3 "$TMP_ROOT/probe-acc" && a3=$((a3 + 1))
          grep -q ' miss$' "$TMP_ROOT/probe-acc" \
            && fail "mode A row $n missed its expected hit: $(tr '\n' ' ' < "$TMP_ROOT/probe-acc")"
          ;;
        B)
          b_den=$((b_den + 1))
          grep -qx at5 "$TMP_ROOT/probe-acc" && b5=$((b5 + 1))
          grep -qx at3 "$TMP_ROOT/probe-acc" && b3=$((b3 + 1))
          grep -q ' miss$' "$TMP_ROOT/probe-acc" && fail "mode B row $n missed top-5"
          ;;
        C)
          c_den=$((c_den + 1))
          grep -qx at3 "$TMP_ROOT/probe-acc" && c3=$((c3 + 1))
          grep -q ' miss$' "$TMP_ROOT/probe-acc" && fail "mode C row $n missed top-3"
          ;;
      esac
    done
    row_i=$((row_i + 1))
  done
  [ "$a_den" -eq 13 ] || fail "mode A denominator $a_den, want 13"
  [ "$a3" -eq 13 ] || fail "mode A top-3 $a3/13, want 13/13"
  [ "$b_den" -eq 8 ] || fail "mode B denominator $b_den, want 8"
  [ "$b5" -eq 8 ] || fail "mode B top-5 $b5/8, want 8/8"
  [ "$c_den" -eq 8 ] || fail "mode C denominator $c_den, want 8"
  [ "$c3" -eq 8 ] || fail "mode C top-3 $c3/8, want 8/8"
  # Private-corpus historical note: B top-3 fell to 7/8 when age left the sort.
  pass "fm-recall.sh: 13-probe floors A@3 13/13, C@3 8/8, B@5 8/8 over the synthetic corpus"
}

load_probe_expectation() {
  python3 - "$1" <<'PY'
import sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 5 or not parts[0].isdigit() or not parts[4].strip():
        raise SystemExit("corrupt probe expectation: %r" % line)
    rows.append(parts)
if len(rows) != 13:
    raise SystemExit("probe expectation must contain 13 rows, got %s" % len(rows))
PY
}

test_extracted_identity_excludes_the_same_canonical_token() {
  local home token out reference
  home="$TMP_ROOT/exclude-token"
  mkdir -p "$home/data"
  write_report "$home" prior-widget "Prior widget archive" 2026-01-01 reported
  write_report "$home" other-sprocket "Other sprocket notes" 2026-01-02 reported
  # shellcheck disable=SC2016 # Backticks must remain literal in the references.
  for reference in 'data/prior-widget/report.md' '`data/prior-widget/report.md`' \
    '``data/prior-widget/report.md``' "\`$home/data/prior-widget/report.md\`"; do
    token=$(
      printf 'status: working: see %s.\n' "$reference" \
        | FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$RECALL" --extract-identities
    )
    [ "$token" = "task:prior-widget" ] \
      || fail "extract-identities did not emit the task token"$'\n'"got: $token"
    out=$(recall_json "$home" --title "prior widget archive sprocket" --surface pointers --exclude-identity "$token")
    printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[hit["id"] for hit in p.get("hits") or []]
assert ids == ["other-sprocket"], p
' || fail "recall output assertion failed"
  done
  pass "fm-recall.sh: extracted identities exclude the same canonical token"
}

test_symlinked_report_is_skipped_without_traceback() {
  local home mode=${1:-file}
  home="$TMP_ROOT/rename-race-$mode"
  mkdir -p "$home/data/swapped" "$home/data/dangling" "$home/outside/swapped"
  write_report "$home" real "Widget sprocket real report" 2026-01-01 reported
  write_report "$home" swapped "Widget sprocket inside report" 2026-01-01 reported
  printf '# OUTSIDE_RACE_MARKER widget sprocket\nstatus: reported\n' > "$home/outside/report.md"
  cp "$home/outside/report.md" "$home/outside/swapped/report.md"
  ln -s "$home/data/dangling/missing.md" "$home/data/dangling/report.md"
  python3 - "$home" "$RECALL" "$mode" <<'PY' || fail "a replacement during recall escaped the Record"
import json, os, subprocess, sys, time
from pathlib import Path
home, command, mode = sys.argv[1:]
home = Path(home)
report = home / "data/swapped/report.md"
hook = home / "hook"
hook.mkdir()
(hook / "sitecustomize.py").write_text('''
import os, time
from pathlib import Path
original_open = os.open
armed = True
def delayed_open(path, flags, *args, **kwargs):
    global armed
    parent = kwargs.get("dir_fd")
    target = os.fspath(path) == os.environ["RACE_REPORT"]
    if os.fspath(path) == "report.md" and parent is not None:
        target = os.fstat(parent).st_ino == int(os.environ["RACE_PARENT_INODE"])
    if os.environ["RACE_MODE"] == "root":
        target = os.fspath(path) == os.path.dirname(os.environ["RACE_REPORT"])
        if os.fspath(path) == "swapped" and parent is not None:
            target = os.fstat(parent).st_ino == int(os.environ["RACE_ROOT_INODE"])
    if armed and target:
        armed = False
        Path(os.environ["RACE_READY"]).touch()
        deadline = time.monotonic() + 5
        while not Path(os.environ["RACE_RESUME"]).exists():
            if time.monotonic() > deadline:
                raise RuntimeError("replacement was not released")
            time.sleep(0.01)
    return original_open(path, flags, *args, **kwargs)
os.open = delayed_open
''', encoding="utf-8")
ready, resume = home / "ready", home / "resume"
env = dict(os.environ, FM_HOME=str(home), FM_DATA_OVERRIDE=str(home / "data"),
           FM_RECALL_TIMEOUT="10", PYTHONPATH=str(hook), RACE_REPORT=str(report),
           RACE_PARENT_INODE=str(report.parent.stat().st_ino), RACE_MODE=mode,
           RACE_ROOT_INODE=str((home / "data").stat().st_ino),
           RACE_READY=str(ready), RACE_RESUME=str(resume))
process = subprocess.Popen([command, "--json", "--title", "widget sprocket", "--surface", "pointers",
                            "--deadline-ms", "5000"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    deadline = time.monotonic() + 5
    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert ready.exists(), "recall never reached the report open before replacement"
    if mode == "file":
        report.rename(report.with_suffix(".moved"))
        report.symlink_to(home / "outside/report.md")
    elif mode == "root":
        (home / "data").rename(home / "saved-root")
        (home / "data").symlink_to(home / "outside", target_is_directory=True)
    else:
        report.parent.rename(home / "saved-parent")
        report.parent.symlink_to(home / "outside", target_is_directory=True)
    resume.touch()
    output, errors = process.communicate(timeout=12)
    assert process.returncode == 0, (output, errors)
    p = json.loads(output)
    assert "OUTSIDE_RACE_MARKER" not in output, p
    ids = [h["id"] for h in p["hits"]]
    assert "real" in ids and "dangling" not in ids, p
    if mode == "file":
        assert "swapped" not in ids, p
    else:
        assert "swapped" in ids, p
finally:
    resume.touch()
    if process.poll() is None:
        process.kill()
        process.communicate()
PY
  pass "recall keeps descriptor protection during a $mode replacement"
}

test_malformed_metadata_is_diagnosed() {
  local home out
  home="$TMP_ROOT/malformed"
  mkdir -p "$home/data/bad"
  {
    printf '# Widget sprocket malformed\n'
    printf 'date: garbage\n'
    printf 'status: reported\n'
    printf 'widget sprocket body.\n'
  } > "$home/data/bad/report.md"
  out=$(recall_json "$home" --title "widget sprocket" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["status"]=="ok", p
assert any("malformed date" in d for d in p.get("diagnostics") or []), p
line=p["rendered"]
assert "date unknown" in line or "unknown" in line, line
' || fail "recall output assertion failed"
  pass "fm-recall.sh: a malformed declared date is diagnosed, never ranked as valid"
}

test_alias_cycle_terminates_with_one_pointer() {
  local home out
  home="$TMP_ROOT/alias-cycle"
  mkdir -p "$home/data/loop-a" "$home/data/loop-b"
  printf '%s\n' 'target: loop-b' > "$home/data/loop-a/POINTER.md"
  printf '%s\n' 'target: loop-a' > "$home/data/loop-b/POINTER.md"
  write_report "$home" loop-a "Cycle widget sprocket" 2026-01-01 reported
  write_report "$home" loop-b "Cycle widget sprocket" 2026-01-01 reported
  out=$(recall_json "$home" --title "cycle widget sprocket" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert p["status"]=="ok", p
assert len(ids)==1, p
assert ids[0] in ("loop-a","loop-b"), p
assert any("cycle" in d for d in p.get("diagnostics") or []), p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: an alias cycle terminates and never duplicates a pointer"
}

test_flat_archive_row_is_indexed() {
  local home out
  home="$TMP_ROOT/flat-archive"
  mkdir -p "$home/data"
  printf -- '- [x] flat-one - Widget sprocket flat row (done 2026-01-05)\n  body text.\n' \
    > "$home/data/done-archive.md"
  out=$(recall_json "$home" --title "widget sprocket flat row" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
hits=p.get("hits") or []
assert [h["id"] for h in hits]==["flat-one"], p
assert hits[0]["path"].startswith("data/done-archive.md:"), p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: a flat archive row without a heading still ranks"
}

test_tight_session_budget_takes_the_shorter_hit() {
  local home queries out
  home="$TMP_ROOT/session-tight"
  mkdir -p "$home/data"
  write_report "$home" big \
    "Widget sprocket with an extremely long descriptive title that consumes the entire session token budget" \
    2026-01-01 reported
  write_report "$home" sm "Widget short" 2026-01-01 reported
  write_report "$home" o "Carb" 2026-01-01 reported
  queries="$TMP_ROOT/session-tight.json"
  printf '%s\n' '[{"id":"item1","title":"widget sprocket","body":""},{"id":"item2","title":"carb","body":""}]' \
    > "$queries"
  out=$(recall_json "$home" --session-batch "$queries" --token-budget 108)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert "big" not in ids, p
assert ids==["sm","o"], p
assert p["selected_item_count"]==2, p
assert p["omitted"]==1, p
text=p["rendered"]
assert "### item1" in text and "### item2" in text, text
assert -(-len(text.encode("utf-8"))//3) <= 108, (len(text), text)
' || fail "recall output assertion failed"
  pass "fm-recall.sh: a tight session budget keeps a shorter lower-ranked pointer"
}

test_exact_fit_cap_emits_the_single_pointer() {
  local home queries out cost
  home="$TMP_ROOT/exact-fit"
  mkdir -p "$home/data"
  write_report "$home" solo "Widget" 2026-09-01 reported
  queries="$TMP_ROOT/exact-fit.json"
  printf '%s\n' '[{"id":"i","title":"widget","body":""}]' > "$queries"
  cost=$(recall_json "$home" --session-batch "$queries" | python3 -c '
import json,sys
p=json.load(sys.stdin)
print(p["estimated_tokens"])
')
  out=$(recall_json "$home" --session-batch "$queries" --token-budget "$cost")
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert [h["id"] for h in p.get("hits") or []]==["solo"], p
assert p["omitted"]==0, p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: a block that costs exactly the cap is still emitted"
}

test_rejection_for_one_item_does_not_block_another() {
  local home queries out long
  home="$TMP_ROOT/per-item"
  mkdir -p "$home/data"
  write_report "$home" solo "Widget" 2026-09-01 reported
  long=$(python3 -c 'print("q"*120)')
  queries="$TMP_ROOT/per-item.json"
  python3 -c '
import json,sys
json.dump([{"id":sys.argv[1],"title":"widget","body":""},{"id":"r","title":"widget","body":""}],
          open(sys.argv[2],"w",encoding="utf-8"))
' "$long" "$queries"
  out=$(recall_json "$home" --session-batch "$queries" --token-budget 60)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert ids==["solo"], p
assert "### r" in p["rendered"], p["rendered"]
assert -(-len(p["rendered"].encode("utf-8"))//3) <= 60, p["rendered"]
' || fail "recall output assertion failed"
  pass "fm-recall.sh: an item that cannot fit a pointer never blocks another item"
}

test_batch_field_types_are_validated() {
  local home queries status out
  home="$TMP_ROOT/batch-types"
  mkdir -p "$home/data"
  write_report "$home" solo "Widget" 2026-09-01 reported
  queries="$TMP_ROOT/batch-types.json"
  printf '%s\n' '[{"id":"i","title":42,"body":""}]' > "$queries"
  set +e
  out=$(recall_json "$home" --session-batch "$queries" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a numeric session title was accepted"
  assert_contains "$out" "must be a string" "a numeric session title had no structured reason"
  assert_not_contains "$out" "Traceback" "a numeric session title crashed the recall owner"
  pass "fm-recall.sh: malformed session batch field types are a structured unavailable result"
}

test_session_partial_input_reaches_the_payload() {
  local home queries out
  home="$TMP_ROOT/batch-partial"
  mkdir -p "$home/data"
  write_report "$home" solo "Widget" 2026-09-01 reported
  queries="$TMP_ROOT/batch-partial.json"
  python3 -c '
import json,sys
json.dump([{"id":"i","title":"widget "*12000,"body":"widget "*12000}], open(sys.argv[1],"w",encoding="utf-8"))
' "$queries"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_RECALL_TIMEOUT=10 \
    "$RECALL" --json --now 2026-09-06 --session-batch "$queries")
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert p["partial_input"] is True, p
assert any("partial-input" in d for d in p.get("diagnostics") or []), p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: session query truncation reaches partial_input, not only diagnostics"
}

test_oversized_first_archive_row_still_ranks() {
  local home out
  home="$TMP_ROOT/big-row"
  mkdir -p "$home/data"
  python3 -c '
import sys
root = sys.argv[1]
with open(root + "/data/done-archive.md", "w", encoding="utf-8") as handle:
    handle.write("- [x] alpha - Widget sprocket alpha " + "z" * 20000 + "\n")
    handle.write("- [x] beta - Widget sprocket beta\n")
' "$home"
  out=$(recall_json "$home" --title "widget sprocket" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert "alpha" in ids, p
assert "beta" in ids, p
assert p["partial_input"] is True, p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: an oversized first archive row keeps its bounded prefix and still ranks"
}

test_metadata_status_does_not_change_rank() {
  local home out
  home="$TMP_ROOT/meta-rank"
  mkdir -p "$home/data"
  write_report "$home" alpha "Widget report" 2026-09-01 reported
  write_report "$home" beta "Widget report" 2026-09-01 held
  out=$(recall_json "$home" --title "widget held" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert ids[:2]==["alpha","beta"], p
scores={h["id"]: h["score"] for h in p["hits"]}
assert scores["alpha"]==scores["beta"], p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: declared status metadata never changes relevance order"
}

test_alias_identity_exclusion_resolves_canonical() {
  local home out
  home="$TMP_ROOT/alias-exclude"
  mkdir -p "$home/data/z"
  write_report "$home" a "Widget alias target" 2026-09-01 reported
  printf '%s\n' 'target: data/a/report.md' > "$home/data/z/POINTER.md"
  out=$(recall_json "$home" --title "widget alias target" --surface pointers \
    --exclude-identity task:z)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert "a" not in ids, p
' || fail "recall output assertion failed"
  pass "fm-recall.sh: an alias identity exclusion removes its canonical document"
}

test_parent_directory_swap_never_leaves_the_record() {
  test_symlinked_report_is_skipped_without_traceback directory
}

test_corrupted_expectation_exits_nonzero() {
  local bad status
  bad="$TMP_ROOT/probe-bad.tsv"
  sed 's/feeder export plan engineering review//' "$PROBE_TSV" > "$bad"
  set +e
  load_probe_expectation "$bad"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "corrupted expectation file was accepted"
  load_probe_expectation "$PROBE_TSV" \
    || fail "the committed probe expectation is not a valid 13-row fixture"
  pass "fm-recall.sh: a corrupted fixed expectation fails the executable harness"
}

test_archive_completion_annotations_do_not_change_rank() {
  local home annotation
  home="$TMP_ROOT/archive-rank"
  mkdir -p "$home/data"
  for annotation in 'done 2020-01-01' 'reported 2026-01-05' 'merged 2025-02-03'; do
    printf '%s\n' '- [x] alpha - Widget' "- [x] bravo - Widget ($annotation)" > "$home/data/done-archive.md"
    recall_json "$home" --title "widget $annotation" --surface pointers > "$home/result.json"
    python3 - "$home/result.json" <<'PY' || fail "completion metadata changed archive relevance"
import json, sys
hits = json.load(open(sys.argv[1], encoding="utf-8"))["hits"]
assert [hit["id"] for hit in hits] == ["alpha", "bravo"], hits
assert hits[0]["score"] == hits[1]["score"], hits
PY
  done
  pass "archive completion annotations do not change relevance"
}

test_unicode_identity_tokens_round_trip() {
  local home token out kind path
  home="$TMP_ROOT/unicode-identity"
  write_report "$home" café 'Widget' 2026-01-01 reported
  write_decision "$home" café 'Widget'
  for kind in task decision; do
    path=data/café/report.md
    [ "$kind" != decision ] || path=data/decisions/café.md
    token=$(printf '%s\n' "$path" | FM_HOME="$home" "$RECALL" --extract-identities)
    [ "$token" = "$kind:café" ] || fail "Unicode identity was not extracted"
    out=$(recall_json "$home" --title widget --surface pointers --exclude-identity "$token")
    printf '%s\n' "$out" | python3 -c '
import json, sys
p = json.load(sys.stdin)
assert sys.argv[1] not in [hit["identity"] for hit in p["hits"]], p
assert p["pointer_count"] == 1, p
' "$token" || fail "Unicode identity exclusion did not round trip"
  done
  pass "Unicode task and decision identities round trip through exclusion"
}

test_archive_locator_excludes_only_its_row() {
  local home reference option token
  home="$TMP_ROOT/archive-locators"
  mkdir -p "$home/data"
  printf '%s\n' '- [x] alpha - Widget' '- [x] bravo - Widget' > "$home/data/done-archive.md"
  for reference in data/done-archive.md:1 data/done-archive.md#L1 \
    "$home/data/done-archive.md:1" "$home/data/done-archive.md#L1" \
    "[old]($home/data/done-archive.md#L1)"; do
    for option in --exclude-path --exclude-identity; do
      recall_json "$home" --title widget --surface pointers "$option" "$reference" > "$home/result.json"
      python3 - "$home/result.json" <<'PY' || fail "archive locator excluded an unrelated row: $reference"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert [hit["id"] for hit in p["hits"]] == ["bravo"], p
PY
    done
    token=$(printf '%s\n' "$reference" | FM_HOME="$home" "$RECALL" --extract-identities)
    [ "$token" = task:alpha ] || fail "archive locator did not extract only its row: $token"
  done
  pass "archive locators exclude only their row across supported forms"
}

test_session_budget_keeps_allocation_order() {
  local home id
  home="$TMP_ROOT/allocation-order"
  for id in a1 a2 a3; do write_report "$home" "$id" Sprocket 2026-09-01 reported; done
  for id in b1 b2 b3; do write_report "$home" "$id" Narwhals 2026-09-01 reported; done
  printf '%s\n' '[{"id":"a","title":"sprocket"},{"id":"b","title":"narwhals"}]' > "$home/queries.json"
  recall_json "$home" --session-batch "$home/queries.json" --token-budget 140 > "$home/result.json"
  python3 - "$home/result.json" <<'PY' || fail "session trimming broke allocation order"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["pointer_count"] == 4, p
assert set(p["identities"]) == {"task:a1", "task:a2", "task:b1", "task:b2"}, p
assert p["estimated_tokens"] <= 140, p
assert p["omitted"] == 2, p
PY
  pass "session trimming preserves round-robin allocation order"
}

test_probe_corpus_ignores_expectation_changes() {
  local home saved
  home="$TMP_ROOT/independent-probes"
  seed_probe_corpus "$home/before"
  saved=$PROBE_TSV
  PROBE_TSV="$home/changed.tsv"
  printf '1\t2026-08-31\tinvented-result\t\tfeeder export plan engineering review\n' > "$PROBE_TSV"
  seed_probe_corpus "$home/after"
  PROBE_TSV=$saved
  recall_json "$home/before" --title 'feeder export plan engineering review' --surface pointers > "$home/before.json"
  recall_json "$home/after" --title 'feeder export plan engineering review' --surface pointers > "$home/after.json"
  python3 - "$home/before.json" "$home/after.json" <<'PY' || fail "probe expectations changed the evaluated corpus"
import json, sys
before, after = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert before["hits"], before
assert before["hits"] == after["hits"], (before, after)
PY
  pass "probe corpus remains independent from the expectations"
}

test_ranking_head_and_footer_use_byte_bounds() {
  local home
  home="$TMP_ROOT/byte-head"
  mkdir -p "$home/data/report" "$home/data/decisions"
  python3 - "$home/data" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path, lines in [(root / "report/report.md", 10), (root / "decisions/ruling.md", 5)]:
    path.write_text("# Widget\n" + "neutral\n" * lines + "sprocket\ndate: 2026-01-01\nstatus: held\n", encoding="utf-8")
PY
  recall_json "$home" --title sprocket --surface pointers > "$home/result.json"
  python3 - "$home/result.json" <<'PY' || fail "the ranking head or metadata stopped at a line count"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert {h["id"] for h in p["hits"]} == {"report", "ruling"}, p
assert all(h["date"] == "2026-01-01" and h["status"] == "held" for h in p["hits"]), p
PY
  python3 - "$home/data" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for path in [root / "report/report.md", root / "decisions/ruling.md"]:
    path.write_text("# Widget\n" + "neutral\n" * 2500 + "outsidehead\ndate: 2026-01-02\nstatus: parked\n", encoding="utf-8")
PY
  recall_json "$home" --title outsidehead --surface pointers > "$home/outside.json"
  recall_json "$home" --title widget --surface pointers > "$home/metadata.json"
  python3 - "$home/outside.json" "$home/metadata.json" <<'PY' || fail "ranking or metadata exceeded its byte boundary"
import json, sys
outside, metadata = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert outside["hits"] == [], outside
assert metadata["partial_input"], metadata
assert len(metadata["hits"]) == 2, metadata
assert all(h["date"] == "2026-01-02" and h["status"] == "parked" for h in metadata["hits"]), metadata
PY
  pass "ranking reads the 16 KiB head and metadata reads the bounded footer"
}

test_decision_filename_dates_do_not_change_scores() {
  local home
  home="$TMP_ROOT/decision-filename-date"
  mkdir -p "$home/data/decisions"
  printf '# Widget\nstatus: decided\n' > "$home/data/decisions/widget-2020-01-01.md"
  cp "$home/data/decisions/widget-2020-01-01.md" "$home/data/decisions/widget-2026-01-01.md"
  recall_json "$home" --title 'widget 2026' --surface pointers > "$home/result.json"
  python3 - "$home/result.json" <<'PY' || fail "the decision filename date changed relevance"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert [h["id"] for h in p["hits"]] == ["widget-2020-01-01", "widget-2026-01-01"], p
assert p["hits"][0]["score"] == p["hits"][1]["score"], p
assert [h["date"] for h in p["hits"]] == ["2020-01-01", "2026-01-01"], p
PY
  pass "decision filename dates affect display but never scores"
}

test_plain_output_discloses_diagnostics() {
  local home surface
  home="$TMP_ROOT/plain-diagnostics"
  mkdir -p "$home/data/widget"
  printf '# Widget\ndate: malformed\nstatus: reported\n' > "$home/data/widget/report.md"
  python3 - "$home/body.md" <<'PY'
import sys
open(sys.argv[1], "w", encoding="utf-8").write("widget " * 20000)
PY
  for surface in pointers brief; do
    FM_HOME="$home" "$RECALL" --title widget --body-file "$home/body.md" --surface "$surface" \
      > "$home/output" 2> "$home/errors" || fail "plain recall failed"
    assert_grep data/widget/report.md "$home/output" "plain recall lost the pointer"
    assert_grep partial-input "$home/errors" "plain recall hid truncated input"
    assert_grep 'malformed date' "$home/errors" "plain recall hid malformed metadata"
  done
  printf '[{"id":"current","title":"widget"}]\n' > "$home/queries.json"
  FM_HOME="$home" "$RECALL" --session-batch "$home/queries.json" \
    > "$home/output" 2> "$home/errors" || fail "plain session recall failed"
  assert_grep 'malformed date' "$home/errors" "plain session recall hid metadata diagnostics"
  pass "plain recall publishes diagnostics on stderr"
}

test_alias_cycle_exclusion_uses_corpus_identity() {
  local home option identity id
  home="$TMP_ROOT/cycle-exclusions"
  write_report "$home" a 'Widget' 2026-01-01 reported
  write_report "$home" b 'Widget' 2026-01-01 reported
  mkdir -p "$home/data/c"
  printf 'target: b\n' > "$home/data/a/POINTER.md"
  printf 'target: c\n' > "$home/data/b/POINTER.md"
  printf 'target: b\n' > "$home/data/c/POINTER.md"
  recall_json "$home" --title widget --surface pointers > "$home/result.json"
  python3 - "$home/result.json" <<'PY' || fail "a prefix changed the canonical cycle identity"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert [h["id"] for h in p["hits"]] == ["b"], p
PY
  for id in a b c; do
    for option in --exclude-id --exclude-identity --exclude-path; do
      identity=$id
      [ "$option" != --exclude-identity ] || identity=task:$id
      [ "$option" != --exclude-path ] || identity=data/$id/report.md
      recall_json "$home" --title widget --surface pointers "$option" "$identity" > "$home/result.json"
      python3 - "$home/result.json" <<'PY' || fail "alias-cycle exclusion disagreed with corpus loading"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["hits"] == [], p
PY
    done
  done
  pass "alias-cycle exclusions use the corpus canonical identity"
}

test_archive_body_keeps_contiguous_byte_prefix() {
  local home filler query
  home="$TMP_ROOT/archive-body-prefix"
  mkdir -p "$home/data"
  for filler in x é; do
    python3 - "$home/data/done-archive.md" "$filler" <<'PYPREFIX' || fail "could not create the archive prefix fixture"
from pathlib import Path
import sys
Path(sys.argv[1]).write_text("- [x] entry - Widget\nneedle " + sys.argv[2] * 17000 + "\nlateword\n- [x] next - Lateword\n", encoding="utf-8")
PYPREFIX
    for query in needle lateword; do
      recall_json "$home" --title "$query" --surface pointers > "$home/result.json"
      python3 - "$home/result.json" "$query" <<'PYPREFIX' || fail "archive ranking lost its contiguous prefix"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert [h["id"] for h in p["hits"]] == (["entry"] if sys.argv[2] == "needle" else ["next"]), p
assert p["partial_input"], p
PYPREFIX
    done
  done
  pass "archive bodies preserve their contiguous byte prefix and stop at the limit"
}

test_foreign_citations_do_not_exclude_local_reports() {
  local home reference token out
  home="$TMP_ROOT/foreign-citations"
  write_report "$home" prior Widget 2026-01-01 reported
  for reference in "$home/other/data/prior/report.md" \
    "\`$home/other/data/prior/report.md\`" \
    "[prior]($home/other/data/prior/report.md)" \
    'https://example.test/data/prior/report.md'; do
    token=$(printf 'See %s.\n' "$reference" | FM_HOME="$home" "$RECALL" --extract-identities)
    [ -z "$token" ] || fail "a foreign reference acquired a local identity: $token"
    out=$(recall_json "$home" --title widget --exclude-identity "$token")
    printf '%s\n' "$out" | python3 -c '
import json, sys
p = json.load(sys.stdin)
assert [h["id"] for h in p["hits"]] == ["prior"], p
' || fail "a foreign reference excluded a local report"
  done
  pass "complete foreign references never become local exclusions"
}

test_brief_limit_is_clamped_to_five() {
  local home id surface
  home="$TMP_ROOT/brief-limit"
  for id in a b c d e f; do
    write_report "$home" "$id" Widget 2026-01-01 held
  done
  for surface in brief pointers; do
    recall_json "$home" --title widget --surface "$surface" --limit 6 --token-budget 1000 > "$home/result.json"
    python3 - "$home/result.json" "$surface" <<'PYLIMIT' || fail "the brief limit exceeded five"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(p["hits"]) == (5 if sys.argv[2] == "brief" else 6), p
PYLIMIT
  done
  pass "brief limits stop at five while pointer limits remain configurable"
}

if [ "${1:-}" = probes ]; then
  test_thirteen_probe_floors
  exit 0
fi

test_archive_body_keeps_contiguous_byte_prefix
test_foreign_citations_do_not_exclude_local_reports
test_brief_limit_is_clamped_to_five
test_ranking_head_and_footer_use_byte_bounds
test_decision_filename_dates_do_not_change_scores
test_plain_output_discloses_diagnostics
test_alias_cycle_exclusion_uses_corpus_identity

test_archive_completion_annotations_do_not_change_rank
test_unicode_identity_tokens_round_trip
test_archive_locator_excludes_only_its_row
test_session_budget_keeps_allocation_order
test_probe_corpus_ignores_expectation_changes

test_header_and_footer_preserve_title_rank_and_caps() {
  local home
  home="$TMP_ROOT/header-footer-rank"
  mkdir -p "$home/data/decisions" "$home/data/sources"
  printf '%s\n' '# Quasar propulsion' 'Thruster notes without extra terms.' \
    > "$home/data/decisions/quasar-propulsion.md"
  printf '%s\n' '# Source' 'quasar catalog.' > "$home/data/sources/quasar.md"
  recall_json "$home" --title quasar --surface pointers > "$home/before.json"
  python3 - "$home/before.json" <<'PY' || fail "plain quasar decision did not score 4.0"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["status"] == "ok", p
assert len(p["hits"]) == 1, p
assert p["hits"][0]["title"] == "Quasar propulsion", p
assert p["hits"][0]["score"] == 4.0, p
assert p["pointer_count"] == 1, p
PY
  python3 - "$home/data/decisions/quasar-propulsion.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
body = path.read_text(encoding="utf-8")
path.write_text(
    '---\nid: decisions/quasar-propulsion\ndate: "2026-09-07"\ntype: decision\nstatus: open\n---\n'
    + body,
    encoding="utf-8",
)
PY
  recall_json "$home" --title quasar --surface pointers > "$home/after-header.json"
  python3 - "$home/before.json" "$home/after-header.json" <<'PY' || fail "YAML header changed quasar ranking"
import json, sys
before, after = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert after["hits"][0]["title"] == before["hits"][0]["title"], after
assert after["hits"][0]["score"] == before["hits"][0]["score"] == 4.0, after
assert after["pointer_count"] == before["pointer_count"], after
assert after["hits"][0]["date"] == "2026-09-07", after
PY
  printf '%s\n' '# General decision' 'Unrelated body about wait policy.' \
    > "$home/data/decisions/general.md"
  recall_json "$home" --title quasar --surface pointers > "$home/general-before.json"
  python3 - "$home/general-before.json" <<'PY' || fail "general decision already matched quasar"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert {h["id"] for h in p["hits"]} == {"quasar-propulsion"}, p
PY
  printf '%s\n' '' 'Related: supersedes: none; cites: [[sources/quasar.md]]; relates: none' \
    >> "$home/data/decisions/general.md"
  recall_json "$home" --title quasar --surface pointers > "$home/general-after.json"
  python3 - "$home/general-before.json" "$home/general-after.json" <<'PY' || fail "Related footer created a quasar hit"
import json, sys
before, after = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert after["hits"] == before["hits"], (before, after)
assert all(h["id"] != "general" for h in after["hits"]), after
PY
  pass "fm-recall: YAML headers and Related footers preserve title, score, and caps"
}

TOKEN_FIXTURE='tok-t17b-throwaway-never-print'

start_fake_mcp() {
  local dir=$1
  mkdir -p "$dir"
  : > "$dir/recv"
  [ -f "$dir/status" ] || printf '200\n' > "$dir/status"
  [ -f "$dir/delay" ] || printf '0\n' > "$dir/delay"
  FAKE_TOKEN="$TOKEN_FIXTURE" python3 - "$dir" <<'PY' &
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = sys.argv[1]
token = os.environ.get("FAKE_TOKEN", "")

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        auth = self.headers.get("Authorization") or ""
        record = {
            "path": self.path,
            "method": "POST",
            "content_type": self.headers.get("Content-Type") or "",
            "accept": self.headers.get("Accept") or "",
            "auth_present": auth.startswith("Bearer "),
            "auth_leaked": bool(token) and token in (self.path + (self.headers.get("Content-Type") or "") + body.decode("utf-8", "replace")),
            "body": body.decode("utf-8", "replace"),
        }
        with open(os.path.join(root, "recv"), "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record) + "\n")
        delay = 0.0
        try:
            delay = float(open(os.path.join(root, "delay"), encoding="utf-8").read().strip() or "0")
        except (OSError, ValueError):
            delay = 0.0
        try:
            slow_match = open(os.path.join(root, "slow_match"), encoding="utf-8").read().strip()
        except OSError:
            slow_match = ""
        if slow_match and slow_match not in record["body"]:
            delay = 0.0
        if delay > 0:
            time.sleep(delay)
        status = 200
        try:
            status = int(open(os.path.join(root, "status"), encoding="utf-8").read().strip() or "200")
        except (OSError, ValueError):
            status = 200
        try:
            payload = open(os.path.join(root, "body"), encoding="utf-8").read()
        except OSError:
            payload = "{}"
        data = payload.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if status < 400:
            self.wfile.write(data)

    def log_message(self, *_args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(os.path.join(root, "port"), "w", encoding="utf-8").write(str(server.server_address[1]))
server.serve_forever()
PY
  FAKE_PIDS+=($!)
  local i=0
  while [ ! -f "$dir/port" ]; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || fail "fake mcp server did not bind"
    sleep 0.05
  done
  FAKE_URL="http://127.0.0.1:$(cat "$dir/port")/mcp"
}

write_token() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$TOKEN_FIXTURE" > "$path"
}

hybrid_env() {
  local home=$1
  mkdir -p "$home/config"
  write_token "$home/config/gbrain-recall.token"
}

assert_no_token() {
  local blob
  blob=$(cat "$@")
  case "$blob" in
    *"$TOKEN_FIXTURE"*) fail "token leaked into $* output" ;;
  esac
}

test_hybrid_refused_keeps_overlap() {
  local home
  home="$TMP_ROOT/hybrid-refused"
  write_report "$home" alpha "Sprocket plan" 2026-09-01 reported
  write_report "$home" beta "Unrelated narwhal" 2026-09-01 reported
  hybrid_env "$home"
  recall_json "$home" --title sprocket --surface pointers --ranker auto \
    --gbrain-recall on --recall-url "http://127.0.0.1:1/mcp" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/auto.json" 2>"$home/auto.err" || fail "auto refused should exit 0"
  python3 - "$home/auto.json" <<'PY' || fail "auto refused did not keep overlap"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["status"] == "ok", p
assert p["retrieval_mode"] == "overlap", p
assert p["ranker"] == "term-overlap-3-1", p
assert [h["id"] for h in p["hits"]] == ["alpha"], p
assert any(d.startswith("hybrid-") for d in p.get("diagnostics") or []), p
PY
  set +e
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_RECALL_TIMEOUT=5 \
    "$RECALL" --json --now 2026-09-06 --title sprocket --surface pointers \
    --ranker hybrid --gbrain-recall on --recall-url "http://127.0.0.1:1/mcp" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/hybrid.json" 2>"$home/hybrid.err"
  RC=$?
  set -e
  [ "$RC" -eq 1 ] || fail "hybrid refused should exit 1, got $RC"
  python3 - "$home/hybrid.json" <<'PY' || fail "hybrid refused JSON shape broke"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["status"] == "unavailable", p
assert p["retrieval_mode"] == "unavailable", p
assert p["hits"] == [], p
assert p["identities"] == [], p
PY
  recall_json "$home" --title sprocket --surface pointers --ranker auto \
    --gbrain-recall on --recall-url "http://192.0.2.1:9/mcp" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/remote.json" 2>"$home/remote.err" || fail "auto non-loopback should exit 0"
  python3 - "$home/remote.json" <<'PY' || fail "non-loopback url was not treated as serve down"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["retrieval_mode"] == "overlap", p
assert [h["id"] for h in p["hits"]] == ["alpha"], p
assert "hybrid-refused: non-loopback url" in p["diagnostics"], p
PY
  set +e
  recall_json "$home" --title sprocket --surface pointers --ranker hybrid \
    --gbrain-recall on --recall-url "http://192.0.2.1:9/mcp" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/remote-hybrid.json" 2>"$home/remote-hybrid.err"
  RC=$?
  set -e
  [ "$RC" -eq 1 ] || fail "hybrid non-loopback should exit 1, got $RC"
  assert_no_token "$home/auto.json" "$home/auto.err" "$home/hybrid.json" "$home/hybrid.err" \
    "$home/remote.json" "$home/remote.err" "$home/remote-hybrid.json" "$home/remote-hybrid.err"
  pass "fm-recall: refused or non-loopback serve keeps overlap under auto and unavailable under hybrid"
}

test_hybrid_timeout_stays_inside_deadline() {
  local home dir
  home="$TMP_ROOT/hybrid-hang"
  dir="$home/fake"
  write_report "$home" alpha "Sprocket plan" 2026-09-01 reported
  hybrid_env "$home"
  mkdir -p "$dir"
  printf '2\n' > "$dir/delay"
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"results":[]},"_meta":{"retrieval":{"vector_enabled":true}}}}' > "$dir/body"
  start_fake_mcp "$dir"
  recall_json "$home" --title sprocket --surface pointers --ranker auto \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" --hybrid-ms 150 \
    > "$home/out.json" 2>"$home/out.err" || fail "timeout auto should exit 0"
  python3 - "$home/out.json" <<'PY' || fail "timeout auto did not keep overlap"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["status"] == "ok", p
assert p["retrieval_mode"] == "overlap", p
assert [h["id"] for h in p["hits"]] == ["alpha"], p
assert any("hybrid-timeout" in d or "hybrid-skipped: deadline" in d for d in p.get("diagnostics") or []), p
PY
  stop_fake_mcp
  assert_no_token "$home/out.json" "$home/out.err" "$dir/recv"
  pass "fm-recall: hung serve falls back inside the deadline"
}

test_hybrid_http_errors_keep_overlap() {
  local home dir code
  home="$TMP_ROOT/hybrid-http"
  write_report "$home" alpha "Sprocket plan" 2026-09-01 reported
  hybrid_env "$home"
  for code in 401 403 500; do
    dir="$home/fake-$code"
    mkdir -p "$dir"
    printf '%s\n' "$code" > "$dir/status"
    printf '%s\n' '{"error":"nope","token":"tok-t17b-throwaway-never-print"}' > "$dir/body"
    start_fake_mcp "$dir"
    recall_json "$home" --title sprocket --surface pointers --ranker auto \
      --gbrain-recall on --recall-url "$FAKE_URL" \
      --token-file "$home/config/gbrain-recall.token" \
      > "$home/$code.json" 2>"$home/$code.err" || fail "auto $code should exit 0"
    python3 - "$home/$code.json" "$code" <<'PY' || fail "http error did not keep overlap"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
code = sys.argv[2]
assert p["retrieval_mode"] == "overlap", p
assert any("hybrid-http:%s" % code in d for d in p.get("diagnostics") or []), p
PY
    assert_no_token "$home/$code.json" "$home/$code.err" "$dir/recv"
    stop_fake_mcp
  done
  dir="$home/fake-badjson"
  mkdir -p "$dir"
  printf '200\n' > "$dir/status"
  printf '%s\n' 'not-json' > "$dir/body"
  start_fake_mcp "$dir"
  recall_json "$home" --title sprocket --surface pointers --ranker auto \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/bad.json" 2>"$home/bad.err" || fail "bad json should exit 0"
  python3 - "$home/bad.json" <<'PY' || fail "bad json did not keep overlap"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["retrieval_mode"] == "overlap", p
assert any("hybrid-bad-json" in d for d in p.get("diagnostics") or []), p
PY
  stop_fake_mcp
  local port
  for port in abc 99999; do
    recall_json "$home" --title sprocket --surface pointers --ranker auto \
      --gbrain-recall on --recall-url "http://127.0.0.1:$port/mcp" \
      --token-file "$home/config/gbrain-recall.token" \
      > "$home/badport.json" 2>"$home/badport.err" || fail "bad port $port should exit 0"
    python3 - "$home/badport.json" <<'PY' || fail "bad port $port did not keep overlap"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["status"] == "ok", p
assert p["retrieval_mode"] == "overlap", p
assert [h["id"] for h in p["hits"]] == ["alpha"], p
assert any(d.startswith("hybrid-") for d in p["diagnostics"]), p
PY
  done
  assert_no_token "$home/bad.json" "$home/bad.err" "$home/badport.json" "$home/badport.err"
  pass "fm-recall: 401 403 500 and invalid JSON keep overlap without leaking secrets"
}

test_hybrid_missing_token_and_overlap_opens_no_socket() {
  local home dir
  home="$TMP_ROOT/hybrid-token"
  dir="$home/fake"
  write_report "$home" alpha "Sprocket plan" 2026-09-01 reported
  mkdir -p "$dir"
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"results":[]},"_meta":{"retrieval":{"vector_enabled":true}}}}' > "$dir/body"
  start_fake_mcp "$dir"
  recall_json "$home" --title sprocket --surface pointers --ranker auto \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    > "$home/none.json" 2>"$home/none.err" || fail "missing token should exit 0"
  python3 - "$home/none.json" <<'PY' || fail "missing token did not skip hybrid"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["retrieval_mode"] == "overlap", p
assert "hybrid-skipped: no token" in (p.get("diagnostics") or []), p
PY
  [ ! -s "$dir/recv" ] || fail "missing token still posted to serve"
  mkdir -p "$home/config"
  printf '\377\376\n' > "$home/config/binary.token"
  recall_json "$home" --title sprocket --surface pointers --ranker auto \
    --gbrain-recall on --recall-url "$FAKE_URL" --token-file "$home/config/binary.token" \
    > "$home/binary.json" 2>"$home/binary.err" || fail "undecodable token should exit 0"
  python3 - "$home/binary.json" <<'PY' || fail "undecodable token did not skip hybrid"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["retrieval_mode"] == "overlap", p
assert "hybrid-skipped: no token" in p["diagnostics"], p
PY
  [ ! -s "$dir/recv" ] || fail "undecodable token still posted to serve"
  hybrid_env "$home"
  recall_json "$home" --title sprocket --surface pointers --ranker overlap \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/overlap.json" 2>"$home/overlap.err" || fail "overlap ranker should exit 0"
  [ ! -s "$dir/recv" ] || fail "overlap ranker opened a socket"
  stop_fake_mcp
  pass "fm-recall: missing token and --ranker overlap open no socket"
}

test_hybrid_order_fill_and_identity_rules() {
  local home dir
  home="$TMP_ROOT/hybrid-order"
  dir="$home/fake"
  write_report "$home" alpha "Sprocket widget" 2026-09-01 reported
  write_report "$home" beta "Sprocket gadget" 2026-09-01 reported
  write_report "$home" gamma "Unrelated narwhal" 2026-09-01 reported
  write_decision "$home" "knowledge-stack-2026-08-31" "Knowledge stack"
  printf '%s\n' '# Archive' 'date: 2026-09-01' 'status: reported' \
    '- [x] archived-one - old sprocket' > "$home/data/done-archive.md"
  write_report "$home" future "Future sprocket" 2026-12-01 reported
  hybrid_env "$home"
  mkdir -p "$dir"
  python3 - "$dir/body" <<'PY'
import json, sys
rows = [
    {"slug": "data/beta/report", "title": "beta"},
    {"slug": "data/beta/report", "title": "beta-dup"},
    {"slug": "data/wiki/generated", "title": "generated"},
    {"slug": "data/done-archive", "title": "archive"},
    {"slug": "data/future/report", "title": "future"},
    {"slug": "data/gamma/report", "title": "gamma"},
]
payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "structuredContent": {"results": rows},
        "_meta": {"retrieval": {"vector_enabled": True}},
    },
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(payload))
PY
  start_fake_mcp "$dir"
  recall_json "$home" --title sprocket --surface pointers --limit 5 \
    --ranker auto --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" --as-of 2026-09-06 \
    --exclude-id gamma \
    > "$home/out.json" 2>"$home/out.err" || fail "hybrid order should exit 0"
  python3 - "$home/out.json" "$dir/recv" <<'PY' || fail "hybrid order or identity rules failed"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["retrieval_mode"] == "hybrid", p
assert p["ranker"] == "gbrain-hybrid+term-overlap-3-1", p
assert p["hybrid_resolved"] == 1, p
ids = [h["id"] for h in p["hits"]]
assert ids[0] == "beta", ids
assert "gamma" not in ids, ids
assert "future" not in ids, ids
assert ids.count("beta") == 1, ids
assert "alpha" in ids, ids
recv = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
assert recv, recv
body = json.loads(recv[0]["body"])
assert body["method"] == "tools/call", body
assert body["params"]["name"] == "search", body
args = body["params"]["arguments"]
assert args["limit"] == 25, args
assert args["recency"] == "off", args
assert args["salience"] == "off", args
assert "mode" not in args, args
assert recv[0]["auth_present"] is True, recv[0]
assert recv[0]["auth_leaked"] is False, recv[0]
assert p["identities"][0] == "task:beta", p
PY
  http_proxy="http://127.0.0.1:1" HTTP_PROXY="http://127.0.0.1:1" no_proxy="" NO_PROXY="" \
    recall_json "$home" --title sprocket --surface pointers --ranker hybrid \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/proxy.json" 2>"$home/proxy.err" || fail "hybrid POST followed the proxy environment"
  stop_fake_mcp
  assert_no_token "$home/out.json" "$home/out.err" "$dir/recv"
  pass "fm-recall: hybrid-first order, fill, drop, dedupe, as-of, and exclude"
}

test_hybrid_slug_mapping_and_collision() {
  local home dir
  home="$TMP_ROOT/hybrid-slug"
  dir="$home/fake"
  mkdir -p "$home/data/KS-T17B-Case" "$home/data/decisions" "$home/data/cafe notes"
  mkdir -p "$home/data/twin case" "$home/data/twin-case"
  printf '%s\n' '# Twin spaced' 'date: 2026-09-01' 'status: reported' 'narwhal body' \
    > "$home/data/twin case/report.md"
  printf '%s\n' '# Twin dashed' 'date: 2026-09-01' 'status: reported' 'narwhal body' \
    > "$home/data/twin-case/report.md"
  printf '%s\n' '# Upper sprocket' 'date: 2026-09-01' 'status: reported' 'sprocket body' \
    > "$home/data/KS-T17B-Case/report.md"
  printf '%s\n' '# Dotted decision' 'date: 2026-08-31' 'status: decided' 'sprocket body' \
    > "$home/data/decisions/knowledge-stack-2026-08-31.md"
  printf '%s\n' '# Accent sprocket' 'date: 2026-09-01' 'status: reported' 'sprocket café' \
    > "$home/data/cafe notes/report.md"
  write_report "$home" "apple-notes" "Apple notes sprocket" 2026-09-01 reported
  hybrid_env "$home"
  mkdir -p "$dir"
  python3 - "$dir/body" <<'PY'
import json, sys
rows = [
    {"slug": "data/ks-t17b-case/report"},
    {"slug": "data/decisions/knowledge-stack-2026-08-31"},
    {"slug": "data/cafe-notes/report"},
    {"slug": "data/twin-case/report"},
]
payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "structuredContent": {"results": rows},
        "_meta": {"retrieval": {"vector_enabled": True}},
    },
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(payload))
PY
  start_fake_mcp "$dir"
  recall_json "$home" --title sprocket --surface pointers --ranker hybrid \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/out.json" 2>"$home/out.err" || fail "slug mapping should exit 0"
  python3 - "$home/out.json" <<'PY' || fail "slug mapping failed"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
ids = [h["id"] for h in p["hits"]]
assert "KS-T17B-Case" in ids, ids
assert "knowledge-stack-2026-08-31" in ids, ids
assert any("cafe" in h["path"] for h in p["hits"]), p["hits"]
assert not any("twin" in h["path"] for h in p["hits"]), p["hits"]
assert "hybrid-slug-collision: data/twin-case/report" in p["diagnostics"], p
PY
  recall_json "$home" --title sprocket --surface pointers --ranker overlap \
    > "$home/overlap.json" 2>"$home/overlap.err" || fail "overlap with slug twins should exit 0"
  python3 - "$home/overlap.json" <<'PY' || fail "overlap lookup reported a hybrid slug diagnostic"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert not any(d.startswith("hybrid-") for d in p["diagnostics"]), p
PY
  python3 - "$ROOT/bin/fm-recall.py" "$ROOT/bin/fm-gbrain-maintain.py" <<'PY' || fail "slug gold or projection disagree"
import importlib.util, sys
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
recall = load("fm_recall", sys.argv[1])
maintain = load("fm_maintain", sys.argv[2])
assert recall.slugify_path("data/KS-T17B-Case/report.md") == "data/ks-t17b-case/report"
assert recall.slugify_path("data/decisions/knowledge-stack-2026-08-31.md") == "data/decisions/knowledge-stack-2026-08-31"
assert recall.slugify_path("data/cafe notes/report.md") == "data/cafe-notes/report"
assert recall.slugify_path("Apple Notes/2017-05-03 ohmygreen.md") == "apple-notes/2017-05-03-ohmygreen"
assert recall.slugify_path("people/alice-smith.md") == "people/alice-smith"
assert recall.slugify_path("notes/v1.0.0.md") == "notes/v1.0.0"
proj = maintain.projected_source_path("ks-x/report.md")
assert proj == "data/ks-x/report.md"
assert recall.slugify_path(proj) == "data/ks-x/report"
PY
  stop_fake_mcp
  pass "fm-recall: case, accent, dotted slugs resolve; projection agrees"
}

test_hybrid_keyword_and_query_alias() {
  local home dir
  home="$TMP_ROOT/hybrid-keyword"
  dir="$home/fake"
  write_report "$home" alpha "Sprocket plan" 2026-09-01 reported
  hybrid_env "$home"
  mkdir -p "$dir"
  python3 - "$dir/body" <<'PY'
import json, sys
payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "structuredContent": {
            "results": [{"slug": "data/alpha/report", "keyword_relaxed": True}]
        },
        "_meta": {
            "retrieval": {
                "vector_enabled": False,
                "degraded": [{"stage": "embed_unavailable", "reason": "no_provider"}],
            }
        },
    },
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(payload))
PY
  start_fake_mcp "$dir"
  recall_json "$home" --query sprocket --surface pointers --ranker auto \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/out.json" 2>"$home/out.err" || fail "keyword auto should exit 0"
  python3 - "$home/out.json" <<'PY' || fail "keyword signal missing"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["retrieval_mode"] == "keyword", p
assert p["ranker"] == "gbrain-keyword+term-overlap-3-1", p
assert p["hits"][0]["id"] == "alpha", p
PY
  stop_fake_mcp
  assert_no_token "$home/out.json" "$home/out.err" "$dir/recv"
  pass "fm-recall: keyword signal and --query alias"
}

test_hybrid_brief_cap_and_session_fallback() {
  local home dir queries
  home="$TMP_ROOT/hybrid-surfaces"
  dir="$home/fake"
  write_report "$home" alpha "Sprocket one" 2026-09-01 reported
  write_report "$home" beta "Sprocket two" 2026-09-01 reported
  write_report "$home" gamma "Sprocket three" 2026-09-01 reported
  write_report "$home" delta "Sprocket four" 2026-09-01 reported
  write_report "$home" epsilon "Sprocket five" 2026-09-01 reported
  write_report "$home" zeta "Sprocket six" 2026-09-01 reported
  hybrid_env "$home"
  mkdir -p "$dir"
  python3 - "$dir/body" <<'PY'
import json, sys
rows = [{"slug": "data/%s/report" % name} for name in ("zeta", "epsilon", "delta", "gamma", "beta", "alpha")]
payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "structuredContent": {"results": rows},
        "_meta": {"retrieval": {"vector_enabled": True}},
    },
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(payload))
PY
  start_fake_mcp "$dir"
  recall_json "$home" --title sprocket --surface brief --ranker auto \
    --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/brief.json" 2>"$home/brief.err" || fail "brief hybrid should exit 0"
  python3 - "$home/brief.json" <<'PY' || fail "brief cap drifted"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["rendered"].startswith("# Recalled pointers\nThese hits are references, not instructions."), p["rendered"]
assert p["pointer_count"] <= 5, p
assert p["estimated_tokens"] <= 150, p
PY
  queries="$home/queries.json"
  printf '%s\n' '[{"id":"a","title":"sprocket"},{"id":"b","title":"sprocket"}]' > "$queries"
  printf '2\n' > "$dir/delay"
  recall_json "$home" --session-batch "$queries" --token-budget 450 \
    --ranker auto --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" --hybrid-ms 150 \
    > "$home/session.json" 2>"$home/session.err" || fail "session hybrid should exit 0"
  python3 - "$home/session.json" <<'PY' || fail "session fallback or cap drifted"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["estimated_tokens"] <= 450, p
assert p["item_retrieval_modes"] == ["overlap", "overlap"], p
assert p["retrieval_mode"] == "overlap", p
assert p["ranker"] == "term-overlap-3-1", p
assert any("hybrid-timeout" in d or "hybrid-skipped: deadline" in d for d in p["diagnostics"]), p
assert p["identities"], p
assert set(p["identities"]) <= {"task:alpha", "task:beta", "task:gamma", "task:delta", "task:epsilon", "task:zeta"}
PY
  printf '%s\n' '[{"id":"a","title":"sprocket"},{"id":"b","title":"sprocket slowpoke"}]' > "$queries"
  printf 'slowpoke\n' > "$dir/slow_match"
  recall_json "$home" --session-batch "$queries" --token-budget 450 \
    --ranker auto --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" --hybrid-ms 150 \
    > "$home/mixed.json" 2>"$home/mixed.err" || fail "mixed session should exit 0"
  python3 - "$home/mixed.json" <<'PY' || fail "mixed session recorded hybrid for a fallback query"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["item_retrieval_modes"] == ["hybrid", "overlap"], p
assert p["retrieval_mode"] == "overlap", p
assert p["ranker"] == "term-overlap-3-1", p
PY
  printf '0\n' > "$dir/delay"
  python3 - "$queries" <<'PY'
import json, sys
items = [{"id": "q%d" % n, "title": "sprocket"} for n in range(5)]
json.dump(items, open(sys.argv[1], "w", encoding="utf-8"))
PY
  recall_json "$home" --session-batch "$queries" --token-budget 450 \
    --ranker auto --gbrain-recall on --recall-url "$FAKE_URL" \
    --token-file "$home/config/gbrain-recall.token" \
    > "$home/five.json" 2>"$home/five.err" || fail "five-item session should exit 0"
  python3 - "$home/five.json" <<'PY' || fail "five-item session skipped hybrid"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["item_retrieval_modes"] == ["hybrid"] * 5, p
assert p["retrieval_mode"] == "hybrid", p
assert p["ranker"] == "gbrain-hybrid+term-overlap-3-1", p
PY
  stop_fake_mcp
  pass "fm-recall: brief cap and session per-query fallback stay inside T2 limits"
}

test_hybrid_default_off_matches_overlap() {
  local home
  home="$TMP_ROOT/hybrid-off"
  seed_probe_corpus "$home"
  write_token "$home/config/gbrain-recall.token"
  recall_json "$home" --title 'feeder export plan engineering review' --surface pointers \
    --ranker overlap > "$home/overlap.json"
  recall_json "$home" --title 'feeder export plan engineering review' --surface pointers \
    --ranker auto > "$home/auto.json"
  python3 - "$home/overlap.json" "$home/auto.json" <<'PY' || fail "default auto drifted from overlap"
import json, sys
overlap, auto = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert auto["retrieval_mode"] == "overlap", auto
assert [h["id"] for h in auto["hits"]] == [h["id"] for h in overlap["hits"]]
assert auto["ranker"] == "term-overlap-3-1", auto
PY
  pass "fm-recall: GBRAIN_RECALL off keeps auto on overlap"
}

test_hybrid_receipt_fields() {
  local home
  home="$TMP_ROOT/hybrid-receipt"
  write_report "$home" alpha "Sprocket plan" 2026-09-01 reported
  recall_json "$home" --title sprocket --surface brief --task-id hybrid-receipt \
    > "$home/payload.json"
  python3 - "$home/payload.json" <<'PY' || fail "payload missing receipt fields"
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
assert p["ranker"] == "term-overlap-3-1", p
assert p["retrieval_mode"] == "overlap", p
assert isinstance(p["identities"], list), p
PY
  pass "fm-recall: payload carries ranker, retrieval_mode, and identities"
}

test_valid_input_returns_bounded_pointers
test_empty_query_is_explicit_empty
test_missing_corpus_is_unavailable
test_alias_collapses_to_one_canonical_pointer
test_equal_relevance_ignores_date
test_freshness_marks_and_unknown_dates
test_held_and_parked_skip_freshness
test_long_title_keeps_usable_path
test_deadline_is_unavailable_not_empty_success
test_partial_body_is_diagnosed
test_thirteen_probe_floors
test_extracted_identity_excludes_the_same_canonical_token
test_symlinked_report_is_skipped_without_traceback
test_malformed_metadata_is_diagnosed
test_alias_cycle_terminates_with_one_pointer
test_flat_archive_row_is_indexed
test_tight_session_budget_takes_the_shorter_hit
test_exact_fit_cap_emits_the_single_pointer
test_rejection_for_one_item_does_not_block_another
test_batch_field_types_are_validated
test_session_partial_input_reaches_the_payload
test_oversized_first_archive_row_still_ranks
test_metadata_status_does_not_change_rank
test_alias_identity_exclusion_resolves_canonical
test_parent_directory_swap_never_leaves_the_record
test_symlinked_report_is_skipped_without_traceback root
test_corrupted_expectation_exits_nonzero
test_header_and_footer_preserve_title_rank_and_caps
test_hybrid_refused_keeps_overlap
test_hybrid_timeout_stays_inside_deadline
test_hybrid_http_errors_keep_overlap
test_hybrid_missing_token_and_overlap_opens_no_socket
test_hybrid_order_fill_and_identity_rules
test_hybrid_slug_mapping_and_collision
test_hybrid_keyword_and_query_alias
test_hybrid_brief_cap_and_session_fallback
test_hybrid_default_off_matches_overlap
test_hybrid_receipt_fields

echo "# all fm-recall tests passed"
