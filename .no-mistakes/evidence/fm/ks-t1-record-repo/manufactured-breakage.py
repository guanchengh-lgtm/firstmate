import json, os, pathlib, subprocess
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/AI/.no-mistakes/evidence/01M1VRWMEZJGZ0328RGDY94JYC')
cases = [
    ('fm-record', 'bin/fm-record.sh', '    if ! git --git-dir="$GIT_DIR_ABS" --work-tree="$RECORD_WORK" diff --cached --quiet --ita-visible-in-index "$tree" --; then', '    if ! cmp -s "$GIT_DIR_ABS/index" "$journal/index"; then', 'test_index_recovery_accepts_a_status_refresh'),
    ('fm-record-scan', 'bin/fm-record-scan.sh', 'SECRET_COMBINED=', None, 'test_eight_classes_refuse_without_echoing_values'),
    ('fm-captain-hold-lifecycle', 'bin/fm-captain-hold.sh', '  record_out=$("$SCRIPT_DIR/fm-record.sh" checkpoint --reason complete 2>&1) \\', '  record_out=$(true) \\', 'test_complete_scan_block_cannot_print_success'),
    ('fm-feeder-export', 'bin/fm-feeder-export.sh', '  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -name report.md -print0 > "$report_sources" 2>/dev/null \\', '  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 4 -name report.md -print0 > "$report_sources" 2>/dev/null \\', 'test_nested_git_report_is_not_exported'),
    ('fm-fleet-snapshot-view', 'bin/fm-fleet-snapshot.sh', '  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \\', '  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 4 -type f -name report.md -print \\', 'test_nested_git_report_is_not_discovered'),
    ('fm-gotmp', 'bin/fm-teardown.sh', '  rm -rf "$TASK_TMP"', '  : "$TASK_TMP"', 'test_teardown_removes_tasktmp_dir'),
    ('fm-lint', 'bin/fm-lint.sh', '    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)', '    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh data/.git/bin/*.sh)', 'test_list_files_reports_the_shell_inventory'),
    ('fm-map-fog-check', 'bin/fm-map-fog-check.sh', '    done < <(find "$DATA" -name .git -prune -o -name map.md -type f -print 2>/dev/null || true)', '    done < <(find "$DATA" -name map.md -type f -print 2>/dev/null || true)', 'test_nested_git_map_is_not_discovered'),
    ('fm-session-start', 'bin/fm-session-start.sh', '  record_out=$("$SCRIPT_DIR/fm-record.sh" checkpoint --reason session-start 2>&1) || true', '  record_out=$("$SCRIPT_DIR/fm-record.sh" health 2>&1) || true', 'test_record_checkpoint_only_on_locked_startup'),
    ('fm-stow-cascade', 'bin/fm-record.sh', '  run_transaction checkpoint "$reason" "$lock_mode"', '  return 0', 'test_cascade_does_not_checkpoint_a_configured_record'),
    ('fm-teardown', 'bin/fm-teardown.sh', '  if ! "$SCRIPT_DIR/fm-record.sh" checkpoint --reason teardown --required >&2; then', '  if ! true; then', 'test_force_preserves_record_checkpoint_when_scan_blocks'),
    ('fm-test-run', 'bin/fm-test-run.sh', '  for f in tests/*.test.sh; do', '  for f in tests/*.test.sh data/.git/tests/*.test.sh; do', 'test_list_all_exact_suite_coverage'),
]
trap = '''trap 'case "$BASH_COMMAND" in test_*) case " $FM_PHASE_SELECT " in *" ${BASH_COMMAND%% *} "*) true ;; *) set +e; false ;; esac ;; *) true ;; esac' DEBUG; source "$1"; true'''
results = []
env = dict(os.environ, FM_TEST_SKIP_ORPHAN_REAP='1')

def clean_status():
    result = subprocess.run(['git', 'status', '--porcelain'], text=True, capture_output=True, check=True)
    assert not result.stdout, result.stdout
    return 'git status --porcelain: empty'

for name, subject, old, new, selector in cases:
    clean_status()
    path = root / subject
    original = path.read_bytes()
    lines = original.decode().splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if line.rstrip('\n') == old or (new is None and line.startswith(old))]
    assert len(matches) == 1, (name, matches)
    line_index = matches[0]
    old_line = lines[line_index].rstrip('\n')
    if new is None:
        new = old_line.replace('gh[pousr]_', 'fmphase_never_')
    assert old_line != new
    lines[line_index] = new + '\n'
    red = evidence / f'breakage-{name}-red.log'
    green = evidence / f'breakage-{name}-green.log'
    test_file = f'tests/{name}.test.sh'
    command = ['bash', '-O', 'extdebug', '-c', trap, 'phase-test', test_file]
    case_env = dict(env, FM_PHASE_SELECT=selector)
    record = dict(test_file=test_file, subject=f'{subject}:{line_index + 1}', selector=selector, red=str(red), green=str(green), before=old_line, mutation=new)
    print(f'Running breakage: {test_file} subject {record["subject"]} selector {selector}', flush=True)
    try:
        path.write_bytes(''.join(lines).encode())
        with red.open('w') as log:
            log.write(f'Test: {test_file}\nSelector: {selector}\nSubject: {record["subject"]}\n- {old_line}\n+ {new}\n\n')
            log.flush()
            result = subprocess.run(command, env=case_env, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            log.write(f'\nexit={result.returncode}\n')
        record['red_exit'] = result.returncode
        assert result.returncode != 0 and 'not ok -' in red.read_text(), f'No test failure observed: {red}'
    finally:
        path.write_bytes(original)
        record['restored_status'] = clean_status()
        with red.open('a') as log:
            log.write('\nAfter source restoration: git status --porcelain is empty.\n')
        results.append(record)
        (evidence / 'manufactured-breakage.json').write_text(json.dumps(results, indent=2) + '\n')
    with green.open('w') as log:
        log.write(f'Test: {test_file}\nSelector: {selector}\nOriginal source restored. git status --porcelain is empty before this run.\n\n')
        log.flush()
        result = subprocess.run(command, env=case_env, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        log.write(f'\nexit={result.returncode}\n')
    record['green_exit'] = result.returncode
    assert result.returncode == 0 and 'ok -' in green.read_text(), f'Restored test did not pass: {green}'
    record['green_status'] = clean_status()
    (evidence / 'manufactured-breakage.json').write_text(json.dumps(results, indent=2) + '\n')
    print(f'Red observed, source restored, porcelain empty, green confirmed: {name}', flush=True)
(evidence / 'breakage-final-clean.log').write_text(clean_status() + '\nAll 12 changed test files observed a code defect and passed after source restoration.\n')
print('All manufactured breakage checks complete. Final porcelain is empty.', flush=True)
