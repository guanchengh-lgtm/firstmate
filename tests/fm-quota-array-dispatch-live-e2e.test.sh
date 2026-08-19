#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-array-dispatch skill.
#
# This drives the public Pi skill-loading interface against a fake quota-axi
# executable rather than parsing instruction source bytes or recreating the
# selector in test code.
set -u

if [ "${FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_QUOTA_ARRAY_DISPATCH_LIVE_E2E=1 to run the credentialed Pi dispatch-selection regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-array-dispatch/SKILL.md"
# Default matches credentialed CI; override locally when only another provider is authed.
PI_MODEL=${FM_QUOTA_ARRAY_DISPATCH_PI_MODEL:-openai-codex/gpt-5.6-sol}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -f "$OWNER" ] || fail "quota-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/quota.json"
CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-array-dispatch" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-array-dispatch/SKILL.md"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != --json ] || [ "$#" -ne 1 ]; then
  printf 'unexpected quota-axi invocation: %s\n' "$*" >&2
  exit 64
fi
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"

write_fixture() {
  cat > "$FIXTURE"
}

# ISO-8601 UTC timestamp offset from now by whole hours (positive future).
iso_hours_from_now() {
  python3 - "$1" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
hours = float(sys.argv[1])
print((datetime.now(timezone.utc) + timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

run_case() {
  local label=$1 expected=$2 prompt=$3 out calls required
  shift 3
  : > "$CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" QUOTA_AXI_FIXTURE="$FIXTURE" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model "$PI_MODEL" --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "$calls" = "--json" ] || fail "$label: skill did not use one quota-axi --json snapshot: $calls"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  for required in "$@"; do
    printf '%s\n' "$out" | grep -Fxq "$required" \
      || fail "$label: expected accounting line $required, got: $out"
  done
  printf '%s\n' "$out"
  printf 'ok - %s\n' "$label"
}

write_fixture <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":600,"projectedExhaustedAt":"2030-01-01T00:10:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]},"effectivePace":[{"scope":"all_models","pace":"ahead","worstReservePercentPoints":-1}]},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]},"effectivePace":[{"scope":"all_models","pace":"ahead","worstReservePercentPoints":-40}]}]}
JSON
run_case \
  "higher headroom and viable runway beat a less-negative reserve" \
  "SELECTED=codex" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove Claude/Sonnet and Codex/GPT models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Return exact lines FACT=claude|headroom=1|runway_seconds=600|reserve=-1 and FACT=codex|headroom=55|runway_seconds=14400|reserve=-40 to preserve candidate accounting, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=1|runway_seconds=600|reserve=-1" \
  "FACT=codex|headroom=55|runway_seconds=14400|reserve=-40"

write_fixture <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"unknown","unmeasurableWindowIds":["weekly"]}}]}},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":45,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectedExhaustedAt":"2030-01-01T04:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}]}
JSON
run_case \
  "unmeasurable runway stays eligible and is accounted for explicitly" \
  "DECISION=CODEX" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Claude has higher known headroom but explicitly unmeasurable runway, while Codex has lower known headroom and established runway that supports completion. The snapshot cannot prove Pareto dominance in either direction, but the known completion-supporting runway justifies Codex while Claude remains eligible and its uncertainty must be disclosed. Return exact lines FACT=claude|eligible=yes|headroom=55|runway=unknown|unmeasurable=weekly and FACT=codex|eligible=yes|headroom=45|runway_seconds=14400|supports_horizon=yes, then an exact final line DECISION=CODEX. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|eligible=yes|headroom=55|runway=unknown|unmeasurable=weekly" \
  "FACT=codex|eligible=yes|headroom=45|runway_seconds=14400|supports_horizon=yes"

write_fixture <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":1,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":10800,"projectedExhaustedAt":"2030-01-01T03:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},{"provider":"codex","quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"2030-01-01T08:00:00Z","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}]}
JSON
run_case \
  "required strongest reasoning class is not downgraded for quota" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. The likely task-completion horizon is two hours with established confidence. Claude/Sonnet is catalog-supported with usable authentication and is the only profile that meets the task's required strongest reasoning class. Codex/GPT is catalog-supported with usable authentication but is a weaker reasoning class and cannot meet the requirement. Return exact lines FACT=claude|reasoning=required|headroom=1|runway_seconds=10800 and FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800, then an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|reasoning=required|headroom=1|runway_seconds=10800" \
  "FACT=codex|reasoning=weaker|headroom=80|runway_seconds=28800"

# --- Reset-bias cases (skill selection order step 5) ---
# Timestamps are relative to wall clock so "about one day" / "two to three days" /
# "four to six days" remain meaningful when the live agent reads resetsAt.
RESET_1D=$(iso_hours_from_now 24)
RESET_2_5D=$(iso_hours_from_now 60)
RESET_5D=$(iso_hours_from_now 120)
RESET_5_5D=$(iso_hours_from_now 132)
RESET_5H=$(iso_hours_from_now 5)
HORIZON_EXHAUST=$(iso_hours_from_now 8)

write_fixture <<JSON
{"schemaVersion":3,"providers":[
  {"provider":"claude","windows":[{"id":"weekly","kind":"weekly","percentRemaining":70,"resetsAt":"$RESET_1D","windowSeconds":604800}],"quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},
  {"provider":"codex","windows":[{"id":"weekly","kind":"weekly","percentRemaining":90,"resetsAt":"$RESET_5D","windowSeconds":604800}],"quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}
]}
JSON
run_case \
  "about-one-day substantial remaining is spent hard over higher far headroom" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Both candidates have supported runway through that horizon. Apply the skill's reset-bias rules among finishable candidates. For every candidate return one exact FACT line naming effective headroom and each applicable window id, next reset, and that window's percentRemaining using the snapshot values verbatim, in the form FACT=<provider>|headroom=<n>|window=<id>|resetsAt=<iso>|window_remaining=<n>. Then return an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=70|window=weekly|resetsAt=$RESET_1D|window_remaining=70" \
  "FACT=codex|headroom=90|window=weekly|resetsAt=$RESET_5D|window_remaining=90"

write_fixture <<JSON
{"schemaVersion":3,"providers":[
  {"provider":"claude","windows":[{"id":"weekly","kind":"weekly","percentRemaining":35,"resetsAt":"$RESET_2_5D","windowSeconds":604800}],"quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":35,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},
  {"provider":"codex","windows":[{"id":"weekly","kind":"weekly","percentRemaining":85,"resetsAt":"$RESET_5D","windowSeconds":604800}],"quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":85,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}
]}
JSON
run_case \
  "two-to-three-day nearer weekly reset beats higher far headroom" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Both candidates have supported runway through that horizon. Neither candidate is in the about-one-day spend-hard band. Apply the skill's reset-bias rules among finishable candidates. For every candidate return one exact FACT line naming effective headroom and each applicable window id, next reset, and that window's percentRemaining using the snapshot values verbatim, in the form FACT=<provider>|headroom=<n>|window=<id>|resetsAt=<iso>|window_remaining=<n>. Then return an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=35|window=weekly|resetsAt=$RESET_2_5D|window_remaining=35" \
  "FACT=codex|headroom=85|window=weekly|resetsAt=$RESET_5D|window_remaining=85"

write_fixture <<JSON
{"schemaVersion":3,"providers":[
  {"provider":"claude","windows":[{"id":"weekly","kind":"weekly","percentRemaining":40,"resetsAt":"$RESET_5D","windowSeconds":604800}],"quotaSemantics":{"description":"The all_models scope bounds every Claude model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":40,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},
  {"provider":"codex","windows":[{"id":"weekly","kind":"weekly","percentRemaining":80,"resetsAt":"$RESET_5_5D","windowSeconds":604800}],"quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}
]}
JSON
run_case \
  "similar four-to-six-day horizons select on longer-cycle remaining" \
  "SELECTED=codex" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Both candidates have supported runway through that horizon. Neither candidate is in the about-one-day spend-hard band or the two-to-three-day nearer-reset band. Apply the skill's reset-bias and farther-horizon rules among finishable candidates. For every candidate return one exact FACT line naming effective headroom and each applicable window id, next reset, and that window's percentRemaining using the snapshot values verbatim, in the form FACT=<provider>|headroom=<n>|window=<id>|resetsAt=<iso>|window_remaining=<n>. Then return an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=40|window=weekly|resetsAt=$RESET_5D|window_remaining=40" \
  "FACT=codex|headroom=80|window=weekly|resetsAt=$RESET_5_5D|window_remaining=80"

# Multi-window trap: Claude's five_hour is soonest and tighter on effective headroom,
# but far-horizon admission and remaining must come from seven_day, not five_hour.
write_fixture <<JSON
{"schemaVersion":3,"providers":[
  {"provider":"claude","windows":[
    {"id":"five_hour","kind":"session","percentRemaining":25,"resetsAt":"$RESET_5H","windowSeconds":18000},
    {"id":"seven_day","kind":"weekly","percentRemaining":75,"resetsAt":"$RESET_5D","windowSeconds":604800}
  ],"quotaSemantics":{"description":"Claude account windows bound every model. A model-specific window is an additional bound, so that model's effective remaining percentage is the minimum across the named windows.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":25,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"five_hour","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}},
  {"provider":"codex","windows":[{"id":"weekly","kind":"weekly","percentRemaining":55,"resetsAt":"$RESET_5_5D","windowSeconds":604800}],"quotaSemantics":{"description":"The all_models scope bounds every Codex model.","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":55,"boundedBy":["weekly"],"runway":{"status":"projected_exhaustion","usableRunwaySeconds":28800,"projectedExhaustedAt":"$HORIZON_EXHAUST","limitingWindowId":"weekly","projectionConfidence":"established","projectionBasis":"cycle_average"}}]}}
]}
JSON
run_case \
  "far horizon uses longer-cycle remaining not five_hour effective minimum" \
  "SELECTED=claude" \
  "Resolve this matched dispatch profile array now. Load quota-array-dispatch and run quota-axi --json exactly once. Both profiles have comparable required task fit and the same strongest reasoning class. The authoritative catalogs already prove both models supported in their stated provider families, and their selected authentication surfaces are usable. The likely task-completion horizon is two hours with established confidence. Both candidates have supported runway through that horizon. Neither candidate is in the about-one-day spend-hard band or the two-to-three-day nearer multi-day reset band. Claude is bounded by both five_hour and seven_day; Codex is weekly-only. Apply the skill's farther-horizon rules: do not let five_hour gate far-horizon admission or supply the far remaining value. For every candidate return exact FACT lines naming effective headroom and each applicable window id, next reset, and that window's own percentRemaining using the snapshot values verbatim. Claude must emit two FACT lines, one per applicable window, of the form FACT=claude|headroom=25|window=<id>|resetsAt=<iso>|window_remaining=<n>. Codex emits FACT=codex|headroom=55|window=weekly|resetsAt=<iso>|window_remaining=55. Then return an exact final line SELECTED=<claude|codex>. Do not use other vendor or model commands and do not modify files." \
  "FACT=claude|headroom=25|window=five_hour|resetsAt=$RESET_5H|window_remaining=25" \
  "FACT=claude|headroom=25|window=seven_day|resetsAt=$RESET_5D|window_remaining=75" \
  "FACT=codex|headroom=55|window=weekly|resetsAt=$RESET_5_5D|window_remaining=55"

echo "# all quota-array-dispatch live behavior tests passed"
