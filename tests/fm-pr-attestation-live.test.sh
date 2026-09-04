#!/usr/bin/env bash
# Regression tests for the live pull request read that feeds the no-mistakes signature gate.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-pr-attestation-live.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-attestation-live)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

# The stub answers each `gh api` call with the next response file, then keeps
# answering with the last one; a response named fail makes the call exit 1.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case_dir="$FM_TEST_GH_CASE"
n=$(cat "$case_dir/calls" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s' "$n" > "$case_dir/calls"
printf '%s\n' "$*" >> "$case_dir/args"
file="$case_dir/$n.json"
[ -f "$file" ] || file="$case_dir/last.json"
if [ "$(cat "$file")" = fail ]; then
  exit 1
fi
cat "$file"
SH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

pr_json() {  # <head-sha> <attested-sha>
  local body
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$2\",\"steps\":[{\"step\":\"review\",\"status\":\"completed\"}]} -->"
  jq -n --arg head "$1" --arg body "$body" '{head:{sha:$head},body:$body}'
}

new_case() {  # <name>; sets CASE_DIR and points the gh stub at it
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR"
  export FM_TEST_GH_CASE="$CASE_DIR"
}

run_live() {  # <output-file> [extra args]
  local out=$1
  shift
  "$SCRIPT" --repo example/repo --pr 99 --output "$out" --interval-seconds 1 "$@" 2>&1
}

output_value() {  # <output-file> <key>
  sed -n "s/^$2=//p" "$1"
}

test_matching_attestation_is_read_once() {
  local dir out rc
  new_case matching
  dir=$CASE_DIR
  pr_json "$NEW_SHA" "$NEW_SHA" > "$dir/last.json"
  out="$dir/output"
  rc=0
  run_live "$out" --timeout-seconds 5 >/dev/null || rc=$?
  expect_code 0 "$rc" "a matching live attestation should be read successfully"
  [ "$(cat "$dir/calls")" = 1 ] || fail "a matching attestation should need exactly one read, got $(cat "$dir/calls")"
  [ "$(output_value "$out" head_sha)" = "$NEW_SHA" ] || fail "head_sha output did not carry the live head"
  [ "$(output_value "$out" attested_sha)" = "$NEW_SHA" ] || fail "attested_sha output did not carry the live attestation"
  [ "$(output_value "$out" converged)" = true ] || fail "converged should be true for a matching attestation"
  assert_grep 'repos/example/repo/pulls/99' "$dir/args" "the live read did not target the named pull request"
  pass "a matching live attestation is read once and exported"
}

test_body_is_exported_verbatim_between_delimiters() {
  local dir out delim body
  new_case body
  dir=$CASE_DIR
  pr_json "$NEW_SHA" "$NEW_SHA" > "$dir/last.json"
  out="$dir/output"
  run_live "$out" --timeout-seconds 5 >/dev/null || fail "live read failed"
  delim=$(sed -n 's/^body<<//p' "$out")
  [ -n "$delim" ] || fail "body output did not use a heredoc delimiter"
  body=$(awk -v d="$delim" '$0 == "body<<" d {on=1; next} $0 == d {on=0} on' "$out")
  assert_contains "$body" "$SIGNATURE" "exported body lost the no-mistakes signature line"
  assert_contains "$body" "no-mistakes-pipeline-attestation:v1" "exported body lost the attestation marker"
  [ "$(printf '%s\n' "$body" | wc -l | tr -d ' ')" = 2 ] || fail "exported body should keep both lines"
  pass "the live body is exported verbatim between unique heredoc delimiters"
}

test_stale_attestation_converges_after_the_body_edit() {
  local dir out rc
  new_case converges
  dir=$CASE_DIR
  pr_json "$NEW_SHA" "$OLD_SHA" > "$dir/1.json"
  pr_json "$NEW_SHA" "$OLD_SHA" > "$dir/2.json"
  pr_json "$NEW_SHA" "$NEW_SHA" > "$dir/last.json"
  out="$dir/output"
  rc=0
  run_live "$out" --timeout-seconds 10 >/dev/null || rc=$?
  expect_code 0 "$rc" "a converging attestation should be read successfully"
  [ "$(cat "$dir/calls")" = 3 ] || fail "the read should poll until the body edit lands, got $(cat "$dir/calls") calls"
  [ "$(output_value "$out" attested_sha)" = "$NEW_SHA" ] || fail "attested_sha should carry the refreshed attestation"
  [ "$(output_value "$out" converged)" = true ] || fail "converged should be true once the body attests the live head"
  pass "a stale synchronize payload converges once the body edit lands"
}

test_never_attested_head_is_exported_for_the_gate_to_refuse() {
  local dir out rc
  new_case stale
  dir=$CASE_DIR
  pr_json "$NEW_SHA" "$OLD_SHA" > "$dir/last.json"
  out="$dir/output"
  rc=0
  run_live "$out" --timeout-seconds 1 >/dev/null || rc=$?
  expect_code 0 "$rc" "a stale attestation must still export live values for the gate"
  [ "$(cat "$dir/calls")" -ge 2 ] || fail "the read should poll until the timeout, got $(cat "$dir/calls") calls"
  [ "$(output_value "$out" head_sha)" = "$NEW_SHA" ] || fail "head_sha output must carry the live head"
  [ "$(output_value "$out" attested_sha)" = "$OLD_SHA" ] || fail "attested_sha output must carry the stale attestation"
  [ "$(output_value "$out" converged)" = false ] || fail "converged must be false when the head is never re-attested"
  pass "a head that is never re-attested is exported unchanged so the gate refuses it"
}

test_unreadable_pull_request_fails() {
  local dir out rc
  new_case unreadable
  dir=$CASE_DIR
  printf 'fail' > "$dir/last.json"
  out="$dir/output"
  rc=0
  run_live "$out" --timeout-seconds 1 >/dev/null || rc=$?
  expect_code 1 "$rc" "an unreadable pull request should fail instead of exporting empty values"
  [ ! -s "$out" ] || fail "no output should be written when the pull request could not be read"
  pass "an unreadable pull request fails closed"
}

test_usage_errors_are_refused() {
  local option rc
  for option in --repo --pr --output --timeout-seconds --interval-seconds; do
    rc=0
    "$SCRIPT" "$option" >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "$option without a value should be a usage error"
  done
  rc=0
  "$SCRIPT" --repo example --pr 99 --output "$TMP_ROOT/unused" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a repo without an owner should be a usage error"
  rc=0
  "$SCRIPT" --repo example/repo --pr abc --output "$TMP_ROOT/unused" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-numeric pull request number should be a usage error"
  rc=0
  "$SCRIPT" --repo example/repo --pr 99 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing --output should be a usage error"
  rc=0
  "$SCRIPT" --repo example/repo --pr 99 --output "$TMP_ROOT/unused" --interval-seconds 0 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a zero poll interval should be a usage error instead of a tight gh api spin"
  pass "usage errors are refused before any pull request read"
}

test_matching_attestation_is_read_once
test_body_is_exported_verbatim_between_delimiters
test_stale_attestation_converges_after_the_body_edit
test_never_attested_head_is_exported_for_the_gate_to_refuse
test_unreadable_pull_request_fails
test_usage_errors_are_refused
