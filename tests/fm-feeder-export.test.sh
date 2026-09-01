#!/usr/bin/env bash
# Behavior tests for the one-way feeder vault exporter: preflight refusal, safe
# aliases, secrets, dates, collisions, signals, every transaction phase, Git
# failures, push retry, and an end-to-end push into a local bare origin.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The repo's bounded-execution owner: it reproduces GNU timeout's 124 on every
# platform and terminates the whole process group, so a wedged export under test
# cannot outlive the bound.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

EXPORT="$ROOT/bin/fm-feeder-export.sh"
# The exporter requires a canonical physical vault path, and the platform temp
# root is often reached through a symlink, so resolve it once here.
TMP_ROOT=$(cd "$(fm_test_tmproot fm-feeder-export)" && pwd -P)
REAL_GIT=$(command -v git)
VAULT_REPO=guanchengh-lgtm/fm-vault
VAULT_URL="git@github.com:$VAULT_REPO.git"
MARKER_VERSION=firstmate-feeder-vault-v1
# shellcheck disable=SC2016 # The banner names sot_path literally, backticks included.
BANNER='> Mirror of a firstmate record. Not the system of record. Read `sot_path` before acting.'
CASE_SEQ=0

fm_git_identity

# --- fixture ----------------------------------------------------------------

write_marker() {  # <vault> <owner/name>
  printf '%s\nremote=%s\n' "$MARKER_VERSION" "$2" > "$1/.feeder-vault"
}

make_gh_axi() {  # <dir> <private|public|fail>
  local dir=$1 mode=$2
  cat > "$dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/gh.log"
if [ -n "\${FM_TEST_GH_LINK_PATH:-}" ]; then
  rm -rf -- "\$FM_TEST_GH_LINK_PATH"
  ln -s "\$FM_TEST_GH_LINK_TARGET" "\$FM_TEST_GH_LINK_PATH"
fi
case "$mode" in
  fail) exit 1 ;;
  none) printf 'repo:\n  name: fm-vault\n'; exit 0 ;;
  ambiguous) printf 'repo:\n  visibility: private\n  visibility: public\n'; exit 0 ;;
esac
printf 'repo:\n  name: fm-vault\n  visibility: %s\n' "$mode"
SH
  chmod +x "$dir/fakebin/gh-axi"
}

make_fixture_ssh() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/fm-feeder-ssh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *git-receive-pack*) exec $REAL_GIT receive-pack "$dir/origin.git" ;;
  *git-upload-pack*) exec $REAL_GIT upload-pack "$dir/origin.git" ;;
esac
exit 1
SH
  chmod +x "$dir/fakebin/fm-feeder-ssh"
}

make_fake_git() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/git" <<SH
#!/usr/bin/env bash
sub=
skip=0
for arg in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$arg" in
    -C | -c) skip=1; continue ;;
    -*) continue ;;
    *) sub=\$arg; break ;;
  esac
done
if [ -n "\${FM_TEST_GIT_SIGNAL:-}" ] && [ "\$sub" = "\${FM_TEST_GIT_SIGNAL_AT:-}" ]; then
  kill -"\$FM_TEST_GIT_SIGNAL" "\$PPID"
  exit 0
fi
if [ -n "\${FM_TEST_GIT_FAIL:-}" ] && [ "\$sub" = "\$FM_TEST_GIT_FAIL" ]; then
  printf 'fake git: forced failure on %s\n' "\$sub" >&2
  exit 1
fi
if [ -n "\${FM_TEST_GIT_FAIL_RESET:-}" ] && [ "\$sub" = reset ]; then
  printf 'fake git: forced reset failure\n' >&2
  exit 1
fi
if [ -n "\${FM_TEST_GIT_SIGNAL_AFTER:-}" ] && [ "\$sub" = "\${FM_TEST_GIT_SIGNAL_AFTER_AT:-}" ]; then
  $REAL_GIT "\$@" || exit \$?
  kill -"\$FM_TEST_GIT_SIGNAL_AFTER" "\$PPID"
  exit 0
fi
if [ -n "\${FM_TEST_GIT_CORRUPT_PATH:-}" ] && [ "\$sub" = commit ]; then
  $REAL_GIT "\$@" || exit \$?
  rel=\${FM_TEST_GIT_CORRUPT_PATH#"\$FM_TEST_GIT_VAULT"/}
  save="\$FM_TEST_GIT_CORRUPT_PATH.fm-test-save"
  $(command -v cp) "\$FM_TEST_GIT_CORRUPT_PATH" "\$save"
  printf 'same-count committed corruption\n' >> "\$FM_TEST_GIT_CORRUPT_PATH"
  $REAL_GIT -C "\$FM_TEST_GIT_VAULT" add -- "\$rel"
  $REAL_GIT -C "\$FM_TEST_GIT_VAULT" -c core.hooksPath=/dev/null commit -qm 'corrupt committed tree' --amend
  $(command -v mv) "\$save" "\$FM_TEST_GIT_CORRUPT_PATH"
  exit 0
fi
if [ -n "\${FM_TEST_GIT_EXTRA_COMMIT:-}" ] && [ "\$sub" = commit ]; then
  $REAL_GIT "\$@" || exit \$?
  printf 'unrelated lineage\n' > "\$FM_TEST_GIT_VAULT/lineage.txt"
  $REAL_GIT -C "\$FM_TEST_GIT_VAULT" add lineage.txt
  $REAL_GIT -C "\$FM_TEST_GIT_VAULT" -c core.hooksPath=/dev/null commit -qm 'unrelated extra commit'
  exit 0
fi
if [ -n "\${FM_TEST_GIT_UNOWNED_AMEND:-}" ] && [ "\$sub" = commit ]; then
  $REAL_GIT "\$@" || exit \$?
  printf 'unowned hook file\n' > "\$FM_TEST_GIT_VAULT/unowned-hook.txt"
  $REAL_GIT -C "\$FM_TEST_GIT_VAULT" add unowned-hook.txt
  $REAL_GIT -C "\$FM_TEST_GIT_VAULT" -c core.hooksPath=/dev/null commit -q --amend --no-edit
  exit 0
fi
if [ -n "\${FM_TEST_GIT_DIRTY_AFTER_COMMIT:-}" ] && [ "\$sub" = commit ]; then
  $REAL_GIT "\$@" || exit \$?
  printf 'dirty after commit\n' >> "\$FM_TEST_GIT_DIRTY_AFTER_COMMIT"
  exit 0
fi
if [ -n "\${FM_TEST_GIT_BACKUP_AFTER_COMMIT:-}" ] && [ "\$sub" = commit ]; then
  $REAL_GIT "\$@" || exit \$?
  mkdir -p "\$FM_TEST_GIT_VAULT/.git/fm-feeder/backup.injected"
  exit 0
fi
exec $REAL_GIT "\$@"
SH
  chmod +x "$dir/fakebin/git"
}

make_dubious_home_git() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = "$dir/home" ] && [ "\${3:-}" = rev-parse ]; then
  printf 'fatal: detected dubious ownership in repository\n' >&2
  exit 128
fi
exec $REAL_GIT "\$@"
SH
  chmod +x "$dir/fakebin/git"
}

make_fake_tool() {  # <dir> <tool> <real-path>
  local dir=$1 tool=$2 real=$3
  cat > "$dir/fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_TEST_${tool}_FAIL:-}" ]; then
  printf 'fake $tool: forced failure\n' >&2
  exit "\${FM_TEST_${tool}_FAIL_CODE:-1}"
fi
if [ -n "\${FM_TEST_${tool}_FAIL_AT:-}" ]; then
  count=0
  [ -f "\${FM_TEST_COUNTER:-/dev/null}" ] && count=\$(cat "\$FM_TEST_COUNTER")
  count=\$((count + 1))
  printf '%s\n' "\$count" > "\${FM_TEST_COUNTER:-/dev/null}"
  if [ "\$count" -ge "\$FM_TEST_${tool}_FAIL_AT" ]; then
    printf 'fake $tool: forced counted failure\n' >&2
    exit "\${FM_TEST_${tool}_FAIL_CODE:-2}"
  fi
fi
if [ -n "\${FM_TEST_${tool}_SIGNAL:-}" ]; then
  count=0
  [ -f "\${FM_TEST_COUNTER:-/dev/null}" ] && count=\$(cat "\$FM_TEST_COUNTER")
  count=\$((count + 1))
  printf '%s\n' "\$count" > "\${FM_TEST_COUNTER:-/dev/null}"
  if [ "\$count" -ge "\${FM_TEST_${tool}_SIGNAL_AT:-1}" ]; then
    kill -"\$FM_TEST_${tool}_SIGNAL" "\$PPID"
    exit 0
  fi
fi
if [ -n "\${FM_TEST_${tool}_CORRUPT:-}" ]; then
  "$real" "\$@" || exit \$?
  printf 'raced\n' >> "\$FM_TEST_${tool}_CORRUPT"
  exit 0
fi
if [ -n "\${FM_TEST_${tool}_REPLACE:-}" ]; then
  "$real" "\$@" || exit \$?
  count=0
  [ -f "\${FM_TEST_COUNTER:-/dev/null}" ] && count=\$(cat "\$FM_TEST_COUNTER")
  count=\$((count + 1))
  printf '%s\n' "\$count" > "\${FM_TEST_COUNTER:-/dev/null}"
  if [ "\$count" -ge "\${FM_TEST_${tool}_REPLACE_AT:-1}" ]; then
    $(command -v cp) "\$FM_TEST_${tool}_REPLACE" "\$FM_TEST_${tool}_REPLACE.fm-test-replacement"
    $(command -v mv) "\$FM_TEST_${tool}_REPLACE.fm-test-replacement" "\$FM_TEST_${tool}_REPLACE"
  fi
  exit 0
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/$tool"
}

make_live_digest_failure() {  # <dir>
  local dir=$1 tool real
  for tool in shasum sha256sum; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    cat > "$dir/fakebin/$tool" <<SH
#!/usr/bin/env bash
case "\$PWD" in
  '$dir/vault/wiki/decisions')
    : > '$dir/fail-next-live-digest'
    exec $real "\$@"
    ;;
esac
if [ -e '$dir/fail-next-live-digest' ]; then
  rm -f '$dir/fail-next-live-digest'
  printf 'fake $tool: forced live digest failure\n' >&2
  exit 7
fi
exec $real "\$@"
SH
    chmod +x "$dir/fakebin/$tool"
  done
}

make_live_digest_enumeration_failure() {  # <dir>
  local dir=$1 real
  real=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
case "\$PWD" in
  '$dir/vault/wiki/decisions')
    $real "\$@"
    printf 'fake find: forced live enumeration failure\n' >&2
    exit 2
    ;;
esac
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/find"
}

make_hits_file_blocking_cp() {  # <dir>
  local dir=$1 real
  real=$(command -v cp)
  cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
$real "\$@" || exit \$?
last=
for arg in "\$@"; do last=\$arg; done
case "\$last" in
  */snapshot/*)
    stage=\${last%/snapshot/*}
    mkdir -p "\$stage/secret-scan-hits"
    ;;
esac
SH
  chmod +x "$dir/fakebin/cp"
}

make_secret_sort_failure() {  # <dir>
  local dir=$1 real
  real=$(command -v sort)
  cat > "$dir/fakebin/sort" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */secret-scan-hits | */secret-scan-hits.sorted)
      printf 'fake sort: forced secret-scan failure\n' >&2
      exit 2
      ;;
  esac
done
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/sort"
}

make_selective_find_failure() {  # <dir>
  local dir=$1 real
  real=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_TEST_FIND_SOURCE_FAIL_PATH:-}" ] \
  && [ "\${1:-}" = "\$FM_TEST_FIND_SOURCE_FAIL_PATH" ]; then
  printf 'fake find: forced source enumeration failure\n' >&2
  exit 2
fi
backup=0
for arg in "\$@"; do
  [ "\$arg" != 'backup.*' ] || backup=1
done
if [ "\$backup" -eq 1 ] && [ -n "\${FM_TEST_FIND_BACKUP_FAIL_AT:-}" ]; then
  count=0
  [ -f '$dir/find-backup-count' ] && count=\$(cat '$dir/find-backup-count')
  count=\$((count + 1))
  printf '%s\n' "\$count" > '$dir/find-backup-count'
  if [ "\$count" -eq "\$FM_TEST_FIND_BACKUP_FAIL_AT" ]; then
    printf 'fake find: forced backup enumeration failure\n' >&2
    exit 2
  fi
fi
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/find"
}

make_exclusion_lookup_failure() {  # <dir>
  local dir=$1 real
  real=$(command -v grep)
  cat > "$dir/fakebin/grep" <<SH
#!/usr/bin/env bash
last=
for arg in "\$@"; do last=\$arg; done
if [ "\${1:-}" = -Fxq ]; then
  case "\$last" in
    */excludes)
      printf 'fake grep: forced exclusion lookup failure\n' >&2
      exit 2
      ;;
  esac
fi
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/grep"
}

make_tracked_lookup_failure() {  # <dir>
  local dir=$1 real
  real=$(command -v grep)
  cat > "$dir/fakebin/grep" <<SH
#!/usr/bin/env bash
last=
for arg in "\$@"; do last=\$arg; done
if [ "\${1:-}" = -Fxq ]; then
  case "\$last" in
    */tracked)
      printf 'fake grep: forced tracked-source lookup failure\n' >&2
      exit 2
      ;;
  esac
fi
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/grep"
}

make_truncating_cat() {  # <dir>
  local dir=$1 real
  real=$(command -v cat)
  cat > "$dir/fakebin/cat" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  */snapshot/*)
    $real "\$1" | sed -n '1p'
    exit 0
    ;;
esac
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/cat"
}

make_corrupt_index_awk() {  # <dir>
  local dir=$1 real
  real=$(command -v awk)
  cat > "$dir/fakebin/awk" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *'printf "- [[%s]]'*)
      $real "\$@" | $real 'NR == 1 { first = \$0; print; next } NR == 2 { print first; next } { print }'
      exit 0
      ;;
  esac
done
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/awk"
}

make_render_path_linker() {  # <dir>
  local dir=$1 real
  real=$(command -v awk)
  cat > "$dir/fakebin/awk" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */snapshot/*)
      $real "\$@" || exit \$?
      if [ ! -e "\${FM_TEST_RENDER_LINK_DONE:-}" ]; then
        link_path=\$FM_TEST_RENDER_LINK_PATH
        link_path=\${link_path//@pid@/\$PPID}
        rm -f "\$link_path"
        ln -s "\$FM_TEST_RENDER_LINK_TARGET" "\$link_path"
        : > "\$FM_TEST_RENDER_LINK_DONE"
      fi
      exit 0
      ;;
  esac
done
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/awk"
}

make_platform_date_tools() {  # <dir> <Darwin|Linux> [birth|mtime]
  local dir=$1 platform=$2 birth_mode=${3:-birth} birth_epoch real_date real_stat
  if [ "$birth_mode" = birth ]; then birth_epoch=946684800; else birth_epoch=0; fi
  real_date=$(command -v date)
  real_stat=$(command -v stat)
  cat > "$dir/fakebin/uname" <<SH
#!/usr/bin/env bash
printf '%s\n' '$platform'
SH
  cat > "$dir/fakebin/stat" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-f %d:%i -- '* | '-c %d:%i -- '*) printf '1:1\n'; exit 0 ;;
  '-f %d -- '* | '-c %d -- '*) printf '1\n'; exit 0 ;;
  '-f %B -- '* | '-c %W -- '*) printf '%s\n' '$birth_epoch'; exit 0 ;;
  '-f %m -- '* | '-c %Y -- '*) printf '946684800\n'; exit 0 ;;
esac
exec $real_stat "\$@"
SH
  cat > "$dir/fakebin/date" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-u -r 946684800 +%Y-%m-%d' | '-u -d @946684800 +%Y-%m-%d') printf '2000-01-01\n'; exit 0 ;;
  '-j -u -f %Y-%m-%d 2000-01-01 +%Y-%m-%d' | '-u -d 2000-01-01 +%Y-%m-%d') printf '2000-01-01\n'; exit 0 ;;
esac
exec $real_date "\$@"
SH
  chmod +x "$dir/fakebin/uname" "$dir/fakebin/stat" "$dir/fakebin/date"
}

make_split_device_stat() {  # <dir> <path>
  local dir=$1 path=$2 real
  real=$(command -v stat)
  cat > "$dir/fakebin/stat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 4 ] && [ "\$3" = -- ] && [ "\$4" = "$path" ]; then
  case "\$1:\$2" in
    '-f:%d' | '-c:%d') printf '999999999\n'; exit 0 ;;
  esac
fi
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/stat"
}

make_snapshot_metadata_mutator() {  # <dir>
  local dir=$1 real
  real=$(command -v cp)
  cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
$real "\$@" || exit \$?
if [ -n "\${FM_TEST_CP_CREATE_SOURCE:-}" ] && [ ! -e "\${FM_TEST_CP_MUTATED:-}" ]; then
  printf '# Added during export\n\nnew source\n' > "\$FM_TEST_CP_CREATE_SOURCE"
  : > "\$FM_TEST_CP_MUTATED"
fi
if [ -n "\${FM_TEST_CP_TOUCH_SOURCE:-}" ] && [ ! -e "\${FM_TEST_CP_MUTATED:-}" ]; then
  touch -t 203001020304 "\$FM_TEST_CP_TOUCH_SOURCE"
  : > "\$FM_TEST_CP_MUTATED"
fi
SH
  chmod +x "$dir/fakebin/cp"
}

make_publication_signaling_mv() {  # <dir>
  local dir=$1 real
  real=$(command -v mv)
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_TEST_PUBLISH_VAULT:-}" ] \
  && [ -f "\$FM_TEST_PUBLISH_VAULT/.git/fm-feeder/journal" ] \
  && [ ! -e "\${FM_TEST_SIGNAL_MARKER:-/dev/null}" ]; then
  count=0
  [ -f "\${FM_TEST_COUNTER:-/dev/null}" ] && count=\$(cat "\$FM_TEST_COUNTER")
  count=\$((count + 1))
  printf '%s\n' "\$count" > "\${FM_TEST_COUNTER:-/dev/null}"
  if [ "\$count" -eq "\${FM_TEST_PUBLISH_MV_AT:-0}" ]; then
    $real "\$@" || exit \$?
    : > "\$FM_TEST_SIGNAL_MARKER"
    kill -"\$FM_TEST_PUBLISH_SIGNAL" "\$PPID"
    exit 0
  fi
fi
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/mv"
}

make_cleanup_signaling_rm() {  # <dir>
  local dir=$1 real
  real=$(command -v rm)
  cat > "$dir/fakebin/rm" <<SH
#!/usr/bin/env bash
matched=0
for arg in "\$@"; do
  case "\$arg" in *backup.*) matched=1 ;; esac
done
if [ "\$matched" -eq 1 ] && [ ! -e "\${FM_TEST_SIGNAL_MARKER:-/dev/null}" ]; then
  $real "\$@" || exit \$?
  : > "\$FM_TEST_SIGNAL_MARKER"
  kill -"\$FM_TEST_CLEANUP_SIGNAL" "\$PPID"
  exit 0
fi
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/rm"
}

fixture_sha256_file() {  # <file>
  if command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

write_hash_wrapper() {  # <path> <shasum|sha256sum>
  local path=$1 interface=$2 provider
  if command -v "$interface" > /dev/null 2>&1; then
    provider=$(command -v "$interface")
    cat > "$path" <<SH
#!/usr/bin/env bash
exec $provider "\$@"
SH
  elif [ "$interface" = shasum ]; then
    provider=$(command -v sha256sum)
    cat > "$path" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -a ]; then shift 2; fi
exec $provider "\$@"
SH
  else
    provider=$(command -v shasum)
    cat > "$path" <<SH
#!/usr/bin/env bash
exec $provider -a 256 "\$@"
SH
  fi
  chmod +x "$path"
}

make_export_day_date() {  # <dir>
  local dir=$1 real
  real=$(command -v date)
  cat > "$dir/fakebin/date" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-u +%Y-%m-%d') printf '%s\n' "\${FM_TEST_EXPORT_DAY:-2026-08-31}"; exit 0 ;;
  '-u +%Y%m%dT%H%M%SZ') printf '%sT000000Z\n' "\$(printf '%s' "\${FM_TEST_EXPORT_DAY:-2026-08-31}" | tr -d -)"; exit 0 ;;
esac
exec $real "\$@"
SH
  chmod +x "$dir/fakebin/date"
}

new_case() {  # <name> -> prints the case directory
  local name=$1 dir
  CASE_SEQ=$((CASE_SEQ + 1))
  dir="$TMP_ROOT/case-$CASE_SEQ-$name"
  mkdir -p "$dir/home/data/decisions" "$dir/home/config" "$dir/fakebin"
  : > "$dir/gh.log"
  git init -q --bare "$dir/origin.git"
  git init -q "$dir/vault"
  git -C "$dir/vault" symbolic-ref HEAD refs/heads/main
  write_marker "$dir/vault" "$VAULT_REPO"
  git -C "$dir/vault" add .feeder-vault
  git -C "$dir/vault" commit -qm init
  make_fixture_ssh "$dir"
  git -C "$dir/vault" remote add origin "$VAULT_URL"
  GIT_SSH_COMMAND="$dir/fakebin/fm-feeder-ssh" git -C "$dir/vault" push -q origin main
  git -C "$dir/vault" branch -q -u origin/main main
  printf '%s\n' "$dir/vault" > "$dir/home/config/feeder-vault"
  make_gh_axi "$dir" private
  printf '%s\n' "$dir"
}

secret_fixture() {  # <fixture> -> prints one assembled credential sample
  # Credential samples are assembled from fragments at run time. A committed
  # literal credential shape trips GitHub push protection and blocks the push,
  # so no line of this file may hold a complete scanner-matching credential.
  case "$1" in
    openssh-private-key) printf -- '-----BEGIN OPENSSH PRIVATE %s-----' 'KEY' ;;
    encrypted-private-key) printf -- '-----BEGIN ENCRYPTED PRIVATE %s-----' 'KEY' ;;
    github-classic) printf '%s%s' 'ghp' '_0123456789abcdefghijklmnopqrstuvwxyzAB' ;;
    github-pat) printf '%s%s' 'github' '_pat_0123456789abcdefghijklmnop' ;;
    aws-access-key) printf '%s%s' 'AKI' 'AABCDEFGHIJKLMNOP' ;;
    slack) printf '%s%s' 'xox' 'b-0123456789abcdef' ;;
    stripe-live) printf '%s%s' 'sk' '_live_0123456789abcdefgh' ;;
    google-api) printf '%s%s' 'AIz' 'aabcdefghijklmnopqrstuvwxyz0123456789' ;;
    openai-project) printf '%s%s' 'sk-' 'proj-0123456789_abcd-efghijklmnop' ;;
    openai-service-account) printf '%s%s' 'sk-' 'svcacct-0123456789_abcd-efghijklmnop' ;;
    openai-admin) printf '%s%s' 'sk-' 'admin-0123456789_abcd-efghijklmnop' ;;
    openai-plain) printf '%s%s' 'sk-' '0123456789abcdefghijklmnop' ;;
    openai-underscore-suffix) printf '%s%s' 'sk-' '0123456789abcdefghij_suffix' ;;
    *) fail "secret_fixture: unknown fixture $1" ;;
  esac
}

add_decision() {  # <dir> <name> <content>
  printf '%s' "$3" > "$1/home/data/decisions/$2"
}

add_report() {  # <dir> <task-id> <content>
  mkdir -p "$1/home/data/$2"
  printf '%s' "$3" > "$1/home/data/$2/report.md"
}

seed_records() {  # <dir>
  add_decision "$1" alpha-2026-01-05.md '# Alpha lock

alpha body
'
  add_report "$1" task-one '# Report one

report body
'
}

RC=0
OUT=

run_export() {  # <dir> [VAR=VAL...]
  local dir=$1
  shift
  OUT=$(env PATH="$dir/fakebin:$PATH" GIT_SSH_COMMAND="$dir/fakebin/fm-feeder-ssh" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$@" "$EXPORT" 2>&1)
  RC=$?
  return 0
}

vault_state() {  # <dir>
  local dir=$1 file
  printf 'head=%s\n' "$(git -C "$dir/vault" rev-parse HEAD 2>/dev/null || printf none)"
  printf 'remote=%s\n' "$(git -C "$dir/origin.git" rev-parse refs/heads/main 2>/dev/null || printf none)"
  printf 'status=%s\n' "$(git -C "$dir/vault" status --porcelain 2>/dev/null | tr '\n' ';')"
  if [ -d "$dir/vault/wiki" ]; then
    (
      cd "$dir/vault" || exit 0
      LC_ALL=C find wiki -type f | LC_ALL=C sort | while IFS= read -r file; do
        printf '%s %s\n' "$file" "$(shasum -a 256 "$file" | awk '{print $1}')"
      done
    )
  fi
}

fixture_dir_digest() {  # <dir>
  local dir=$1
  (
    cd "$dir" || exit 1
    LC_ALL=C find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s\t%s\n' "$file" "$(shasum -a 256 "$file" | awk '{print $1}')"
    done | shasum -a 256 | awk '{print $1}'
  )
}

assert_refused() {  # <dir> <needle> <label> [expected-rc]
  local dir=$1 needle=$2 label=$3 want_rc=${4:-} before
  before=$(vault_state "$dir")
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail "$label: exporter unexpectedly succeeded"
  if [ -n "$want_rc" ]; then
    expect_code "$want_rc" "$RC" "$label"
  fi
  assert_contains "$OUT" "$needle" "$label"
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail "$label: the vault changed before refusal"$'\n'"$(vault_state "$dir")"
}

assert_export_ok() {  # <dir> <label>
  run_export "$1"
  [ "$RC" -eq 0 ] || fail "$2: exporter failed with $RC"$'\n'"$OUT"
}

page_field() {  # <page> <field>
  LC_ALL=C awk -v key="$2" -F': ' '$1 == key { sub(/^[^:]*: /, ""); print; exit }' "$1"
}

parsed_page_title() {  # <page>
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse generated feeder YAML"
  ruby -ryaml -e '
text = File.read(ARGV.fetch(0), encoding: "UTF-8")
match = text.match(/\A---\n(.*?)\n---\n/m)
raise "missing frontmatter" if match.nil?
document = YAML.load(match[1])
title = document.fetch("title")
raise "title is not a string" unless title.is_a?(String)
print title
' "$1"
}

# --- preflight: configuration ------------------------------------------------

test_config_refusals() {
  local dir config before
  dir=$(new_case config)
  seed_records "$dir"
  config="$dir/home/config/feeder-vault"

  rm -f "$config"
  assert_refused "$dir" 'missing feeder vault config' 'missing config'

  : > "$config"
  assert_refused "$dir" 'is empty' 'empty config'

  printf '%s\n%s\n' "$dir/vault" "$dir/vault" > "$config"
  assert_refused "$dir" 'exactly one line' 'multiline config'

  printf '%s\n%s' "$dir/vault" "$dir/vault" > "$config"
  assert_refused "$dir" 'exactly one line' 'unterminated second config record'

  printf 'vault\n' > "$config"
  assert_refused "$dir" 'must be absolute and normalized' 'relative config'

  printf '%s\n' "$dir/../$(basename "$dir")/vault" > "$config"
  assert_refused "$dir" 'must be absolute and normalized' 'traversal config'

  printf '%s\n' "$dir/va$(printf '\t')ult" > "$config"
  assert_refused "$dir" 'must be absolute and normalized' 'control-character config'

  printf '%s\000\n' "$dir/vault" > "$config"
  assert_refused "$dir" 'must not contain NUL bytes' 'NUL byte in vault config'

  printf '%s\n' "$dir/absent-vault" > "$config"
  assert_refused "$dir" 'is not a directory' 'nonexistent config target'

  rm -f "$config"
  printf '%s\n' "$dir/vault" > "$dir/real-config"
  ln -s "$dir/real-config" "$config"
  assert_refused "$dir" 'must not be a symlink' 'symbolic config file'

  rm -f "$config"
  ln -s "$dir/vault" "$dir/vault-link"
  printf '%s\n' "$dir/vault-link" > "$config"
  assert_refused "$dir" 'must not be a symlink' 'symbolic vault path'

  dir=$(new_case config-glob)
  seed_records "$dir"
  config="$dir/home/config/feeder-vault"
  printf '%s\n' "$dir/v*" > "$config"
  before=$(vault_state "$dir")
  OUT=$(cd "$dir" && env PATH="$dir/fakebin:$PATH" \
    GIT_SSH_COMMAND="$dir/fakebin/fm-feeder-ssh" FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" "$EXPORT" 2>&1)
  RC=$?
  [ "$RC" -ne 0 ] || fail 'wildcard vault path: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'is not a directory' 'wildcard vault path'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'wildcard vault path: the vault changed before refusal'

  pass "fm-feeder-export: malformed vault configuration refuses before any mutation"
}

test_git_environment_refusals() {
  local dir variable before
  dir=$(new_case git-environment)
  seed_records "$dir"
  before=$(vault_state "$dir")

  for variable in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; do
    run_export "$dir" "$variable=$dir/git-override"
    [ "$RC" -ne 0 ] || fail "$variable override: exporter unexpectedly succeeded"
    assert_contains "$OUT" "Git environment override $variable" "$variable override"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "$variable override: the vault changed before refusal"
  done

  pass "fm-feeder-export: Git path and object overrides refuse before mutation"
}

test_vault_identity_refusals() {
  local dir config before
  dir=$(new_case vault-identity)
  seed_records "$dir"
  config="$dir/home/config/feeder-vault"

  mkdir -p "$dir/plain"
  write_marker "$dir/plain" "$VAULT_REPO"
  printf '%s\n' "$dir/plain" > "$config"
  assert_refused "$dir" 'is not a Git repository' 'non-repository vault'

  mkdir -p "$dir/vault/nested"
  write_marker "$dir/vault/nested" "$VAULT_REPO"
  printf '%s\n' "$dir/vault/nested" > "$config"
  assert_refused "$dir" 'is not the Git top level' 'nested path inside the vault'
  rm -rf "$dir/vault/nested"

  printf '/\n' > "$config"
  assert_refused "$dir" 'must be absolute and normalized' 'filesystem root as the vault'

  printf '%s\n' "$dir/vault" > "$config"
  mv "$dir/vault/.git" "$dir/vault-git"
  ln -s "$dir/vault-git" "$dir/vault/.git"
  assert_refused "$dir" '.git must not be a symlink' 'symbolic vault Git directory'

  dir=$(new_case redirected-common-dir)
  seed_records "$dir"
  mkdir "$dir/external-common"
  cp -R "$dir/vault/.git/." "$dir/external-common/"
  printf '%s\n' "$dir/external-common" > "$dir/vault/.git/commondir"
  before=$(fixture_dir_digest "$dir/external-common")
  assert_refused "$dir" 'effective Git common directory' 'external Git common directory'
  [ "$(fixture_dir_digest "$dir/external-common")" = "$before" ] \
    || fail 'external Git common directory: external metadata changed before refusal'

  pass "fm-feeder-export: an unauthorized vault identity refuses before any mutation"
}

restore_marker() {  # <dir>
  local dir=$1
  rm -f "$dir/vault/.feeder-vault"
  write_marker "$dir/vault" "$VAULT_REPO"
  git -C "$dir/vault" add -A .feeder-vault
  git -C "$dir/vault" commit -qm 'restore marker'
}

test_marker_refusals() {
  local dir
  dir=$(new_case marker)
  seed_records "$dir"

  git -C "$dir/vault" rm -q .feeder-vault
  git -C "$dir/vault" commit -qm 'drop marker'
  assert_refused "$dir" 'is not an authorized feeder vault' 'missing marker'
  restore_marker "$dir"

  printf 'firstmate-feeder-vault-v0\nremote=%s\n' "$VAULT_REPO" > "$dir/vault/.feeder-vault"
  git -C "$dir/vault" commit -qam 'downgrade marker'
  assert_refused "$dir" "expected $MARKER_VERSION" 'wrong marker version'
  restore_marker "$dir"

  printf '%s\000\nremote=%s\n' "$MARKER_VERSION" "$VAULT_REPO" > "$dir/vault/.feeder-vault"
  git -C "$dir/vault" add .feeder-vault
  git -C "$dir/vault" commit -qm 'add NUL marker'
  assert_refused "$dir" 'must not contain NUL bytes' 'marker with a trailing NUL'
  restore_marker "$dir"

  write_marker "$dir/vault" other-owner/other-vault
  git -C "$dir/vault" commit -qam 'copied marker'
  assert_refused "$dir" "must pin $VAULT_REPO" \
    'marker copied from another vault'
  restore_marker "$dir"

  printf '%s\n' "$MARKER_VERSION" > "$dir/vault/.feeder-vault"
  git -C "$dir/vault" commit -qam 'truncate marker'
  assert_refused "$dir" 'exactly two lines' 'marker without a pinned repository'
  restore_marker "$dir"

  git -C "$dir/vault" rm -q --cached .feeder-vault
  rm -f "$dir/vault/.feeder-vault"
  write_marker "$dir" "$VAULT_REPO"
  ln -s "$dir/.feeder-vault" "$dir/vault/.feeder-vault"
  git -C "$dir/vault" add -A
  git -C "$dir/vault" commit -qm 'symbolic marker'
  assert_refused "$dir" 'marker' 'symbolic marker'

  pass "fm-feeder-export: the versioned pinned marker is required before any mutation"
}

test_overlap_refusals() {
  local dir config
  dir=$(new_case overlap)
  seed_records "$dir"
  config="$dir/home/config/feeder-vault"

  printf '%s\n' "$dir/home" > "$config"
  assert_refused "$dir" 'vault must not be' 'vault equal to the home'

  mkdir -p "$dir/home/inner-vault"
  printf '%s\n' "$dir/home/inner-vault" > "$config"
  assert_refused "$dir" 'must not be inside' 'vault inside the home'

  mkdir -p "$dir/home/data/inner-vault"
  printf '%s\n' "$dir/home/data/inner-vault" > "$config"
  assert_refused "$dir" 'must not be inside' 'vault inside the source tree'

  printf '%s\n' "$dir" > "$config"
  assert_refused "$dir" 'must not be an ancestor of' 'vault above the home'

  printf '%s\n' "$ROOT" > "$config"
  assert_refused "$dir" 'vault must not be' 'vault equal to the code root'

  pass "fm-feeder-export: a vault overlapping the home, code root, or sources refuses"
}

test_owned_symlink_refusals() {
  local dir owned before tree link

  dir=$(new_case owned-symlinks)
  seed_records "$dir"
  : > "$dir/outside-sentinel"
  mkdir -p "$dir/elsewhere"
  : > "$dir/elsewhere/journal"

  for owned in wiki wiki/decisions wiki/reports; do
    mkdir -p "$dir/vault/$(dirname "$owned")"
    ln -s "$dir/elsewhere" "$dir/vault/$owned"
    assert_refused "$dir" 'must not be a symlink' "symbolic $owned"
    assert_present "$dir/outside-sentinel" "symbolic $owned: external sentinel removed"
    assert_present "$dir/elsewhere/journal" "symbolic $owned: link target emptied"
    rm -f "$dir/vault/$owned"
    rm -rf "$dir/vault/wiki"
  done

  mkdir -p "$dir/vault/.git/fm-feeder"
  ln -s "$dir/elsewhere/journal" "$dir/vault/.git/fm-feeder/journal"
  assert_refused "$dir" 'must not be a symlink' 'symbolic journal'
  rm -f "$dir/vault/.git/fm-feeder/journal"

  ln -s "$dir/elsewhere" "$dir/vault/.git/fm-feeder/lock"
  assert_refused "$dir" 'must not be a symlink' 'symbolic lock'
  rm -f "$dir/vault/.git/fm-feeder/lock"

  mkdir -p "$dir/vault/wiki"
  : > "$dir/vault/wiki/decisions"
  assert_refused "$dir" 'is not a directory' 'owned path is a regular file'

  for tree in decisions reports; do
    dir=$(new_case "nested-owned-$tree-symlink")
    seed_records "$dir"
    assert_export_ok "$dir" "nested owned $tree symlink: baseline"
    mkdir -p "$dir/vault/wiki/$tree/nested"
    printf 'external sentinel\n' > "$dir/outside-sentinel"
    link="$dir/vault/wiki/$tree/nested/link.md"
    ln -s "$dir/outside-sentinel" "$link"
    git -C "$dir/vault" add "wiki/$tree/nested/link.md"
    git -C "$dir/vault" commit -qm "add tracked nested $tree link"
    before=$(vault_state "$dir")
    assert_refused "$dir" 'contains a symbolic path' "nested owned $tree symlink"
    [ -L "$link" ] || fail "nested owned $tree symlink: link was removed"
    assert_grep 'external sentinel' "$dir/outside-sentinel" \
      "nested owned $tree symlink: external target changed"
    assert_absent "$dir/vault/.git/fm-feeder/journal" \
      "nested owned $tree symlink: journal was created"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "nested owned $tree symlink: vault changed before refusal"
  done

  dir=$(new_case raced-transaction-root)
  seed_records "$dir"
  mkdir -p "$dir/outside-transaction/stage.external"
  : > "$dir/outside-transaction/stage.external/sentinel"
  before=$(vault_state "$dir")
  run_export "$dir" FM_TEST_GH_LINK_PATH="$dir/vault/.git/fm-feeder" \
    FM_TEST_GH_LINK_TARGET="$dir/outside-transaction"
  [ "$RC" -ne 0 ] || fail 'raced transaction root: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'transaction path' 'raced transaction root'
  assert_present "$dir/outside-transaction/stage.external/sentinel" \
    'raced transaction root: external transaction bytes were removed'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'raced transaction root: the vault changed before refusal'

  dir=$(new_case symbolic-stage)
  seed_records "$dir"
  assert_export_ok "$dir" 'symbolic stage: baseline'
  stage_hard_stop "$dir" prepared
  rm -rf "$dir/vault/.git/fm-feeder/stage.hardstop"
  mkdir -p "$dir/outside-stage"
  : > "$dir/outside-stage/sentinel"
  ln -s "$dir/outside-stage" "$dir/vault/.git/fm-feeder/stage.hardstop"
  run_export "$dir"
  expect_code 4 "$RC" 'symbolic journal stage'
  assert_contains "$OUT" 'symbolic stage path' 'symbolic journal stage'
  assert_present "$dir/outside-stage/sentinel" 'symbolic journal stage: external target changed'

  dir=$(new_case symbolic-orphan-stage)
  seed_records "$dir"
  mkdir -p "$dir/vault/.git/fm-feeder" "$dir/outside-orphan-stage"
  : > "$dir/outside-orphan-stage/sentinel"
  ln -s "$dir/outside-orphan-stage" "$dir/vault/.git/fm-feeder/stage.orphan"
  assert_refused "$dir" 'orphan stage path' 'symbolic orphan stage'
  assert_present "$dir/outside-orphan-stage/sentinel" \
    'symbolic orphan stage: external target changed'

  dir=$(new_case symbolic-backup)
  seed_records "$dir"
  assert_export_ok "$dir" 'symbolic backup: baseline'
  stage_hard_stop "$dir" prepared
  rm -rf "$dir/vault/.git/fm-feeder/backup.hardstop"
  mkdir -p "$dir/outside-backup"
  : > "$dir/outside-backup/sentinel"
  ln -s "$dir/outside-backup" "$dir/vault/.git/fm-feeder/backup.hardstop"
  run_export "$dir"
  expect_code 4 "$RC" 'symbolic journal backup'
  assert_contains "$OUT" 'symbolic backup path' 'symbolic journal backup'
  assert_present "$dir/outside-backup/sentinel" 'symbolic journal backup: external target changed'

  pass "fm-feeder-export: a symbolic owned, nested, stage, journal, or lock path refuses"
}

test_render_time_transaction_link_refusals() {
  local dir path label

  for label in journal backup; do
    dir=$(new_case "render-link-$label")
    seed_records "$dir"
    printf 'external sentinel\n' > "$dir/external-sentinel"
    make_render_path_linker "$dir"
    if [ "$label" = journal ]; then
      path="$dir/vault/.git/fm-feeder/journal"
    else
      path="$dir/vault/.git/fm-feeder/backup.@pid@"
    fi
    run_export "$dir" FM_TEST_RENDER_LINK_PATH="$path" \
      FM_TEST_RENDER_LINK_TARGET="$dir/external-sentinel" \
      FM_TEST_RENDER_LINK_DONE="$dir/render-link-done"
    [ "$RC" -ne 0 ] || fail "render-time $label link: exporter unexpectedly succeeded"
    assert_present "$dir/external-sentinel" "render-time $label link: external sentinel changed"
    assert_grep 'external sentinel' "$dir/external-sentinel" \
      "render-time $label link: external sentinel content changed"
  done

  pass "fm-feeder-export: render-time journal and backup links do not change external targets"
}

test_prior_digest_failure_refuses_before_journal() {
  local dir before

  dir=$(new_case prior-digest-failure)
  seed_records "$dir"
  assert_export_ok "$dir" 'prior digest failure: baseline'
  before=$(vault_state "$dir")
  add_decision "$dir" new.md '# New decision

body
'
  make_live_digest_failure "$dir"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'prior digest failure: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot digest live wiki/decisions' 'prior digest failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'prior digest failure: live vault changed before journal creation'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'prior digest failure: journal was created with an empty digest'

  dir=$(new_case prior-digest-enumeration-failure)
  seed_records "$dir"
  assert_export_ok "$dir" 'prior digest enumeration failure: baseline'
  before=$(vault_state "$dir")
  add_decision "$dir" later.md '# Later decision

body
'
  make_live_digest_enumeration_failure "$dir"
  run_export "$dir"
  [ "$RC" -ne 0 ] \
    || fail 'prior digest enumeration failure: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot digest live wiki/decisions' \
    'prior digest enumeration failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'prior digest enumeration failure: live vault changed before journal creation'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'prior digest enumeration failure: journal was created from a truncated listing'

  pass "fm-feeder-export: prior tree digests must succeed before journal creation"
}

# --- discovery, aliases, names, titles, dates -------------------------------

test_empty_and_mixed_source_sets() {
  local dir

  dir=$(new_case sources-empty)
  assert_export_ok "$dir" 'empty source set'
  assert_present "$dir/vault/wiki/decisions/_index.md" 'empty set: decision index missing'
  assert_present "$dir/vault/wiki/reports/_index.md" 'empty set: report index missing'
  [ "$(page_field "$dir/vault/wiki/decisions/_index.md" created)" = 2026-08-31 ] \
    || fail 'empty set: the empty index does not carry the fixed schema date'
  assert_no_grep '- [[' "$dir/vault/wiki/decisions/_index.md" 'empty set: index links a page'
  [ "$(git -C "$dir/vault" ls-tree -r --name-only HEAD | LC_ALL=C grep -c '^wiki/')" -eq 2 ] \
    || fail 'empty set: the commit does not hold exactly the two indexes'

  dir=$(new_case sources-mixed)
  seed_records "$dir"
  add_decision "$dir" beta.md '# Beta lock

beta
'
  add_report "$dir" task-two '# Report two

two
'
  assert_export_ok "$dir" 'mixed source set'
  assert_present "$dir/vault/wiki/decisions/alpha-2026-01-05.md" 'mixed: decision page missing'
  assert_present "$dir/vault/wiki/decisions/beta.md" 'mixed: second decision page missing'
  assert_present "$dir/vault/wiki/reports/task-one.md" 'mixed: report page missing'
  assert_present "$dir/vault/wiki/reports/task-two.md" 'mixed: second report page missing'
  assert_grep 'Excluded records: 0' "$dir/vault/wiki/reports/_index.md" 'mixed: exclusion count missing'

  pass "fm-feeder-export: empty and mixed source sets both publish complete indexes"
}

test_source_enumeration_failures() {
  local dir before
  dir=$(new_case source-enumeration-failures)
  seed_records "$dir"
  assert_export_ok "$dir" 'source enumeration failures: baseline'
  before=$(vault_state "$dir")
  make_selective_find_failure "$dir"

  run_export "$dir" FM_TEST_FIND_SOURCE_FAIL_PATH="$dir/home/data/decisions"
  [ "$RC" -ne 0 ] || fail 'decision enumeration failure: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot enumerate decision sources' 'decision enumeration failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'decision enumeration failure: the vault changed before refusal'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'decision enumeration failure: journal was created'

  run_export "$dir" FM_TEST_FIND_SOURCE_FAIL_PATH="$dir/home/data"
  [ "$RC" -ne 0 ] || fail 'report enumeration failure: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot enumerate report sources' 'report enumeration failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'report enumeration failure: the vault changed before refusal'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'report enumeration failure: journal was created'

  pass "fm-feeder-export: source enumeration failures preserve the prior mirror"
}

test_source_alias_handling() {
  local dir

  dir=$(new_case decision-directory-link)
  mkdir -p "$dir/home/data/real-decisions"
  printf '# Linked decision\n\nbody\n' > "$dir/home/data/real-decisions/linked.md"
  rmdir "$dir/home/data/decisions"
  ln -s "$dir/home/data/real-decisions" "$dir/home/data/decisions"
  assert_refused "$dir" 'source directory data/decisions must not be a symbolic link' \
    'symbolic decision directory'

  dir=$(new_case decision-alias-refusal)
  printf '# Real decision\n\nbody\n' > "$dir/home/data/real-decision.md"
  ln -s "$dir/home/data/real-decision.md" "$dir/home/data/decisions/linked.md"
  assert_refused "$dir" 'must not be a symbolic link' 'symbolic decision source'
  assert_present "$dir/home/data/real-decision.md" 'symbolic decision source: target removed'

  dir=$(new_case alias-in-tree)
  seed_records "$dir"
  mkdir -p "$dir/home/data/aliased"
  printf '# Aliased report\n\naliased body\n' > "$dir/home/data/real-report.md"
  ln -s "$dir/home/data/real-report.md" "$dir/home/data/aliased/report.md"
  assert_export_ok "$dir" 'in-tree alias'
  assert_grep 'aliased body' "$dir/vault/wiki/reports/aliased.md" 'in-tree alias: payload missing'
  [ "$(page_field "$dir/vault/wiki/reports/aliased.md" sot_path)" = "'data/aliased/report.md'" ] \
    || fail 'in-tree alias: sot_path is not the logical source path'

  dir=$(new_case alias-refusals)
  seed_records "$dir"
  mkdir -p "$dir/home/data/leaky"
  printf 'external secret payload\n' > "$dir/outside.md"
  ln -s "$dir/outside.md" "$dir/home/data/leaky/report.md"
  assert_refused "$dir" 'outside' 'alias leaving the source tree'
  assert_not_contains "$OUT" 'external secret payload' 'alias leaving the source tree: content echoed'
  rm -rf "$dir/home/data/leaky"

  mkdir -p "$dir/home/data/dangling"
  ln -s "$dir/home/data/never-existed.md" "$dir/home/data/dangling/report.md"
  assert_refused "$dir" 'does not resolve to a regular file' 'dangling alias'
  rm -rf "$dir/home/data/dangling"

  mkdir -p "$dir/home/data/dirlink" "$dir/home/data/target-dir"
  ln -s "$dir/home/data/target-dir" "$dir/home/data/dirlink/report.md"
  assert_refused "$dir" 'does not resolve to a regular file' 'directory alias'

  dir=$(new_case symbolic-report-parent)
  seed_records "$dir"
  mkdir -p "$dir/home/data/real-task"
  printf '# Linked parent report\n\nbody\n' > "$dir/home/data/real-task/report.md"
  ln -s "$dir/home/data/real-task" "$dir/home/data/linked-task"
  assert_refused "$dir" 'source directory data/linked-task must not be a symbolic link' \
    'symbolic report parent'

  pass "fm-feeder-export: only in-tree regular-file aliases are mirrored"
}

test_titles_and_yaml_quoting() {
  local dir page parser_rc

  dir=$(new_case titles)
  add_decision "$dir" plain.md '# Plain title

body
'
  add_decision "$dir" no-heading.md 'body with no heading

more
'
  add_decision "$dir" colon.md '# Title: with a colon

body
'
  add_decision "$dir" single.md "# It's quoted

body
"
  add_decision "$dir" double.md '# The "quoted" title

body
'
  add_decision "$dir" unicode.md '# 船長の記録 - navegación

body
'
  add_decision "$dir" late-heading.md '

## Second line heading

body
'
  add_decision "$dir" indented-heading.md '   ## Indented title ###

body
'
  assert_export_ok "$dir" 'title extraction'
  [ "$(page_field "$dir/vault/wiki/decisions/plain.md" title)" = "'Plain title'" ] \
    || fail 'titles: first heading not used'
  [ "$(page_field "$dir/vault/wiki/decisions/no-heading.md" title)" = "'no-heading'" ] \
    || fail 'titles: fallback identifier not used'
  [ "$(page_field "$dir/vault/wiki/decisions/colon.md" title)" = "'Title: with a colon'" ] \
    || fail 'titles: colon not quoted safely'
  [ "$(page_field "$dir/vault/wiki/decisions/single.md" title)" = "'It''s quoted'" ] \
    || fail 'titles: embedded single quote not doubled'
  [ "$(page_field "$dir/vault/wiki/decisions/double.md" title)" = "'The \"quoted\" title'" ] \
    || fail 'titles: double quotes were rewritten'
  [ "$(page_field "$dir/vault/wiki/decisions/unicode.md" title)" = "'船長の記録 - navegación'" ] \
    || fail 'titles: Unicode not preserved'
  [ "$(parsed_page_title "$dir/vault/wiki/decisions/unicode.md")" = '船長の記録 - navegación' ] \
    || fail 'titles: parsed Unicode title not preserved'
  [ "$(page_field "$dir/vault/wiki/decisions/late-heading.md" title)" = "'Second line heading'" ] \
    || fail 'titles: later heading not used'
  [ "$(page_field "$dir/vault/wiki/decisions/indented-heading.md" title)" = "'Indented title'" ] \
    || fail 'titles: valid indentation or closing hashes were not normalized'

  for page in plain no-heading colon single double unicode late-heading indented-heading; do
    [ "$(sed -n '11p' "$dir/vault/wiki/decisions/$page.md")" = "$BANNER" ] \
      || fail "titles: $page.md does not open with the banner"
  done

  dir=$(new_case title-control)
  add_decision "$dir" control.md "# bad$(printf '\001')title

body
"
  assert_refused "$dir" 'contains control characters' 'control characters in a title'

  dir=$(new_case title-c1-control)
  add_decision "$dir" control-c1.md "# bad$(printf '\302\200')title

body
"
  assert_refused "$dir" 'contains control characters' 'C1 control characters in a title'

  dir=$(new_case title-yaml-forbidden)
  printf -- "---\ntitle: 'bad\357\277\276title'\n---\n" > "$dir/forbidden.yml"
  ruby -ryaml -e 'YAML.load_file(ARGV.fetch(0))' "$dir/forbidden.yml" >/dev/null 2>&1
  parser_rc=$?
  [ "$parser_rc" -ne 0 ] || fail 'titles: YAML parser accepted U+FFFE'
  printf '# bad\357\277\276title\n\nbody\n' > "$dir/home/data/decisions/forbidden.md"
  assert_refused "$dir" 'YAML-forbidden code point' 'YAML-forbidden code point in a title'

  pass "fm-feeder-export: titles are extracted, quoted, and Unicode-preserving"
}

test_destination_names_and_collisions() {
  local dir decisions reserved
  dir=$(new_case destination-names)
  decisions="$dir/home/data/decisions"

  printf '# Reserved\n\nbody\n' > "$decisions/_index.md"
  assert_refused "$dir" 'reserved index name' 'reserved destination name'
  rm -f "$decisions/_index.md"

  printf '# Case-folded reserved\n\nbody\n' > "$decisions/_INDEX.md"
  assert_refused "$dir" 'collides with the generated _index page after case-folding' \
    'case-folded decision index collision'
  rm -f "$decisions/_INDEX.md"

  add_report "$dir" _INDEX '# Case-folded report index

body
'
  assert_refused "$dir" 'collides with the generated _index page after case-folding' \
    'case-folded report index collision'
  rm -rf "$dir/home/data/_INDEX"

  printf '# Leading dash\n\nbody\n' > "$decisions/-leading.md"
  assert_refused "$dir" 'must start with an ASCII letter or digit' 'unsafe leading character'
  rm -f "$decisions/-leading.md"

  printf '# Unicode filename\n\nbody\n' > "$decisions/name-with-ünicode.md"
  assert_refused "$dir" 'must match' 'Unicode destination identifier'
  rm -f "$decisions/name-with-ünicode.md"

  for reserved in CON NUL.txt com1 LPT9.log; do
    printf '# Reserved portable basename\n\nbody\n' > "$decisions/$reserved.md"
    assert_refused "$dir" 'reserved portable destination basename' \
      "reserved portable destination $reserved"
    rm -f "$decisions/$reserved.md"
  done

  add_report "$dir" 'task one' '# Spaced task

body
'
  assert_refused "$dir" 'report task identifier' 'unsafe report identifier'
  rm -rf "$dir/home/data/task one"

  add_decision "$dir" alpha.md '# Alpha

one
'
  add_decision "$dir" ALPHA.md '# Alpha upper

two
'
  if [ -f "$decisions/alpha.md" ] && [ -f "$decisions/ALPHA.md" ] \
    && [ "$(cat "$decisions/alpha.md")" != "$(cat "$decisions/ALPHA.md")" ]; then
    assert_refused "$dir" 'claimed by more than one source' 'case-folded destination collision'
    assert_absent "$dir/vault/wiki/decisions/alpha.md" 'case-fold: a colliding page was emitted'
  else
    printf 'note: this filesystem folds case, so the collision pair cannot be created here\n' >&2
    assert_export_ok "$dir" 'case-insensitive filesystem single record'
    assert_present "$dir/vault/wiki/decisions/alpha.md" 'case-insensitive: page missing'
  fi

  pass "fm-feeder-export: unsafe and colliding destination identifiers refuse"
}

test_dates() {
  local dir created updated today platform before

  today=$(date -u +%Y-%m-%d)

  dir=$(new_case dates-untracked)
  add_decision "$dir" dated-2023-04-05.md '# Dated by name

body
'
  add_decision "$dir" undated.md '# No name date

body
'
  add_decision "$dir" invalid-2023-02-29.md '# Invalid filename date

body
'
  add_decision "$dir" leap-2024-02-29.md '# Valid leap date

body
'
  add_decision "$dir" 2026-08-31.md '# Exact date identifier

body
'
  touch -t 202401021200 "$dir/home/data/decisions/dated-2023-04-05.md"
  touch -t 202401021200 "$dir/home/data/decisions/undated.md"
  touch -t 202401021200 "$dir/home/data/decisions/invalid-2023-02-29.md"
  touch -t 202401021200 "$dir/home/data/decisions/leap-2024-02-29.md"
  assert_export_ok "$dir" 'untracked dates'
  created=$(page_field "$dir/vault/wiki/decisions/dated-2023-04-05.md" created)
  updated=$(page_field "$dir/vault/wiki/decisions/dated-2023-04-05.md" updated)
  [ "$created" = 2023-04-05 ] || fail "untracked dates: filename first-known date ignored (got $created)"
  [ "$updated" = 2024-01-02 ] || fail "untracked dates: source modification date ignored (got $updated)"
  [ "$created" != "$today" ] || fail 'untracked dates: fell back to the export day'
  created=$(page_field "$dir/vault/wiki/decisions/undated.md" created)
  case "$created" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail "untracked dates: undated record has no valid created date (got $created)" ;;
  esac
  [ "$(page_field "$dir/vault/wiki/decisions/undated.md" updated)" = 2024-01-02 ] \
    || fail 'untracked dates: undated record ignored its modification date'
  [ "$(page_field "$dir/vault/wiki/decisions/invalid-2023-02-29.md" created)" != 2023-02-29 ] \
    || fail 'untracked dates: an impossible filename date was accepted'
  [ "$(page_field "$dir/vault/wiki/decisions/leap-2024-02-29.md" created)" = 2024-02-29 ] \
    || fail 'untracked dates: a valid leap-day filename date was rejected'
  [ "$(page_field "$dir/vault/wiki/decisions/2026-08-31.md" created)" = 2026-08-31 ] \
    || fail 'untracked dates: an exact date identifier was ignored'

  dir=$(new_case report-date-suffix)
  add_report "$dir" task-1999-01-01 '# Report suffix is not a date source

body
'
  touch -t 202401021200 "$dir/home/data/task-1999-01-01/report.md"
  assert_export_ok "$dir" 'report identifier date suffix'
  [ "$(page_field "$dir/vault/wiki/reports/task-1999-01-01.md" created)" != 1999-01-01 ] \
    || fail 'report identifier date suffix: a report task identifier supplied the created date'

  for platform in Darwin Linux; do
    dir=$(new_case "dates-${platform}")
    add_report "$dir" task-1999-01-01 '# Platform date fallback

body
'
    make_platform_date_tools "$dir" "$platform"
    assert_export_ok "$dir" "$platform date fallback"
    [ "$(page_field "$dir/vault/wiki/reports/task-1999-01-01.md" created)" = 2000-01-01 ] \
      || fail "$platform date fallback: filesystem birth date path was not used"
    [ "$(page_field "$dir/vault/wiki/reports/task-1999-01-01.md" updated)" = 2000-01-01 ] \
      || fail "$platform date fallback: filesystem modification date path was not used"

    dir=$(new_case "dates-${platform}-mtime")
    add_report "$dir" task-mtime '# Platform mtime fallback

body
'
    make_platform_date_tools "$dir" "$platform" mtime
    assert_export_ok "$dir" "$platform mtime fallback"
    [ "$(page_field "$dir/vault/wiki/reports/task-mtime.md" created)" = 2000-01-01 ] \
      || fail "$platform mtime fallback: missing birth date did not fall back to mtime"
  done

  dir=$(new_case dates-tracked)
  git init -q "$dir/home"
  add_decision "$dir" tracked.md '# Tracked

first
'
  git -C "$dir/home" add -f data/decisions/tracked.md
  GIT_AUTHOR_DATE='2022-03-04T12:00:00+0000' GIT_COMMITTER_DATE='2022-03-04T12:00:00+0000' \
    git -C "$dir/home" commit -qm 'add tracked'
  add_decision "$dir" tracked.md '# Tracked

second
'
  git -C "$dir/home" add -f data/decisions/tracked.md
  GIT_AUTHOR_DATE='2023-06-07T12:00:00+0000' GIT_COMMITTER_DATE='2023-06-07T12:00:00+0000' \
    git -C "$dir/home" commit -qm 'change tracked'
  add_decision "$dir" readded.md '# Readded

first
'
  git -C "$dir/home" add -f data/decisions/readded.md
  GIT_AUTHOR_DATE='2020-01-02T12:00:00+0000' GIT_COMMITTER_DATE='2020-01-02T12:00:00+0000' \
    git -C "$dir/home" commit -qm 'first add readded'
  git -C "$dir/home" rm -q data/decisions/readded.md
  GIT_AUTHOR_DATE='2021-02-03T12:00:00+0000' GIT_COMMITTER_DATE='2021-02-03T12:00:00+0000' \
    git -C "$dir/home" commit -qm 'remove readded'
  add_decision "$dir" readded.md '# Readded

again
'
  git -C "$dir/home" add -f data/decisions/readded.md
  GIT_AUTHOR_DATE='2024-08-09T12:00:00+0000' GIT_COMMITTER_DATE='2024-08-09T12:00:00+0000' \
    git -C "$dir/home" commit -qm 're-add tracked'
  assert_export_ok "$dir" 'tracked dates'
  [ "$(page_field "$dir/vault/wiki/decisions/tracked.md" created)" = 2022-03-04 ] \
    || fail 'tracked dates: first-add date ignored'
  [ "$(page_field "$dir/vault/wiki/decisions/tracked.md" updated)" = 2023-06-07 ] \
    || fail 'tracked dates: last-change date ignored'
  [ "$(page_field "$dir/vault/wiki/decisions/readded.md" created)" = 2020-01-02 ] \
    || fail 'tracked dates: oldest addition was not used after re-add'
  [ "$(page_field "$dir/vault/wiki/decisions/readded.md" updated)" = 2024-08-09 ] \
    || fail 'tracked dates: re-added source did not use its latest change'

  add_decision "$dir" tracked.md '# Tracked

uncommitted working bytes
'
  touch -t 202501021200 "$dir/home/data/decisions/tracked.md"
  assert_export_ok "$dir" 'tracked working bytes'
  [ "$(page_field "$dir/vault/wiki/decisions/tracked.md" updated)" = 2025-01-02 ] \
    || fail 'tracked working bytes: updated date did not use the source modification time'

  dir=$(new_case dates-tracked-report-alias)
  git init -q "$dir/home"
  mkdir -p "$dir/home/data/report-target" "$dir/home/data/task-alias"
  printf '# Aliased report\n\nworking target bytes\n' > "$dir/home/data/report-target/source.md"
  touch -t 202402031200 "$dir/home/data/report-target/source.md"
  ln -s ../report-target/source.md "$dir/home/data/task-alias/report.md"
  git -C "$dir/home" add -f data/task-alias/report.md
  GIT_AUTHOR_DATE='2022-03-04T12:00:00+0000' GIT_COMMITTER_DATE='2022-03-04T12:00:00+0000' \
    git -C "$dir/home" commit -qm 'add tracked report alias'
  assert_export_ok "$dir" 'tracked report alias date'
  [ "$(page_field "$dir/vault/wiki/reports/task-alias.md" updated)" = 2024-02-03 ] \
    || fail 'tracked report alias date: updated date came from the symbolic-link commit'

  dir=$(new_case dates-tracked-no-history)
  git init -q "$dir/home"
  printf 'fixture\n' > "$dir/home/README.md"
  git -C "$dir/home" add README.md
  git -C "$dir/home" commit -qm 'initialize home history'
  add_decision "$dir" no-history-2020-01-02.md '# Tracked without history

body
'
  touch -t 202401021200 "$dir/home/data/decisions/no-history-2020-01-02.md"
  git -C "$dir/home" add -f data/decisions/no-history-2020-01-02.md
  assert_export_ok "$dir" 'tracked source without history'
  [ "$(page_field "$dir/vault/wiki/decisions/no-history-2020-01-02.md" created)" = 2020-01-02 ] \
    || fail 'tracked source without history: filename date fallback was ignored'
  [ "$(page_field "$dir/vault/wiki/decisions/no-history-2020-01-02.md" updated)" = 2024-01-02 ] \
    || fail 'tracked source without history: modification date fallback was ignored'

  dir=$(new_case dates-git-failures)
  git init -q "$dir/home"
  add_decision "$dir" tracked.md '# Tracked

body
'
  git -C "$dir/home" add -f data/decisions/tracked.md
  git -C "$dir/home" commit -qm 'add tracked source'
  make_fake_git "$dir"
  before=$(vault_state "$dir")
  run_export "$dir" FM_TEST_GIT_FAIL=ls-files
  [ "$RC" -ne 0 ] || fail 'tracked source enumeration failure: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot enumerate tracked feeder sources' 'tracked source enumeration failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'tracked source enumeration failure: the vault changed before refusal'
  run_export "$dir" FM_TEST_GIT_FAIL=log
  [ "$RC" -ne 0 ] || fail 'tracked source history failure: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot determine a created date' 'tracked source history failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'tracked source history failure: the vault changed before refusal'

  dir=$(new_case dates-tracked-lookup-failure)
  git init -q "$dir/home"
  add_decision "$dir" tracked.md '# Tracked

body
'
  git -C "$dir/home" add -f data/decisions/tracked.md
  git -C "$dir/home" commit -qm 'add tracked source'
  make_tracked_lookup_failure "$dir"
  before=$(vault_state "$dir")
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'tracked source lookup failure: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot look up tracked feeder sources' 'tracked source lookup failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'tracked source lookup failure: the vault changed before refusal'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'tracked source lookup failure: journal was created'

  dir=$(new_case dates-git-home-failure)
  git init -q "$dir/home"
  add_decision "$dir" tracked.md '# Tracked\n\nbody\n'
  git -C "$dir/home" add -f data/decisions/tracked.md
  git -C "$dir/home" commit -qm 'add tracked source'
  make_dubious_home_git "$dir"
  before=$(vault_state "$dir")
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'source-home Git refusal: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'cannot inspect source-home Git metadata' 'source-home Git refusal'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'source-home Git refusal: the vault changed before refusal'

  pass "fm-feeder-export: first-known and source-update dates never fall back to the export day"
}

test_byte_identical_rerun() {
  local dir first second

  dir=$(new_case rerun-identical)
  seed_records "$dir"
  assert_export_ok "$dir" 'first run'
  first=$(vault_state "$dir")
  assert_export_ok "$dir" 'second run'
  second=$(vault_state "$dir")
  [ "$first" = "$second" ] || fail "rerun: the second run changed the mirror"$'\n'"$first"$'\n'"$second"
  assert_contains "$OUT" 'bytes are unchanged' 'rerun: no-change path not taken'
  [ "$(git -C "$dir/vault" rev-list --count HEAD)" -eq 2 ] \
    || fail 'rerun: an unchanged corpus created a second commit'

  dir=$(new_case rerun-different-days)
  seed_records "$dir"
  make_export_day_date "$dir"
  run_export "$dir" FM_TEST_EXPORT_DAY=2026-08-31
  [ "$RC" -eq 0 ] || fail "different-day rerun: first export failed with $RC"$'\n'"$OUT"
  first=$(vault_state "$dir")
  run_export "$dir" FM_TEST_EXPORT_DAY=2026-09-01
  [ "$RC" -eq 0 ] || fail "different-day rerun: second export failed with $RC"$'\n'"$OUT"
  second=$(vault_state "$dir")
  [ "$first" = "$second" ] \
    || fail "different-day rerun: export-day change rewrote stable bytes"$'\n'"$first"$'\n'"$second"
  assert_contains "$OUT" 'bytes are unchanged' 'different-day rerun: no-change path not taken'

  pass "fm-feeder-export: unchanged corpora rerun byte-identically across export days"
}

test_index_determinism() {
  local dir links

  dir=$(new_case index-order)
  add_decision "$dir" charlie.md '# Charlie

c
'
  add_decision "$dir" alpha.md '# Alpha

a
'
  add_decision "$dir" bravo.md '# Bravo

b
'
  assert_export_ok "$dir" 'index order'
  links=$(LC_ALL=C grep '^- \[\[' "$dir/vault/wiki/decisions/_index.md")
  [ "$links" = "$(printf -- '- [[alpha]]\n- [[bravo]]\n- [[charlie]]')" ] \
    || fail "index order: not deterministic"$'\n'"$links"
  [ "$(page_field "$dir/vault/wiki/decisions/_index.md" type)" = feeder-index ] \
    || fail 'index: wrong type'
  assert_no_grep 'sot_path' "$dir/vault/wiki/decisions/_index.md" 'index: invented provenance fields'

  pass "fm-feeder-export: each index lists every emitted page once in a deterministic order"
}

test_staged_payload_and_index_validation() {
  local dir before

  dir=$(new_case render-write-failure)
  seed_records "$dir"
  before=$(vault_state "$dir")
  make_fake_tool "$dir" cat "$(command -v cat)"
  run_export "$dir" FM_TEST_cat_FAIL=1
  [ "$RC" -ne 0 ] || fail 'render write failure: exporter reported success'
  assert_contains "$OUT" 'cannot render the staged page' 'render write failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'render write failure: live mirror changed before validation'

  dir=$(new_case payload-validation)
  seed_records "$dir"
  before=$(vault_state "$dir")
  make_truncating_cat "$dir"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'payload validation: truncated page was accepted'
  assert_contains "$OUT" 'does not match its source snapshot' 'payload validation'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'payload validation: live mirror changed before refusal'

  dir=$(new_case index-validation)
  add_decision "$dir" alpha.md '# Alpha

alpha
'
  add_decision "$dir" bravo.md '# Bravo

bravo
'
  before=$(vault_state "$dir")
  make_corrupt_index_awk "$dir"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'index validation: duplicate and missing links were accepted'
  assert_contains "$OUT" 'ordered page manifest' 'index validation'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'index validation: live mirror changed before refusal'

  pass "fm-feeder-export: render writes, payload bytes, and ordered index links are validated off-path"
}

# --- secrets and exclusions -------------------------------------------------

test_secret_classes_refuse_before_mutation() {
  local dir pair class secret
  # Each entry pairs the class the exporter must name with a fixture assembled
  # by secret_fixture, so this file stores no literal credential shape.
  local pairs='private-key:openssh-private-key
private-key:encrypted-private-key
github-classic-token:github-classic
github-fine-grained-token:github-pat
aws-access-key-id:aws-access-key
slack-token:slack
stripe-live-key:stripe-live
google-api-key:google-api
openai-key:openai-project
openai-key:openai-service-account
openai-key:openai-admin
openai-key:openai-plain
openai-key:openai-underscore-suffix'

  dir=$(new_case secret-classes)
  seed_records "$dir"
  while IFS= read -r pair; do
    class=${pair%%:*}
    secret=$(secret_fixture "${pair#*:}")
    printf '# Leaky\n\n%s\n' "$secret" > "$dir/home/data/decisions/leaky.md"
    assert_refused "$dir" 'refusing to publish' "secret class $class"
    assert_contains "$OUT" "data/decisions/leaky.md" "secret class $class: source path not named"
    assert_contains "$OUT" "$class" "secret class $class: pattern class not named"
    assert_not_contains "$OUT" "$secret" "secret class $class: the candidate secret was echoed"
    assert_absent "$dir/vault/wiki/decisions/leaky.md" "secret class $class: a page was published"
  done <<< "$pairs"

  pass "fm-feeder-export: every high-confidence credential class refuses before mutation"
}

test_secret_lookalikes_publish() {
  local dir

  dir=$(new_case secret-lookalikes)
  cat > "$dir/home/data/decisions/lookalikes.md" <<'MD'
# Safe lookalikes

A short OpenAI token like sk-short stays ordinary text.
A short token like ghp_abc or AKIAshort is not a credential shape.
The literal pattern gh[pousr]_[A-Za-z0-9]{36,255} is documentation.
MD
  assert_export_ok "$dir" 'safe lookalikes'
  assert_grep 'sk-short' "$dir/vault/wiki/decisions/lookalikes.md" \
    'lookalikes: the record was not mirrored'

  pass "fm-feeder-export: ordinary text that resembles a credential still publishes"
}

test_exclusions() {
  local dir excludes

  dir=$(new_case exclusion-preflight)
  seed_records "$dir"
  excludes="$dir/home/config/feeder-vault-excludes"
  printf 'data/decisions/*.md\n' > "$excludes"
  assert_refused "$dir" 'looks like a glob' 'invalid exclusion before live path creation'
  assert_absent "$dir/vault/wiki/decisions" \
    'invalid exclusion: decision live path was created before publication'
  assert_absent "$dir/vault/wiki/reports" \
    'invalid exclusion: report live path was created before publication'

  dir=$(new_case exclusions)
  seed_records "$dir"
  add_decision "$dir" private-note.md '# Private note

do not mirror
'
  excludes="$dir/home/config/feeder-vault-excludes"

  printf 'data/decisions/*.md\n' > "$excludes"
  assert_refused "$dir" 'looks like a glob' 'glob exclusion'

  printf '%s\n' "$dir/home/data/decisions/alpha-2026-01-05.md" > "$excludes"
  assert_refused "$dir" 'must be relative to the home' 'absolute exclusion'

  printf 'data/decisions/../decisions/alpha-2026-01-05.md\n' > "$excludes"
  assert_refused "$dir" "must not contain" 'traversal exclusion'

  add_decision "$dir" foo..bar.md '# Double-dot identifier

body
'
  printf 'data/decisions/foo..bar.md\n' > "$excludes"
  assert_export_ok "$dir" 'double-dot exact exclusion'
  assert_absent "$dir/vault/wiki/decisions/foo..bar.md" \
    'double-dot exclusion: exact valid identifier was mirrored'
  rm -f "$dir/home/data/decisions/foo..bar.md"

  printf 'data/decisions/alpha-2026-01-05.md\ndata/decisions/alpha-2026-01-05.md\n' > "$excludes"
  assert_refused "$dir" 'listed more than once' 'duplicate exclusion'

  printf 'data/decisions/never-existed.md\n' > "$excludes"
  assert_refused "$dir" 'names no current source record' 'nonexistent exclusion'

  printf 'data/notes/other.md\n' > "$excludes"
  assert_refused "$dir" 'matches neither' 'exclusion outside the two source patterns'

  printf '# Top-level file, not a selected report\n' > "$dir/home/data/report.md"
  printf 'data//report.md\n' > "$excludes"
  assert_refused "$dir" 'not normalized' 'non-normalized exclusion outside the selected set'

  printf 'data/decisions/private-note.md\000\n' > "$excludes"
  assert_refused "$dir" 'must not contain NUL bytes' 'NUL byte in exclusion config'

  rm -f "$excludes"
  printf 'data/decisions/alpha-2026-01-05.md\n' > "$dir/real-excludes"
  ln -s "$dir/real-excludes" "$excludes"
  assert_refused "$dir" 'must not be a symlink' 'symbolic exclusion file'
  rm -f "$excludes"

  ln -s "$dir/never-created-excludes" "$excludes"
  assert_refused "$dir" 'must not be a symlink' 'dangling symbolic exclusion file'
  rm -f "$excludes"

  printf '# a comment\ndata/decisions/private-note.md\n' > "$excludes"
  assert_export_ok "$dir" 'valid exclusion'
  assert_absent "$dir/vault/wiki/decisions/private-note.md" 'exclusion: the record was mirrored'
  assert_present "$dir/vault/wiki/decisions/alpha-2026-01-05.md" 'exclusion: an unrelated record vanished'
  assert_grep 'Excluded records: 1' "$dir/vault/wiki/decisions/_index.md" 'exclusion: count not reported'
  assert_no_grep 'private-note' "$dir/vault/wiki/decisions/_index.md" 'exclusion: excluded name leaked into the index'
  [ "$(LC_ALL=C grep -c '^- \[\[' "$dir/vault/wiki/decisions/_index.md")" -eq 1 ] \
    || fail 'exclusion: the index does not list the remaining page exactly once'

  dir=$(new_case exclusion-lookup-failure)
  seed_records "$dir"
  add_decision "$dir" private-note.md '# Private note

do not mirror
'
  excludes="$dir/home/config/feeder-vault-excludes"
  printf 'data/decisions/private-note.md\n' > "$excludes"
  make_exclusion_lookup_failure "$dir"
  assert_refused "$dir" 'cannot look up feeder exclusions' 'exclusion lookup failure'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'exclusion lookup failure: journal was created'

  pass "fm-feeder-export: exact exclusions omit whole records and every invalid entry refuses"
}

test_secret_in_a_generated_page_refuses() {
  local dir token body_token

  dir=$(new_case secret-in-title)
  token=$(secret_fixture github-classic)
  printf '# %s\n\nbody\n' "$token" \
    > "$dir/home/data/decisions/titled.md"
  assert_refused "$dir" 'refusing to publish' 'credential in a generated page'
  assert_absent "$dir/vault/wiki/decisions/titled.md" 'generated page secret: a page was published'

  dir=$(new_case secret-in-source-name)
  token=$(secret_fixture github-classic)
  body_token=$(secret_fixture aws-access-key)
  add_decision "$dir" "$token.md" "# Leaky body

$body_token
"
  assert_refused "$dir" 'credential-shaped source path redacted' 'credential-shaped source name'
  assert_contains "$OUT" 'aws-access-key-id' 'credential-shaped source name: class missing'
  assert_not_contains "$OUT" "$token" 'credential-shaped source name: token reached refusal output'
  assert_not_contains "$OUT" "$body_token" 'credential-shaped source name: body token reached refusal output'

  pass "fm-feeder-export: a credential reaching a generated page refuses before publication"
}

test_secret_scan_errors_fail_closed() {
  local dir before

  dir=$(new_case secret-scan-error)
  seed_records "$dir"
  before=$(vault_state "$dir")
  make_fake_tool "$dir" grep "$(command -v grep)"
  run_export "$dir" FM_TEST_grep_FAIL=1 FM_TEST_grep_FAIL_CODE=2
  [ "$RC" -ne 0 ] || fail 'secret scan error: exporter reported success'
  assert_contains "$OUT" 'credential scan failed' 'secret scan error'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'secret scan error: the vault changed'

  dir=$(new_case secret-class-error)
  add_decision "$dir" leaky.md "# Leaky

$(secret_fixture github-classic)
"
  before=$(vault_state "$dir")
  make_fake_tool "$dir" grep "$(command -v grep)"
  : > "$dir/counter"
  run_export "$dir" FM_TEST_grep_FAIL_AT=2 FM_TEST_grep_FAIL_CODE=2 \
    FM_TEST_COUNTER="$dir/counter"
  [ "$RC" -ne 0 ] || fail 'secret class scan error: exporter reported success'
  assert_contains "$OUT" 'credential scan failed' 'secret class scan error'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'secret class scan error: the vault changed'

  dir=$(new_case secret-hits-file-error)
  add_decision "$dir" leaky.md "# Leaky

$(secret_fixture github-classic)
"
  before=$(vault_state "$dir")
  make_hits_file_blocking_cp "$dir"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'secret hits file error: exporter reported success'
  assert_contains "$OUT" 'could not create its hits file' 'secret hits file error'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'secret hits file error: the vault changed'

  dir=$(new_case secret-sort-error)
  add_decision "$dir" leaky.md "# Leaky

$(secret_fixture github-classic)
"
  before=$(vault_state "$dir")
  make_secret_sort_failure "$dir"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'secret sort error: exporter reported success'
  assert_contains "$OUT" 'failed while sorting staged content' 'secret sort error'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'secret sort error: the vault changed'

  pass "fm-feeder-export: credential scan command and storage errors fail closed"
}

test_invalid_text_refuses_before_mutation() {
  local dir before

  dir=$(new_case nul-source)
  seed_records "$dir"
  before=$(vault_state "$dir")
  printf '# NUL source\n\nbefore\000after\n' > "$dir/home/data/decisions/binary.md"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'NUL source: exporter reported success'
  assert_contains "$OUT" 'contains NUL bytes' 'NUL source'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'NUL source: the vault changed'

  dir=$(new_case invalid-utf8-source)
  seed_records "$dir"
  before=$(vault_state "$dir")
  printf '# Invalid UTF-8\n\n\377\n' > "$dir/home/data/decisions/invalid.md"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'invalid UTF-8 source: exporter reported success'
  assert_contains "$OUT" 'not valid UTF-8' 'invalid UTF-8 source'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'invalid UTF-8 source: the vault changed'

  pass "fm-feeder-export: NUL and invalid UTF-8 source bytes refuse before mutation"
}

# --- transaction, signals, recovery -----------------------------------------

test_snapshot_race_refuses_before_swap() {
  local dir before

  dir=$(new_case snapshot-race)
  seed_records "$dir"
  assert_export_ok "$dir" 'snapshot race: baseline publication'
  before=$(vault_state "$dir")

  make_fake_tool "$dir" cp "$(command -v cp)"
  run_export "$dir" FM_TEST_cp_CORRUPT="$dir/home/data/decisions/alpha-2026-01-05.md"
  [ "$RC" -ne 0 ] || fail 'snapshot race: exporter published a stale provenance hash'
  assert_contains "$OUT" 'changed its update time' 'snapshot race'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'snapshot race: the previous mirror changed'

  dir=$(new_case snapshot-identity)
  add_decision "$dir" identity.md '# Identity

first
'
  assert_export_ok "$dir" 'snapshot identity: baseline'
  before=$(vault_state "$dir")
  add_decision "$dir" identity.md '# Identity

second
'
  make_fake_tool "$dir" cp "$(command -v cp)"
  : > "$dir/counter"
  run_export "$dir" FM_TEST_cp_REPLACE="$dir/home/data/decisions/identity.md" \
    FM_TEST_COUNTER="$dir/counter"
  [ "$RC" -ne 0 ] || fail 'snapshot identity replacement: exporter reported success'
  assert_contains "$OUT" 'changed path, type, containment, or identity during its snapshot' \
    'snapshot identity replacement'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'snapshot identity replacement: the mirror changed'

  dir=$(new_case final-hash-identity)
  add_decision "$dir" identity.md '# Identity

first
'
  assert_export_ok "$dir" 'final hash identity: baseline'
  before=$(vault_state "$dir")
  add_decision "$dir" identity.md '# Identity

second
'
  make_fake_tool "$dir" shasum "$(command -v shasum)"
  : > "$dir/counter"
  run_export "$dir" FM_TEST_shasum_REPLACE="$dir/home/data/decisions/identity.md" \
    FM_TEST_shasum_REPLACE_AT=2 FM_TEST_COUNTER="$dir/counter"
  [ "$RC" -ne 0 ] || fail 'final hash identity replacement: exporter reported success'
  assert_contains "$OUT" 'changed path, type, containment, or identity during the final hash' \
    'final hash identity replacement'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'final hash identity replacement: the mirror changed'

  dir=$(new_case source-set-race)
  seed_records "$dir"
  assert_export_ok "$dir" 'source set race: baseline'
  before=$(vault_state "$dir")
  make_snapshot_metadata_mutator "$dir"
  run_export "$dir" \
    FM_TEST_CP_CREATE_SOURCE="$dir/home/data/decisions/added-during-export.md" \
    FM_TEST_CP_MUTATED="$dir/source-mutated"
  [ "$RC" -ne 0 ] || fail 'source set race: exporter reported success'
  assert_contains "$OUT" 'selected source set changed' 'source set race'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'source set race: the mirror changed'

  dir=$(new_case source-mtime-race)
  seed_records "$dir"
  assert_export_ok "$dir" 'source mtime race: baseline'
  before=$(vault_state "$dir")
  make_snapshot_metadata_mutator "$dir"
  run_export "$dir" \
    FM_TEST_CP_TOUCH_SOURCE="$dir/home/data/decisions/alpha-2026-01-05.md" \
    FM_TEST_CP_MUTATED="$dir/source-mutated"
  [ "$RC" -ne 0 ] || fail 'source mtime race: exporter reported success'
  assert_contains "$OUT" 'changed its update time' 'source mtime race'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'source mtime race: the mirror changed'

  pass "fm-feeder-export: source bytes, identity, membership, and timestamps stay stable"
}

test_lock_contention_and_stale_lock() {
  local dir before

  dir=$(new_case lock-contention)
  seed_records "$dir"
  assert_export_ok "$dir" 'lock: baseline publication'
  before=$(vault_state "$dir")
  mkdir -p "$dir/vault/.git/fm-feeder/lock"
  printf 'pid=1\nhost=other\nstarted=2020-01-01T00:00:00Z\n' \
    > "$dir/vault/.git/fm-feeder/lock/owner"
  run_export "$dir"
  expect_code 3 "$RC" 'lock contention'
  assert_contains "$OUT" 'another exporter holds' 'lock contention'
  assert_contains "$OUT" 'rm -rf' 'lock contention: no exact recovery instruction'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'lock contention: the vault changed'

  touch -t 202001010000 "$dir/vault/.git/fm-feeder/lock"
  run_export "$dir"
  expect_code 3 "$RC" 'stale lock'
  assert_contains "$OUT" 'another exporter holds' 'stale lock'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'stale lock: the vault changed'

  rm -rf "$dir/vault/.git/fm-feeder/lock"
  assert_export_ok "$dir" 'lock released'

  pass "fm-feeder-export: a held or stale lock refuses before mutation with an exact instruction"
}

test_dirty_vault_refuses() {
  local dir

  dir=$(new_case dirty-vault-fresh)
  seed_records "$dir"
  printf 'unrelated\n' > "$dir/vault/loose.md"
  assert_refused "$dir" 'dirty vault' 'fresh dirty vault'
  assert_absent "$dir/vault/.git/fm-feeder" 'fresh dirty vault: transaction directory was created'
  assert_absent "$dir/vault/wiki" 'fresh dirty vault: live directory was created'

  dir=$(new_case dirty-vault)
  seed_records "$dir"
  assert_export_ok "$dir" 'dirty: baseline publication'

  printf 'hand edit\n' >> "$dir/vault/wiki/decisions/alpha-2026-01-05.md"
  assert_refused "$dir" 'dirty vault' 'dirty owned path'
  git -C "$dir/vault" checkout -- wiki/decisions/alpha-2026-01-05.md

  printf 'unrelated\n' > "$dir/vault/other.md"
  git -C "$dir/vault" add other.md
  assert_refused "$dir" 'dirty vault' 'dirty index'
  git -C "$dir/vault" reset -q HEAD -- other.md
  rm -f "$dir/vault/other.md"

  printf 'unrelated\n' > "$dir/vault/loose.md"
  assert_refused "$dir" 'dirty vault' 'unrelated dirty path'

  pass "fm-feeder-export: a dirty vault worktree or index refuses before publication"
}

test_publication_filesystem_refusal() {
  local dir before

  dir=$(new_case publication-filesystem)
  seed_records "$dir"
  assert_export_ok "$dir" 'publication filesystem: plain clone baseline'
  add_decision "$dir" beta.md '# Beta\n\nbody\n'
  before=$(vault_state "$dir")
  make_split_device_stat "$dir" "$dir/vault/wiki"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'split-device publication: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'must be on the same filesystem' 'split-device publication'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'split-device publication: the vault changed before refusal'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'split-device publication: transaction journal was created'

  pass "fm-feeder-export: split-device publication refuses before live mutation"
}

test_exact_staging() {
  local dir committed

  dir=$(new_case exact-staging)
  seed_records "$dir"
  printf 'ignored\n' > "$dir/vault/.gitignore"
  printf 'notes.txt\n' >> "$dir/vault/.gitignore"
  printf 'operator note\n' > "$dir/vault/notes.txt"
  git -C "$dir/vault" add .gitignore
  git -C "$dir/vault" commit -qm 'ignore operator notes'
  assert_export_ok "$dir" 'exact staging'
  committed=$(git -C "$dir/vault" show --pretty=format: --name-only HEAD | LC_ALL=C grep -v '^$')
  case "$committed" in
    *notes.txt* | *.gitignore*) fail "exact staging: an unrelated file was committed"$'\n'"$committed" ;;
  esac
  if printf '%s\n' "$committed" | LC_ALL=C grep -qv '^wiki/decisions/\|^wiki/reports/'; then
    fail "exact staging: the commit reaches outside the owned paths"$'\n'"$committed"
  fi
  assert_present "$dir/vault/notes.txt" 'exact staging: an operator file was removed'

  pass "fm-feeder-export: only wiki/decisions and wiki/reports are staged and committed"
}

test_committed_tree_and_lineage_verification() {
  local dir remote_before

  dir=$(new_case commit-tree-digest)
  seed_records "$dir"
  assert_export_ok "$dir" 'commit tree digest: baseline'
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  add_decision "$dir" digest.md '# Digest

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_VAULT="$dir/vault" \
    FM_TEST_GIT_CORRUPT_PATH="$dir/vault/wiki/decisions/digest.md"
  [ "$RC" -ne 0 ] || fail 'commit tree digest: same-count corruption was pushed'
  assert_contains "$OUT" 'committed Git tree or HEAD lineage' 'commit tree digest'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_before" ] \
    || fail 'commit tree digest: remote moved'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'commit tree digest: recoverable transaction was discarded'

  dir=$(new_case commit-lineage)
  seed_records "$dir"
  assert_export_ok "$dir" 'commit lineage: baseline'
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  add_decision "$dir" lineage.md '# Lineage

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_VAULT="$dir/vault" FM_TEST_GIT_EXTRA_COMMIT=1
  [ "$RC" -ne 0 ] || fail 'commit lineage: non-direct HEAD was pushed'
  assert_contains "$OUT" 'committed Git tree or HEAD lineage' 'commit lineage'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_before" ] \
    || fail 'commit lineage: remote moved'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'commit lineage: recoverable transaction was discarded'

  dir=$(new_case commit-unowned-amend)
  seed_records "$dir"
  assert_export_ok "$dir" 'unowned amend: baseline'
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  add_decision "$dir" unowned.md '# Unowned amend

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_VAULT="$dir/vault" FM_TEST_GIT_UNOWNED_AMEND=1
  [ "$RC" -ne 0 ] || fail 'unowned amend: unowned committed file was pushed'
  assert_contains "$OUT" 'committed Git tree or HEAD lineage' 'unowned amend'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_before" ] \
    || fail 'unowned amend: remote moved'

  dir=$(new_case dirty-after-commit)
  seed_records "$dir"
  assert_export_ok "$dir" 'dirty after commit: baseline'
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  add_decision "$dir" dirty.md '# Dirty after commit

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_DIRTY_AFTER_COMMIT="$dir/vault/wiki/decisions/dirty.md"
  [ "$RC" -ne 0 ] || fail 'dirty after commit: exporter pushed an inconsistent live mirror'
  assert_contains "$OUT" 'dirty vault' 'dirty after commit'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_before" ] \
    || fail 'dirty after commit: remote moved'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'dirty after commit: recoverable transaction was discarded'

  dir=$(new_case backup-before-push)
  seed_records "$dir"
  assert_export_ok "$dir" 'backup before push: baseline'
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  add_decision "$dir" backup.md '# Backup artifact

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_VAULT="$dir/vault" FM_TEST_GIT_BACKUP_AFTER_COMMIT=1
  expect_code 5 "$RC" 'backup before push'
  assert_contains "$OUT" 'transaction backup remains before push' 'backup before push'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_before" ] \
    || fail 'backup before push: remote moved'
  assert_present "$dir/vault/.git/fm-feeder/backup.injected" \
    'backup before push: injected transaction artifact vanished'

  pass "fm-feeder-export: committed lineage, full tree, live bytes, and push artifacts are verified"
}

test_command_failures_roll_back() {
  local dir before stage

  dir=$(new_case git-failures)
  seed_records "$dir"
  assert_export_ok "$dir" 'git failures: baseline publication'
  before=$(vault_state "$dir")
  add_decision "$dir" gamma.md '# Gamma

new record
'
  make_fake_git "$dir"
  for stage in add commit; do
    run_export "$dir" FM_TEST_GIT_FAIL="$stage"
    [ "$RC" -ne 0 ] || fail "git $stage failure: exporter reported success"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "git $stage failure: the previous mirror was not restored"$'\n'"$(vault_state "$dir")"
    assert_absent "$dir/vault/.git/fm-feeder/journal" "git $stage failure: a journal survived"
  done
  rm -f "$dir/fakebin/git"

  dir=$(new_case reset-failure-preserves-recovery)
  seed_records "$dir"
  assert_export_ok "$dir" 'reset failure: baseline publication'
  add_decision "$dir" reset.md '# Reset failure

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_FAIL=commit FM_TEST_GIT_FAIL_RESET=1
  [ "$RC" -ne 0 ] || fail 'reset failure: exporter reported success'
  assert_contains "$OUT" 'preserving' 'reset failure'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'reset failure: journal was discarded'
  [ -n "$(LC_ALL=C find "$dir/vault/.git/fm-feeder" -maxdepth 1 -name 'backup.*' -print | head -1)" ] \
    || fail 'reset failure: backups were discarded'

  dir=$(new_case rollback-renames-live)
  seed_records "$dir"
  assert_export_ok "$dir" 'rollback rename: baseline publication'
  before=$(vault_state "$dir")
  add_decision "$dir" rollback.md '# Rename rollback

new record
'
  make_fake_git "$dir"
  make_fake_rm "$dir"
  run_export "$dir" FM_TEST_GIT_FAIL=commit \
    FM_TEST_RM_FAIL_EXACT="$dir/vault/wiki/decisions"
  [ "$RC" -ne 0 ] || fail 'rollback rename: forced commit failure reported success'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'rollback rename: prior generation was not restored by rename'
  assert_not_contains "$OUT" 'refused live mirror deletion' \
    'rollback rename: exporter tried to remove a live mirror directory'

  dir=$(new_case tool-failures)
  seed_records "$dir"
  assert_export_ok "$dir" 'tool failures: baseline publication'
  before=$(vault_state "$dir")
  make_fake_tool "$dir" cp "$(command -v cp)"
  run_export "$dir" FM_TEST_cp_FAIL=1
  [ "$RC" -ne 0 ] || fail 'render failure: exporter reported success'
  assert_contains "$OUT" 'cannot snapshot' 'render failure'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'render failure: the previous mirror changed'
  rm -f "$dir/fakebin/cp"

  add_decision "$dir" delta.md '# Delta

new record
'
  make_fake_tool "$dir" mv "$(command -v mv)"
  run_export "$dir" FM_TEST_mv_FAIL=1
  [ "$RC" -ne 0 ] || fail 'rename failure: exporter reported success'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail "rename failure: the previous mirror was not restored"$'\n'"$(vault_state "$dir")"

  pass "fm-feeder-export: a failing render, rename, add, or commit rolls the mirror back"
}

test_signals_roll_back() {
  local dir before signal

  dir=$(new_case signal-render)
  seed_records "$dir"
  assert_export_ok "$dir" 'signal: baseline publication'
  before=$(vault_state "$dir")
  add_decision "$dir" epsilon.md '# Epsilon

new record
'
  make_fake_tool "$dir" cp "$(command -v cp)"
  for signal in INT TERM HUP; do
    : > "$dir/counter"
    run_export "$dir" FM_TEST_cp_SIGNAL="$signal" FM_TEST_cp_SIGNAL_AT=2 \
      FM_TEST_COUNTER="$dir/counter"
    [ "$RC" -ne 0 ] || fail "signal $signal during render: exporter reported success"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "signal $signal during render: the previous mirror changed"
    assert_absent "$dir/vault/.git/fm-feeder/journal" "signal $signal during render: a journal survived"
  done
  rm -f "$dir/fakebin/cp"

  dir=$(new_case signal-publish)
  seed_records "$dir"
  assert_export_ok "$dir" 'signal during publication: baseline'
  before=$(vault_state "$dir")
  add_decision "$dir" zeta.md '# Zeta

new record
'
  make_fake_git "$dir"
  for signal in INT TERM HUP; do
    run_export "$dir" FM_TEST_GIT_SIGNAL="$signal" FM_TEST_GIT_SIGNAL_AT=add
    [ "$RC" -ne 0 ] || fail "signal $signal during publication: exporter reported success"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "signal $signal during publication: both directories were not restored"$'\n'"$(vault_state "$dir")"
    assert_absent "$dir/vault/.git/fm-feeder/journal" \
      "signal $signal during publication: a journal survived"
  done

  run_export "$dir" FM_TEST_GIT_SIGNAL_AFTER=INT FM_TEST_GIT_SIGNAL_AFTER_AT=add
  [ "$RC" -ne 0 ] || fail 'signal after git add: exporter reported success'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'signal after git add: the previous mirror or index was not restored'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'signal after git add: a journal survived'

  pass "fm-feeder-export: INT, TERM, and HUP during render or publication roll back cleanly"
}

test_publication_phase_signals() {
  local dir before spec at signal head remote_before

  dir=$(new_case signal-publication-moves)
  seed_records "$dir"
  assert_export_ok "$dir" 'publication move signals: baseline'
  before=$(vault_state "$dir")
  add_decision "$dir" move-signal.md '# Move signal

new record
'
  make_publication_signaling_mv "$dir"
  for spec in 1:INT 2:TERM 3:HUP 4:INT; do
    at=${spec%%:*}
    signal=${spec#*:}
    : > "$dir/counter"
    rm -f "$dir/signal-marker"
    run_export "$dir" FM_TEST_PUBLISH_VAULT="$dir/vault" \
      FM_TEST_COUNTER="$dir/counter" FM_TEST_SIGNAL_MARKER="$dir/signal-marker" \
      FM_TEST_PUBLISH_MV_AT="$at" FM_TEST_PUBLISH_SIGNAL="$signal"
    [ "$RC" -ne 0 ] || fail "publication move $at signal: exporter reported success"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "publication move $at signal: the previous generation was not restored"
    assert_absent "$dir/vault/.git/fm-feeder/journal" \
      "publication move $at signal: a journal survived"
  done

  dir=$(new_case signal-commit)
  seed_records "$dir"
  assert_export_ok "$dir" 'commit signal: baseline'
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  add_decision "$dir" commit-signal.md '# Commit signal

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_SIGNAL_AFTER=TERM FM_TEST_GIT_SIGNAL_AFTER_AT=commit
  [ "$RC" -ne 0 ] || fail 'commit signal: exporter reported success'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  [ "$head" != "$remote_before" ] || fail 'commit signal: the local commit was not retained'
  assert_present "$dir/vault/.git/fm-feeder/journal" 'commit signal: journal missing'
  rm -f "$dir/fakebin/git"
  assert_export_ok "$dir" 'commit signal recovery'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$head" ] \
    || fail 'commit signal recovery: the retained commit was not pushed'

  dir=$(new_case signal-cleanup)
  seed_records "$dir"
  assert_export_ok "$dir" 'cleanup signal: baseline'
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  add_decision "$dir" cleanup-signal.md '# Cleanup signal

new record
'
  make_cleanup_signaling_rm "$dir"
  rm -f "$dir/signal-marker"
  run_export "$dir" FM_TEST_SIGNAL_MARKER="$dir/signal-marker" FM_TEST_CLEANUP_SIGNAL=HUP
  [ "$RC" -ne 0 ] || fail 'cleanup signal: exporter reported success'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  [ "$head" != "$remote_before" ] || fail 'cleanup signal: the local commit was not retained'
  assert_present "$dir/vault/.git/fm-feeder/journal" 'cleanup signal: journal missing'
  rm -f "$dir/fakebin/rm"
  assert_export_ok "$dir" 'cleanup signal recovery'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$head" ] \
    || fail 'cleanup signal recovery: the retained commit was not pushed'

  dir=$(new_case signal-push)
  seed_records "$dir"
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_SIGNAL=HUP FM_TEST_GIT_SIGNAL_AT=push
  [ "$RC" -ne 0 ] || fail 'push signal: exporter reported success'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  [ "$head" != "$remote_before" ] || fail 'push signal: the local commit was not retained'
  assert_absent "$dir/vault/.git/fm-feeder/journal" 'push signal: journal survived'
  rm -f "$dir/fakebin/git"
  assert_export_ok "$dir" 'push signal retry'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$head" ] \
    || fail 'push signal retry: the retained commit was not pushed'

  pass "fm-feeder-export: publication, commit, cleanup, and push signals preserve recoverable state"
}

# Rebuild the exact on-disk state a hard stop would leave at one journal phase,
# so recovery is exercised without depending on winning a kill race.
stage_hard_stop() {  # <dir> <phase>
  local dir=$1 phase=$2 feeder stage backup head decisions_old reports_old decisions_new reports_new
  feeder="$dir/vault/.git/fm-feeder"
  mkdir -p "$feeder"
  stage="$feeder/stage.hardstop"
  backup="$feeder/backup.hardstop"
  mkdir -p "$stage/decisions" "$stage/reports" "$backup"
  head=$(git -C "$dir/vault" rev-parse HEAD)
  decisions_old=$(fixture_dir_digest "$dir/vault/wiki/decisions")
  reports_old=$(fixture_dir_digest "$dir/vault/wiki/reports")
  cp "$dir/vault/wiki/decisions/_index.md" "$stage/decisions/_index.md"
  cp "$dir/vault/wiki/reports/_index.md" "$stage/reports/_index.md"
  decisions_new=$(fixture_dir_digest "$stage/decisions")
  reports_new=$(fixture_dir_digest "$stage/reports")
  printf 'version=1\nrun=hardstop\nhead=%s\nstage=%s\nbackup=%s\n' "$head" "$stage" "$backup" \
    > "$feeder/journal"
  printf 'decisions_old=%s\nreports_old=%s\ndecisions_new=%s\nreports_new=%s\n' \
    "$decisions_old" "$reports_old" "$decisions_new" "$reports_new" >> "$feeder/journal"
  printf 'phase=prepared\n' >> "$feeder/journal"
  case "$phase" in
    prepared) ;;
    moved-decisions)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      printf 'phase=moved-decisions\n' >> "$feeder/journal"
      ;;
    moved-reports)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      mv "$dir/vault/wiki/reports" "$backup/reports"
      printf 'phase=moved-decisions\nphase=moved-reports\n' >> "$feeder/journal"
      ;;
    installed-decisions)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      mv "$dir/vault/wiki/reports" "$backup/reports"
      mv "$stage/decisions" "$dir/vault/wiki/decisions"
      printf 'phase=moved-decisions\nphase=moved-reports\nphase=installed-decisions\n' >> "$feeder/journal"
      ;;
    installed-reports)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      mv "$dir/vault/wiki/reports" "$backup/reports"
      mv "$stage/decisions" "$dir/vault/wiki/decisions"
      mv "$stage/reports" "$dir/vault/wiki/reports"
      printf 'phase=moved-decisions\nphase=moved-reports\nphase=installed-decisions\nphase=installed-reports\n' \
        >> "$feeder/journal"
      ;;
    after-move-decisions)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      ;;
    after-move-reports)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      mv "$dir/vault/wiki/reports" "$backup/reports"
      printf 'phase=moved-decisions\n' >> "$feeder/journal"
      ;;
    after-install-decisions)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      mv "$dir/vault/wiki/reports" "$backup/reports"
      mv "$stage/decisions" "$dir/vault/wiki/decisions"
      printf 'phase=moved-decisions\nphase=moved-reports\n' >> "$feeder/journal"
      ;;
    after-install-reports)
      mv "$dir/vault/wiki/decisions" "$backup/decisions"
      mv "$dir/vault/wiki/reports" "$backup/reports"
      mv "$stage/decisions" "$dir/vault/wiki/decisions"
      mv "$stage/reports" "$dir/vault/wiki/reports"
      printf 'phase=moved-decisions\nphase=moved-reports\nphase=installed-decisions\n' \
        >> "$feeder/journal"
      ;;
  esac
}

test_journal_recovery_per_phase() {
  local dir phase before

  dir=$(new_case recover-phases)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery: baseline publication'
  before=$(vault_state "$dir")

  for phase in prepared moved-decisions moved-reports installed-decisions installed-reports; do
    stage_hard_stop "$dir" "$phase"
    assert_export_ok "$dir" "recovery $phase"
    assert_contains "$OUT" 'recovering interrupted export run' "recovery $phase: no recovery reported"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "recovery $phase: the prior generation was not restored"$'\n'"$(vault_state "$dir")"
    assert_absent "$dir/vault/.git/fm-feeder/journal" "recovery $phase: the journal survived"
    assert_absent "$dir/vault/.git/fm-feeder/backup.hardstop" "recovery $phase: the backup survived"
    assert_absent "$dir/vault/.git/fm-feeder/stage.hardstop" "recovery $phase: the stage survived"
  done

  for phase in after-move-decisions after-move-reports after-install-decisions after-install-reports; do
    stage_hard_stop "$dir" "$phase"
    assert_export_ok "$dir" "recovery operation gap $phase"
    assert_contains "$OUT" 'recovering interrupted export run' \
      "recovery operation gap $phase: no recovery reported"
    [ "$(vault_state "$dir")" = "$before" ] \
      || fail "recovery operation gap $phase: the prior generation was not restored"$'\n'"$(vault_state "$dir")"
    assert_absent "$dir/vault/.git/fm-feeder/journal" \
      "recovery operation gap $phase: the journal survived"
  done

  pass "fm-feeder-export: hard stops at phases and operation-to-journal gaps recover"
}

test_recovery_precedes_normal_preflight() {
  local dir before

  dir=$(new_case recovery-before-privacy)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery before privacy: baseline'
  before=$(vault_state "$dir")
  stage_hard_stop "$dir" installed-decisions
  make_gh_axi "$dir" fail
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'recovery before privacy: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'recovering interrupted export run' 'recovery before privacy'
  assert_contains "$OUT" 'refusing to push' 'recovery before privacy: privacy refusal missing'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'recovery before privacy: prior generation was not restored'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'recovery before privacy: journal survived'

  dir=$(new_case recovery-before-source-git)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery before source Git: baseline'
  before=$(vault_state "$dir")
  stage_hard_stop "$dir" installed-decisions
  make_dubious_home_git "$dir"
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'recovery before source Git: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'recovering interrupted export run' 'recovery before source Git'
  assert_contains "$OUT" 'cannot inspect source-home Git metadata' \
    'recovery before source Git: source refusal missing'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'recovery before source Git: prior generation was not restored'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'recovery before source Git: journal survived'

  dir=$(new_case recovery-before-upstream)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery before upstream: baseline'
  before=$(vault_state "$dir")
  stage_hard_stop "$dir" installed-decisions
  git -C "$dir/vault" branch -q --unset-upstream main
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'recovery before upstream: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'recovering interrupted export run' 'recovery before upstream'
  assert_contains "$OUT" 'has no upstream' 'recovery before upstream: refusal missing'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'recovery before upstream: prior generation was not restored'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'recovery before upstream: journal survived'

  pass "fm-feeder-export: journal recovery precedes ordinary preflight"
}

test_vault_authority_precedes_recovery() {
  local dir

  dir=$(new_case authority-before-recovery)
  seed_records "$dir"
  assert_export_ok "$dir" 'authority before recovery: baseline'
  stage_hard_stop "$dir" installed-decisions
  git -C "$dir/vault" remote set-url origin https://github.com/other-owner/other-vault.git
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'authority before recovery: exporter unexpectedly succeeded'
  assert_contains "$OUT" 'does not match the marker repository' 'authority before recovery'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'authority before recovery: recovery ran despite an unpinned remote'
  assert_present "$dir/vault/.git/fm-feeder/backup.hardstop/reports" \
    'authority before recovery: the backup was consumed despite an unpinned remote'

  pass "fm-feeder-export: vault authority refuses before recovery mutates state"
}

test_recovery_resumes_after_hard_stop() {
  local dir feeder before

  dir=$(new_case recover-retry)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery retry: baseline publication'
  before=$(vault_state "$dir")
  stage_hard_stop "$dir" installed-decisions
  feeder="$dir/vault/.git/fm-feeder"
  make_publication_signaling_mv "$dir"
  : > "$dir/counter"
  rm -f "$dir/signal-marker"
  run_export "$dir" FM_TEST_PUBLISH_VAULT="$dir/vault" \
    FM_TEST_COUNTER="$dir/counter" FM_TEST_SIGNAL_MARKER="$dir/signal-marker" \
    FM_TEST_PUBLISH_MV_AT=1 FM_TEST_PUBLISH_SIGNAL=KILL
  [ "$RC" -ne 0 ] || fail 'recovery retry hard stop: exporter reported success'
  rm -f "$dir/fakebin/mv"
  rm -rf "$feeder/lock"
  assert_present "$feeder/stage.hardstop/recovery-decisions" \
    'recovery retry hard stop: failed generation was not preserved'
  assert_absent "$dir/vault/wiki/decisions" \
    'recovery retry hard stop: live decisions unexpectedly remained'
  assert_present "$feeder/backup.hardstop/decisions" \
    'recovery retry hard stop: prior decisions were not preserved'

  assert_export_ok "$dir" 'recovery retry'
  assert_contains "$OUT" 'recovered run hardstop' 'recovery retry'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'recovery retry: the prior generation was not restored'
  assert_absent "$feeder/journal" 'recovery retry: journal survived'
  assert_absent "$feeder/stage.hardstop" 'recovery retry: stage survived'
  assert_absent "$feeder/backup.hardstop" 'recovery retry: backup survived'

  pass "fm-feeder-export: recovery resumes after a hard stop during recovery"
}

test_precommit_cleanup_survives_hard_stops() {
  local dir feeder stage

  dir=$(new_case rollback-cleanup-hard-stop)
  seed_records "$dir"
  assert_export_ok "$dir" 'rollback cleanup hard stop: baseline'
  add_decision "$dir" rollback-cleanup.md '# Rollback cleanup\n\nnew bytes\n'
  make_fake_git "$dir"
  make_cleanup_signaling_rm "$dir"
  rm -f "$dir/signal-marker"
  run_export "$dir" FM_TEST_GIT_FAIL=commit \
    FM_TEST_SIGNAL_MARKER="$dir/signal-marker" FM_TEST_CLEANUP_SIGNAL=KILL
  [ "$RC" -ne 0 ] || fail 'rollback cleanup hard stop: exporter reported success'
  feeder="$dir/vault/.git/fm-feeder"
  assert_present "$feeder/journal" 'rollback cleanup hard stop: journal missing'
  stage=$(LC_ALL=C awk -F= '$1 == "stage" { print substr($0, 7) }' "$feeder/journal")
  assert_present "$stage" 'rollback cleanup hard stop: stage was removed before the journal'
  rm -f "$dir/fakebin/git" "$dir/fakebin/rm"
  rm -rf "$feeder/lock"
  assert_export_ok "$dir" 'rollback cleanup hard stop recovery'
  assert_present "$dir/vault/wiki/decisions/rollback-cleanup.md" \
    'rollback cleanup hard stop recovery: refreshed record missing'

  dir=$(new_case recovery-cleanup-hard-stop)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery cleanup hard stop: baseline'
  stage_hard_stop "$dir" installed-reports
  feeder="$dir/vault/.git/fm-feeder"
  make_cleanup_signaling_rm "$dir"
  rm -f "$dir/signal-marker"
  run_export "$dir" FM_TEST_SIGNAL_MARKER="$dir/signal-marker" FM_TEST_CLEANUP_SIGNAL=KILL
  [ "$RC" -ne 0 ] || fail 'recovery cleanup hard stop: exporter reported success'
  assert_present "$feeder/journal" 'recovery cleanup hard stop: journal missing'
  assert_present "$feeder/stage.hardstop" \
    'recovery cleanup hard stop: stage was removed before the journal'
  rm -f "$dir/fakebin/rm"
  rm -rf "$feeder/lock"
  assert_export_ok "$dir" 'recovery cleanup hard stop recovery'
  assert_absent "$feeder/journal" 'recovery cleanup hard stop recovery: journal survived'

  pass "fm-feeder-export: pre-commit cleanup keeps recovery state crash-safe"
}

test_empty_live_directory_recovery() {
  local dir backup

  dir=$(new_case recover-empty-live-directories)
  seed_records "$dir"
  mkdir -p "$dir/vault/wiki/decisions" "$dir/vault/wiki/reports"
  make_publication_signaling_mv "$dir"
  : > "$dir/counter"
  rm -f "$dir/signal-marker"
  run_export "$dir" FM_TEST_PUBLISH_VAULT="$dir/vault" \
    FM_TEST_COUNTER="$dir/counter" FM_TEST_SIGNAL_MARKER="$dir/signal-marker" \
    FM_TEST_PUBLISH_MV_AT=2 FM_TEST_PUBLISH_SIGNAL=KILL
  [ "$RC" -ne 0 ] || fail 'empty live directory hard stop: exporter reported success'
  rm -f "$dir/fakebin/mv"
  rm -rf "$dir/vault/.git/fm-feeder/lock"
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'empty live directory hard stop: journal missing'
  backup=$(LC_ALL=C find "$dir/vault/.git/fm-feeder" -maxdepth 1 -type d -name 'backup.*' | head -1)
  [ -n "$backup" ] || fail 'empty live directory hard stop: backup missing'
  [ -d "$backup/decisions" ] && [ -d "$backup/reports" ] \
    || fail 'empty live directory hard stop: empty live directories were not backed up'

  assert_export_ok "$dir" 'empty live directory recovery'
  assert_contains "$OUT" 'recovering interrupted export run' 'empty live directory recovery'
  assert_present "$dir/vault/wiki/decisions/alpha-2026-01-05.md" \
    'empty live directory recovery: decision generation missing'
  assert_present "$dir/vault/wiki/reports/task-one.md" \
    'empty live directory recovery: report generation missing'
  assert_absent "$dir/vault/.git/fm-feeder/journal" \
    'empty live directory recovery: journal survived'

  pass "fm-feeder-export: hard-stop recovery preserves empty owned directories"
}

test_commit_intent_recovery() {
  local dir head remote_before

  dir=$(new_case recover-commit-intent)
  seed_records "$dir"
  assert_export_ok "$dir" 'commit intent recovery: baseline'
  add_decision "$dir" post-commit.md '# Post commit

new record
'
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_SIGNAL_AFTER=KILL FM_TEST_GIT_SIGNAL_AFTER_AT=commit
  [ "$RC" -ne 0 ] || fail 'commit intent hard stop: exporter reported success'
  rm -f "$dir/fakebin/git"
  assert_present "$dir/vault/.git/fm-feeder/journal" 'commit intent hard stop: journal missing'
  assert_grep 'phase=commit-intent' "$dir/vault/.git/fm-feeder/journal" \
    'commit intent hard stop: intent phase missing'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  [ "$head" != "$remote_before" ] || fail 'commit intent hard stop: commit was not created'
  rm -rf "$dir/vault/.git/fm-feeder/lock"

  assert_export_ok "$dir" 'commit intent recovery'
  assert_contains "$OUT" 'recovered committed run' 'commit intent recovery: not reported'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$head" ] \
    || fail 'commit intent recovery: retained commit was not pushed'
  assert_absent "$dir/vault/.git/fm-feeder/journal" 'commit intent recovery: journal survived'

  pass "fm-feeder-export: a hard stop after commit recovers commit intent"
}

test_precommit_recovery_refuses_unsafe_state() {
  local dir feeder before

  dir=$(new_case recover-symbolic-child)
  seed_records "$dir"
  assert_export_ok "$dir" 'symbolic recovery child: baseline'
  stage_hard_stop "$dir" after-move-reports
  feeder="$dir/vault/.git/fm-feeder"
  rm -rf "$feeder/backup.hardstop/reports"
  mkdir -p "$dir/outside-recovery"
  : > "$dir/outside-recovery/sentinel"
  ln -s "$dir/outside-recovery" "$feeder/backup.hardstop/reports"
  before=$(vault_state "$dir")
  run_export "$dir"
  expect_code 4 "$RC" 'symbolic recovery child'
  assert_contains "$OUT" 'symbolic backup/reports operand' 'symbolic recovery child'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'symbolic recovery child: recovery mutated the vault before refusal'
  assert_present "$dir/outside-recovery/sentinel" \
    'symbolic recovery child: external sentinel changed'
  assert_present "$feeder/backup.hardstop/decisions" \
    'symbolic recovery child: first backup operand was consumed'
  assert_present "$feeder/journal" 'symbolic recovery child: journal was removed'

  dir=$(new_case recover-head-mismatch)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery HEAD mismatch: baseline'
  stage_hard_stop "$dir" prepared
  feeder="$dir/vault/.git/fm-feeder"
  printf 'intervening commit\n' > "$dir/vault/intervening.md"
  git -C "$dir/vault" add intervening.md
  git -C "$dir/vault" commit -qm 'intervening commit'
  before=$(vault_state "$dir")
  run_export "$dir"
  expect_code 4 "$RC" 'recovery HEAD mismatch'
  assert_contains "$OUT" 'vault HEAD changed' 'recovery HEAD mismatch'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'recovery HEAD mismatch: recovery mutated the vault before refusal'
  assert_present "$feeder/journal" 'recovery HEAD mismatch: journal was removed'
  assert_present "$feeder/stage.hardstop" 'recovery HEAD mismatch: stage was removed'
  assert_present "$feeder/backup.hardstop" 'recovery HEAD mismatch: backup was removed'

  dir=$(new_case recover-old-digest-mismatch)
  seed_records "$dir"
  assert_export_ok "$dir" 'recovery digest mismatch: baseline'
  stage_hard_stop "$dir" prepared
  feeder="$dir/vault/.git/fm-feeder"
  printf 'decisions_old=%064d\n' 0 >> "$feeder/journal"
  before=$(vault_state "$dir")
  run_export "$dir"
  expect_code 4 "$RC" 'recovery digest mismatch'
  assert_contains "$OUT" 'recorded prior decision digest does not match' \
    'recovery digest mismatch'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'recovery digest mismatch: recovery mutated the vault before refusal'
  assert_present "$feeder/journal" 'recovery digest mismatch: journal was removed'
  assert_present "$feeder/stage.hardstop" 'recovery digest mismatch: stage was removed'
  assert_present "$feeder/backup.hardstop" 'recovery digest mismatch: backup was removed'

  dir=$(new_case recover-unexpected-live-bytes)
  seed_records "$dir"
  assert_export_ok "$dir" 'unexpected live recovery bytes: baseline'
  stage_hard_stop "$dir" installed-decisions
  feeder="$dir/vault/.git/fm-feeder"
  printf 'unexpected live edit\n' >> "$dir/vault/wiki/decisions/_index.md"
  before=$(vault_state "$dir")
  run_export "$dir"
  expect_code 4 "$RC" 'unexpected live recovery bytes'
  assert_contains "$OUT" 'does not match the staged generation' 'unexpected live recovery bytes'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'unexpected live recovery bytes: recovery mutated the vault before refusal'
  assert_present "$feeder/journal" 'unexpected live recovery bytes: journal was removed'
  assert_present "$feeder/stage.hardstop" 'unexpected live recovery bytes: stage was removed'
  assert_present "$feeder/backup.hardstop" 'unexpected live recovery bytes: backup was removed'

  pass "fm-feeder-export: unsafe pre-commit recovery state refuses without mutation"
}

make_fake_rm() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/rm" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_TEST_RM_KEEP_MATCH:-}" ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *"\$FM_TEST_RM_KEEP_MATCH"*) exit 0 ;;
    esac
  done
fi
if [ -n "\${FM_TEST_RM_FAIL_MATCH:-}" ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *"\$FM_TEST_RM_FAIL_MATCH"*)
        printf 'fake rm: forced failure\n' >&2
        exit 1
        ;;
    esac
  done
fi
if [ -n "\${FM_TEST_RM_FAIL_EXACT:-}" ]; then
  for arg in "\$@"; do
    if [ "\$arg" = "\$FM_TEST_RM_FAIL_EXACT" ]; then
      printf 'fake rm: refused live mirror deletion\n' >&2
      exit 1
    fi
  done
fi
exec $(command -v rm) "\$@"
SH
  chmod +x "$dir/fakebin/rm"
}

test_committed_phase_recovery_pushes() {
  local dir head remote_before

  dir=$(new_case recover-committed)
  seed_records "$dir"
  assert_export_ok "$dir" 'committed recovery: baseline publication'
  add_decision "$dir" eta.md '# Eta

new record
'
  # Fail the post-commit cleanup so the exporter leaves its own committed-phase
  # journal behind, rather than hand-writing one the recovery format must match.
  make_fake_rm "$dir"
  run_export "$dir" FM_TEST_RM_FAIL_MATCH=backup.
  expect_code 5 "$RC" 'committed recovery: cleanup failure'
  rm -f "$dir/fakebin/rm"
  assert_present "$dir/vault/.git/fm-feeder/journal" 'committed recovery: no journal was retained'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  [ "$head" != "$remote_before" ] || fail 'committed recovery: the fixture never diverged'
  assert_present "$dir/vault/wiki/decisions/eta.md" 'committed recovery: the new generation was rolled back'

  make_fake_rm "$dir"
  run_export "$dir" FM_TEST_RM_FAIL_MATCH=stage.
  expect_code 4 "$RC" 'committed recovery: recovery cleanup failure'
  assert_contains "$OUT" 'cannot clean committed recovery artifacts' \
    'committed recovery: recovery cleanup failure'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'committed recovery: cleanup failure removed the journal'
  rm -f "$dir/fakebin/rm"

  assert_export_ok "$dir" 'committed recovery'
  assert_contains "$OUT" 'recovered committed run' 'committed recovery: not reported'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$head" ] \
    || fail 'committed recovery: the retained commit never reached the remote'
  assert_absent "$dir/vault/.git/fm-feeder/journal" 'committed recovery: the journal survived'
  assert_absent "$dir/vault/.git/fm-feeder/backup.orphan" 'committed recovery: a backup survived'

  dir=$(new_case cleanup-postcondition-backup)
  seed_records "$dir"
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  make_fake_rm "$dir"
  run_export "$dir" FM_TEST_RM_KEEP_MATCH=backup.
  expect_code 5 "$RC" 'backup cleanup postcondition'
  assert_contains "$OUT" 'transaction backup remains' 'backup cleanup postcondition'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'backup cleanup postcondition: journal was removed before backup validation'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  [ "$head" != "$remote_before" ] || fail 'backup cleanup postcondition: commit missing'
  rm -f "$dir/fakebin/rm"
  assert_export_ok "$dir" 'backup cleanup postcondition recovery'

  dir=$(new_case cleanup-postcondition-journal)
  seed_records "$dir"
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  make_fake_rm "$dir"
  run_export "$dir" FM_TEST_RM_KEEP_MATCH=/journal
  expect_code 5 "$RC" 'journal cleanup postcondition'
  assert_contains "$OUT" 'transaction journal remains' 'journal cleanup postcondition'
  assert_present "$dir/vault/.git/fm-feeder/journal" \
    'journal cleanup postcondition: undetected journal vanished'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  [ "$head" != "$remote_before" ] || fail 'journal cleanup postcondition: commit missing'
  rm -f "$dir/fakebin/rm"
  assert_export_ok "$dir" 'journal cleanup postcondition recovery'

  pass "fm-feeder-export: committed cleanup is verified before journal removal and push"
}

test_inconsistent_journal_refuses() {
  local dir before feeder

  dir=$(new_case recover-inconsistent)
  seed_records "$dir"
  assert_export_ok "$dir" 'inconsistent journal: baseline publication'
  before=$(vault_state "$dir")
  feeder="$dir/vault/.git/fm-feeder"
  mkdir -p "$feeder"
  printf 'version=1\nrun=broken\nhead=%s\nstage=%s\nbackup=%s\nphase=committed\n' \
    "$(git -C "$dir/vault" rev-parse HEAD)" "$feeder/stage.x" "$feeder/backup.x" > "$feeder/journal"
  run_export "$dir"
  expect_code 4 "$RC" 'inconsistent journal'
  assert_contains "$OUT" 'recover manually' 'inconsistent journal: no exact instruction'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'inconsistent journal: the vault changed'

  dir=$(new_case recover-orphan-backup)
  seed_records "$dir"
  assert_export_ok "$dir" 'orphan backup: baseline publication'
  before=$(vault_state "$dir")
  mkdir -p "$dir/vault/.git/fm-feeder/backup.orphan"
  run_export "$dir"
  expect_code 4 "$RC" 'orphan backup'
  assert_contains "$OUT" 'backup artifacts remain with no journal' 'orphan backup'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'orphan backup: the vault changed'

  pass "fm-feeder-export: an unexplained journal or backup refuses instead of guessing"
}

test_backup_enumeration_failures() {
  local dir before remote_before local_head

  dir=$(new_case recovery-backup-enumeration-failure)
  seed_records "$dir"
  before=$(vault_state "$dir")
  make_selective_find_failure "$dir"
  run_export "$dir" FM_TEST_FIND_BACKUP_FAIL_AT=1
  expect_code 4 "$RC" 'recovery backup enumeration failure'
  assert_contains "$OUT" 'cannot enumerate transaction backups' \
    'recovery backup enumeration failure'
  [ "$(vault_state "$dir")" = "$before" ] \
    || fail 'recovery backup enumeration failure: the vault changed'

  dir=$(new_case push-backup-enumeration-failure)
  seed_records "$dir"
  remote_before=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  make_selective_find_failure "$dir"
  run_export "$dir" FM_TEST_FIND_BACKUP_FAIL_AT=2
  expect_code 5 "$RC" 'push backup enumeration failure'
  assert_contains "$OUT" 'cannot enumerate transaction backups before push' \
    'push backup enumeration failure'
  local_head=$(git -C "$dir/vault" rev-parse HEAD)
  [ "$local_head" != "$remote_before" ] \
    || fail 'push backup enumeration failure: local commit was not preserved'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_before" ] \
    || fail 'push backup enumeration failure: the commit reached the remote'

  pass "fm-feeder-export: backup enumeration failures fail closed"
}

# --- remote identity, privacy, push, retry ----------------------------------

test_remote_identity_and_privacy_refusals() {
  local dir remote_head before

  dir=$(new_case remote-identity)
  seed_records "$dir"
  remote_head=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  before=$(vault_state "$dir")

  git -C "$dir/vault" remote remove origin
  assert_refused "$dir" "no 'origin' remote" 'missing remote'
  assert_absent "$dir/vault/.git/fm-feeder" 'missing remote: transaction directory was created'
  assert_absent "$dir/vault/wiki" 'missing remote: live directory was created'
  git -C "$dir/vault" remote add origin "$VAULT_URL"
  GIT_SSH_COMMAND="$dir/fakebin/fm-feeder-ssh" git -C "$dir/vault" fetch -q origin
  git -C "$dir/vault" branch -q -u origin/main main

  git -C "$dir/vault" remote set-url origin https://github.com/other-owner/other-vault.git
  assert_refused "$dir" 'does not match the marker repository' 'changed remote'

  git -C "$dir/vault" remote set-url origin \
    'https://github.com/acme/fm-vault.git?token=TOPSECRET_REMOTE_TOKEN'
  assert_refused "$dir" 'does not match the marker repository' 'credential-bearing remote URL'
  assert_not_contains "$OUT" 'TOPSECRET_REMOTE_TOKEN' \
    'credential-bearing remote URL: secret reached refusal output'

  git -C "$dir/vault" remote set-url origin "file://$dir/origin.git"
  assert_refused "$dir" 'not a GitHub repository URL' 'non-GitHub remote'
  git -C "$dir/vault" remote set-url origin "$VAULT_URL"

  git -C "$dir/vault" config --add remote.origin.pushurl \
    https://github.com/other-owner/other-vault.git
  assert_refused "$dir" 'push destination that does not match' 'changed push destination'
  assert_absent "$dir/vault/.git/fm-feeder" \
    'changed push destination: transaction directory was created'
  git -C "$dir/vault" config --unset-all remote.origin.pushurl

  git -C "$dir/vault" config \
    url.git@github.com:other-owner/other-vault.git.pushInsteadOf "$VAULT_URL"
  assert_refused "$dir" 'effective push destination that does not match' \
    'rewritten effective push destination'
  git -C "$dir/vault" config --unset-all \
    url.git@github.com:other-owner/other-vault.git.pushInsteadOf

  git -C "$dir/vault" config --add remote.origin.pushurl \
    'https://github.com/other-owner/other-vault.git?token=TOPSECRET_PUSH_TOKEN'
  assert_refused "$dir" 'push destination that does not match' \
    'credential-bearing push destination'
  assert_not_contains "$OUT" 'TOPSECRET_PUSH_TOKEN' \
    'credential-bearing push destination: secret reached refusal output'
  git -C "$dir/vault" config --unset-all remote.origin.pushurl

  git -C "$dir/vault" config --add remote.origin.pushurl "https://github.com/$VAULT_REPO.git"
  git -C "$dir/vault" config --add remote.origin.pushurl ''
  assert_refused "$dir" 'empty push URL' 'empty additional push destination'
  git -C "$dir/vault" config --unset-all remote.origin.pushurl

  git -C "$dir/vault" branch -m wrong
  assert_refused "$dir" "not the required branch 'main'" 'wrong branch'
  assert_absent "$dir/vault/.git/fm-feeder" 'wrong branch: transaction directory was created'
  assert_absent "$dir/vault/wiki" 'wrong branch: live directory was created'
  git -C "$dir/vault" branch -m main

  make_gh_axi "$dir" public
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'public vault: exporter reported success'
  assert_contains "$OUT" 'is public, not private' 'public vault'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'public vault: local state changed'
  assert_absent "$dir/vault/.git/fm-feeder" 'public vault: transaction directory was created'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_head" ] \
    || fail 'public vault: the mirror was pushed anyway'

  make_gh_axi "$dir" fail
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'unavailable privacy check: exporter reported success'
  assert_contains "$OUT" 'refusing to push' 'unavailable privacy check'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'unavailable privacy check: local state changed'
  assert_absent "$dir/vault/.git/fm-feeder" \
    'unavailable privacy check: transaction directory was created'

  make_gh_axi "$dir" none
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'missing visibility field: exporter reported success'
  assert_contains "$OUT" 'no visibility field' 'missing visibility field'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'missing visibility field: local state changed'
  assert_absent "$dir/vault/.git/fm-feeder" \
    'missing visibility field: transaction directory was created'

  make_gh_axi "$dir" ambiguous
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'ambiguous visibility: exporter reported success'
  assert_contains "$OUT" 'ambiguous visibility fields' 'ambiguous visibility'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'ambiguous visibility: local state changed'
  assert_absent "$dir/vault/.git/fm-feeder" \
    'ambiguous visibility: transaction directory was created'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_head" ] \
    || fail 'ambiguous visibility: mirror was pushed anyway'
  make_gh_axi "$dir" private

  git -C "$dir/vault" branch -q --unset-upstream main
  run_export "$dir"
  [ "$RC" -ne 0 ] || fail 'missing upstream: exporter reported success'
  assert_contains "$OUT" 'has no upstream' 'missing upstream'
  [ "$(vault_state "$dir")" = "$before" ] || fail 'missing upstream: local state changed'
  assert_absent "$dir/vault/.git/fm-feeder" 'missing upstream: transaction directory was created'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$remote_head" ] \
    || fail 'remote identity: the remote moved during the refusal cases'

  pass "fm-feeder-export: the pinned private remote is verified before every push"
}

test_push_failure_then_retry() {
  local dir head

  dir=$(new_case push-retry)
  seed_records "$dir"
  make_fake_git "$dir"
  run_export "$dir" FM_TEST_GIT_FAIL=push
  expect_code 5 "$RC" 'push failure'
  assert_contains "$OUT" 'the local commit' 'push failure: the retained commit was not reported'
  assert_contains "$OUT" 'retry with' 'push failure: no retry instruction'
  rm -f "$dir/fakebin/git"

  head=$(git -C "$dir/vault" rev-parse HEAD)
  assert_present "$dir/vault/wiki/decisions/alpha-2026-01-05.md" 'push failure: the generation was discarded'
  [ "$(git -C "$dir/vault" status --porcelain | head -1)" = '' ] \
    || fail 'push failure: the vault was left dirty'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" != "$head" ] \
    || fail 'push failure: the fixture pushed anyway'
  assert_absent "$dir/vault/.git/fm-feeder/journal" 'push failure: a journal survived'

  assert_export_ok "$dir" 'push retry'
  assert_contains "$OUT" 'bytes are unchanged' 'push retry: the retry created new content'
  [ "$(git -C "$dir/vault" rev-parse HEAD)" = "$head" ] \
    || fail 'push retry: a second commit was created'
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$head" ] \
    || fail 'push retry: the retained commit never reached the remote'

  pass "fm-feeder-export: a push failure keeps the local commit and the next run pushes it"
}

test_end_to_end_local_bare_remote() {
  local dir head remote_files gh_calls

  dir=$(new_case end-to-end)
  seed_records "$dir"
  add_report "$dir" task-two '# Report two

second body
'
  assert_export_ok "$dir" 'end to end'
  head=$(git -C "$dir/vault" rev-parse HEAD)
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/main)" = "$head" ] \
    || fail 'end to end: the remote did not receive the commit'
  remote_files=$(git -C "$dir/origin.git" ls-tree -r --name-only refs/heads/main -- wiki | LC_ALL=C sort)
  [ "$remote_files" = "$(printf 'wiki/decisions/_index.md\nwiki/decisions/alpha-2026-01-05.md\nwiki/reports/_index.md\nwiki/reports/task-one.md\nwiki/reports/task-two.md')" ] \
    || fail "end to end: the remote holds an incomplete generation"$'\n'"$remote_files"
  git -C "$dir/origin.git" show "refs/heads/main:wiki/reports/task-two.md" | LC_ALL=C grep -q 'second body' \
    || fail 'end to end: the pushed page lost its payload'
  gh_calls=$(LC_ALL=C grep -c "repo view $VAULT_REPO" "$dir/gh.log")
  [ "$gh_calls" -ge 1 ] || fail 'end to end: the privacy check never ran against the pinned repository'

  pass "fm-feeder-export: a full generation reaches a local bare origin through the pinned identity"
}

run_minimal() {  # <dir> <path>
  OUT=$(env -i PATH="$2" HOME="$1" GIT_SSH_COMMAND="$1/fakebin/fm-feeder-ssh" \
    FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" \
    /bin/bash "$EXPORT" 2>&1)
  RC=$?
  return 0
}

test_hash_tool_requirement() {
  local dir minimal tool source expected

  dir=$(new_case hash-tools)
  seed_records "$dir"
  minimal="$dir/minimal"
  mkdir -p "$minimal"
  for tool in git awk sed grep find sort uniq cp mv rm mkdir ln basename dirname cat head tail \
    date stat wc tr cmp xargs mktemp paste uname readlink env sleep touch \
    iconv python3 chmod ls bash; do
    source=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$source" "$minimal/$tool"
  done
  ln -sf "$dir/fakebin/gh-axi" "$minimal/gh-axi"
  expected=$(fixture_sha256_file "$dir/home/data/decisions/alpha-2026-01-05.md")
  write_hash_wrapper "$minimal/shasum" shasum

  # A minimal PATH can lack what Git needs to reach the fixture origin, so this
  # case asserts the generation and its digests, not the push.
  run_minimal "$dir" "$minimal"
  case "$RC" in
    0 | 5) ;;
    *) fail "hash tools: the shasum branch failed with $RC"$'\n'"$OUT" ;;
  esac
  [ "$(page_field "$dir/vault/wiki/decisions/alpha-2026-01-05.md" sot_sha256)" = "$expected" ] \
    || fail 'hash tools: the shasum branch produced the wrong provenance digest'

  rm -f "$minimal/shasum"
  write_hash_wrapper "$minimal/sha256sum" sha256sum
  run_minimal "$dir" "$minimal"
  case "$RC" in
    0 | 5) ;;
    *) fail "hash tools: the sha256sum branch failed with $RC"$'\n'"$OUT" ;;
  esac
  [ "$(page_field "$dir/vault/wiki/decisions/alpha-2026-01-05.md" sot_sha256)" = "$expected" ] \
    || fail 'hash tools: the sha256sum branch produced the wrong provenance digest'
  rm -f "$minimal/sha256sum"

  run_minimal "$dir" "$minimal"
  [ "$RC" -ne 0 ] || fail 'hash tools: no SHA-256 tool still succeeded'
  assert_contains "$OUT" 'no SHA-256 tool available' 'hash tools'

  pass "fm-feeder-export: both hash-tool branches work and their absence refuses"
}

# A corpus this size is what exposed the earlier non-terminating export: bash 3.2
# leaked one process-substitution descriptor per validated page, and the run spun
# at 100% CPU without ever returning once those descriptors ran out. The bound
# here is generous against a run that normally takes a few seconds, so it fails
# on a non-terminating path rather than on a slow machine.
test_large_corpus_terminates_within_a_bound() {
  local dir index pages bound=180

  dir=$(new_case large-corpus)
  index=0
  while [ "$index" -lt 90 ]; do
    printf '# Decision %s\n\nbody %s\n' "$index" "$index" \
      > "$dir/home/data/decisions/bulk-$index.md"
    mkdir -p "$dir/home/data/bulk-task-$index"
    printf '# Report %s\n\nbody %s\n' "$index" "$index" \
      > "$dir/home/data/bulk-task-$index/report.md"
    index=$((index + 1))
  done

  OUT=$(fm_run_timed "$bound" env PATH="$dir/fakebin:$PATH" \
    GIT_SSH_COMMAND="$dir/fakebin/fm-feeder-ssh" FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" "$EXPORT" 2>&1)
  RC=$?
  [ "$RC" -ne 124 ] || fail "large corpus: the export did not terminate within ${bound}s"
  [ "$RC" -eq 0 ] || fail "large corpus: the export failed with $RC"$'\n'"$OUT"
  pages=$(LC_ALL=C find "$dir/vault/wiki" -type f -name '*.md' | LC_ALL=C awk 'END {print NR}')
  [ "$pages" -eq 182 ] || fail "large corpus: published $pages pages, expected 182"

  pass "fm-feeder-export: a corpus of many records completes inside a hard time bound"
}

test_help_documents_the_date_limitation() {
  OUT=$("$EXPORT" --help 2>&1)
  RC=$?
  expect_code 0 "$RC" 'help'
  assert_contains "$OUT" 'first-known' 'help: the first-known date rule is undocumented'
  assert_contains "$OUT" 'config/feeder-vault' 'help: the configuration path is undocumented'
  assert_contains "$OUT" 'private' 'help: the private-visibility requirement is undocumented'
  pass "fm-feeder-export: --help documents the configuration and the first-known date limitation"
}

test_config_refusals
test_git_environment_refusals
test_vault_identity_refusals
test_marker_refusals
test_overlap_refusals
test_owned_symlink_refusals
test_render_time_transaction_link_refusals
test_prior_digest_failure_refuses_before_journal
test_empty_and_mixed_source_sets
test_source_enumeration_failures
test_source_alias_handling
test_titles_and_yaml_quoting
test_destination_names_and_collisions
test_dates
test_byte_identical_rerun
test_index_determinism
test_staged_payload_and_index_validation
test_secret_classes_refuse_before_mutation
test_secret_lookalikes_publish
test_secret_in_a_generated_page_refuses
test_secret_scan_errors_fail_closed
test_invalid_text_refuses_before_mutation
test_exclusions
test_snapshot_race_refuses_before_swap
test_lock_contention_and_stale_lock
test_dirty_vault_refuses
test_publication_filesystem_refusal
test_exact_staging
test_committed_tree_and_lineage_verification
test_command_failures_roll_back
test_signals_roll_back
test_publication_phase_signals
test_journal_recovery_per_phase
test_recovery_precedes_normal_preflight
test_vault_authority_precedes_recovery
test_recovery_resumes_after_hard_stop
test_precommit_cleanup_survives_hard_stops
test_empty_live_directory_recovery
test_commit_intent_recovery
test_precommit_recovery_refuses_unsafe_state
test_committed_phase_recovery_pushes
test_inconsistent_journal_refuses
test_backup_enumeration_failures
test_remote_identity_and_privacy_refusals
test_push_failure_then_retry
test_end_to_end_local_bare_remote
test_hash_tool_requirement
test_large_corpus_terminates_within_a_bound
test_help_documents_the_date_limitation
