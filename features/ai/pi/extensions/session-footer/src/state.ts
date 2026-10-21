import type { PullRequestStateEvent } from "pi-prs/api";
import { Diagnostics } from "./diagnostics.ts";
import type { QuotaState } from "./quota.ts";
import type { AgentSummary, Task } from "./workflow.ts";
import type { GitState } from "./git.ts";
import type { RpcFailure } from "./rpc.ts";

export interface UsageTotals {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  latestHit: number | undefined;
}

export interface Activity {
  runningSince: number | undefined;
  activeMs: number;
  observedSince: number;
  lastContentAt: number;
  waiting: boolean;
  compacting: boolean;
  activeSince: number | undefined;
  tool: string | undefined;
  compactingSince: number | undefined;
  outcome: string | undefined;
}

export interface FooterSnapshot {
  now: number;
  startedAt: number;
  cwd: string;
  model: string;
  provider: string;
  thinking: string;
  context: { tokens: number | null; capacity: number; percent: number | null };
  quota: QuotaState | undefined;
  serviceTier: string | undefined;
  tasks: Task[];
  agents: AgentSummary | undefined;
  delegationCost: unknown;
  pending: boolean;
  diagnostics: Diagnostics;
  git: GitState | undefined;
  gitError: string | undefined;
  rpcErrors: Record<"status" | "cost", RpcFailure | undefined>;
  pr: PullRequestStateEvent | undefined;
  statuses: ReadonlyMap<string, string>;
  usage: UsageTotals;
  activity: Activity;
}

export function createSnapshot(now: number, cwd: string): FooterSnapshot {
  return {
    now,
    startedAt: now,
    cwd,
    model: "no model",
    provider: "",
    thinking: "",
    context: { tokens: null, capacity: 0, percent: null },
    quota: undefined,
    serviceTier: undefined,
    tasks: [],
    agents: undefined,
    delegationCost: undefined,
    pending: false,
    diagnostics: new Diagnostics(cwd),
    git: undefined,
    gitError: undefined,
    rpcErrors: { status: undefined, cost: undefined },
    pr: undefined,
    statuses: new Map(),
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      cost: 0,
      latestHit: undefined,
    },
    activity: {
      runningSince: undefined,
      activeSince: undefined,
      activeMs: 0,
      observedSince: now,
      lastContentAt: now,
      waiting: false,
      compacting: false,
      compactingSince: undefined,
      tool: undefined,
      outcome: undefined,
    },
  };
}
