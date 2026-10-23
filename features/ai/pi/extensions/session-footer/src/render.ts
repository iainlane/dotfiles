import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { homedir } from "node:os";
import { basename, sep } from "node:path";
import type { FooterSnapshot } from "./state.ts";
import { quotaWindows, type QuotaView } from "./quota.ts";
import { duration, link, text, tokens } from "./text.ts";
import { taskSummary } from "./workflow.ts";
import { inactivity } from "./activity.ts";
import {
  contextStyle,
  gitStyle,
  quotaStyle,
  styles,
  thinkingStyle,
  type FooterStyle,
} from "./palette.ts";

type Paint = (style: FooterStyle, value: string) => string;

const home = homedir();

function directory(cwd: string): string {
  if (cwd === home) return "~";

  if (cwd.startsWith(home + sep)) return "~" + cwd.slice(home.length);

  return cwd;
}

function quotaLabel(window: QuotaView, resets: boolean, paint: Paint): string {
  const label = paint(styles.label, window.label.toLowerCase());

  if (window.used === undefined)
    return `${label} ${paint(styles.detail, "unavailable")}`;

  const used = paint(
    quotaStyle(window.freshness),
    `${Math.round(window.used)}%`,
  );
  const reset =
    resets && window.reset ? paint(styles.detail, ` (${window.reset})`) : "";
  const freshness =
    window.freshness === "fresh"
      ? ""
      : paint(styles.warning, ` ${window.freshness}`);

  return `${label} ${used}${paint(styles.label, " used")}${reset}${freshness}`;
}

interface Item {
  variants: string[];
  priority: number;
  detailPriority?: number;
  right?: boolean;
}

function fit(items: Item[], width: number, paint: Paint): string {
  const leftSeparator = paint(styles.separator, "  ");
  const rightArrow = paint(styles.separator, "");
  const levels = items.map(() => 0);
  let omitted = 0;

  const value = (item: Item, index: number) =>
    item.variants[levels[index] ?? 0] ?? "";

  const join = (marker = "") => {
    const left = items
      .map((item, i) => (item.right ? "" : value(item, i)))
      .filter(Boolean);

    if (marker) left.push(paint(styles.detail, marker));

    const right = items
      .flatMap((item, i) => {
        if (!item.right) return [];

        const rendered = value(item, i);

        return rendered ? [`${rightArrow} ${rendered}`] : [];
      })
      .join(" ");
    const l = left.join(leftSeparator);

    if (!right) return l;

    const gap = Math.max(
      l ? 2 : 0,
      width - visibleWidth(l) - visibleWidth(right),
    );

    return l + " ".repeat(gap) + right;
  };

  while (visibleWidth(join()) > width) {
    const remaining = items.filter((item, index) => value(item, index)).length;
    const candidate = items
      .map((item, index) => {
        const level = levels[index] ?? 0;
        const next = item.variants[level + 1];

        return {
          item,
          index,
          next,
          priority: next
            ? (item.detailPriority ?? item.priority)
            : item.priority,
        };
      })
      .filter(({ next }) => next !== undefined && (next || remaining > 1))
      .sort((a, b) => a.priority - b.priority || b.index - a.index)[0];

    if (!candidate) {
      const important = items
        .map((item, index) => ({ item, rendered: value(item, index) }))
        .filter(({ rendered }) => rendered)
        .sort((a, b) => b.item.priority - a.item.priority)[0];
      const rendered = important?.rendered ?? "";

      return truncateToWidth(
        important?.item.right ? `${rightArrow} ${rendered}` : rendered,
        width,
        "…",
      );
    }

    levels[candidate.index] = (levels[candidate.index] ?? 0) + 1;

    if (!value(candidate.item, candidate.index)) omitted++;
  }

  if (omitted) {
    for (const marker of [`+${omitted}`, "…"]) {
      const rendered = join(marker);

      if (visibleWidth(rendered) <= width) return rendered;
    }
  }

  return join();
}

export function renderFooter(
  state: FooterSnapshot,
  width: number,
  theme?: Pick<Theme, "fg" | "bold">,
): string[] {
  width = Math.max(0, Math.floor(width));

  if (!width) return [];

  const paint: Paint = (style, value) => {
    if (!theme) return value;

    const coloured = theme.fg(style.color, value);

    return style.bold ? theme.bold(coloured) : coloured;
  };

  const item = (
    value: string,
    priority: number,
    compact = "",
    right = false,
  ): Item => ({
    variants: compact && compact !== value ? [value, compact, ""] : [value, ""],
    priority,
    right,
  });

  const model = text(state.model);
  const provider =
    state.provider === "openai-codex" ? "codex" : text(state.provider);
  const context =
    state.context.percent === null
      ? "?"
      : `${state.context.percent.toFixed(1)}%`;
  const capacity = state.context.capacity
    ? `/${tokens(state.context.capacity)}`
    : "";
  const contextValue =
    paint(styles.label, "ctx ") +
    paint(contextStyle(state.context.percent), context);

  const row1: Item[] = [
    {
      variants: [
        (provider ? paint(styles.provider, `${provider}/`) : "") +
          paint(styles.model, model),
        paint(styles.model, model),
        paint(styles.model, truncateToWidth(model, 12, "…")),
        "",
      ],
      priority: 90,
    },
    item(
      [
        paint(thinkingStyle(state.thinking), text(state.thinking)),
        state.serviceTier && paint(styles.serviceTier, text(state.serviceTier)),
      ]
        .filter(Boolean)
        .join(" "),
      20,
    ),
    item(
      paint(styles.directory, text(directory(state.cwd))),
      10,
      paint(styles.directory, text(basename(state.cwd))),
    ),
  ];
  const git = state.git;

  if (git) {
    const branchStyle = gitStyle(git);

    const counts = [
      git.staged && paint(styles.success, `+${git.staged}`),
      git.unstaged && paint(styles.warning, `±${git.unstaged}`),
      git.untracked && paint(styles.label, `?${git.untracked}`),
      git.ahead && paint(styles.label, `↑${git.ahead}`),
      git.behind && paint(styles.label, `↓${git.behind}`),
    ]
      .filter(Boolean)
      .join(" ");

    row1.push(
      item(
        [
          paint(styles.label, ""),
          paint(branchStyle, git.branch),
          git.worktree && paint(styles.detail, `[${git.worktree}]`),
          counts,
          git.stale && paint(styles.warning, "stale"),
        ]
          .filter(Boolean)
          .join(" "),
        40,
        paint(styles.label, " ") +
          paint(branchStyle, truncateToWidth(git.branch, 16, "…")),
      ),
    );

    if (git.operation)
      row1.push(item(paint(styles.warning, git.operation), 110));

    if (git.conflicts)
      row1.push(item(paint(styles.error, `conflicts ${git.conflicts}`), 120));
  }

  row1.push({
    variants: [contextValue + paint(styles.detail, capacity), contextValue, ""],
    priority: 100,
    right: true,
  });

  const row2: Item[] = [];
  const activity = state.activity;
  const inactive = inactivity(activity, state.now);

  if (activity.waiting)
    row2.push(
      item(
        paint(styles.warning, "awaiting input"),
        120,
        paint(styles.warning, "input!"),
      ),
    );
  else if (activity.compacting)
    row2.push(item(paint(styles.activity, "compacting"), 115));
  else if (activity.tool)
    row2.push(item(paint(styles.tool, text(activity.tool)), 60));
  else if (activity.outcome === "failed" || activity.outcome === "cancelled")
    row2.push(
      item(
        paint(
          activity.outcome === "failed" ? styles.error : styles.warning,
          `run ${activity.outcome}`,
        ),
        110,
      ),
    );
  else if (inactive)
    row2.push(
      item(
        paint(styles.warning, `no content ${inactive}`),
        110,
        paint(styles.warning, "waiting"),
      ),
    );

  const diagnostics = state.diagnostics.summary();

  if (diagnostics.errors || diagnostics.warnings)
    row2.push(
      item(
        paint(
          diagnostics.errors ? styles.error : styles.detail,
          `${diagnostics.errors}E`,
        ) +
          " " +
          paint(
            diagnostics.warnings ? styles.warning : styles.detail,
            `${diagnostics.warnings}W`,
          ) +
          paint(
            styles.warning,
            `${diagnostics.truncated ? "+" : ""}${diagnostics.pending ? " pending" : ""}`,
          ),
        120,
      ),
    );

  const tasks = taskSummary(state.tasks);

  if (tasks.total > tasks.completed) {
    const progress =
      paint(styles.label, "tasks ") +
      paint(styles.workflow, `${tasks.completed}/${tasks.total}`);

    row2.push(
      item(
        progress +
          (tasks.current ? paint(styles.text, ` ${tasks.current}`) : ""),
        50,
        progress,
      ),
    );
  }

  if (tasks.blocked)
    row2.push(item(paint(styles.warning, `blocked ${tasks.blocked}`), 100));

  if (state.agents) {
    if (state.agents.active)
      row2.push(
        item(
          paint(styles.label, "agents ") +
            paint(styles.workflow, `${state.agents.active}`) +
            paint(
              styles.warning,
              `${state.agents.incomplete ? "+" : ""}${state.agents.stale ? " stale" : ""}`,
            ),
          70,
        ),
      );

    if (state.agents.failed)
      row2.push(
        item(
          paint(
            styles.error,
            `runs failed ${state.agents.failed}${state.agents.incomplete ? "+" : ""}`,
          ),
          120,
        ),
      );

    if (state.agents.paused)
      row2.push(
        item(paint(styles.warning, `runs paused ${state.agents.paused}`), 110),
      );
  }

  if (state.pending)
    row2.push(
      item(
        paint(styles.activity, "messages pending"),
        65,
        paint(styles.activity, "pending"),
      ),
    );

  for (const [key, value] of state.statuses) {
    if (key === "plan-mode")
      row2.push(item(paint(styles.activity, text(value)), 80));
    else if (key === "pi-lens-lsp" && /Failed|✗/.test(value))
      row2.push(
        item(
          paint(styles.error, text(value)),
          120,
          paint(styles.error, "LSP failed"),
        ),
      );
  }

  const pr = state.pr?.pullRequest;

  if (pr) {
    let prStyle: FooterStyle = styles.pullRequest;

    if (pr.mergeState === "blocked" || pr.mergeState === "conflicting")
      prStyle = styles.error;

    if (state.pr?.health !== "ok") prStyle = styles.detail;

    row2.push(
      item(link(paint(prStyle, `PR#${pr.target.number}`), pr.target.url), 35),
    );

    if (pr.ci?.failedCount)
      row2.push(
        item(
          link(
            paint(styles.error, `CI ${pr.ci.failedCount} failed`),
            pr.ci.url,
          ),
          120,
        ),
      );

    if (pr.unresolvedThreadCount)
      row2.push(
        item(
          link(
            paint(styles.warning, `reviews ${pr.unresolvedThreadCount}`),
            pr.target.url,
          ),
          105,
        ),
      );
  }

  const unknown = [...state.statuses].filter(
    ([key]) =>
      !["plan-mode", "pi-lens-lsp", "pi-footer"].includes(key) &&
      key !== "session-footer",
  );

  if (unknown.length)
    row2.push(item(paint(styles.label, `status +${unknown.length}`), 25));

  for (const window of quotaWindows(state.quota, state.now)) {
    row2.push({
      variants: [
        quotaLabel(window, true, paint),
        quotaLabel(window, false, paint),
        "",
      ],
      detailPriority: 0,
      priority: 90,
      right: true,
    });
  }

  row2.push(
    item(paint(styles.detail, `$${state.usage.cost.toFixed(2)}`), 2, "", true),
  );
  row2.push(
    item(
      paint(styles.detail, duration(state.now - state.startedAt)),
      1,
      "",
      true,
    ),
  );

  return [
    fit(
      row1.filter((entry) => entry.variants[0]),
      width,
      paint,
    ),
    fit(row2, width, paint),
  ];
}
