#!/usr/bin/env bash
# Manual end-to-end demo of bin/fm-merge-local.sh --exact-sync against a bare remote.
set -u
ROOT=$1
DEMO_DIR=$2
rm -rf "$DEMO_DIR"; mkdir -p "$DEMO_DIR"
origin="$DEMO_DIR/origin.git"; proj="$DEMO_DIR/project"; home="$DEMO_DIR/home"; fakebin="$DEMO_DIR/fakebin"
mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
git init -q --bare "$origin"; git -C "$origin" symbolic-ref HEAD refs/heads/main
git clone -q "$origin" "$DEMO_DIR/_seed"
mkdir -p "$DEMO_DIR/_seed/.github/workflows"
cat > "$DEMO_DIR/_seed/.github/workflows/ci.yml" <<'YAML'
on:
  push:
    branches: [main, fm/merge-upstream-2]
jobs:
  lint:
    name: lint
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
printf 'disable_project_settings: true\n' > "$DEMO_DIR/_seed/.no-mistakes.yaml"
cd "$DEMO_DIR/_seed"
git add -A; git -c user.email=t@t -c user.name=t commit -q -m base
git push -q origin HEAD:main
B=$(git rev-parse HEAD)
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m upstream; U=$(git rev-parse HEAD)
git reset -q --hard "$B"
printf 'staged\n' > feature.txt; git add feature.txt
git -c user.email=t@t -c user.name=t commit -q -m stage; S=$(git rev-parse HEAD)
M=$(git commit-tree "$(git rev-parse "$S^{tree}")" -p "$B" -p "$U" -m 'merge upstream/main into main')
git push -q origin "$M":refs/heads/fm/task-demo
git push -q origin "$S":refs/heads/stage-tip
cd /; rm -rf "$DEMO_DIR/_seed"
git clone -q "$origin" "$proj"
git -C "$proj" fetch -q origin fm/task-demo stage-tip
git -C "$proj" branch --no-track fm/task-demo origin/fm/task-demo >/dev/null
git -C "$proj" remote set-head origin main >/dev/null 2>&1 || true
cat > "$home/state/task-demo.meta" <<META
window=firstmate:fm-task-demo
endpoint_task_id=task-demo
worktree=$proj
project=$proj
kind=ship
mode=local-only
META
cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  "run list"*) printf '%s\n' '[{"databaseId":9,"headSha":"$M","headBranch":"fm/merge-upstream-2","event":"push","conclusion":"success","status":"completed"}]'; exit 0 ;;
  run\ view*) printf '%s\n' '{"jobs":[{"name":"lint","conclusion":"success","status":"completed"}],"conclusion":"success","headSha":"$M","headBranch":"fm/merge-upstream-2","event":"push"}'; exit 0 ;;
esac
exit 1
SH
chmod +x "$fakebin/gh"
run() { FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" PATH="$fakebin:/usr/bin:/bin" \
  "$ROOT/bin/fm-merge-local.sh" "$@" 2>&1 | grep -v '^●' | grep -v '^warning:'; return "${PIPESTATUS[0]}"; }

echo "### pins:  B=$B  U=$U  S=$S  M=$M"
echo
echo "\$ fm-merge-local.sh task-demo --exact-sync --force --base B --upstream U --stage S"
run task-demo --exact-sync --force --base "$B" --upstream "$U" --stage "$S"; echo "exit=$?"
echo
echo "\$ fm-merge-local.sh task-demo --base B --upstream U --stage S     # dropped --exact-sync"
run task-demo --base "$B" --upstream "$U" --stage "$S"; echo "exit=$?"
echo
echo "\$ fm-merge-local.sh task-demo --exact-sync --base <WRONG-U-as-base> --upstream U --stage S"
run task-demo --exact-sync --base "$U" --upstream "$U" --stage "$S"; echo "exit=$?"
echo
echo "\$ fm-merge-local.sh task-demo --exact-sync --base B --upstream U --stage S --remote origin --branch main"
run task-demo --exact-sync --base "$B" --upstream "$U" --stage "$S" --remote origin --branch main; echo "exit=$?"
echo
echo "\$ git -C origin.git log --oneline -1 main ; parents of main"
git -C "$origin" log --format='%h %s' -1 main
echo "main == M : $([ "$(git -C "$origin" rev-parse main)" = "$M" ] && echo yes || echo no)"
echo "parents   : $(git -C "$origin" rev-parse main^1) $(git -C "$origin" rev-parse main^2)"
echo "tree(main) == tree(S) : $([ "$(git -C "$origin" rev-parse main^{tree})" = "$(git -C "$proj" rev-parse "$S^{tree}")" ] && echo yes || echo no)"
echo
echo "\$ fm-merge-local.sh task-demo --exact-sync ...   # idempotent re-run"
run task-demo --exact-sync --base "$B" --upstream "$U" --stage "$S"; echo "exit=$?"
echo
echo "### recorded sync outcome (fm-merge-outcome-lib.sh):"
echo "--- state/.wake-queue"; cat "$home/state/.wake-queue"
echo "--- state/task-demo.pr-poll-merge-notified (dedup identity)"; cat "$home/state/task-demo.pr-poll-merge-notified"
