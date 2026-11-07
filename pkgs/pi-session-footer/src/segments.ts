import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";
import { basename, sep } from "node:path";
import { inactivity } from "./activity.ts";
import {
  contextStyle,
  gitStyle,
  quotaStyle,
  styles,
  thinkingStyle,
  type FooterStyle,
} from "./palette.ts";
import { quotaWindows } from "./quota.ts";
import type { FooterSnapshot } from "./state.ts";
import { DEFAULT_SYMBOLS, sourceSymbol, type SegmentId } from "./settings.ts";
import { duration, link, text, tokens } from "./text.ts";
import { taskSummary } from "./workflow.ts";

export type Domain =
  | "overview"
  | "quota"
  | "workflow"
  | "diagnostics"
  | "git"
  | "usage";
export interface SegmentPart {
  key: string;
  variants: string[];
  priority: number;
  detailPriority?: number;
}
export interface Reading {
  id: SegmentId;
  state: "available" | "unavailable" | "idle" | "superseded";
  reason: string;
  parts: SegmentPart[];
  details: string[];
  symbols?: string;
}
interface Definition {
  title: string;
  section: Domain;
  symbols: string;
  priority: number;
  variants: string;
}
function definition(
  title: string,
  section: Domain,
  symbols: string,
  priority = 50,
): Definition {
  return {
    title,
    section,
    symbols,
    priority,
    variants: "Full, shortened where supported, then omitted for width",
  };
}
export const SEGMENTS = {
  model: definition("Model", "overview", " provider/model identifier", 90),
  thinking: definition(
    "Thinking",
    "overview",
    "⊘ off; ○ minimal; ◔ low; ◑ medium; ◒ high; ◕ xhigh; ◉ max (native reasoning levels)",
    20,
  ),
  tier: definition(
    "Service tier",
    "overview",
    "Published service tier, including ⚡",
    20,
  ),
  directory: definition(
    "Directory",
    "overview",
    " current directory or worktree identity",
    10,
  ),
  git: definition(
    "Git",
    "git",
    " branch; ✚ staged, ✎ modified, ? untracked paths; ↑ ahead, ↓ behind commits",
    40,
  ),
  "git-operation": definition(
    "Git operation",
    "git",
    "↻ reported merge, rebase or other operation",
    110,
  ),
  "git-conflicts": definition(
    "Git conflicts",
    "git",
    "⚠ conflicting paths, not changed lines",
    120,
  ),
  pr: definition("Pull request", "git", " # pull request number", 35),
  context: definition(
    "Context",
    "overview",
    "◫ percentage used / token capacity; border gauge shows used fraction",
    100,
  ),
  activity: definition(
    "Activity",
    "overview",
    " current tool;  awaiting input; 󰁯 compacting; ✗ failed; ⊘ cancelled; ◷ no content",
    115,
  ),
  diagnostics: definition(
    "Diagnostics",
    "diagnostics",
    "⊗ errors, ⚠ warnings; + lower bound; pending provisional files",
    120,
  ),
  tasks: definition(
    "Tasks",
    "workflow",
    "☑ completed / total tasks and current task",
    50,
  ),
  blocked: definition(
    "Blocked tasks",
    "workflow",
    " dependency-blocked tasks",
    100,
  ),
  agents: definition(
    "Delegation",
    "workflow",
    " active children (exact); failed/paused runs may be lower bounds",
    120,
  ),
  pending: definition(
    "Queued messages",
    "workflow",
    " native pending messages, not a queue count",
    65,
  ),
  planning: definition(
    "Planning",
    "workflow",
    "≡ published planning message",
    80,
  ),
  ci: definition(
    "CI failures",
    "git",
    " failed checks reported by PR integration",
    120,
  ),
  reviews: definition("Reviews", "git", " unresolved review threads", 105),
  statuses: definition(
    "Extension messages",
    "overview",
    "◇ source name and actual published message",
    25,
  ),
  quota: definition(
    "Quota",
    "quota",
    "◴ percent used; ↻ time until reset, not reading age",
    90,
  ),
  cache: definition(
    "Cache hit rate",
    "usage",
    " cache read / (input + cache read + cache write); latest request",
    3,
  ),
  cost: definition(
    "Session cost",
    "usage",
    "$ provider-billed or ≈$ recorded estimate, whole session",
    2,
  ),
  "auxiliary-cost": definition(
    "Auxiliary cost",
    "usage",
    " separate auxiliary scope, not added to session cost",
    2,
  ),
  age: definition(
    "Session age",
    "usage",
    " elapsed wall-clock session age",
    1,
  ),
  input: definition(
    "Input tokens",
    "usage",
    "↑ whole-session uncached input",
    3,
  ),
  output: definition("Output tokens", "usage", "↓ whole-session output", 3),
  "cache-read": definition(
    "Cache read tokens",
    "usage",
    "Whole-session cached input read",
    3,
  ),
  "cache-write": definition(
    "Cache write tokens",
    "usage",
    "Whole-session cache writes",
    3,
  ),
  "run-duration": definition("Run duration", "usage", "Elapsed current run", 2),
  "active-duration": definition(
    "Active work",
    "usage",
    "Observed active-work time",
    2,
  ),
  "compaction-duration": definition(
    "Compaction duration",
    "usage",
    "Elapsed current compaction",
    2,
  ),
} satisfies Record<SegmentId, Definition>;
export type Readings = Record<SegmentId, Reading>;
type Paint = (style: FooterStyle, value: string) => string;
export function createPaint(theme?: Pick<Theme, "fg" | "bold">): Paint {
  return (style, value) => {
    if (!theme) {
      return value;
    }
    const coloured = theme.fg(style.color, value);
    return style.bold === true ? theme.bold(coloured) : coloured;
  };
}
function available(
  id: SegmentId,
  value: string,
  options: { compact?: string; details?: string[]; priority?: number } = {},
): Reading {
  const {
    compact = "",
    details = [],
    priority = SEGMENTS[id].priority,
  } = options;
  return {
    id,
    state: "available",
    reason: "",
    details,
    parts: [
      {
        key: id,
        variants:
          compact && compact !== value ? [value, compact, ""] : [value, ""],
        priority,
      },
    ],
  };
}
function hidden(
  id: SegmentId,
  reason: string,
  state: Reading["state"] = "unavailable",
): Reading {
  return { id, state, reason, parts: [], details: [] };
}
function directory(
  state: FooterSnapshot,
  home: string | undefined,
  paint: Paint,
): Reading {
  const cwd =
    home !== undefined &&
    home !== "" &&
    (state.cwd === home || state.cwd.startsWith(home + sep))
      ? "~" + state.cwd.slice(home.length)
      : state.cwd;
  return available(
    "directory",
    paint(styles.directory, " ") + paint(styles.directory, text(cwd)),
    {
      compact:
        paint(styles.directory, " ") +
        paint(styles.directory, text(basename(state.cwd))),
      details: [state.cwd],
    },
  );
}
function model(state: FooterSnapshot, paint: Paint): Reading {
  if (!state.model || ["unknown", "no model"].includes(state.model)) {
    return hidden("model", "No known model selected");
  }
  const provider =
    state.provider === "openai-codex" ? "codex" : text(state.provider);
  const name = text(state.model);
  const reading = available(
    "model",
    paint(styles.label, " ") +
      (provider ? paint(styles.provider, provider + "/") : "") +
      paint(styles.model, name),
    { compact: paint(styles.label, " ") + paint(styles.model, name) },
  );
  const part = reading.parts[0];
  const shortened =
    paint(styles.label, " ") +
    paint(styles.model, truncateToWidth(name, 12, "…"));
  if (part !== undefined && !part.variants.includes(shortened)) {
    part.variants.splice(part.variants.length - 1, 0, shortened);
  }
  return reading;
}
const THINKING_GLYPHS = [
  ["off", "⊘"],
  ["minimal", "○"],
  ["low", "◔"],
  ["medium", "◑"],
  ["high", "◒"],
  ["xhigh", "◕"],
  ["max", "◉"],
] as const;
function thinking(state: FooterSnapshot, paint: Paint): Reading {
  if (!state.reasoning || !state.thinking || state.model === "no model") {
    return hidden(
      "thinking",
      "Native model does not report reasoning capability",
    );
  }
  const symbol = THINKING_GLYPHS.find(
    ([level]) => level === state.thinking,
  )?.[1];
  let display = paint(thinkingStyle(state.thinking), text(state.thinking));
  if (symbol !== undefined) {
    display = paint(thinkingStyle(state.thinking), symbol + " ") + display;
  }
  if (state.thinking === "off") {
    display = paint(thinkingStyle(state.thinking), "⊘");
  }
  return available("thinking", display, {
    compact:
      symbol === undefined
        ? display
        : paint(thinkingStyle(state.thinking), symbol),
    details: ["Applicability comes from native model.reasoning"],
  });
}
function context(state: FooterSnapshot, paint: Paint): Reading {
  const { percent, capacity } = state.context;
  if (percent === null && !capacity) {
    return hidden("context", "Context usage and capacity unavailable");
  }
  const label = paint(styles.label, "◫ ");
  const details = [
    `Active branch context; ${state.context.tokens ?? "unknown"} tokens; capacity ${capacity || "unknown"}`,
  ];

  if (percent === null) {
    return available(
      "context",
      label + paint(styles.detail, tokens(capacity)),
      {
        details,
      },
    );
  }

  const value = label + paint(contextStyle(percent), `${percent.toFixed(1)}%`);
  let display = value;

  if (capacity) {
    display += paint(styles.detail, `/${tokens(capacity)}`);
  }

  return available("context", display, { compact: value, details });
}
function git(state: FooterSnapshot, paint: Paint): Reading {
  const g = state.git;
  if (!g) {
    if (state.gitError !== undefined && state.gitError !== "") {
      return available(
        "git",
        paint(styles.error, ` ⚠ ${text(state.gitError)}`),
        { details: [state.gitError], priority: 120 },
      );
    }
    return hidden("git", "No repository reading");
  }
  const counts = [
    [g.staged, "✚", styles.success],
    [g.unstaged, "✎", styles.warning],
    [g.untracked, "?", styles.label],
    [g.ahead, "↑", styles.label],
    [g.behind, "↓", styles.label],
  ] as const;
  const full = [
    paint(styles.label, ""),
    paint(gitStyle(g), text(g.branch)),
    ...counts.flatMap(([count, symbol, style]) =>
      count ? [paint(style, `${symbol}${count}`)] : [],
    ),
    g.stale ? paint(styles.warning, "stale") : "",
  ]
    .filter(Boolean)
    .join(" ");
  return available("git", full, {
    compact:
      paint(styles.label, " ") +
      paint(gitStyle(g), truncateToWidth(text(g.branch), 16, "…")),
    details: [
      "Counts are paths and commits, not line changes",
      `Git data: ${g.stale ? "stale" : "fresh"}`,
      state.gitError ?? "No error reported",
    ],
  });
}
function activity(state: FooterSnapshot, paint: Paint): Reading {
  const a = state.activity;
  const inactive = inactivity(a, state.now);
  if (a.waiting) {
    return available("activity", paint(styles.warning, " awaiting input"), {
      compact: paint(styles.warning, " input!"),
    });
  }
  if (a.compacting) {
    return available("activity", paint(styles.activity, "󰁯 compacting"));
  }
  if (a.tool !== undefined && a.tool !== "") {
    return available("activity", paint(styles.tool, ` ${text(a.tool)}`), {
      priority: 60,
    });
  }
  if (a.outcome === "failed" || a.outcome === "cancelled") {
    return available(
      "activity",
      paint(
        a.outcome === "failed" ? styles.error : styles.warning,
        `${a.outcome === "failed" ? "✗" : "⊘"} run ${a.outcome}`,
      ),
    );
  }
  if (inactive !== undefined && inactive !== "") {
    return available(
      "activity",
      paint(styles.warning, `◷ no content ${inactive}`),
      { compact: paint(styles.warning, "◷ waiting") },
    );
  }
  return hidden("activity", "No active attention state", "idle");
}
function diagnostics(state: FooterSnapshot, paint: Paint): Reading {
  const d = state.diagnostics.summary();
  if (!d.errors && !d.warnings && !d.pending) {
    const reason = d.observed
      ? "No received findings; not a workspace-wide verdict"
      : "No diagnostics received";
    return hidden("diagnostics", reason);
  }
  return available(
    "diagnostics",
    paint(d.errors ? styles.error : styles.detail, `⊗${d.errors}`) +
      " " +
      paint(d.warnings ? styles.warning : styles.detail, `⚠${d.warnings}`) +
      paint(
        styles.warning,
        `${d.truncated ? "+" : ""}${d.pending ? " pending" : ""}`,
      ),
    {
      details: [
        "Received events only, not a workspace-wide verdict",
        d.truncated ? "Counts are lower bounds" : "Received counts",
        `${d.pending} files provisional`,
      ],
    },
  );
}
function quota(state: FooterSnapshot, paint: Paint): Reading {
  const windows = quotaWindows(state.quota, state.now);
  const parts = windows
    .filter((w) => w.used !== undefined)
    .map((w, index) => {
      const base =
        paint(styles.label, `◴ ${w.label.toLowerCase()}`) +
        " " +
        paint(quotaStyle(w.freshness), `${Math.round(w.used ?? 0)}%`);
      const freshness =
        w.freshness === "fresh" ? "" : paint(styles.warning, ` ${w.freshness}`);
      return {
        key: `${index}:${w.label}`,
        variants: [
          base +
            (w.reset !== undefined && w.reset !== ""
              ? paint(styles.detail, ` ↻${w.reset}`)
              : "") +
            freshness,
          base + freshness,
          "",
        ],
        priority: 90,
        detailPriority: 0,
      };
    });
  const details = [
    `Reading: ${state.quota?.lastSuccessAt === undefined ? "unknown" : new Date(state.quota.lastSuccessAt).toISOString()}`,
    `Source: ${state.quota?.source ?? "unknown"}; account ${state.quota?.account ?? "unknown"}`,
    `Last error: ${state.quota?.error ?? "none reported"}`,
    ...windows.map(
      (window) =>
        `${window.label}: ${window.used === undefined ? "percentage unavailable or expired" : `${window.used}% used`}; ${window.freshness}; reset in ${window.reset ?? "unknown"}`,
    ),
  ];
  if (parts.length === 0) {
    if (state.quota?.error !== undefined && state.quota.error !== "") {
      return available(
        "quota",
        paint(styles.error, `◴ ⚠ ${text(state.quota.error)}`),
        { details, priority: 120 },
      );
    }
    let reason = "No quota publication";
    if (state.quota !== undefined) {
      reason = "No quota percentages reported";
      const expired =
        state.quota.lastSuccessAt !== undefined &&
        (state.now - state.quota.lastSuccessAt > 300_000 ||
          state.quota.windows.some(
            (window) =>
              window.resetAt !== undefined && state.now >= window.resetAt,
          ));
      if (expired) {
        reason = "Quota percentages expired";
      }
    }
    return { ...hidden("quota", reason), details };
  }
  return {
    id: "quota",
    state: "available",
    reason: "",
    parts,
    details,
  };
}
function agents(state: FooterSnapshot, paint: Paint): Reading {
  const a = state.agents;
  if (!a) {
    return hidden("agents", "No delegation publication");
  }
  const suffix = a.incomplete ? "+" : "";
  const stale = a.stale ? " stale" : "";
  const parts: SegmentPart[] = [];
  if (a.active) {
    parts.push({
      key: "active",
      variants: [paint(styles.workflow, ` ${a.active}${stale}`), ""],
      priority: 70,
    });
  }
  if (a.failed) {
    parts.push({
      key: "failed",
      variants: [
        paint(styles.error, ` failed ${a.failed}${suffix}${stale}`),
        "",
      ],
      priority: 120,
    });
  }
  if (a.paused) {
    parts.push({
      key: "paused",
      variants: [
        paint(styles.warning, ` paused ${a.paused}${suffix}${stale}`),
        "",
      ],
      priority: 110,
    });
  }
  if (parts.length === 0) {
    return hidden(
      "agents",
      "No active children or reported failed/paused runs",
      "idle",
    );
  }
  return {
    id: "agents",
    state: "available",
    reason: "",
    parts,
    details: [
      "Active children are exact; run details may be incomplete",
      `Reporting ${a.stale ? "stale" : "current"}`,
    ],
  };
}
function statuses(
  state: FooterSnapshot,
  paint: Paint,
  symbols: ReadonlyMap<string, string>,
): Reading {
  const parts: SegmentPart[] = [];
  const messages: string[] = [];
  const selected: string[] = [];

  for (const [source, status] of state.cooperativeStatuses) {
    if (source === "planning" || !status.active) {
      continue;
    }
    const symbol = sourceSymbol(symbols, source);
    const value =
      symbol +
      (status.text !== undefined && status.text !== ""
        ? ` ${status.text}`
        : "");
    parts.push({
      key: source,
      variants: [paint(styles.detail, value), ""],
      priority: SEGMENTS.statuses.priority,
    });
    messages.push(`${source}: ${status.text ?? "active"}`);
    selected.push(`${source}: ${symbol}`);
  }

  for (const [key, raw] of state.statuses) {
    if (
      state.cooperativeStatuses.has(key) ||
      ["planning", "pi-footer", "session-footer"].includes(key)
    ) {
      continue;
    }

    const value = text(raw, 500);

    if (!value) {
      continue;
    }

    const source = text(key);
    const message = source ? `${source}: ${value}` : value;
    const failure = key === "pi-lens-lsp" && /Failed|✗/.test(value);
    const symbol = sourceSymbol(symbols, key);
    selected.push(`${source}: ${symbol}`);
    parts.push({
      key,
      variants: [
        paint(failure ? styles.error : styles.detail, `${symbol} ${message}`),
        "",
      ],
      priority: failure ? 120 : SEGMENTS.statuses.priority,
    });
    messages.push(message);
  }

  if (parts.length === 0) {
    return {
      ...hidden("statuses", "No other extension messages published"),
      symbols: sourceSymbol(symbols, "default"),
    };
  }

  return {
    id: "statuses",
    state: "available",
    reason: "",
    parts,
    details: messages,
    symbols: selected.join("; "),
  };
}
function planning(
  state: FooterSnapshot,
  paint: Paint,
  symbols: ReadonlyMap<string, string>,
): Reading {
  const status = state.cooperativeStatuses.get("planning");
  const symbol = sourceSymbol(symbols, "planning");
  const detail = status
    ? (status.text ?? "")
    : text(state.statuses.get("planning"));
  if (status?.active === false) {
    return {
      ...hidden("planning", "Planning is inactive", "idle"),
      symbols: symbol,
    };
  }

  if (status?.active === true || detail !== "") {
    return {
      ...available(
        "planning",
        paint(styles.activity, symbol + (detail ? ` ${detail}` : "")),
      ),
      symbols: symbol,
    };
  }

  return {
    ...hidden("planning", "No planning publication"),
    symbols: symbol,
  };
}
function cost(u: FooterSnapshot["usage"]): string {
  return `${u.costFromProvider ? "$" : "≈$"}${u.cost.toFixed(2)}`;
}
function pullRequest(state: FooterSnapshot, paint: Paint): Reading {
  const source = state.pr;
  if (!source?.pullRequest) {
    return hidden("pr", "No pull request publication");
  }
  const pr = source.pullRequest;
  let style: FooterStyle = styles.pullRequest;
  if (["blocked", "conflicting"].includes(pr.mergeState)) {
    style = styles.error;
  }
  if (source.health !== "ok") {
    style = styles.detail;
  }
  return available(
    "pr",
    link(paint(style, ` #${pr.target.number}`), pr.target.url),
    {
      details: [
        `Source ${source.health}; updated ${new Date(source.updatedAt).toISOString()}`,
      ],
    },
  );
}
function tasks(summary: ReturnType<typeof taskSummary>, paint: Paint): Reading {
  if (summary.total <= summary.completed) {
    return hidden("tasks", "No unfinished tasks", "idle");
  }
  const progress =
    paint(styles.label, "☑ ") +
    paint(styles.workflow, `${summary.completed}/${summary.total}`);
  let display = progress;
  if (summary.current !== undefined && summary.current !== "") {
    display += paint(styles.text, ` ${summary.current}`);
  }
  return available("tasks", display, {
    compact: display === progress ? "" : progress + "…",
  });
}
export function readSegments(
  state: FooterSnapshot,
  {
    theme,
    home,
    symbols = DEFAULT_SYMBOLS,
  }: {
    theme?: Pick<Theme, "fg" | "bold">;
    home?: string;
    symbols?: ReadonlyMap<string, string>;
  } = {},
): Readings {
  const p = createPaint(theme);
  const task = taskSummary(state.tasks);
  const pr = state.pr?.pullRequest;
  const used =
    state.usage.input +
    state.usage.output +
    state.usage.cacheRead +
    state.usage.cacheWrite;
  const aux = state.auxiliaryUsage;
  const hasAux = Boolean(
    aux.input || aux.output || aux.cacheRead || aux.cacheWrite || aux.cost,
  );
  const measured =
    used > 0 || state.usage.cost > 0 || state.activity.activeMs > 0;
  const costSource = state.usage.costFromProvider
    ? "Provider-billed total"
    : "Recorded estimate, not a verified invoice";
  const time = (id: SegmentId, start: number | undefined, label: string) =>
    start === undefined
      ? hidden(id, `Not ${label}`, "idle")
      : available(
          id,
          p(styles.detail, `${label} ${duration(state.now - start)}`),
        );
  return {
    model: model(state, p),
    thinking: thinking(state, p),
    directory: directory(state, home, p),
    context: context(state, p),
    git: git(state, p),
    tier:
      state.serviceTier !== undefined && state.serviceTier !== ""
        ? available("tier", p(styles.serviceTier, text(state.serviceTier)))
        : hidden("tier", "No service tier publication"),
    "git-operation":
      state.git?.operation !== undefined && state.git.operation !== ""
        ? available(
            "git-operation",
            p(styles.warning, `↻ ${text(state.git.operation)}`),
          )
        : hidden("git-operation", "No operation reported", "idle"),
    "git-conflicts":
      (state.git?.conflicts ?? 0) > 0
        ? available(
            "git-conflicts",
            p(styles.error, `⚠ conflicts ${state.git?.conflicts}`),
          )
        : hidden("git-conflicts", "No conflicting paths reported", "idle"),
    pr: pullRequest(state, p),
    activity: activity(state, p),
    diagnostics: diagnostics(state, p),
    tasks: tasks(task, p),
    blocked: task.blocked
      ? available("blocked", p(styles.warning, ` ${task.blocked}`))
      : hidden("blocked", "No blocked tasks", "idle"),
    agents: agents(state, p),
    pending: state.pending
      ? available("pending", p(styles.activity, " pending"))
      : hidden("pending", "No queued messages", "idle"),
    planning: planning(state, p, symbols),
    ci:
      pr?.ci !== undefined && (pr.ci.failedCount ?? 0) > 0
        ? available(
            "ci",
            link(p(styles.error, ` ${pr.ci.failedCount} failed`), pr.ci.url),
          )
        : hidden(
            "ci",
            "No CI failures reported; not a healthy integration claim",
          ),
    reviews:
      pr !== undefined && pr.unresolvedThreadCount > 0
        ? available(
            "reviews",
            link(
              p(styles.warning, ` ${pr.unresolvedThreadCount}`),
              pr.target.url,
            ),
          )
        : hidden("reviews", "No unresolved review threads reported"),
    statuses: statuses(state, p, symbols),
    quota: quota(state, p),
    cache:
      state.usage.latestHit === undefined
        ? hidden("cache", "No latest-request cache denominator")
        : available(
            "cache",
            p(styles.detail, ` ${state.usage.latestHit.toFixed(1)}%`),
            {
              details: [
                "Latest active-branch request, not whole-session cache rate or invoice savings",
              ],
            },
          ),
    cost: measured
      ? available("cost", p(styles.detail, cost(state.usage)), {
          details: [
            "Whole-session scope, including abandoned branches and reported tool usage",
            costSource,
          ],
        })
      : hidden("cost", "Initial zero cost suppressed", "idle"),
    "auxiliary-cost": hasAux
      ? available("auxiliary-cost", p(styles.detail, ` ${cost(aux)}`), {
          details: ["Separate auxiliary scope, not added to session cost"],
        })
      : hidden("auxiliary-cost", "No auxiliary usage", "idle"),
    age:
      measured || state.now - state.startedAt >= 60_000
        ? available(
            "age",
            p(styles.detail, ` ${duration(state.now - state.startedAt)}`),
          )
        : hidden("age", "Initial idle age suppressed", "idle"),
    input: available(
      "input",
      p(styles.detail, `↑${tokens(state.usage.input)}`),
    ),
    output: available(
      "output",
      p(styles.detail, `↓${tokens(state.usage.output)}`),
    ),
    "cache-read": available(
      "cache-read",
      p(styles.detail, `cache read ${tokens(state.usage.cacheRead)}`),
    ),
    "cache-write": available(
      "cache-write",
      p(styles.detail, `cache write ${tokens(state.usage.cacheWrite)}`),
    ),
    "run-duration": time("run-duration", state.activity.runningSince, "run"),
    "active-duration": available(
      "active-duration",
      p(
        styles.detail,
        `active ${duration(state.activity.activeMs + (state.activity.activeSince === undefined ? 0 : state.now - state.activity.activeSince))}`,
      ),
      {
        details: [
          `Observed since ${new Date(state.activity.observedSince).toISOString()}`,
        ],
      },
    ),
    "compaction-duration": time(
      "compaction-duration",
      state.activity.compactingSince,
      "compacting",
    ),
  };
}
