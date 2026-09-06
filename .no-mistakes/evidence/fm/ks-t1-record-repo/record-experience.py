import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
scratch_parent = root / ".no-mistakes" / "test-phase-fixtures"
scratch_parent.mkdir(parents=True, exist_ok=True)
scratch = Path(tempfile.mkdtemp(prefix="record-experience-", dir=scratch_parent))
env = os.environ.copy()
env.update(HOME=str(scratch / "empty-home"), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
           GIT_AUTHOR_NAME="Record fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
           GIT_COMMITTER_NAME="Record fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
           FM_ROOT_OVERRIDE=str(root), FM_RECORD_PUSH_TIMEOUT="5")
for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "FM_RECORD_SETTLE_SECONDS"):
    env.pop(key, None)
Path(env["HOME"]).mkdir()
home = scratch / "first-home"
origin = scratch / "origin.git"
for name in ("data/raw", "state/task-one.inbox/handled", "config"):
    (home / name).mkdir(parents=True)

def run(args, expected=0, show=True, at=None, extra=None):
    current = dict(env)
    if at:
        current.update(FM_HOME=str(at), FM_DATA_OVERRIDE=str(at / "data"),
                       FM_STATE_OVERRIDE=str(at / "state"), FM_CONFIG_OVERRIDE=str(at / "config"))
    if extra:
        current.update(extra)
    command = [str(a) for a in args]
    if show:
        print("$ " + " ".join(command), flush=True)
    result = subprocess.run(command, env=current, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if show:
        print(result.stdout.rstrip(), flush=True)
        print("exit=" + str(result.returncode), flush=True)
    assert result.returncode == expected, result.stdout
    return result.stdout

def rec(*args, at=home, expected=0):
    return run([root / "bin/fm-record.sh", *args], at=at, expected=expected)

try:
    print("Scratch-only Record experience. Git and Git LFS use a local bare remote.")
    print("The settle window uses the production default of two seconds.")
    run(["git", "init", "--quiet", "--bare", "--initial-branch=main", origin])
    rec("setup", "--init", "--origin", "file://" + str(origin), "--code-root", str(root))
    (home / "data/captain.md").write_text("# Captain note\n\nThe next step is to review the stored report.\n")
    (home / "data/raw/measurements.csv").write_bytes(b"value\n" + b"1\n" * 524285)
    (home / "data/raw/photo.png").write_bytes(bytes.fromhex("89504e470d0a1a0a") + b"Synthetic image fixture\n")
    (home / "data/note-link.md").symlink_to("captain.md")
    (home / "state/task-one.status").write_text("done: the report is ready\n")
    (home / "state/task-one.meta").write_text("kind=scout\n")
    (home / "state/task-one.inbox/handled/001.msg").write_text("Preserve the report and its context.\n")
    (home / "state/task-one.inbox/.staging.fixture").write_text("Transient bytes.\n")
    rec("checkpoint", "--reason", "stow")
    assert not run(["git", "--git-dir=" + str(origin), "for-each-ref"], show=False).strip()
    print("The completed-stow checkpoint created a local commit. The remote still has no branch.")
    rec("tick")
    before = run(["git", "-C", home / "data", "rev-parse", "HEAD"], show=False).strip()
    rec("tick")
    assert before == run(["git", "-C", home / "data", "rev-parse", "HEAD"], show=False).strip()
    print("The quiet tick preserved the commit.")
    run(["git", "--git-dir=" + str(origin), "ls-tree", "-r", "--name-only", "main"])
    run(["git", "--git-dir=" + str(origin), "show", "main:.record-state/task-one.inbox/handled/001.msg"])
    restored = scratch / "restored-home"
    restored.mkdir()
    run(["git", "clone", "--quiet", "file://" + str(origin), restored / "data"])
    rec("setup", "--origin", "file://" + str(origin), "--code-root", str(root), at=restored)
    run(["git", "-C", restored / "data", "lfs", "pull"], at=restored)
    for name in ("captain.md", "raw/photo.png", "raw/measurements.csv", ".record-state/task-one.inbox/handled/001.msg"):
        left = (home / "data" / name).read_bytes()
        right = (restored / "data" / name).read_bytes()
        assert left == right, name
        print("Restored bytes match: " + name + " sha256=" + hashlib.sha256(right).hexdigest())
    assert (restored / "data/note-link.md").read_bytes() == (restored / "data/captain.md").read_bytes()
    assert not (restored / "data/.record-state/task-one.inbox/.staging.fixture").exists()
    print("The relative link resolves at the new path. The transient inbox file is absent.")
    print("The fresh clone recreated its local LFS configuration and hooks.")
    (home / "data/manual.md").write_text("This manual change is not pushed yet.\n")
    run(["git", "-C", home / "data", "add", "manual.md"], at=home)
    run(["git", "-C", home / "data", "commit", "-qm", "Capture a manual note"], at=home)
    health_file = home / "data/.git/record-health"
    receipt = health_file.read_bytes()
    output = rec("health")
    assert "pending=1" in output and "delivery=pending" in output
    assert health_file.read_bytes() == receipt
    print("Read-only health detects the manual commit and keeps the saved push receipt unchanged.")
    away = scratch / "origin-offline.git"
    origin.rename(away)
    rec("tick", expected=6)
    rec("health")
    away.rename(origin)
    rec("tick")
    run(["git", "-C", restored / "data", "pull", "--ff-only"], at=restored)
    (restored / "data/second-device.md").write_text("The second device has independent progress.\n")
    run(["git", "-C", restored / "data", "add", "second-device.md"], at=restored)
    run(["git", "-C", restored / "data", "commit", "-qm", "Capture second device progress"], at=restored)
    run(["git", "-C", restored / "data", "push", "origin", "main"], at=restored)
    remote_tip = run(["git", "--git-dir=" + str(origin), "rev-parse", "main"], show=False).strip()
    (home / "data/first-device.md").write_text("The first device has independent progress.\n")
    rec("tick", expected=7)
    local_tip = run(["git", "-C", home / "data", "rev-parse", "HEAD"], show=False).strip()
    assert remote_tip == run(["git", "--git-dir=" + str(origin), "rev-parse", "main"], show=False).strip()
    print("Divergence retained the remote tip " + remote_tip + " and the local tip " + local_tip + ".")
    token = "ghp" + "_0123456789abcdefghijklmnopqrstuvwxyzAB"
    (home / "data/rejected.md").write_text(token + "\n")
    run(["git", "-C", home / "data", "add", "rejected.md"], at=home)
    output = run(["git", "-C", home / "data", "commit", "-qm", "Reject a synthetic scanner fixture"], at=home, expected=1, show=False)
    assert token not in output
    print("$ git commit -qm 'Reject a synthetic scanner fixture'")
    print(output.rstrip())
    print("exit=1")
    assert local_tip == run(["git", "-C", home / "data", "rev-parse", "HEAD"], show=False).strip()
    print("The real pre-commit hook refused the synthetic credential without printing its value or changing HEAD.")
finally:
    shutil.rmtree(scratch)
    if not any(scratch_parent.iterdir()):
        scratch_parent.rmdir()
