import type { ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import {
  Key,
  matchesKey,
  truncateToWidth,
  wrapTextWithAnsi,
} from "@earendil-works/pi-tui";
import type { FooterSnapshot } from "./state.ts";
import { duration, text } from "./text.ts";
import { quotaWindows, type QuotaView } from "./quota.ts";
import { taskSummary } from "./workflow.ts";

export const SECTIONS = [
  "overview",
  "quota",
  "workflow",
  "diagnostics",
  "git",
  "usage",
] as const;

export type Section = (typeof SECTIONS)[number];

function quotaLine(window: QuotaView): string {
  const used =
    window.used === undefined ? "unknown" : `${window.used.toFixed(1)}% used`;
  const parts = [`${window.label}: ${used}`, window.freshness];

  if (window.reset) parts.push(`resets in ${window.reset}`);

  if (window.pace === undefined)
    return [...parts, "pace unavailable"].join(" · ");

  const direction = window.pace >= 0 ? "ahead of" : "behind";

  return [
    ...parts,
    `${Math.abs(window.pace)} percentage points ${direction} linear pace`,
  ].join(" · ");
}

function prLines(state: FooterSnapshot["pr"]): string[] {
  const pr = state?.pullRequest;

  if (!pr) return [];

  return [
    `PR #${pr.target.number}: ${text(pr.target.url, 500)}`,
    `Merge: ${pr.mergeState} · ${pr.lifecycle}${pr.isDraft ? " · draft" : ""}`,
    `Review threads: ${pr.unresolvedThreadCount} unresolved`,
    `CI: ${pr.ci?.state ?? "unknown"} · ${pr.ci?.failedCount ?? "?"} failures`,
    ...(pr.ci?.url ? [text(pr.ci.url, 500)] : []),
    `Watching: ${pr.watching ? "enabled by user" : "off"}`,
  ];
}

function rpcError(state: FooterSnapshot, method: "status" | "cost"): string {
  const error = state.rpcErrors[method];

  return error ? `${error.kind}: ${text(error.message, 240)}` : "none reported";
}

export function detailsLines(
  state: FooterSnapshot,
  section: Section,
): string[] {
  if (section === "quota")
    return [
      "Quota percentages are used, not remaining.",
      `Provider: ${state.quota?.provider ?? "unavailable"}`,
      `Account identity: ${state.quota?.account ?? "unavailable"} (account of the reading; runtime identity is not verified)`,
      `Credential source: ${state.quota?.source ?? "unavailable"}`,
      `Last successful fetch: ${state.quota?.lastSuccessAt ? new Date(state.quota.lastSuccessAt).toISOString() : "unavailable"}`,
      `Last error: ${state.quota?.error ?? "none reported"}`,
      ...quotaWindows(state.quota, state.now).map(quotaLine),
      "Pace compares quota consumed with the elapsed fraction of a reported-duration window. It is a heuristic, not a forecast.",
      "Cached readings become stale after 30 seconds; percentages expire after five minutes or the quota reset.",
    ];

  if (section === "workflow") {
    const summary = taskSummary(state.tasks);
    let reporting = "unavailable";

    if (state.agents) reporting = state.agents.stale ? "stale" : "available";

    return [
      `Tasks: ${summary.completed}/${summary.total} completed · ${summary.running} running · ${summary.blocked} dependency-blocked`,
      ...state.tasks.flatMap((task) => {
        if (task.status === "deleted") return [];

        return [
          `#${task.id} [${task.status}] ${task.activeForm ?? task.subject}${task.blockedBy.length ? ` (dependencies: ${task.blockedBy.join(", ")})` : ""}`,
        ];
      }),
      `Subagent reporting: ${reporting}`,
      `Subagent last error: ${rpcError(state, "status")}`,
      `Active children: ${state.agents?.active ?? "unknown"}${state.agents?.incomplete ? " · run details incomplete" : ""}`,
      ...(state.agents?.runs.map((run) => `[${run.state}] ${run.label}`) ?? []),
      `Pending native messages: ${state.pending ? "yes" : "no"} (queue size unavailable)`,
      `Plan: ${text(state.statuses.get("plan-mode")) || "not active"}`,
      "Use /todos and /subagents for their native views and controls.",
    ];
  }

  if (section === "diagnostics") {
    const summary = state.diagnostics.summary();

    return [
      `Coverage: ${summary.observed ? "received events only; not a workspace-wide verdict" : "unknown"}`,
      `Received findings: ${summary.errors} errors, ${summary.warnings} warnings, ${summary.pending} files pending${summary.truncated ? " · counts are lower bounds" : ""}`,
      ...[...state.diagnostics.files].flatMap(([path, file]) => [
        `${text(path, 400)}${file.pending ? " (provisional)" : ""}`,
        ...file.messages,
      ]),
      ...[...state.statuses].flatMap(([key, value]) =>
        /lsp|mcp/i.test(key) ? [`${text(key)}: ${text(value, 400)}`] : [],
      ),
      "Missing diagnostics or MCP inventory does not establish clean files or healthy servers.",
      "Use /lens-widget-toggle to show pi-lens's native diagnostic widget.",
    ];
  }

  if (section === "git") {
    const git = state.git;
    const pr = state.pr;
    let gitFreshness = "unavailable";

    if (git) gitFreshness = git.stale ? "stale" : "fresh";

    return [
      `Repository: ${git?.root ?? "unavailable"}`,
      `Worktree: ${git?.worktree ?? "main or unavailable"}`,
      `Branch: ${git?.branch ?? "unavailable"}`,
      `Operation: ${git?.operation ?? "none reported"}`,
      `Paths: staged ${git?.staged ?? "?"}, modified ${git?.unstaged ?? "?"}, untracked ${git?.untracked ?? "?"}, conflicts ${git?.conflicts ?? "?"}`,
      `Upstream: ahead ${git?.ahead ?? "?"}, behind ${git?.behind ?? "?"} (last fetched state)`,
      `Git data: ${gitFreshness}`,
      `Git last error: ${state.gitError ?? "none reported"}`,
      `GitHub data: ${pr?.health ?? "unavailable"}`,
      `GitHub last update: ${pr ? new Date(pr.updatedAt).toISOString() : "unavailable"}`,
      ...prLines(pr),
      "PR integration is passive by default. Missing authentication and unsuccessful reads are not successful checks.",
    ];
  }

  if (section === "usage") {
    const u = state.usage;
    const prompt = u.input + u.cacheRead + u.cacheWrite;

    return [
      `Whole-session recorded estimate: $${u.cost.toFixed(4)} (includes abandoned branches, reported tool usage, summaries and cache warming; not a verified invoice)`,
      `Tokens: input ${u.input}, output ${u.output}, cache read ${u.cacheRead}, cache write ${u.cacheWrite}`,
      `Latest active-branch request cache hit rate: ${u.latestHit === undefined ? "unknown" : `${u.latestHit.toFixed(1)}%`}`,
      `Whole-session cache hit rate: ${prompt ? `${((u.cacheRead / prompt) * 100).toFixed(1)}%` : "unknown"}`,
      `Live session age: ${duration(state.now - state.startedAt)}`,
      `Current run duration: ${state.activity.runningSince === undefined ? "not running" : duration(state.now - state.activity.runningSince)}`,
      `Observed active-work time: ${duration(state.activity.activeMs + (state.activity.activeSince === undefined ? 0 : state.now - state.activity.activeSince))} (observed since ${new Date(state.activity.observedSince).toISOString()})`,
      `Current tool: ${state.activity.tool ?? "none"}`,
      `Compaction duration: ${state.activity.compactingSince === undefined ? "not compacting" : duration(state.now - state.activity.compactingSince)}`,
      "Cache hit rate is not an estimate of invoice savings.",
      `Delegation last error: ${rpcError(state, "cost")}`,
      "Delegation report (separate scope; not added to session cost):",
      state.delegationCost === undefined
        ? "unavailable"
        : text(JSON.stringify(state.delegationCost), 2000),
    ];
  }

  return [
    `Model: ${state.provider}/${state.model} · thinking ${state.thinking || "off"}`,
    `Directory: ${text(state.cwd, 500)}`,
    `Context: ${state.context.percent === null ? "unknown" : `${state.context.percent.toFixed(1)}% used`} · ${state.context.tokens ?? "unknown"}/${state.context.capacity || "unknown"} tokens`,
    `Service tier: ${state.serviceTier ?? "unavailable"}`,
    ...[...state.statuses].map(
      ([key, value]) => `${text(key)}: ${text(value, 500)}`,
    ),
    "Select a section for source, scope, freshness and complete details.",
  ];
}

export class Inspector {
  private close: (() => void) | undefined;
  private generation = 0;

  constructor(private readonly snapshot: () => FooterSnapshot | undefined) {}

  dispose(): void {
    this.generation++;

    const close = this.close;

    this.close = undefined;
    close?.();
  }

  async open(ctx: ExtensionCommandContext, section?: Section): Promise<void> {
    if (ctx.mode !== "tui") {
      ctx.ui.notify("The footer inspector is available in TUI mode.", "info");

      return;
    }

    this.dispose();

    const generation = this.generation;
    const selected =
      section ?? (await ctx.ui.select("Footer details", [...SECTIONS]));
    const choice = SECTIONS.find((candidate) => candidate === selected);

    if (!choice || generation !== this.generation || !this.snapshot()) return;

    await ctx.ui.custom<void>(
      (tui, theme, _keys, done) => {
        let offset = 0;

        const close = () => done();

        this.close = close;

        return {
          render: (width: number) => {
            const state = this.snapshot();

            if (!state) return [];

            const lines = detailsLines(state, choice).flatMap((line) =>
              wrapTextWithAnsi(text(line, 4096), Math.max(1, width)),
            );
            const height = Math.max(1, tui.terminal.rows - 4);

            offset = Math.min(offset, Math.max(0, lines.length - height));

            return [
              truncateToWidth(
                theme.fg("accent", `Footer: ${choice}`),
                width,
                "",
              ),
              ...lines.slice(offset, offset + height),
              truncateToWidth(
                theme.fg("dim", "↑/↓ scroll · PgUp/PgDn page · Esc close"),
                width,
                "",
              ),
            ];
          },
          invalidate() {},
          handleInput: (data: string) => {
            if (matchesKey(data, Key.escape)) {
              done();

              return;
            }

            if (matchesKey(data, Key.up)) offset = Math.max(0, offset - 1);

            if (matchesKey(data, Key.down)) offset++;

            if (matchesKey(data, Key.pageUp)) offset = Math.max(0, offset - 10);

            if (matchesKey(data, Key.pageDown)) offset += 10;

            tui.requestRender();
          },
          dispose: () => {
            if (this.close === close) this.close = undefined;
          },
        };
      },
      {
        overlay: true,
        overlayOptions: { anchor: "top-center", width: "100%" },
      },
    );
  }
}
