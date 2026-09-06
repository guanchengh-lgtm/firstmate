#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$ROOT/bin/fm-primary-scope-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-primary-scope)
fm_git_identity fmtest fmtest@example.invalid
mkdir -p "$TMP_ROOT/plain"
git init -q -b main "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" commit -qm init --allow-empty
git -C "$TMP_ROOT/repo" worktree add -qb task "$TMP_ROOT/copy"
! fm_home_is_linked_worktree "$TMP_ROOT/repo" || fail 'plain checkout refused'
! fm_home_is_linked_worktree "$TMP_ROOT/plain" || fail 'non-git directory refused'
fm_home_is_linked_worktree "$TMP_ROOT/copy" || fail 'linked copy not detected'
status=0
out=$(fm_home_refuse_linked_worktree "$TMP_ROOT/copy" test 2>&1) || status=$?
[ "$status" = 1 ] || fail 'refusal status'
[ "$out" = "REFUSED: test self-located its home to linked worktree $TMP_ROOT/copy; that copy's state/ is not a firstmate home. Set FM_HOME=$TMP_ROOT/repo or start firstmate from $TMP_ROOT/repo, then retry." ] || fail "refusal wording: $out"
printf 'sm-test\n' > "$TMP_ROOT/copy/.fm-secondmate-home"
fm_home_refuse_linked_worktree "$TMP_ROOT/copy" test || fail 'marked secondmate refused'
rm "$TMP_ROOT/copy/.fm-secondmate-home"
pass 'home classification and exact refusal preserve secondmate divergence'
# A real parent holds the task directory while its child exercises the public API.
cat > "$TMP_ROOT/probe" <<'SH'
#!/usr/bin/env bash
. "$1/bin/fm-primary-scope-lib.sh"
fm_ancestor_cwd_in_linked_worktree "$PPID"
SH
# shellcheck disable=SC2016
out=$(bash -c 'cd "$1"; sleep 300 & sleeper=$!; trap "kill $sleeper 2>/dev/null || true" EXIT; printf "%s\n" "$$" > "$2/parent"; bash "$2/probe" "$3"; :' _ "$TMP_ROOT/copy" "$TMP_ROOT" "$ROOT")
case "$out" in *$'\t'"$TMP_ROOT/copy") ;; *) fail "real parent cwd absent: $out" ;; esac
pid=${out%%$'\t'*}
[ "$pid" = "$(cat "$TMP_ROOT/parent")" ] || fail 'ancestor probe did not name parent'
mkdir "$TMP_ROOT/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/fakebin/lsof"
chmod +x "$TMP_ROOT/fakebin/lsof"
status=0
PATH="$TMP_ROOT/fakebin:$PATH" fm_ancestor_cwd_in_linked_worktree "$$" >/dev/null || status=$?
[ "$status" = 2 ] || fail 'lsof failure not unknown'
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/fakebin/ps"
chmod +x "$TMP_ROOT/fakebin/ps"
status=0
PATH="$TMP_ROOT/fakebin:$PATH" fm_ancestor_cwd_in_linked_worktree "$$" >/dev/null || status=$?
[ "$status" = 2 ] || fail 'ps failure not unknown'
status=0
fm_ancestor_cwd_in_linked_worktree 1 >/dev/null || status=$?
[ "$status" = 1 ] || fail 'empty ancestor chain not clean'
printf '#!/bin/sh\nprintf "1 bash\\n"\n' > "$TMP_ROOT/fakebin/ps"
printf '#!/bin/sh\nprintf "n%%s\\n" "%s"\n' "$TMP_ROOT/plain" > "$TMP_ROOT/fakebin/lsof"
status=0
PATH="$TMP_ROOT/fakebin:$PATH" fm_ancestor_cwd_in_linked_worktree "$$" >/dev/null || status=$?
[ "$status" = 1 ] || fail 'verified non-worktree ancestry not clean'
pass 'ancestor walk finds real cwd and distinguishes tool failures'
