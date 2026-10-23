import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readGit, type GitState } from "./git.ts";
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

type GitReader = (cwd: string, now: number) => Promise<GitState | undefined>;

export class FooterSession {
  readonly state;
  private readonly rpc: RpcClient;
  private readonly ledger = new UsageLedger();
  private readonly interval: ReturnType<typeof setInterval>;
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
    private readonly getGit: GitReader = readGit,
  ) {
    const now = Date.now();

    this.state = createSnapshot(now, context.cwd);
    this.tracker = new ActivityTracker(this.state.activity);

    const start = Date.parse(
      context.sessionManager.getHeader()?.timestamp ?? "",
    );

    if (Number.isFinite(start)) this.state.startedAt = start;

    this.rpc = new RpcClient(bus);

    this.sync(context, true);

    this.interval = setInterval(() => this.tick(), 1000);

    void this.refreshGit();
    void this.refreshAgents();
  }

  dispose(): void {
    this.disposed = true;

    clearInterval(this.interval);
    this.rpc.dispose();
  }

  get alive(): boolean {
    return !this.disposed;
  }

  sync(context: FooterContext, force = false): void {
    if (this.disposed) return;

    this.context = context;
    this.state.now = Date.now();

    const provider = context.model?.provider ?? "";

    if (provider !== this.state.provider) this.state.quota = undefined;

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
    if (this.disposed) return;

    const previous = this.leaf;
    const clock = this.clockKey();

    this.sync(this.context);

    const now = this.state.now;

    if (now - this.gitAt >= 5000) void this.refreshGit();

    if (this.state.agents?.active && now - this.agentsAt >= 2000)
      void this.refreshAgents();

    if (
      clock !== this.clockKey() ||
      previous !== this.leaf ||
      this.state.activity.runningSince !== undefined
    )
      this.changed();
  }

  async refreshGit(): Promise<void> {
    if (this.disposed || this.gitPending) return;

    this.gitPending = true;
    this.gitAt = Date.now();

    const previous = this.state.git;
    const previousError = this.state.gitError;

    try {
      const git = await this.getGit(this.context.cwd, this.gitAt);

      if (this.disposed) return;

      this.state.git = git;
      this.state.gitError = undefined;

      if (this.state.pr && this.state.pr.branch !== git?.branch)
        this.state.pr = undefined;

      if (previousError || JSON.stringify(previous) !== JSON.stringify(git))
        this.changed();
    } catch (error) {
      if (this.disposed) return;

      this.state.gitError =
        text(error instanceof Error ? error.message : error) ||
        "Git probe failed";

      if (previous) this.state.git = { ...previous, stale: true };

      if (
        previousError !== this.state.gitError ||
        (previous && !previous.stale)
      )
        this.changed();
    } finally {
      this.gitPending = false;
    }
  }

  async refreshAgents(): Promise<void> {
    if (this.disposed) return;

    this.agentsAt = Date.now();

    const result = await this.rpc.request("status");

    if (this.disposed) return;

    const next = result.ok ? readAgents(result.data) : undefined;

    if (next) {
      this.state.agents = next;
      this.state.rpcErrors.status = undefined;
    } else {
      this.state.rpcErrors.status = result.ok
        ? { kind: "malformed", message: "Invalid subagent status data" }
        : result.error;

      if (this.state.agents)
        this.state.agents = { ...this.state.agents, stale: true };
    }

    this.changed();
  }

  async refreshCost(): Promise<void> {
    if (this.disposed) return;

    const result = await this.rpc.request("cost");

    if (this.disposed) return;

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
    this.state.now = Date.now();

    const warning = inactivity(this.state.activity, this.state.now);

    this.tracker.update(event, this.state.now, outcome);

    if (event !== "content" || warning !== undefined) this.changed();
  }

  tool(id: string, name?: string): void {
    this.tracker.tool(id, name, Date.now());
    this.changed();
  }
}
