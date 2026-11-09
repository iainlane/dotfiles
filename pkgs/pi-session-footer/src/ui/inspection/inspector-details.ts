import type { FooterSnapshot } from "#footer/domain/state.ts";
import { duration, text } from "#footer/shared/text.ts";
import { quotaWindows, type QuotaView } from "#footer/domain/quota.ts";
import { taskSummary } from "#footer/domain/workflow.ts";
import type { StatusSnapshot } from "#footer/domain/status.ts";

function statusDescription(status: StatusSnapshot): string {
  if (!status.active) {
    return "inactive";
  }
  return status.text !== undefined && status.text !== ""
    ? status.text
    : "active";
}

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
  if (window.reset !== undefined && window.reset !== "") {
    parts.push(`resets in ${window.reset}`);
  }
  if (window.pace === undefined) {
    return [...parts, "pace unavailable"].join(" · ");
  }
  const direction = window.pace >= 0 ? "ahead of" : "behind";
  return [
    ...parts,
    `${Math.abs(window.pace)} percentage points ${direction} linear pace`,
  ].join(" · ");
}
function prLines(state: FooterSnapshot["pr"]): string[] {
  const pr = state?.pullRequest;
  if (!pr) {
    return [];
  }
  return [
    `PR #${pr.target.number}: ${text(pr.target.url, 500)}`,
    `Merge: ${pr.mergeState} · ${pr.lifecycle}${pr.isDraft ? " · draft" : ""}`,
    `Review threads: ${pr.unresolvedThreadCount} unresolved`,
    `CI: ${pr.ci?.state ?? "unknown"} · ${pr.ci?.failedCount ?? "?"} failures`,
    ...(pr.ci?.url !== undefined && pr.ci.url !== ""
      ? [text(pr.ci.url, 500)]
      : []),
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
  if (section === "quota") {
    return [
      "Quota percentages are used, not remaining.",
      `Provider: ${state.quota?.provider ?? "unavailable"}`,
      `Account identity: ${state.quota?.account ?? "unavailable"} (account of the reading; runtime identity is not verified)`,
      `Credential source: ${state.quota?.source ?? "unavailable"}`,
      `Last successful fetch: ${state.quota?.lastSuccessAt !== undefined && state.quota.lastSuccessAt !== 0 ? new Date(state.quota.lastSuccessAt).toISOString() : "unavailable"}`,
      `Last error: ${state.quota?.error ?? "none reported"}`,
      ...quotaWindows(state.quota, state.now).map((window) =>
        quotaLine(window),
      ),
      "Pace compares quota consumed with the elapsed fraction of a reported-duration window. It is a heuristic, not a forecast.",
      "Cached readings become stale after 30 seconds; percentages expire after five minutes or the quota reset.",
    ];
  }
  if (section === "workflow") {
    const summary = taskSummary(state.tasks);
    const planning = state.cooperativeStatuses.get("planning");
    let reporting = "unavailable";
    if (state.agents) {
      reporting = state.agents.stale ? "stale" : "available";
    }
    return [
      `Tasks: ${summary.completed}/${summary.total} completed · ${summary.running} running · ${summary.blocked} dependency-blocked`,
      ...state.tasks.flatMap((task) => {
        if (task.status === "deleted") {
          return [];
        }
        return [
          `#${task.id} [${task.status}] ${task.activeForm ?? task.subject}${task.blockedBy.length > 0 ? ` (dependencies: ${task.blockedBy.join(", ")})` : ""}`,
        ];
      }),
      `Subagent reporting: ${reporting}`,
      `Subagent last error: ${rpcError(state, "status")}`,
      `Active children: ${state.agents?.active ?? "unknown"}${state.agents?.incomplete === true ? " · run details incomplete" : ""}`,
      ...(state.agents?.runs.map((run) => `[${run.state}] ${run.label}`) ?? []),
      `Pending native messages: ${state.pending ? "yes" : "no"} (queue size unavailable)`,
      `Plan: ${planning ? statusDescription(planning) : text(state.statuses.get("planning")) || "not active"}`,
      "Use /todos and /subagents for their native views and controls.",
    ];
  }
  if (section === "diagnostics") {
    const summary = state.diagnostics.summary();
    return [
      `Coverage: ${summary.observed ? "received events only; not a workspace-wide verdict" : "unknown"}`,
      `Received findings: ${summary.errors} errors, ${summary.warnings} warnings, ${summary.pending} files pending${summary.truncated ? " · counts are lower bounds" : ""}`,
      ...[...state.diagnostics.files].flatMap(([path, file]) =>
        [`${text(path, 400)}${file.pending ? " (provisional)" : ""}`].concat(
          file.messages,
        ),
      ),
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
    if (git) {
      gitFreshness = git.stale ? "stale" : "fresh";
    }
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
    const auxiliary = state.auxiliaryUsage;
    const prompt = u.input + u.cacheRead + u.cacheWrite;
    const sessionScope =
      "includes abandoned branches, reported tool usage, summaries and cache warming";
    return [
      u.costFromProvider
        ? `Whole-session billed total reported by the provider: $${u.cost.toFixed(4)} (${sessionScope})`
        : `Whole-session recorded estimate: $${u.cost.toFixed(4)} (${sessionScope}; not a verified invoice)`,
      `Auxiliary ${auxiliary.costFromProvider ? "billed total reported by the provider" : "recorded estimate"} (separate from session cost): $${auxiliary.cost.toFixed(4)}`,
      `Auxiliary tokens: input ${auxiliary.input}, output ${auxiliary.output}, cache read ${auxiliary.cacheRead}, cache write ${auxiliary.cacheWrite}`,
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
      "Delegation report (separate scope; not added to session cost; safe raw JSON, capped at 2000 columns and 4096 source characters; ellipsis indicates truncation):",
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
    ...[...state.cooperativeStatuses].map(
      ([source, status]) => `${source}: ${statusDescription(status)}`,
    ),
    ...[...state.statuses].flatMap(([key, value]) =>
      state.cooperativeStatuses.has(key)
        ? []
        : [`${text(key)}: ${text(value, 500)}`],
    ),
    "Select a section for source, scope, freshness and complete details.",
  ];
}
