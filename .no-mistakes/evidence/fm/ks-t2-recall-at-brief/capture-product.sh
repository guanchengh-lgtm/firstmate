#!/usr/bin/env bash
# Execute the real product commands in the session test's isolated fixture.
# Only external tools and harness detection use the existing test doubles.
set -euT
EVIDENCE=/Users/AI/.no-mistakes/evidence/01M1VX4783MRHEA6B80DDHFHSY

capture_product() {
  local rec root home fakebin brief
  rec=$(new_world product-evidence)
  IFS='|' read -r root home fakebin <<< "$rec"
  make_fake_toolchain "$fakebin"
  make_fake_ps_claude "$fakebin"
  seed_session_recall_world "$home"
  mkdir -p "$home/data/cited" "$home/data/held" "$home/data/parked"
  printf '# Widget reference\ndate: 2026-01-01\nstatus: reported\n' > "$home/data/cited/report.md"
  printf '# Widget held\ndate: 2026-01-01\nstatus: held\n' > "$home/data/held/report.md"
  printf '# Widget parked\ndate: 2026-01-01\nstatus: parked\n' > "$home/data/parked/report.md"
  printf 'Use data/cited/report.md for widget work.\n' > "$home/data/captain.md"
  printf '# Task\nContinue widget sprocket work.\nRead `data/cited/report.md` first.\n' > "$home/task.md"
  cp "$home/task.md" "$EVIDENCE/finalized-task.md"

  printf '$ fm-brief.sh evidence-brief firstmate --mode no-mistakes --task-file task.md --source data/cited/report.md\n'
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" evidence-brief firstmate --mode no-mistakes \
    --task-file "$home/task.md" --source data/cited/report.md
  brief="$home/data/evidence-brief/brief.md"
  cp "$brief" "$EVIDENCE/brief-before-session.md"
  cp "$home/data/evidence-brief/recall.json" "$EVIDENCE/brief-before-session-receipt.json"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" --check-worker ship "$brief"

  printf '\n$ fm-recall.sh --title "widget sprocket" --surface brief --now 2026-09-07\n'
  FM_HOME="$home" "$ROOT/bin/fm-recall.sh" --title 'widget sprocket' --surface brief --now 2026-09-07
  FM_HOME="$home" python3 - "$ROOT/bin/fm-recall.sh" "$EVIDENCE" <<'PY'
import json, os, subprocess, sys, time
from pathlib import Path
start = time.perf_counter()
result = subprocess.run([sys.argv[1], '--title', 'widget sprocket', '--surface', 'brief', '--json', '--now', '2026-09-07'], capture_output=True, text=True, check=True)
elapsed = time.perf_counter() - start
p = json.loads(result.stdout)
assert p['status'] == 'ok' and p['pointer_count'] <= 5 and p['estimated_tokens'] <= 150, p
Path(sys.argv[2], 'recall-response.json').write_text(result.stdout)
print('Synthetic corpus timing: %.6f seconds; documents=%s; rendered_bytes=%s; estimated_tokens=%s.' % (elapsed, p['docs'], p['bytes'], p['estimated_tokens']))
assert elapsed < 1, elapsed
PY

  printf '\n$ fm-session-start.sh\n'
  run_named_harness_session_start claude "$home" "$root" "$fakebin:$BASE_PATH" > "$EVIDENCE/session-digest.txt"
  cp "$home/state/.session-recall-receipt.$(cat "$home/state/.lock").json" "$EVIDENCE/session-receipt.json"
  cp "$home/state/.session-recall-identities" "$EVIDENCE/session-identities.txt"
  cat "$EVIDENCE/session-digest.txt"

  printf '\n$ fm-brief.sh --refresh-recall ship brief.md\n'
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" --refresh-recall ship "$brief"
  cp "$brief" "$EVIDENCE/brief-after-session.md"
  cp "$home/data/evidence-brief/recall.json" "$EVIDENCE/brief-after-session-receipt.json"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" --check-worker ship "$brief"
  python3 - "$EVIDENCE" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
before = json.loads((root / 'brief-before-session-receipt.json').read_text())
after = json.loads((root / 'brief-after-session-receipt.json').read_text())
session = json.loads((root / 'session-receipt.json').read_text())
digest = (root / 'session-digest.txt').read_text()
recalled = digest.split('\nRECALLED POINTERS\n', 1)[1].split('\nNEXT STEP\n', 1)[0]
assert before['status'] == 'emitted' and before['emitted_paths'], before
assert before['named_sources'] == ['data/cited/report.md'], before
assert 'data/cited/report.md' not in before['emitted_paths'], before
assert 'data/cited/report.md' not in recalled, recalled
assert 'data/prior-widget/report.md' in recalled and 'check-freshness' in recalled, recalled
assert all('check-freshness' not in line for line in recalled.splitlines() if 'data/held/' in line or 'data/parked/' in line), recalled
assert session['selected_item_count'] == 5, session
assert session['digest_bytes'] == len((root / 'session-digest.txt').read_bytes()), session
assert not after['emitted_paths'], after
a = (root / 'brief-before-session.md').read_text()
b = (root / 'brief-after-session.md').read_text()
assert a.split('# Recalled pointers')[0] == b.split('# Recalled pointers')[0]
assert a.split('# Herdr', 1)[1] == b.split('# Herdr', 1)[1]
print('Before session, the brief emits: ' + ', '.join(before['emitted_paths']))
print('After session, refresh emits no duplicate pointers and preserves task and scaffold text.')
print('Session receipt: ' + json.dumps(session, sort_keys=True))
PY
}

# Select the fixture helpers before the file starts its existing test cases.
trap 'if [[ "$BASH_COMMAND" == test_session_recall_returns_before_slow_network ]]; then trap - DEBUG; capture_product; exit; fi' DEBUG
source tests/fm-session-start.test.sh recall
