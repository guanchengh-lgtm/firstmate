#!/usr/bin/env bash
set -u

ROOT=${1:?repo root required}
DEMO_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-partial-create-demo.XXXXXX")
trap 'rm -rf "$DEMO_TMP"' EXIT

show_log() {
  tr '\037' ' ' < "$1"
}

printf '=== cmux: cleanup proves absence ===\n'
eval "$(sed -n '31,80p;100,102p' "$ROOT/tests/fm-backend-cmux.test.sh")"
. "$ROOT/bin/backends/cmux.sh"
cmux_dir="$DEMO_TMP/cmux-clean"
mkdir -p "$cmux_dir/responses"
cmux_title=$(fm_backend_cmux_scoped_title fm-evidence)
cmux_id=bbbbbbbb-3333-3333-3333-333333333333
printf '{"workspaces":[]}' > "$cmux_dir/responses/1.out"
printf '{"workspaces":[]}' > "$cmux_dir/responses/3.out"
cmux_workspace_list_response "$cmux_dir" 4 "$cmux_id" "$cmux_title"
printf '[]' > "$cmux_dir/responses/5.out"
printf '{"workspaces":[]}' > "$cmux_dir/responses/7.out"
cmux_fb=$(make_cmux_fakebin "$cmux_dir")
cmux_out=$(PATH="$cmux_fb:$PATH" FM_CMUX_LOG="$cmux_dir/log" FM_CMUX_RESPONSES="$cmux_dir/responses" \
  bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-evidence /tmp/proj' "$ROOT" 2>&1)
cmux_status=$?
printf 'status=%s\n%s\n' "$cmux_status" "$cmux_out"
printf 'cleanup calls:\n'
show_log "$cmux_dir/log" | grep -E 'close-workspace|workspace list'
printf 'final strict list: '
cat "$cmux_dir/responses/7.out"
printf '\n\n=== cmux: failed cleanup names the orphan ===\n'
cmux_dir="$DEMO_TMP/cmux-leak"
mkdir -p "$cmux_dir/responses"
cmux_title=$(fm_backend_cmux_scoped_title fm-evidence-leak)
cmux_id=bbbbbbbb-4444-4444-4444-444444444444
printf '{"workspaces":[]}' > "$cmux_dir/responses/1.out"
cmux_workspace_list_response "$cmux_dir" 3 "$cmux_id" "$cmux_title"
printf '{"panes":[]}' > "$cmux_dir/responses/4.out"
printf '[]' > "$cmux_dir/responses/5.out"
printf '1' > "$cmux_dir/responses/6.exit"
cmux_workspace_list_response "$cmux_dir" 7 "$cmux_id" "$cmux_title"
cmux_fb=$(make_cmux_fakebin "$cmux_dir")
cmux_out=$(PATH="$cmux_fb:$PATH" FM_CMUX_LOG="$cmux_dir/log" FM_CMUX_RESPONSES="$cmux_dir/responses" \
  bash -c '. "$0/bin/backends/cmux.sh"; fm_backend_cmux_create_task fm-evidence-leak /tmp/proj' "$ROOT" 2>&1)
cmux_status=$?
printf 'status=%s\n%s\n' "$cmux_status" "$cmux_out"
printf 'final strict list: '
cat "$cmux_dir/responses/7.out"

printf '\n\n=== Zellij: cleanup proves absence ===\n'
eval "$(sed -n '30,68p' "$ROOT/tests/fm-backend-zellij.test.sh")"
. "$ROOT/bin/backends/zellij.sh"
zellij_dir="$DEMO_TMP/zellij-clean"
mkdir -p "$zellij_dir/responses"
printf '[{"tab_id":0,"name":"Tab #1","active":true}]\n' > "$zellij_dir/responses/1.out"
printf '4\n' > "$zellij_dir/responses/2.out"
printf '[]\n' > "$zellij_dir/responses/3.out"
printf '[{"tab_id":0,"name":"Tab #1","active":true}]\n' > "$zellij_dir/responses/5.out"
zellij_fb=$(make_zellij_fakebin "$zellij_dir")
zellij_out=$(PATH="$zellij_fb:$PATH" FM_ZELLIJ_LOG="$zellij_dir/log" FM_ZELLIJ_RESPONSES="$zellij_dir/responses" \
  FM_ZELLIJ_SESSION_LIST=firstmate \
  bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_create_task firstmate fm-evidence /tmp/proj' "$ROOT" 2>&1)
zellij_status=$?
printf 'status=%s\n%s\n' "$zellij_status" "$zellij_out"
printf 'cleanup calls:\n'
show_log "$zellij_dir/log" | grep -E 'close-tab-by-id|list-tabs'
printf 'final strict list: '
cat "$zellij_dir/responses/5.out"

printf '\n\n=== Zellij: failed cleanup names the orphan ===\n'
zellij_dir="$DEMO_TMP/zellij-leak"
mkdir -p "$zellij_dir/responses"
zellij_title=$(fm_backend_zellij_scoped_title fm-evidence-leak)
printf '[{"tab_id":0,"name":"Tab #1","active":true}]\n' > "$zellij_dir/responses/1.out"
printf '4\n' > "$zellij_dir/responses/2.out"
printf '[]\n' > "$zellij_dir/responses/3.out"
printf '1' > "$zellij_dir/responses/4.exit"
printf '[{"tab_id":0,"name":"Tab #1","active":true},{"tab_id":4,"name":"%s","active":false}]\n' "$zellij_title" > "$zellij_dir/responses/5.out"
zellij_fb=$(make_zellij_fakebin "$zellij_dir")
zellij_out=$(PATH="$zellij_fb:$PATH" FM_ZELLIJ_LOG="$zellij_dir/log" FM_ZELLIJ_RESPONSES="$zellij_dir/responses" \
  FM_ZELLIJ_SESSION_LIST=firstmate \
  bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_create_task firstmate fm-evidence-leak /tmp/proj' "$ROOT" 2>&1)
zellij_status=$?
printf 'status=%s\n%s\n' "$zellij_status" "$zellij_out"
printf 'final strict list: '
cat "$zellij_dir/responses/5.out"

printf '\n\n=== Herdr: malformed response cleanup frees the label ===\n'
eval "$(sed -n '85,196p' "$ROOT/tests/fm-backend-herdr.test.sh")"
. "$ROOT/bin/backends/herdr.sh"
herdr_dir="$DEMO_TMP/herdr-clean"
mkdir -p "$herdr_dir"
herdr_fb=$(make_herdr_statefake "$herdr_dir")
herdr_out=$(PATH="$herdr_fb:$PATH" FM_HERDR_LOG="$herdr_dir/log" FM_FAKE_HERDR_STATE="$herdr_dir/state.json" \
  FM_HERDR_FAKE_CREATE_RESPONSE=malformed \
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-evidence /tmp/proj' "$ROOT" 2>&1)
herdr_status=$?
printf 'first status=%s\n%s\n' "$herdr_status" "$herdr_out"
printf 'state after cleanup: '
jq -c '{matching_tabs:[.tabs[] | select(.label == "fm-evidence")]}' "$herdr_dir/state.json"
herdr_retry=$(PATH="$herdr_fb:$PATH" FM_HERDR_LOG="$herdr_dir/log" FM_FAKE_HERDR_STATE="$herdr_dir/state.json" \
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-evidence /tmp/proj' "$ROOT")
herdr_retry_status=$?
printf 'retry status=%s target=%s\n' "$herdr_retry_status" "$herdr_retry"

printf '\n=== Herdr: failed cleanup names and retains the orphan ===\n'
herdr_dir="$DEMO_TMP/herdr-leak"
mkdir -p "$herdr_dir"
herdr_fb=$(make_herdr_statefake "$herdr_dir")
herdr_out=$(PATH="$herdr_fb:$PATH" FM_HERDR_LOG="$herdr_dir/log" FM_FAKE_HERDR_STATE="$herdr_dir/state.json" \
  FM_HERDR_FAKE_CREATE_RESPONSE=tab-only FM_HERDR_FAKE_TAB_CLOSE_FAIL=1 \
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-evidence-leak /tmp/proj' "$ROOT" 2>&1)
herdr_status=$?
printf 'status=%s\n%s\n' "$herdr_status" "$herdr_out"
printf 'retained state: '
jq -c '{matching_tabs:[.tabs[] | select(.label == "fm-evidence-leak") | {tab_id,pane_id,label}]}' "$herdr_dir/state.json"
