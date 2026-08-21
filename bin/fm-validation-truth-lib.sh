#!/usr/bin/env bash
# Shared no-mistakes validation-truth refusal.
#
# A no-mistakes ship may be armed, merged, or cleaned up only when a fresh
# fm-crew-state.sh read reports source: run-step (the no-mistakes axi status
# run, not a live pane or status log) and state: done. direct-PR, local-only,
# scout, and secondmate tasks are exempt because they have no validation run
# by design.
#
# When the run is unreadable, the message is "validation truth unreadable"
# rather than "not validated". Callers must not restart the shared no-mistakes
# daemon; escalate instead.
#
# Test-harness escape: FM_VALIDATION_TRUTH_BYPASS=1 is exported only by
# tests/lib.sh so firstmate's own suite can drive pr-check, pr-merge, and
# teardown without a real validation run. Production callers never set it.
# tests/fm-validation-truth.test.sh strips it to verify real refusal.
#
# Residual: speech that a ship is fine without running this helper, ci-step
# override inherited from fm-crew-state.sh, time-of-check to time-of-use, and
# direct-PR ships. No completeness claim.
#
# Sourced by bin/fm-pr-check.sh, bin/fm-pr-merge.sh, and bin/fm-teardown.sh.
# No side effects on source. set -u / set -e safe.

fm_validation_truth_parse() {
  local line=$1
  FM_VT_STATE=
  FM_VT_SOURCE=
  case "$line" in
    state:\ *' · source: '*)
      FM_VT_STATE=${line#state: }
      FM_VT_STATE=${FM_VT_STATE%% · *}
      FM_VT_SOURCE=${line#* · source: }
      FM_VT_SOURCE=${FM_VT_SOURCE%% · *}
      FM_VT_STATE=${FM_VT_STATE#"${FM_VT_STATE%%[![:space:]]*}"}
      FM_VT_STATE=${FM_VT_STATE%"${FM_VT_STATE##*[![:space:]]}"}
      FM_VT_SOURCE=${FM_VT_SOURCE#"${FM_VT_SOURCE%%[![:space:]]*}"}
      FM_VT_SOURCE=${FM_VT_SOURCE%"${FM_VT_SOURCE##*[![:space:]]}"}
      ;;
  esac
}

fm_require_validation_truth() {  # <meta-file> <task-id>
  local meta=$1 id=$2 mode kind line crew_state
  [ "${FM_VALIDATION_TRUTH_BYPASS:-}" = 1 ] && return 0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2- || true)
  case "$kind" in
    scout|secondmate) return 0 ;;
  esac
  mode=$(grep '^mode=' "$meta" | tail -1 | cut -d= -f2- || true)
  [ "$mode" = no-mistakes ] || return 0
  crew_state=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
  if [ ! -x "$crew_state" ]; then
    echo "REFUSED: no-mistakes task $id has no validation-run current state (source: none). validation truth unreadable" >&2
    return 1
  fi
  line=$("$crew_state" "$id" 2>/dev/null || true)
  fm_validation_truth_parse "$line"
  if [ "$FM_VT_SOURCE" = run-step ] && [ "$FM_VT_STATE" = done ]; then
    return 0
  fi
  if [ "$FM_VT_SOURCE" = run-step ]; then
    echo "REFUSED: no-mistakes task $id validation run is not done (state: ${FM_VT_STATE:-unknown}, source: run-step)" >&2
    return 1
  fi
  echo "REFUSED: no-mistakes task $id has no validation-run current state (source: ${FM_VT_SOURCE:-none}). validation truth unreadable" >&2
  return 1
}
