#!/usr/bin/env bash
set -u
W=$1; T=$(mktemp -d /tmp/fm-stale-slot.XXXX); repo=$T/root; home=$T/home; log=$T/arm.log
mkdir -p $repo/bin $home/state $home/config && git init -q $repo && : > $repo/AGENTS.md && : > $home/state/task.meta
cat > $repo/bin/fm-watch-arm.sh <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"; exit 0; fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then printf 'watcher: started pid=%s (beacon fresh)\n' "$$"; printf 'signal: first wake\n'; exit 0; fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
if [ "$count" -eq 2 ]; then trap 'exit 0' TERM INT; while [ ! -e "$FM_DIE_FILE_1" ]; do sleep 0.02; done; printf 'signal: STALE mid-delivery close\n'; exit 0; fi
if [ "$count" -eq 3 ]; then trap 'exit 0' TERM INT; while [ ! -e "$FM_DIE_FILE_2" ]; do sleep 0.02; done; printf 'signal: LATER unrelated close\n'; exit 0; fi
trap 'exit 0' TERM INT; while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
chmod +x $repo/bin/fm-watch-arm.sh
PLUGIN=$W/.opencode/plugins/fm-primary-watch-arm.js WORKTREE=$repo FM_HOME=$home FM_ARM_LOG=$log FM_STOP_FILE=$T/stop FM_DIE_FILE_1=$T/die1 FM_DIE_FILE_2=$T/die2 NODE_NO_WARNINGS=1 timeout 60 node --input-type=module <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
let rejectPrompt = () => {};
const blocked = new Promise((_, reject) => { rejectPrompt = reject; });
const client = { session: { promptAsync: async (payload) => { prompts.push(JSON.stringify(payload?.body?.parts ?? payload)); if (prompts.length === 1) await blocked; } } };
const rows = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG,"utf8").split("\n").filter(r=>r.startsWith("arm=")) : [];
async function waitFor(p, m){ for(let i=0;i<500;i++){ if(p()) return; await new Promise(r=>setTimeout(r,10)); } throw new Error(m); }
const hooks = await mod.FmPrimaryWatchArm({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s" } } });
await waitFor(() => rows().length >= 2 && prompts.length >= 1, "first delivery did not begin");
writeFileSync(process.env.FM_DIE_FILE_1, "x");
await waitFor(() => rows().length >= 3, "third arm did not start during blocked delivery");
rejectPrompt(new Error("synthetic promptAsync failure"));
await new Promise(r => setTimeout(r, 300));
writeFileSync(process.env.FM_DIE_FILE_2, "x");
await waitFor(() => rows().length >= 4 && prompts.length >= 3, "later close did not deliver");
await new Promise(r => setTimeout(r, 500));
const stale = prompts.filter(p => p.includes("STALE")).length, later = prompts.filter(p => p.includes("LATER")).length, failed = prompts.filter(p => /synthetic promptAsync failure/.test(p)).length;
console.log(`prompts=${prompts.length} STALE replays=${stale} LATER deliveries=${later} surfaced failures=${failed}`);
writeFileSync(process.env.FM_STOP_FILE, "x");
if (prompts.length !== 3 || stale !== 0 || later !== 1 || failed !== 1) { console.log("RESULT: FAIL - stale mid-delivery reason replayed or delivery miscount"); process.exit(1); }
console.log("RESULT: PASS - stale slot cleared on delivery error, no replay"); process.exit(0);
EOF
rc=$?; rm -rf $T; echo "exit=$rc"
