#!/usr/bin/env bash
# Round 2 live drive of bin/fm-nightly.sh on a fixture home with tool doubles.
set -u
ROOT=/Users/AI/.no-mistakes/worktrees/edb446952c22/01M2CV541BEPXKMFSNBJDAMH09
T=$(mktemp -d /tmp/fm-live-r2.XXXX)
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export NIGHTLY_TICK_RETRY_SECONDS=0 FM_RECORD_SETTLE_SECONDS=0 FM_RECORD_LOCK_WAIT_SECONDS=1 FM_RECORD_PUSH_TIMEOUT=5
NOW=2026-09-07T03:00:00Z
mkhome() { # name -> $H
  H="$T/$1/home"; mkdir -p "$H/data" "$H/state" "$H/config" "$T/$1/trans/.claude/projects" "$T/$1/bin"
  printf 'hello\n' > "$T/$1/trans/.claude/projects/a.jsonl"
  ORIGIN="$T/$1/origin.git"; git init --quiet --bare --initial-branch=main "$ORIGIN"; mkdir -p "$T/empty-home"
  rec() { HOME="$T/empty-home" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$H/data" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/fm-record.sh" "$@"; }
  rec setup --init --origin "file://$ORIGIN" --code-root "$ROOT" >/dev/null || echo "SETUP FAILED"
  printf '# backlog\n' > "$H/data/backlog.md"; rec tick >/dev/null || echo "TICK FAILED"
  printf '[fixture]\ntype = local\n' > "$T/$1/rclone.conf"; printf 'pw\n' > "$T/$1/pw"
  { printf 'NIGHTLY_RESTIC_REPO=rclone:fixture:%s/repo\n' "$T/$1"; printf 'NIGHTLY_RCLONE_CONFIG=%s/rclone.conf\n' "$T/$1"; printf 'NIGHTLY_RESTIC_PASSWORD_COMMAND=cat %s/pw\n' "$T/$1"; } > "$H/config/nightly.env"
  FB="$T/$1/bin"; TRANS="$T/$1/trans"
  cat > "$FB/rclone" <<'S'
#!/usr/bin/env bash
exit 0
S
  chmod +x "$FB/rclone"
}
restic_ok() { cat > "$FB/restic" <<'S'
#!/usr/bin/env bash
case " $* " in *" check "*) exit 0;; esac
printf '%s\n' '{"message_type":"summary","snapshot_id":"livesnap01"}'
S
chmod +x "$FB/restic"; }
run() { HOME="$TRANS" FM_ROOT_OVERRIDE="$ROOT" PATH="$FB:$PATH" "$ROOT/bin/fm-nightly.sh" "$@"; }
show() { echo "--- stages.tsv"; cat "$H/data/.git/nightly/stages.tsv"; echo "--- last-attempt"; cat "$H/data/.git/nightly/last-attempt" 2>/dev/null; echo "--- last-complete"; cat "$H/data/.git/nightly/last-complete" 2>/dev/null; echo; }

echo "########## S1 full run on fixture home: every stage visible"
mkhome full; restic_ok
run run --fm-home "$H" --now "$NOW"; echo "exit=$?"; show
echo "--- status"; run status --fm-home "$H"
echo "--- receipt view"; ls "$H/data/wiki/views/maintenance/" && cat "$H/data/wiki/views/maintenance/"*.md
echo "--- digest via fm-maintain"; python3 -B "$ROOT/bin/fm-maintain.py" digest --record "$H/data" --now "$NOW"; echo "digest exit=$?"
echo "--- origin log"; git --git-dir="$ORIGIN" log --format=%s | head -3

echo "########## S2 run bound: in-flight restic stopped, bound-hit recorded, prior success kept"
mkhome bound; printf 'NIGHTLY_RUN_BOUND_SECONDS=4\n' >> "$H/config/nightly.env"
cat > "$FB/restic" <<S
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$T/bound/restic.pid"
sleep 60
S
chmod +x "$FB/restic"
mkdir -p "$H/data/.git/nightly"; printf 'date=2026-09-06\n' > "$H/data/.git/nightly/last-complete"
s=$(date +%s); run run --fm-home "$H" --now "$NOW"; echo "exit=$? elapsed=$(( $(date +%s) - s ))s"; show
sleep 1; if kill -0 "$(cat "$T/bound/restic.pid")" 2>/dev/null; then echo "RESTIC STILL ALIVE"; else echo "restic double pid $(cat "$T/bound/restic.pid") is gone"; fi
echo "lock present? $( [ -e "$H/data/.git/nightly/lock" ] && echo yes || echo no )"

echo "########## S3 external SIGTERM: signal-term, not bound-hit"
mkhome term
cat > "$FB/restic" <<S
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$T/term/restic.pid"
sleep 60
S
chmod +x "$FB/restic"
HOME="$TRANS" FM_ROOT_OVERRIDE="$ROOT" PATH="$FB:$PATH" "$ROOT/bin/fm-nightly.sh" run --fm-home "$H" --now "$NOW" > "$T/term/out" 2>&1 & np=$!
i=0; while [ $i -lt 100 ] && [ ! -f "$T/term/restic.pid" ]; do sleep 0.1; i=$((i+1)); done
echo "sending TERM to nightly pid $np"; kill -TERM $np; wait $np; echo "exit=$?"; show
sleep 0.5; kill -0 "$(cat "$T/term/restic.pid")" 2>/dev/null && echo "RESTIC STILL ALIVE" || echo "restic child gone"

echo "########## S4 locked restic repository -> archive failed locked (exit 11) and stderr marker on exit 1"
mkhome lock11; cat > "$FB/restic" <<'S'
#!/usr/bin/env bash
case " $* " in *" check "*) exit 0;; esac
echo "Fatal: unable to create lock in backend" >&2; exit 11
S
chmod +x "$FB/restic"; run archive --fm-home "$H" --now "$NOW"; echo "exit=$?"; show; echo "--- archive.json"; cat "$H/data/.git/nightly/archive.json"; echo
mkhome lockmsg; cat > "$FB/restic" <<'S'
#!/usr/bin/env bash
case " $* " in *" check "*) exit 0;; esac
echo "Fatal: repository is already locked by PID 4242 on otherhost" >&2; exit 1
S
chmod +x "$FB/restic"; run archive --fm-home "$H" --now "$NOW"; echo "exit=$?"; show
echo "--- Record must never hold stderr text:"; grep -rl 'otherhost' "$H/data" --exclude-dir=.git && echo "STDERR LEAKED" || echo "no stderr text in Record files"

echo "########## S5 archive subcommand never writes last-attempt"
mkhome arch; restic_ok; run archive --fm-home "$H" --now "$NOW"; echo "exit=$?"; show

echo "########## S6 record-only: explicit skipped stages"
mkhome ro; restic_ok
CL="$T/ro/clone"; git clone --quiet "file://$ORIGIN" "$CL"
echo "--- dry-run"; run run --record-only --record "$CL" --dry-run --now "$NOW"; echo "exit=$?"
run run --record-only --record "$CL" --now "$NOW"; echo "exit=$?"; echo "--- stages.tsv"; cat "$CL/.git/nightly/stages.tsv"; echo "--- origin log"; git --git-dir="$ORIGIN" log --format=%s | head -3
echo "########## S7 home dry-run: every stage visible, skipped explicit"
mkhome dry; restic_ok; run run --fm-home "$H" --dry-run --now "$NOW"; echo "exit=$?"
rm -rf "$T"
