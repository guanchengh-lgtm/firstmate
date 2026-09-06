#!/usr/bin/env bash
set -euo pipefail
phase_root=$PWD
phase_fixture="$phase_root/.no-mistakes/test-phase/recovery-rehearsal"
export GIT_AUTHOR_NAME='Recovery fixture' GIT_AUTHOR_EMAIL=recovery@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export FM_ROOT_OVERRIDE="$phase_root" FM_RECORD_SETTLE_SECONDS=0
export FM_TEST_REAL_COMMAND
rec() { env HOME="$phase_fixture/empty-home" "$phase_root/bin/fm-record.sh" "$@"; }
for fault in mv rm; do
  printf '\nCASE: interruption at %s, followed by git status and recovery.\n' "$fault"
  export FM_HOME="$phase_fixture/$fault/home"
  export FM_DATA_OVERRIDE="$FM_HOME/data" FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
  mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/config" "$phase_fixture/empty-home" "$FM_HOME/fakebin"
  git init -q --bare -b main "$FM_HOME/origin.git"
  rec setup --init --origin "file://$FM_HOME/origin.git" --code-root "$phase_root"
  printf 'before\n' > "$FM_HOME/data/note.md"
  rec checkpoint --reason stow
  before=$(git -C "$FM_HOME/data" rev-parse HEAD)
  printf 'after\n' > "$FM_HOME/data/note.md"
  if [ "$fault" = mv ]; then export FM_TEST_FAULT_TARGET=index.lock; else export FM_TEST_FAULT_TARGET=record-publication; fi
  cat > "$FM_HOME/fakebin/$fault" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != "$FM_HOME/data/.git/$FM_TEST_FAULT_TARGET" ] || exit 1
done
exec "$FM_TEST_REAL_COMMAND" "$@"
STUB
  chmod +x "$FM_HOME/fakebin/$fault"
  FM_TEST_REAL_COMMAND=$(command -v "$fault")
  printf '\n$ fm-record.sh checkpoint --reason teardown --required [injected %s failure]\n' "$fault"
  status=0
  PATH="$FM_HOME/fakebin:$PATH" rec checkpoint --reason teardown --required || status=$?
  [ "$status" -eq 9 ]
  committed=$(git -C "$FM_HOME/data" rev-parse HEAD)
  [ "$committed" != "$before" ]
  [ -f "$FM_HOME/data/.git/record-publication/index" ]
  printf 'exit=%s; the new commit and prepared index remain recoverable.\n' "$status"
  printf '$ git show HEAD:note.md\n'
  git -C "$FM_HOME/data" show HEAD:note.md
  cp "$FM_HOME/data/.git/index" "$FM_HOME/index-before-status"
  git -C "$FM_HOME/data" ls-files --stage > "$FM_HOME/entries-before-status"
  printf '\n$ GIT_OPTIONAL_LOCKS=1 git status --porcelain\n'
  GIT_OPTIONAL_LOCKS=1 git -C "$FM_HOME/data" status --porcelain
  git -C "$FM_HOME/data" ls-files --stage > "$FM_HOME/entries-after-status"
  cmp "$FM_HOME/entries-before-status" "$FM_HOME/entries-after-status"
  ! cmp -s "$FM_HOME/index-before-status" "$FM_HOME/data/.git/index"
  printf 'git status changed cached index bytes and preserved all staged entries.\n'
  printf '\n$ fm-record.sh checkpoint --reason teardown --required [fault removed]\n'
  rec checkpoint --reason teardown --required
  [ "$(git -C "$FM_HOME/data" rev-parse HEAD)" = "$committed" ]
  git -C "$FM_HOME/data" diff --cached --quiet
  [ ! -e "$FM_HOME/data/.git/record-publication" ]
  printf 'Recovery kept the same commit, reconciled the index, and removed the completed journal.\n'
  if [ "$fault" = mv ]; then
    printf '\nCASE: recovery refuses actual user staging.\n'
    printf 'next content\n' > "$FM_HOME/data/note.md"
    status=0
    PATH="$FM_HOME/fakebin:$PATH" rec checkpoint --reason teardown --required || status=$?
    [ "$status" -eq 9 ]
    git -C "$FM_HOME/data" read-tree HEAD
    printf 'user staging\n' > "$FM_HOME/data/user.md"
    git -C "$FM_HOME/data" add user.md
    cp "$FM_HOME/data/.git/index" "$FM_HOME/staged-index"
    printf '$ git diff --cached --name-status\n'
    git -C "$FM_HOME/data" diff --cached --name-status
    printf '$ fm-record.sh checkpoint --reason stow\n'
    status=0
    rec checkpoint --reason stow || status=$?
    [ "$status" -eq 8 ]
    cmp "$FM_HOME/staged-index" "$FM_HOME/data/.git/index"
    printf 'exit=%s; the user index remained byte-for-byte unchanged.\n' "$status"
    printf '$ git show :user.md\n'
    git -C "$FM_HOME/data" show :user.md
  fi
done
