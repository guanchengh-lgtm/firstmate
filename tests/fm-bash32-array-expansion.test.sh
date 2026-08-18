#!/usr/bin/env bash
# Regression contract for empty arrays under stock macOS Bash 3.2 with nounset.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bash32-array-expansion)
RUNTIME_FIXTURE="$TMP_ROOT/runtime.sh"

cat >"$RUNTIME_FIXTURE" <<'SH'
#!/bin/bash
set -u

print_argv() {
  local label=$1 item
  shift
  printf '%s argc=%s' "$label" "$#"
  for item in "$@"; do
    printf ' <%s>' "$item"
  done
  printf '\n'
}

empty=()
empty_loop=()
for item in ${empty[@]+"${empty[@]}"}; do
  empty_loop+=("$item")
done
empty_copy=(${empty[@]+"${empty[@]}"})
printf 'empty loop=%s copy=%s star=<%s>\n' \
  "${#empty_loop[@]}" "${#empty_copy[@]}" "${empty[*]-}"
print_argv empty ${empty[@]+"${empty[@]}"}

values=("one two" "" three)
nonempty_loop=()
for item in ${values[@]+"${values[@]}"}; do
  nonempty_loop+=("$item")
done
nonempty_copy=(${values[@]+"${values[@]}"})
[ "${nonempty_loop[0]}" = "one two" ] || exit 31
[ -z "${nonempty_loop[1]}" ] || exit 32
[ "${nonempty_loop[2]}" = three ] || exit 33
[ "${nonempty_copy[0]}" = "one two" ] || exit 34
[ -z "${nonempty_copy[1]}" ] || exit 35
[ "${nonempty_copy[2]}" = three ] || exit 36
printf 'nonempty loop=%s copy=%s star=<%s>\n' \
  "${#nonempty_loop[@]}" "${#nonempty_copy[@]}" "${values[*]-}"
print_argv nonempty ${values[@]+"${values[@]}"}
SH

runtime_output=$(/bin/bash "$RUNTIME_FIXTURE")
runtime_rc=$?
[ "$runtime_rc" -eq 0 ] || fail "guarded runtime fixture failed under /bin/bash -u with exit $runtime_rc"
empty_output=$(printf '%s\n' "$runtime_output" | sed -n '1,2p')
expected_empty=$(printf '%s\n' 'empty loop=0 copy=0 star=<>' 'empty argc=0')
[ "$empty_output" = "$expected_empty" ] || fail "empty arrays changed guarded behavior: $empty_output"
pass "guarded empty arrays stay nounset-safe"

nonempty_output=$(printf '%s\n' "$runtime_output" | sed -n '3,4p')
expected_nonempty=$(printf '%s\n' \
  'nonempty loop=3 copy=3 star=<one two  three>' \
  'nonempty argc=3 <one two> <> <three>')
[ "$nonempty_output" = "$expected_nonempty" ] \
  || fail "nonempty arrays changed element boundaries: $nonempty_output"
pass "guarded nonempty arrays preserve element boundaries"
