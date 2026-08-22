# shellcheck shell=bash
# Shared ship-brief scaffold marker reads for Role: and Delivery contract.
# Usage: . bin/fm-brief-scaffold-lib.sh
#        fm_brief_scaffold_mode <brief-path>
#        fm_brief_scaffold_role <brief-path>
#
# ONE OWNER for the zones bin/fm-spawn.sh and bin/fm-brief.sh --verifier both
# treat as scaffold markers. Role: and Delivery contract: mode= live either in
# the pre-heading head (verifier briefs put Role: on line 1) or in the trailing
# scaffold # Definition of done block (builder briefs). Task prose, intermediate
# headings, and a task-authored earlier # Definition of done must not satisfy or
# poison the gate: only the head and the last # Definition of done block count,
# and a value from the last DoD wins over the head when both are present.
#
# No side effects on source. set -u / set -e safe.

# fm_brief_scaffold_field <brief-path> <mode|role>
# Prints the scaffold value for the named field, or nothing when absent.
fm_brief_scaffold_field() {
  local brief=$1 field=$2
  awk -v field="$field" '
    BEGIN { zone = "head"; head_val = ""; dod_val = "" }
    /^# Definition of done([[:space:]]|$)/ { zone = "dod"; dod_val = ""; next }
    /^# / { zone = "skip"; next }
    {
      if (zone != "head" && zone != "dod") next
      line = $0
      val = ""
      if (field == "mode" && line ~ /^Delivery contract: mode=/) {
        sub(/^Delivery contract: mode=/, "", line)
        sub(/[[:space:]].*$/, "", line)
        if (line != "") val = line
      } else if (field == "role" && line ~ /^Role:[[:space:]]+/) {
        sub(/^Role:[[:space:]]+/, "", line)
        sub(/[[:space:]].*$/, "", line)
        if (line == "builder" || line == "verifier") val = line
      }
      if (val == "") next
      if (zone == "head") head_val = val
      else dod_val = val
    }
    END {
      if (dod_val != "") print dod_val
      else if (head_val != "") print head_val
    }
  ' "$brief"
}

fm_brief_scaffold_mode() {
  fm_brief_scaffold_field "$1" mode
}

fm_brief_scaffold_role() {
  fm_brief_scaffold_field "$1" role
}
