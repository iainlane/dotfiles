import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { FooterRuntime } from "./runtime.ts";
import { RpcClient, type FooterBus } from "./rpc.ts";
import { createSnapshot } from "./state.ts";
import { UsageLedger } from "./usage.ts";
import { readAgents, readTasks } from "./workflow.ts";
import { ActivityTracker, inactivity, type ActivityEvent } from "./activity.ts";
import { quotaWindows } from "./quota.ts";
import { duration, text } from "./text.ts";

export interface FooterContext {
  cwd: string;
  model: { id: string; provider: string; contextWindow: number } | undefined;
  thinkingLevel?: string;
  getContextUsage: ExtensionContext["getContextUsage"];
  hasPendingMessages: ExtensionContext["hasPendingMessages"];
  sessionManager: {
    getHeader(): { timestamp: string } | null;
    getEntries(): readonly unknown[];
    getBranch(): readonly unknown[];
    getLeafId(): string | null;
  };
}

export class FooterSession {
  readonly state;
  private readonly rpc: RpcClient;
  private readonly ledger = new UsageLedger();
  private readonly stopClock: () => void;
  private disposed = false;
  private gitPending = false;
  private gitAt = -Infinity;
  private agentsAt = -Infinity;
  private leaf: string | null | undefined;
  private readonly tracker: ActivityTracker;

  constructor(
    private context: FooterContext,
    bus: FooterBus,
    private readonly changed: () => void,
    private readonly runtime: FooterRuntime,
  ) {
    const now = this.runtime.clock.now();

    this.state = createSnapshot(now, context.cwd);
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

    this.refreshGit().catch(this.runtime.reportError);
    this.refreshAgents().catch(this.runtime.reportError);
  }

  dispose(): void {
    this.disposed = true;

    this.stopClock();
    this.rpc.dispose();
  }

  get alive(): boolean {
    return !this.disposed;
  }

  sync(context: FooterContext, force = false): void {
    if (this.disposed) {
      return;
    }

    this.context = context;
    this.state.now = this.runtime.clock.now();

    const provider = context.model?.provider ?? "";

    if (provider !== this.state.provider) {
      this.state.quota = undefined;
    }

    this.state.model = context.model?.id ?? "no model";
    this.state.provider = provider;
    this.state.thinking = context.thinkingLevel ?? "";

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
      this.state.auxiliaryUsage = { ...this.ledger.auxiliary };
      this.state.tasks = readTasks(branch);
    }
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

    const previous = this.leaf;
    const clock = this.clockKey();

    this.sync(this.context);

    const now = this.state.now;

    if (now - this.gitAt >= 5000) {
      this.refreshGit().catch(this.runtime.reportError);
    }

    if (
      this.state.agents?.active !== undefined &&
      this.state.agents?.active !== 0 &&
      now - this.agentsAt >= 2000
    ) {
      this.refreshAgents().catch(this.runtime.reportError);
    }

    if (
      clock !== this.clockKey() ||
      previous !== this.leaf ||
      this.state.activity.runningSince !== undefined
    ) {
      this.changed();
    }
  }

  async refreshGit(): Promise<void> {
    if (this.disposed || this.gitPending) {
      return;
    }

    this.gitPending = true;
    this.gitAt = this.runtime.clock.now();

    const previous = this.state.git;
    const previousError = this.state.gitError;

    try {
      const git = await this.runtime.readGit(this.context.cwd, this.gitAt);

      if (this.disposed) {
        return;
      }

      this.state.git = git;
      this.state.gitError = undefined;

      if (this.state.pr && this.state.pr.branch !== git?.branch) {
        this.state.pr = undefined;
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
    } finally {
      this.gitPending = false;
    }
  }

  async refreshAgents(): Promise<void> {
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

  async refreshCost(): Promise<void> {
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
