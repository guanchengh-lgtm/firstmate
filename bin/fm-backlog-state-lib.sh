#!/usr/bin/env bash
# Current structured backlog states for one Record backlog file.
# Sourced by bin/fm-session-start.sh and bin/fm-brief.sh; it owns the single
# reading of data/backlog.md that turns live rows into recall status
# overrides. Prints one "<task-id>=<state>" line for each in-flight or queued
# row, where the state is in_flight, queued, held, or parked. It prints
# nothing for an absent, symlinked, or unreadable backlog.

fm_backlog_status_overrides() {  # <backlog-path>
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  awk '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    function emit(line, fallback,    id, state) {
      if (line !~ /^[-*][[:space:]]+\[/) return
      id = line
      sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", id)
      sub(/[[:space:]].*$/, "", id)
      if (id == "") return
      state = fallback
      if (line ~ /hold-kind:[[:space:]]*parked/) state = "parked"
      else if (line ~ /[(]hold|hold-kind:/) state = "held"
      printf "%s=%s\n", id, state
    }
    /^##[[:space:]]+/ { state = state_for_heading($0); next }
    state == "in_flight" && /^[-*][[:space:]]+/ { emit($0, "in_flight"); next }
    state == "queued" && /^[-*][[:space:]]+/ { emit($0, "queued"); next }
  ' "$path"
}
