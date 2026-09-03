import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";

// Shared wake-dispatch handshake between the Pi watcher extension (the
// dispatcher) and the supervision-branch extension (the handler), carried over
// pi.events so neither extension imports the other.
//
// Contract: the watcher builds one offer per actionable wake and emits it on
// FM_BRANCH_DISPATCH_EVENT. A live, enabled branch extension calls accept()
// SYNCHRONOUSLY inside its handler (the event bus invokes handlers
// synchronously up to their first await), so after emit returns the watcher
// reads `accepted`: true means the branch owns handling the wake, and its
// settlement promise keeps the watcher outcome pending until handling finishes
// or rejects back to the watcher's consumption-acknowledged main path; false
// means no branch took it and the watcher delivers to main exactly as it did
// before the branch existed. Watcher-failure alarms are never offered - only
// main can repair the watcher cycle (fm_watch_arm_pi lives on main).

export const FM_BRANCH_DISPATCH_EVENT = "fm-branch-supervision:dispatch";

export type UnreadWakeScopeStatus = "safe" | "empty" | "main-only" | "corrupted";

export interface UnreadWakeScope {
  status: UnreadWakeScopeStatus;
  eligible: boolean;
  projects: string[];
  eligibleSeqs: string[];
}

const EMPTY_SCOPE: UnreadWakeScope = { status: "empty", eligible: false, projects: [], eligibleSeqs: [] };
const CORRUPTED_SCOPE: UnreadWakeScope = { status: "corrupted", eligible: false, projects: [], eligibleSeqs: [] };

// A main-only, corrupted, or unresolvable row sends the whole queue to main.
export function scopeForUnreadWake(state: string, heartbeat: boolean): UnreadWakeScope {
  let queue = "";
  try {
    queue = readFileSync(`${state}/.wake-queue`, "utf8");
  } catch {
    return CORRUPTED_SCOPE;
  }

  const rows = queue.split(/\r?\n/).filter((line) => line.length > 0);
  if (rows.length === 0) return EMPTY_SCOPE;

  const projects = new Set<string>();
  const metadata = new Map<string, string>();
  try {
    for (const name of readdirSync(state)) {
      if (!name.endsWith(".meta")) continue;
      const task = name.slice(0, -5);
      const fields = readFileSync(`${state}/${name}`, "utf8").split(/\r?\n/);
      const project = fields.find((line) => line.startsWith("project="))?.slice(8) ?? "";
      const window = fields.find((line) => line.startsWith("window="))?.slice(7) ?? "";
      if (project) {
        metadata.set(task, project);
        if (window) metadata.set(window, project);
      }
    }
  } catch {
    return CORRUPTED_SCOPE;
  }

  const eligibleSeqs: string[] = [];
  for (const line of rows) {
    const fields = line.split("\t");
    if (fields.length < 5 || !/^[0-9]+$/.test(fields[1])) return CORRUPTED_SCOPE;
    const seq = fields[1];
    const kind = fields[2];
    const key = fields[3];
    if (kind === "heartbeat") {
      if (heartbeat) eligibleSeqs.push(seq);
      continue;
    }
    if (kind === "check") {
      return { status: "main-only", eligible: false, projects: [], eligibleSeqs: [] };
    }
    let project = "";
    if (kind === "signal") {
      const task = key.replace(/\.(?:status|turn-ended)$/, "");
      project = metadata.get(task) ?? "";
    } else if (kind === "stale") {
      project = metadata.get(key) ?? metadata.get(key.replace(/^fm-/, "")) ?? "";
    } else {
      // A kind fm_wake_append never emits: structural corruption, not an
      // ordinary main-only row.
      return CORRUPTED_SCOPE;
    }
    if (!project) return CORRUPTED_SCOPE;
    projects.add(project);
    eligibleSeqs.push(seq);
  }
  const eligible = eligibleSeqs.length > 0;
  return { status: eligible ? "safe" : "corrupted", eligible, projects: [...projects], eligibleSeqs };
}

// The branch-side claim record written before each prompt. Queue consumption
// remains whole-queue, so callers publish this only after full-queue approval.
export const BRANCH_ELIGIBLE_ROWS_FILE = ".branch-eligible-rows";

// Atomically publish the approved queue sequence set. A main-owned result
// means the competing main turn won the claim; error means no actor acquired
// the requested rows.
export type EligibleRowsSnapshotResult = "published" | "main-owned" | "error";

function runGrantScript(state: string, grantScript: string, args: readonly string[]): number | null {
  try {
    const result = spawnSync("bash", [grantScript, ...args], {
      encoding: "utf8",
      env: {
        ...process.env,
        FM_STATE_OVERRIDE: state,
        FM_WAKE_QUEUE: `${state}/.wake-queue`,
        FM_WAKE_QUEUE_LOCK: `${state}/.wake-queue.lock`,
      },
    });
    return result.status;
  } catch {
    return null;
  }
}

export function activateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): boolean {
  return runGrantScript(state, grantScript, ["activate", String(ownerPid), generation]) === 0;
}

export function writeEligibleRowsSnapshot(
  state: string,
  seqs: readonly string[],
  grantScript: string,
  generation: string,
): EligibleRowsSnapshotResult {
  if (seqs.length === 0 || seqs.some((seq) => !/^[0-9]+$/.test(seq))) return "error";
  const status = runGrantScript(state, grantScript, ["publish", generation, ...seqs]);
  if (status === 0) return "published";
  if (status === 3) return "main-owned";
  return "error";
}

export function releaseEligibleRowsSnapshot(state: string, grantScript: string, generation: string): boolean {
  return runGrantScript(state, grantScript, ["release", generation]) === 0;
}

export function deactivateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): boolean {
  return runGrantScript(state, grantScript, ["deactivate", String(ownerPid), generation]) === 0;
}

export interface BranchDispatchOffer {
  /** The watcher's actionable close message (the wake reason line(s)). */
  message: string;
  /**
   * Exact project values from the unread task metadata this wake will drain.
   * Empty means the wake is fleet-wide or could not be scoped safely.
   */
  projects: readonly string[];
  /** True when the watcher classified this wake as a fleet-wide heartbeat scan. */
  heartbeat: boolean;
  /** True only when at least one currently unread row is safe for branch handling. */
  eligible: boolean;
  /** Set by accept(); read by the watcher after emit returns. */
  accepted: boolean;
  settlement: Promise<void>;
  accept(settlement?: Promise<void>): void;
}

export function createBranchDispatchOffer(
  message: string,
  projects: readonly string[] = [],
  heartbeat = false,
  eligible = false,
): BranchDispatchOffer {
  const offer: BranchDispatchOffer = {
    message,
    projects: [...projects],
    heartbeat,
    eligible,
    accepted: false,
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.settlement = settlement;
    },
  };
  return offer;
}
