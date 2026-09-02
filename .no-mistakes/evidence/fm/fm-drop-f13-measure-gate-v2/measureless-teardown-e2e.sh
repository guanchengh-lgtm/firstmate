#!/usr/bin/env bash
set -eu

repo=${1:?usage: measureless-teardown-e2e.sh <repo>}
case "$repo" in
  /Users/AI/.no-mistakes/worktrees/edb446952c22/01M1F6308B73VCJZX3K3BJ30G3) ;;
  *) echo "refusing unexpected repository: $repo" >&2; exit 2 ;;
esac

fixture=$(mktemp -d "${TMPDIR:-/tmp}/fm-measureless-e2e.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT INT TERM
id=measureless-evidence
home="$fixture/home"
state="$home/state"
data="$home/data"
config="$home/config"
fakebin="$fixture/fakebin"
mkdir -p "$state" "$data/$id" "$config" "$fakebin"
touch "$state/.last-watcher-beat"

printf '%s\n' \
  "window=firstmate:fm-$id" \
  "endpoint_task_id=$id" \
  "worktree=$fixture/missing-worktree" \
  "project=$fixture/missing-project" \
  'kind=ship' \
  'role=builder' \
  'mode=local-only' > "$state/$id.meta"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/tmux"
chmod +x "$fakebin/tmux"

measure="$data/$id/measure.md"
printf 'before: measure.md=%s meta=%s\n' \
  "$([ -e "$measure" ] && echo present || echo absent)" \
  "$([ -e "$state/$id.meta" ] && echo present || echo absent)"

set +e
FM_HOME="$home" \
FM_ROOT_OVERRIDE="$repo" \
FM_STATE_OVERRIDE="$state" \
FM_DATA_OVERRIDE="$data" \
FM_CONFIG_OVERRIDE="$config" \
FM_TEARDOWN_GUARD_DONE=1 \
FM_GATE_REFUSE_BYPASS=1 \
FM_VALIDATION_TRUTH_BYPASS=1 \
PATH="$fakebin:$PATH" \
  "$repo/bin/fm-teardown.sh" "$id"
rc=$?
set -e

printf 'command: fm-teardown.sh %s\n' "$id"
printf 'exit: %s\n' "$rc"
printf 'after: measure.md=%s meta=%s\n' \
  "$([ -e "$measure" ] && echo present || echo absent)" \
  "$([ -e "$state/$id.meta" ] && echo present || echo absent)"

[ "$rc" -eq 0 ]
[ ! -e "$measure" ]
[ ! -e "$state/$id.meta" ]
