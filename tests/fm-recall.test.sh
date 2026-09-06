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
trap fm_test_cleanup EXIT

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
  python3 - "$PROBE_TSV" "$root" <<'PY'
import os, sys
tsv, root = sys.argv[1], sys.argv[2]
seen = {}
for line in open(tsv, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    _n, date, disp, prior, query = line.rstrip("\n").split("\t")
    for raw in [x for x in (disp + "," + prior).split(",") if x]:
        if raw.startswith("decisions/"):
            slug = os.path.basename(raw)[:-3]
            path = os.path.join(root, "data", "decisions", slug + ".md")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if slug not in seen:
                seen[slug] = query
            body = seen[slug]
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("# %s\n" % slug.replace("-", " "))
                handle.write("date: %s\n" % date)
                handle.write("status: decided\n")
                handle.write("%s\n" % body)
        else:
            path = os.path.join(root, "data", raw, "report.md")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if raw not in seen:
                seen[raw] = query
            body = seen[raw]
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("# %s\n" % raw.replace("-", " "))
                handle.write("date: %s\n" % date)
                handle.write("status: reported\n")
                handle.write("%s\n" % body)
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
'
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
'
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
'
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
  python3 - "$home/first.json" "$home/second.json" <<'PY'
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
'
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
'
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
'
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
'
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
'
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
  python3 - "$PROBE_TSV" "$TMP_ROOT/probe-rows" <<'PY'
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
    eval "$(python3 - "$TMP_ROOT/probe-rows" "$row_i" <<'PY'
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
  local home token out
  home="$TMP_ROOT/exclude-token"
  mkdir -p "$home/data"
  write_report "$home" prior-widget "Prior widget archive" 2026-01-01 reported
  write_report "$home" other-sprocket "Other sprocket notes" 2026-01-02 reported
  token=$(
    printf 'status: working: see data/prior-widget/report.md\n' \
      | FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$RECALL" --extract-identities
  )
  [ "$token" = "task:prior-widget" ] \
    || fail "extract-identities did not emit the task token"$'\n'"got: $token"
  out=$(recall_json "$home" --title "prior widget archive" --exclude-identity "$token")
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[hit["id"] for hit in p.get("hits") or []]
assert "prior-widget" not in ids, p
assert "other-sprocket" in ids or p.get("status") in ("ok","empty"), p
'
  pass "fm-recall.sh: extracted identities exclude the same canonical token"
}

test_symlinked_report_is_skipped_without_traceback() {
  local home out before
  home="$TMP_ROOT/rename-race"
  mkdir -p "$home/data/swapped" "$home/outside"
  write_report "$home" real "Widget sprocket real report" 2026-01-01 reported
  write_report "$home" swapped "Widget sprocket regular report" 2026-01-01 reported
  printf '# Widget sprocket secret outside the Record\nwidget sprocket\n' \
    > "$home/outside/secret.md"
  before=$(recall_json "$home" --title "widget sprocket" --surface pointers)
  printf '%s\n' "$before" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert "swapped" in ids, p
'
  mv "$home/data/swapped/report.md" "$home/data/swapped/report.md.moved"
  ln -s "$home/outside/secret.md" "$home/data/swapped/report.md"
  mkdir -p "$home/data/dangling"
  ln -s "$home/data/dangling/missing.md" "$home/data/dangling/report.md"
  out=$(recall_json "$home" --title "widget sprocket" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert "swapped" not in ids, p
assert "dangling" not in ids, p
assert "real" in ids, p
assert "secret" not in json.dumps(p), p
'
  pass "fm-recall.sh: a report replaced by a symlink is skipped, never read through"
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
'
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
'
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
'
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
'
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
'
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
  out=$(recall_json "$home" --session-batch "$queries" --token-budget 90)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
ids=[h["id"] for h in p.get("hits") or []]
assert ids==["solo"], p
assert "### r" in p["rendered"], p["rendered"]
assert -(-len(p["rendered"].encode("utf-8"))//3) <= 90, p["rendered"]
'
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
'
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
'
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
'
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
'
  pass "fm-recall.sh: an alias identity exclusion removes its canonical document"
}

test_parent_directory_swap_never_leaves_the_record() {
  local home out
  home="$TMP_ROOT/dir-swap"
  mkdir -p "$home/data" "$home/outside/alpha"
  write_report "$home" alpha "Widget sprocket inside" 2026-09-01 reported
  printf '# OUTSIDE_RACE_MARKER widget sprocket\ndate: 2026-09-01\nstatus: reported\nwidget sprocket\n' \
    > "$home/outside/alpha/report.md"
  rm -rf "$home/data/alpha"
  ln -s "$home/outside/alpha" "$home/data/alpha"
  out=$(recall_json "$home" --title "widget sprocket" --surface pointers)
  printf '%s\n' "$out" | python3 -c '
import json,sys
p=json.load(sys.stdin)
assert "OUTSIDE_RACE_MARKER" not in json.dumps(p), p
assert p["status"] in ("ok","empty"), p
'
  pass "fm-recall.sh: a swapped task directory never renders an outside report"
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
test_corrupted_expectation_exits_nonzero

echo "# all fm-recall tests passed"
