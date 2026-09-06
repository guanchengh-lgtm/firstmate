#!/usr/bin/env bash
# Exercise linked-home refusal through each state-reading executable.
# Every repository and linked worktree belongs to this disposable fixture.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-linked-home-entrypoints)
fm_git_identity
mkdir -p "$TMP_ROOT/repo"
cp -R "$ROOT/bin" "$TMP_ROOT/repo/bin"
cp "$ROOT/AGENTS.md" "$TMP_ROOT/repo/AGENTS.md"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" add bin AGENTS.md
git -C "$TMP_ROOT/repo" -c core.hooksPath=/dev/null commit -qm 'Create the fixture.'
git -C "$TMP_ROOT/repo" worktree add -q --detach "$TMP_ROOT/copy"

python3 - "$TMP_ROOT" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
copy = root / 'copy'
repo = root / 'repo'
scripts = ('fm-session-start.sh', 'fm-lock.sh', 'fm-guard.sh',
           'fm-watch.sh', 'fm-teardown.sh', 'fm-merge-local.sh', 'fm-pr-merge.sh')
env = dict(os.environ)
for name in ('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE',
             'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE'):
    env.pop(name, None)
fakebin = root / 'fakebin'
fakebin.mkdir()
probe = root / 'lsof-called'
(fakebin / 'lsof').write_text('#!/bin/sh\nprintf called >> "$HOME_TEST_LSOF_LOG"\nexit 1\n')
(fakebin / 'lsof').chmod(0o755)
env['PATH'] = str(fakebin) + os.pathsep + env['PATH']
env['HOME_TEST_LSOF_LOG'] = str(probe)
env['FM_SUPERVISION_MODEL'] = 'persistent'


def run(script, home=None, args=()):
    command = ['env', '-u', 'FM_HOME', '-u', 'FM_ROOT_OVERRIDE', '-u', 'FM_STATE_OVERRIDE']
    if home is not None:
        command.append('FM_HOME=' + str(home))
    command.extend([str(copy / 'bin' / script), *args])
    child = subprocess.Popen(command, env=env, cwd=copy,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True, text=True)
    try:
        out, err = child.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise AssertionError(script + ' did not terminate')
    return child.returncode, out, err


def snapshot():
    return {str(path.relative_to(copy)): (path.stat().st_mtime_ns,
            path.stat().st_size if path.is_file() else None)
            for path in copy.rglob('*')}


sleeper = subprocess.Popen(['sleep', '300'], cwd=copy)
try:
    for script in scripts:
        state = copy / 'state'
        if script == 'fm-guard.sh':
            state.mkdir(exist_ok=True)
            (state / 'task.meta').write_text('window=test:worker\nkind=ship\n')
        before = snapshot()
        code, out, err = run(script)
        expected = 0 if script == 'fm-guard.sh' else 1
        assert code == expected, (script, code, out, err)
        expected_line = (f"REFUSED: {script} self-located its home to linked worktree {copy}; "
                         f"that copy's state/ is not a firstmate home. Set FM_HOME={repo} "
                         f"or start firstmate from {repo}, then retry.\n")
        assert err == expected_line, (script, err)
        assert not out, (script, out)
        assert 'WATCHER DOWN' not in out + err, script
        assert snapshot() == before, script + ' changed the linked home'
        assert not (state / '.lock').exists(), script
        assert not (state / '.watch.lock').exists(), script
        assert not probe.exists(), script + ' called lsof before refusal'
        assert sleeper.poll() is None, script + ' killed the worktree sleeper'
        assert copy.is_dir(), script + ' removed the worktree'
        print('ok - ' + script + ' refuses the linked home before state or process changes')

    # Both allowed-home cases must demonstrably reach each executable's next gate.
    plain = root / 'plain-home'
    plain.mkdir()
    (copy / '.fm-secondmate-home').write_text('test-secondmate\n')
    for home in (plain, copy):
        state = home / 'state'
        state.mkdir(exist_ok=True)
        lock = state / '.watch.lock'
        lock.mkdir()
        (lock / 'pid').write_text(str(sleeper.pid) + '\n')
        for script in scripts:
            args = ()
            if script == 'fm-session-start.sh':
                args = ('--unknown-test-option',)
            elif script == 'fm-lock.sh':
                args = ('status',)
            code, out, err = run(script, home=home, args=args)
            assert 'self-located its home to linked worktree' not in out + err, (home, script, err)
            if script == 'fm-session-start.sh':
                assert code == 2 and 'unknown argument' in err, (script, code, out, err)
            elif script == 'fm-lock.sh':
                assert code == 0 and 'lock: free' in out, (script, code, out, err)
            elif script == 'fm-watch.sh':
                assert code == 0 and 'watcher: already running' in out, (script, code, out, err)
            elif script == 'fm-guard.sh':
                assert code == 0, (script, code, out, err)
            else:
                assert code != 0 and out + err, (script, code, out, err)
            print('ok - ' + script + ' accepts effective ' + ('marked secondmate' if home == copy else 'non-git home'))
finally:
    sleeper.terminate()
    sleeper.wait(timeout=5)
PY
