import { detailsLines } from "./inspector-details.ts";
import {
  detailRow,
  paragraphs,
  sectionsRow,
  SECTION_LABELS,
  type InspectionContent,
  type InspectionNavigation,
  type InspectionPage,
  type InspectionRow,
  type InspectionText,
  type Section,
} from "./inspection-page.ts";
import { quotaWindows } from "#footer/domain/quota.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";
import { duration, text, tokens } from "#footer/shared/text.ts";
import { taskSummary } from "#footer/domain/workflow.ts";
import { usageContent } from "./usage-pages.ts";

function elapsed(milliseconds: number): string {
  return milliseconds < 60_000
    ? `${Math.max(0, Math.floor(milliseconds / 1000))}s`
    : duration(milliseconds);
}
function taskStatus(state: FooterSnapshot, id: number): string {
  const task = state.tasks.find((value) => value.id === id);
  if (!task) {
    return "Task is no longer available";
  }
  const dependencies = task.blockedBy.filter((dependency) => {
    const value = state.tasks.find((item) => item.id === dependency);
    return (
      value === undefined ||
      (value.status !== "completed" && value.status !== "deleted")
    );
  });
  if (dependencies.length > 0 && task.status !== "completed") {
    return `Waiting on ${dependencies.map((dependency) => `#${dependency}`).join(", ")}`;
  }
  const labels = {
    pending: "Pending",
    in_progress: "In progress",
    completed: "Complete",
    deleted: "Deleted",
  };
  return labels[task.status];
}
export class DomainPages {
  constructor(
    private readonly snapshot: () => FooterSnapshot | undefined,
    private readonly navigation: InspectionNavigation,
  ) {}
  page(section: Section): InspectionPage {
    return {
      kind: "menu",
      title: SECTION_LABELS[section],
      content: () => {
        const state = this.snapshot();
        if (state === undefined) {
          return { summary: [], rows: [] };
        }
        const content = this.content(state, section);
        if (!content.rows.some((row) => row.key === "sections")) {
          content.rows.push(sectionsRow(this.navigation));
        }
        return content;
      },
    };
  }
  private content(state: FooterSnapshot, section: Section): InspectionContent {
    const pages = {
      overview: () => this.overview(state),
      quota: () => this.quota(state),
      workflow: () => this.workflow(state),
      diagnostics: () => this.diagnostics(state),
      git: () => this.git(state),
      usage: () => usageContent(state, this.navigation),
    } satisfies Record<Section, () => InspectionContent>;
    return pages[section]();
  }
  private source(
    state: FooterSnapshot,
    section: Section,
    label = "Source details",
  ): InspectionRow {
    return detailRow(
      this.navigation,
      SECTION_LABELS[section],
      "source",
      label,
      () => detailsLines(state, section),
    );
  }
  private overview(state: FooterSnapshot): InspectionContent {
    let activity = "Idle";
    if (state.activity.runningSince !== undefined) {
      activity = "Running";
    }
    if (state.activity.tool !== undefined) {
      activity = text(state.activity.tool);
    }
    if (state.activity.compacting) {
      activity = "Compacting";
    }
    if (state.activity.waiting) {
      activity = "Awaiting input";
    }
    if (
      state.activity.outcome === "failed" ||
      state.activity.outcome === "cancelled"
    ) {
      activity = state.activity.outcome;
    }
    const summary = paragraphs(
      `Model: ${text(state.model)}`,
      `Thinking: ${text(state.thinking) || "Off"}`,
      `Directory: ${text(state.cwd, 500)}`,
      `Context: ${state.context.percent === null ? "Unavailable" : `${state.context.percent.toFixed(1)}% of ${tokens(state.context.capacity)}`}`,
    );
    const status: InspectionText = { value: `Activity: ${activity}` };
    if (state.activity.outcome === "failed") {
      status.colour = "error";
    }
    if (state.activity.outcome === "cancelled") {
      status.colour = "warning";
    }
    summary.push(status);
    return {
      summary,
      rows: [
        this.source(state, "overview", "Model & context details"),
        detailRow(
          this.navigation,
          "Overview",
          "messages",
          "Extension messages",
          () => {
            const values = [...state.cooperativeStatuses].map(
              ([source, value]) =>
                `${text(source)}: ${value.active ? text(value.text) || "Active" : "Inactive"}`,
            );
            values.push(
              ...[...state.statuses]
                .filter(([source]) => !state.cooperativeStatuses.has(source))
                .map(
                  ([source, value]) => `${text(source)}: ${text(value, 500)}`,
                ),
            );
            return values.length > 0 ? values : ["No extension messages yet."];
          },
        ),
      ],
    };
  }
  private quota(state: FooterSnapshot): InspectionContent {
    const windows = quotaWindows(state.quota, state.now);
    const summary: InspectionText[] = [];
    if (windows.length === 0) {
      summary.push({ value: "No quota data yet." });
    }
    const at = state.quota?.lastSuccessAt;
    if (at !== undefined) {
      const stale = windows.some((window) => window.freshness === "stale");
      summary.push(
        stale
          ? {
              value: `Stale · updated ${elapsed(state.now - at)} ago`,
              colour: "warning",
            }
          : { value: `Updated ${elapsed(state.now - at)} ago` },
      );
    }
    if (state.quota?.error !== undefined) {
      summary.push({ value: text(state.quota.error), colour: "error" });
    }
    const rows = windows.map((window, index): InspectionRow => {
      const row = detailRow(
        this.navigation,
        "Quota",
        `window:${index}`,
        window.label,
        () => detailsLines(state, "quota"),
        `${window.used === undefined ? "No current reading" : `${window.used.toFixed(1)}% used`}${window.reset !== undefined && window.reset !== "" ? ` · Resets in ${window.reset}` : ""}`,
      );
      if (window.freshness === "stale" || window.freshness === "unavailable") {
        row.colour = "warning";
      }
      return row;
    });
    rows.push(this.source(state, "quota", "Account & source"));
    return { summary, rows };
  }
  private workflow(state: FooterSnapshot): InspectionContent {
    const tasks = taskSummary(state.tasks);
    const summary = paragraphs(
      tasks.total === 0
        ? "No tasks recorded."
        : `Tasks: ${tasks.completed} of ${tasks.total} complete`,
    );
    if (tasks.blocked > 0) {
      summary.push({
        value: `Blocked: ${tasks.blocked} ${tasks.blocked === 1 ? "task" : "tasks"}`,
      });
    }
    const agents = state.agents;
    if (agents === undefined) {
      summary.push({ value: "Agents: No report yet" });
    }
    if (agents !== undefined) {
      const value = `Agents: ${agents.active} running${agents.failed ? ` · ${agents.failed} failed` : ""}${agents.paused ? ` · ${agents.paused} paused` : ""}${agents.incomplete ? " · incomplete report" : ""}${agents.stale ? " · stale" : ""}`;
      summary.push(
        agents.incomplete || agents.stale || agents.failed > 0
          ? { value, colour: "warning" }
          : { value },
      );
    }
    if (state.rpcErrors.status !== undefined) {
      summary.push({
        value: text(state.rpcErrors.status.message),
        colour: "error",
      });
    }
    const rows = state.tasks
      .filter((task) => task.status !== "deleted")
      .map((task) =>
        detailRow(
          this.navigation,
          "Workflow",
          `task:${task.id}`,
          text(task.activeForm ?? task.subject),
          () => {
            const current = state.tasks.find((value) => value.id === task.id);
            return current === undefined
              ? ["Task is no longer available."]
              : [
                  `#${current.id} ${text(current.subject)}`,
                  taskStatus(state, task.id),
                  `Dependencies: ${current.blockedBy.length > 0 ? current.blockedBy.join(", ") : "None"}`,
                  "Open /todos for task controls.",
                ];
          },
          taskStatus(state, task.id),
        ),
      );
    rows.push(
      ...(agents?.runs.map((run, index) =>
        detailRow(
          this.navigation,
          "Workflow",
          `agent:${index}`,
          text(run.label),
          () => [
            `${text(run.label)}: ${text(run.state)}`,
            "Open /subagents for agent controls.",
          ],
          text(run.state),
        ),
      ) ?? []),
      this.source(state, "workflow", "Task & agent details"),
    );
    return { summary, rows };
  }
  private diagnostics(state: FooterSnapshot): InspectionContent {
    const value = state.diagnostics.summary();
    const suffix = value.truncated ? "+" : "";
    const counts = `${value.errors}${suffix} errors · ${value.warnings}${suffix} warnings${value.pending ? ` · ${value.pending} pending` : ""}`;
    const summary: InspectionText[] = value.observed
      ? [
          {
            value: counts,
            ...(value.errors > 0
              ? { colour: "error" as const }
              : value.warnings > 0 || value.pending > 0
                ? { colour: "warning" as const }
                : {}),
          },
        ]
      : paragraphs("No findings received.");
    const rows = [...state.diagnostics.files].map(
      ([path, file]): InspectionRow => {
        const fileSuffix = file.truncated ? "+" : "";
        const row = detailRow(
          this.navigation,
          "Diagnostics",
          `file:${path}`,
          text(path, 500),
          () =>
            state.diagnostics.files.get(path)?.messages ?? [
              "No findings received.",
            ],
          `${file.errors}${fileSuffix} errors · ${file.warnings}${fileSuffix} warnings${file.pending ? " · pending" : ""}`,
        );
        if (file.errors > 0) {
          row.colour = "error";
        }
        if (file.errors === 0 && (file.warnings > 0 || file.pending)) {
          row.colour = "warning";
        }
        return row;
      },
    );
    rows.push(this.source(state, "diagnostics", "Source & coverage"));
    return { summary, rows };
  }
  private git(state: FooterSnapshot): InspectionContent {
    const git = state.git;
    const summary =
      git === undefined
        ? paragraphs("No repository data yet.")
        : paragraphs(
            text(git.branch),
            `Staged ${git.staged} · Modified ${git.unstaged} · Untracked ${git.untracked}`,
            `Ahead ${git.ahead} · Behind ${git.behind}`,
          );
    if (git?.stale === true) {
      summary.push({ value: "Stale repository data", colour: "warning" });
    }
    if (git !== undefined && git.conflicts > 0) {
      summary.push({ value: `${git.conflicts} conflicts`, colour: "error" });
    }
    if (git?.operation !== undefined) {
      summary.push({ value: text(git.operation), colour: "warning" });
    }
    if (state.gitError !== undefined) {
      summary.push({ value: text(state.gitError), colour: "error" });
    }
    const rows: InspectionRow[] = [];
    if (git !== undefined) {
      rows.push(
        detailRow(this.navigation, "Git", "paths", "File changes", () => [
          `Staged: ${state.git?.staged ?? "Unavailable"}`,
          `Modified: ${state.git?.unstaged ?? "Unavailable"}`,
          `Untracked: ${state.git?.untracked ?? "Unavailable"}`,
          `Conflicts: ${state.git?.conflicts ?? "Unavailable"}`,
          "Counts refer to paths, not changed lines. A path can have staged and unstaged changes.",
        ]),
      );
    }
    const pr = state.pr?.pullRequest;
    if (pr !== undefined) {
      const request = detailRow(
        this.navigation,
        "Git",
        "pr",
        `Pull request #${pr.target.number}`,
        () => detailsLines(state, "git"),
        `${pr.lifecycle}${pr.mergeState === "conflicting" ? " · Merge conflicts" : ""}`,
      );
      const checks = detailRow(
        this.navigation,
        "Git",
        "checks",
        "Checks",
        () => detailsLines(state, "git"),
        pr.ci === undefined
          ? "No check report"
          : `${pr.ci.state} · ${pr.ci.failedCount} failed`,
      );
      const reviews = detailRow(
        this.navigation,
        "Git",
        "reviews",
        "Review threads",
        () => detailsLines(state, "git"),
        `${pr.unresolvedThreadCount} unresolved`,
      );
      if (pr.mergeState === "conflicting") {
        request.colour = "error";
      }
      if (pr.ci?.state === "failed") {
        checks.colour = "error";
      }
      if (pr.unresolvedThreadCount > 0) {
        reviews.colour = "warning";
      }
      rows.push(request, checks, reviews);
    }
    if (state.pr !== undefined && state.pr.health !== "ok") {
      summary.push({ value: `GitHub: ${state.pr.health}`, colour: "warning" });
    }
    rows.push(this.source(state, "git"));
    return { summary, rows };
  }
}
