import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { FooterRuntime } from "./runtime.ts";
import { RpcClient, type FooterBus } from "#footer/integrations/rpc.ts";
import { createSnapshot, type FooterSnapshot } from "#footer/domain/state.ts";
import { UsageLedger } from "#footer/domain/usage.ts";
import { readAgents, readTasks } from "#footer/domain/workflow.ts";
import {
  ActivityTracker,
  inactivity,
  type ActivityEvent,
} from "#footer/domain/activity.ts";
import { quotaWindows } from "#footer/domain/quota.ts";
import { duration, text } from "#footer/shared/text.ts";
import { readStatus } from "#footer/domain/status.ts";

export interface FooterContext {
  cwd: string;
  model:
    | {
        id: string;
        provider: string;
        contextWindow: number;
        reasoning?: boolean;
      }
    | undefined;
  thinkingLevel?: string;
  getContextUsage: ExtensionContext["getContextUsage"];
  hasPendingMessages: ExtensionContext["hasPendingMessages"];
  sessionManager: {
    getSessionId?(): string;
    getHeader(): { timestamp: string } | null;
    getEntries(): readonly unknown[];
    getBranch(): readonly unknown[];
    getLeafId(): string | null;
  };
}

const GIT_INTERVAL = 5000;
const GIT_MAX_INTERVAL = 60_000;

export class FooterSession {
  readonly state;
  private context: FooterContext;
  private readonly changed: () => void;
  private readonly runtime: FooterRuntime;
  private readonly rpc: RpcClient;
  private readonly ledger = new UsageLedger();
  private readonly stopClock: () => void;
  private disposed = false;
  private gitPending = false;
  private gitRerun = false;
  private gitFailures = 0;
  private gitAt = -Infinity;
  private pr: FooterSnapshot["pr"];
  private agentsAt = -Infinity;
  private leaf: string | null | undefined;
  private readonly tracker: ActivityTracker;

  constructor(
    context: FooterContext,
    bus: FooterBus,
    changed: () => void,
    runtime: FooterRuntime,
  ) {
    this.context = context;
    this.changed = changed;
    this.runtime = runtime;

    const now = this.runtime.clock.now();

    this.state = createSnapshot(now, context.cwd);
    this.state.sessionId = context.sessionManager.getSessionId?.();
    this.tracker = new ActivityTracker(this.state.activity);

    const start = Date.parse(
      context.sessionManager.getHeader()?.timestamp ?? "",
    );

    if (Number.isFinite(start)) {
      this.state.startedAt = start;
    }

    this.rpc = new RpcClient(bus, runtime);

    this.sync(context, true);

    this.stopClock = runtime.clock.every(1000, () => {
      this.tick();
    });

    void this.refreshGit();
    void this.refreshAgents();
  }

  dispose(): void {
    this.disposed = true;

    this.stopClock();
    this.rpc.dispose();
    this.state.cooperativeStatuses = new Map();
  }

  receiveStatus(raw: unknown): boolean {
    const status = readStatus(raw);
    if (this.disposed || !status || status.sessionId !== this.state.sessionId) {
      return false;
    }
    this.state.cooperativeStatuses = new Map([
      ...this.state.cooperativeStatuses,
      [status.source, status],
    ]);
    return true;
  }

  receivePr(pr: FooterSnapshot["pr"]): boolean {
    if (this.disposed) {
      return false;
    }
    this.pr = pr;
    if (this.state.git && pr?.branch !== this.state.git.branch) {
      return false;
    }
    this.state.pr = pr;
    return true;
  }

  get alive(): boolean {
    return !this.disposed;
  }

  sync(context: FooterContext, force = false): boolean {
    if (this.disposed) {
      return false;
    }

    const displayed = this.displayed();
    this.context = context;
    this.state.now = this.runtime.clock.now();

    const provider = context.model?.provider ?? "";

    if (provider !== this.state.provider) {
      this.state.quota = undefined;
    }

    this.state.model = context.model?.id ?? "no model";
    this.state.provider = provider;
    this.state.thinking = context.thinkingLevel ?? "";
    this.state.reasoning = context.model?.reasoning === true;

    const usage = context.getContextUsage();

    this.state.context = {
      tokens: usage?.tokens ?? null,
      capacity: usage?.contextWindow ?? context.model?.contextWindow ?? 0,
      percent: usage?.percent ?? null,
    };
    this.state.pending = context.hasPendingMessages();

    const leaf = context.sessionManager.getLeafId();

    if (force || this.leaf !== leaf) {
      this.leaf = leaf;

      const branch = context.sessionManager.getBranch();

      this.ledger.update(context.sessionManager.getEntries(), branch);

      this.state.usage = { ...this.ledger.totals };
      this.state.cachePrompt = this.ledger.latestPrompt;
      this.state.auxiliaryUsage = { ...this.ledger.auxiliary };
      this.state.tasks = readTasks(branch);

      return true;
    }

    return displayed !== this.displayed();
  }

  private displayed(): string {
    const { model, provider, thinking, reasoning, context, pending } =
      this.state;

    return JSON.stringify([
      model,
      provider,
      thinking,
      reasoning,
      context,
      pending,
    ]);
  }

  private clockKey(): string {
    const { now, startedAt, activity, quota } = this.state;

    return JSON.stringify([
      duration(now - startedAt),
      duration(
        activity.activeMs +
          (activity.activeSince === undefined ? 0 : now - activity.activeSince),
      ),
      activity.runningSince === undefined
        ? undefined
        : duration(now - activity.runningSince),
      activity.compactingSince === undefined
        ? undefined
        : duration(now - activity.compactingSince),
      inactivity(activity, now),
      quotaWindows(quota, now).map(({ freshness, reset, pace }) => [
        freshness,
        reset,
        pace,
      ]),
    ]);
  }

  private tick(): void {
    if (this.disposed) {
      return;
    }

    const clock = this.clockKey();
    const displayed = this.sync(this.context);
    const now = this.state.now;

    if (!this.gitPending && now - this.gitAt >= this.gitInterval()) {
      void this.refreshGit();
    }

    if (
      this.state.agents?.active !== undefined &&
      this.state.agents?.active !== 0 &&
      now - this.agentsAt >= 2000
    ) {
      void this.refreshAgents();
    }

    if (
      displayed ||
      clock !== this.clockKey() ||
      this.state.activity.runningSince !== undefined
    ) {
      this.changed();
    }
  }

  async refreshGit(): Promise<void> {
    try {
      await this.updateGit();
    } catch (error) {
      this.runtime.reportError(error);
    }
  }

  async refreshAgents(): Promise<void> {
    try {
      await this.updateAgents();
    } catch (error) {
      this.runtime.reportError(error);
    }
  }

  async refreshCost(): Promise<void> {
    try {
      await this.updateCost();
    } catch (error) {
      this.runtime.reportError(error);
    }
  }

  private gitInterval(): number {
    return Math.min(GIT_INTERVAL * 2 ** this.gitFailures, GIT_MAX_INTERVAL);
  }

  private async updateGit(): Promise<void> {
    if (this.disposed) {
      return;
    }

    if (this.gitPending) {
      this.gitRerun = true;
      return;
    }

    this.gitPending = true;

    try {
      await this.probeGit();
    } finally {
      this.gitPending = false;
      this.gitAt = this.runtime.clock.now();
    }

    if (this.gitRerun) {
      this.gitRerun = false;
      await this.updateGit();
    }
  }

  private async probeGit(): Promise<void> {
    const previous = this.state.git;
    const previousError = this.state.gitError;

    try {
      const git = await this.runtime.readGit(
        this.context.cwd,
        this.runtime.clock.now(),
      );

      if (this.disposed) {
        return;
      }

      this.gitFailures = 0;
      this.state.git = git;
      this.state.gitError = undefined;

      if (this.state.pr?.branch !== git?.branch) {
        this.state.pr = this.pr?.branch === git?.branch ? this.pr : undefined;
      }

      if (
        (previousError !== undefined && previousError !== "") ||
        JSON.stringify(previous) !== JSON.stringify(git)
      ) {
        this.changed();
      }
    } catch (error) {
      if (this.disposed) {
        return;
      }

      this.gitFailures++;
      this.state.gitError =
        text(error instanceof Error ? error.message : error) ||
        "Git probe failed";

      if (previous) {
        this.state.git = { ...previous, stale: true };
      }

      if (
        previousError !== this.state.gitError ||
        (previous && !previous.stale)
      ) {
        this.changed();
      }
    }
  }

  private async updateAgents(): Promise<void> {
    if (this.disposed) {
      return;
    }

    this.agentsAt = this.runtime.clock.now();

    const result = await this.rpc.request("status");

    if (this.disposed) {
      return;
    }

    const next = result.ok ? readAgents(result.data) : undefined;

    if (next) {
      this.state.agents = next;
      this.state.rpcErrors.status = undefined;
    } else {
      this.state.rpcErrors.status = result.ok
        ? { kind: "malformed", message: "Invalid subagent status data" }
        : result.error;

      if (this.state.agents) {
        this.state.agents = { ...this.state.agents, stale: true };
      }
    }

    this.changed();
  }

  private async updateCost(): Promise<void> {
    if (this.disposed) {
      return;
    }

    const result = await this.rpc.request("cost");

    if (this.disposed) {
      return;
    }

    if (result.ok && result.data !== undefined) {
      this.state.delegationCost = result.data;
      this.state.rpcErrors.cost = undefined;
    } else {
      this.state.rpcErrors.cost = result.ok
        ? { kind: "malformed", message: "Missing delegation cost data" }
        : result.error;
    }

    this.changed();
  }

  activity(event: ActivityEvent, outcome?: string): void {
    this.state.now = this.runtime.clock.now();

    const warning = inactivity(this.state.activity, this.state.now);

    this.tracker.update(event, this.state.now, outcome);

    if (event !== "content" || warning !== undefined) {
      this.changed();
    }
  }

  tool(id: string, name?: string): void {
    this.tracker.tool(id, name, this.runtime.clock.now());
    this.changed();
  }
}
