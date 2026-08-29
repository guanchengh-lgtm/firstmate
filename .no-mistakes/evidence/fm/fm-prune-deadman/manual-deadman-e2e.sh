#!/usr/bin/env bash
set -eu

repo=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/deadman-e2e.XXXXXX")
trap 'rm -rf "$root"' EXIT

notifier="$root/notifier"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s|%s\n'\'' "$1" "$2" >> "$FM_TEST_NOTIFY_LOG"' > "$notifier"
chmod +x "$notifier"

make_case() {
  name=$1
  kind=$2
  dir="$root/$name"
  mkdir -p "$dir/install" "$dir/home/state"
  : > "$dir/home/state/.last-watcher-beat"
  case "$kind" in
    idle) ;;
    process)
      mkdir -p "$dir/home/state/procevent"
      : > "$dir/home/state/procevent/source.source"
      ;;
    task) : > "$dir/home/state/task.meta" ;;
    relay) : > "$dir/home/state/x-watch.check.sh" ;;
  esac
  printf '%s\n' \
    "FM_HOME=$dir/home" \
    'STALE_AFTER_SECS=600' \
    'SAMPLE_GAP_SECS=60' \
    'SAMPLE_MAX_GAP_SECS=120' \
    'FIRST_ARM_GRACE_SECS=660' \
    'WAKE_GRACE_SECS=300' \
    'SLEEP_GAP_DETECT_SECS=99999' \
    'COOLDOWN_SECS=1800' > "$dir/install/deadman.env"
  printf '%s\n' 'command:true' > "$dir/install/deadman.conf"
  printf '%s\n' 0 > "$dir/install/installed-at"
  printf '%s\n' 0 > "$dir/install/armed"
  printf '%s\n' "$dir"
}

run_probe() {
  dir=$1
  now=$2
  shift 2
  FM_DEADMAN_INSTALL_DIR="$dir/install" \
    FM_DEADMAN_NOW="$now" \
    FM_DEADMAN_NOTIFY_EXEC="$notifier" \
    FM_TEST_NOTIFY_LOG="$dir/notify.log" \
    "$repo/bin/fm-deadman.sh" "$@"
}

page_count() {
  file=$1
  if [ -f "$file" ]; then
    wc -l < "$file" | tr -d ' '
  else
    printf 0
  fi
}

show_case() {
  kind=$1
  dir=$(make_case "$kind" "$kind")
  run_probe "$dir" 2000000000
  run_probe "$dir" 2000000060
  pages=$(page_count "$dir/notify.log")
  notification=$(sed -n '1p' "$dir/notify.log" 2>/dev/null || true)
  printf 'case=%s pages=%s notification=%s\n' "$kind" "$pages" "${notification:-none}"
}

show_case idle
show_case process
show_case task
show_case relay

unavailable=$(make_case unavailable idle)
printf '%s\n' '1999999940|home-unavailable' > "$unavailable/install/first-stale"
rm -rf "$unavailable/home"
run_probe "$unavailable" 2000000000
run_probe "$unavailable" 2000000060
printf 'case=unavailable pages=%s first_stale=%s\n' \
  "$(page_count "$unavailable/notify.log")" \
  "$([ -e "$unavailable/install/first-stale" ] && printf retained || printf cleared)"

reset=$(make_case reset task)
run_probe "$reset" 2000000000
rm -f "$reset/home/state/task.meta"
run_probe "$reset" 2000000060
: > "$reset/home/state/task.meta"
run_probe "$reset" 2000000120
before=$(page_count "$reset/notify.log")
run_probe "$reset" 2000000180
after=$(page_count "$reset/notify.log")
printf 'case=reset pages_after_first_new_sample=%s pages_after_second_new_sample=%s\n' "$before" "$after"

canary=$(make_case canary idle)
run_probe "$canary" 2000000000 --canary
printf 'case=canary notification=%s\n' "$(sed -n '1p' "$canary/notify.log")"
