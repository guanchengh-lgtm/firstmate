"""Run the five required one-line mutations, restoring each before its green run."""
from pathlib import Path
import json
import os
import subprocess

root = Path.cwd()
evidence = Path('/Users/AI/.no-mistakes/evidence/01M1VX4783MRHEA6B80DDHFHSY')
env = dict(os.environ, TMPDIR=str(root / 'state/test-tmp'))

cases = [
    ('tests/fm-recall.test.sh', 'bin/fm-recall.py', 'BRIEF_LIMIT = 5', 'BRIEF_LIMIT = 6', 'all', ['bash', 'tests/fm-recall.test.sh']),
    ('tests/fm-brief.test.sh', 'bin/fm-brief.sh', '  if brief_task_is_pending "$task_tmp"; then', '  if true; then', 'recall', ['bash', 'tests/fm-brief.test.sh', 'recall']),
    ('tests/fm-session-start.test.sh', 'bin/fm-session-start.sh', '      limit = (n < 5) ? n : 5', '      limit = (n < 4) ? n : 4', 'test_session_recall_selects_five_open_items', ['bash', '-T', '-c', '''trap 'if [[ "$BASH_COMMAND" == test_session_recall_returns_before_slow_network ]]; then trap - DEBUG; test_session_recall_selects_five_open_items; exit; fi' DEBUG; source tests/fm-session-start.test.sh recall''']),
    ('tests/fm-lint.test.sh', 'bin/fm-lint.sh', 'REQUIRED_RUFF=0.16.6', 'REQUIRED_RUFF=0.0.0', 'test_pins_an_explicit_version', ['bash', '-T', '-c', '''trap 'if [[ "$BASH_COMMAND" == test_help_reports_the_complete_interface ]]; then trap - DEBUG; test_pins_an_explicit_version; exit; fi' DEBUG; source tests/fm-lint.test.sh''']),
    ('tests/fm-test-run.test.sh', 'bin/fm-test-run.sh', '    bin/fm-recall.sh|bin/fm-recall.py)', '    bin/fm-recall.sh|bin/fm-recall-disabled.py)', 'test_changed_dependency_selection_and_unmapped_failure', ['bash', '-T', '-c', '''trap 'if [[ "$BASH_COMMAND" == test_list_all_exact_suite_coverage ]]; then trap - DEBUG; test_changed_dependency_selection_and_unmapped_failure; exit; fi' DEBUG; source tests/fm-test-run.test.sh''']),
]
entries = []
for test, subject, old, new, selector, command in cases:
    assert not subprocess.check_output(['git', 'status', '--porcelain']), 'Mutation requires a clean worktree.'
    path = root / subject
    original = path.read_bytes()
    text = original.decode()
    assert text.count(old) == 1, (subject, old, text.count(old))
    line = text[:text.index(old)].count('\n') + 1
    label = Path(test).name.removesuffix('.test.sh')
    red_path = evidence / (label + '-mutation-red.log')
    green_path = evidence / (label + '-mutation-green.log')
    print('Mutating %s:%s for %s (%s).' % (subject, line, test, selector), flush=True)
    try:
        path.write_bytes(text.replace(old, new).encode())
        red = subprocess.run(command, env=env, capture_output=True, text=True, timeout=300)
        red_path.write_text('Subject: %s:%s\nBefore: %s\nAfter: %s\nSelector: %s\nCommand: %s\nExit: %s\n\n%s%s' % (subject, line, old, new, selector, json.dumps(command), red.returncode, red.stdout, red.stderr))
    finally:
        path.write_bytes(original)
    assert not subprocess.check_output(['git', 'status', '--porcelain']), 'Restore left a dirty worktree.'
    assert red.returncode != 0, ('Mutation survived', test)
    print('Observed red; restored source; git status --porcelain is empty.', flush=True)
    green = subprocess.run(command, env=env, capture_output=True, text=True, timeout=300)
    green_path.write_text('Command: %s\nExit: %s\n\n%s%s' % (json.dumps(command), green.returncode, green.stdout, green.stderr))
    assert green.returncode == 0, (test, green.stdout, green.stderr)
    assert not subprocess.check_output(['git', 'status', '--porcelain']), 'Green run left a dirty worktree.'
    entry = 'breakage: %s subject %s:%s selector %s red %s; restored; porcelain empty; same selector green (%s).' % (test, subject, line, selector, red_path, green_path)
    entries.append(entry)
    (evidence / 'breakage-tested.json').write_text(json.dumps(entries, indent=2) + '\n')
    print('Same selector is green.', flush=True)
entries.append('breakage: final clean state; git status --porcelain is empty after all five restores and green reruns.')
(evidence / 'breakage-tested.json').write_text(json.dumps(entries, indent=2) + '\n')
print(entries[-1], flush=True)
