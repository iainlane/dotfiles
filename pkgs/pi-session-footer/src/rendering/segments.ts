import type { Theme } from "@earendil-works/pi-coding-agent";
import { basename, sep } from "node:path";
import { inactivity } from "#footer/domain/activity.ts";
import {
  contextStyle,
  gitStyle,
  quotaStyle,
  styles,
  thinkingStyle,
  type FooterStyle,
} from "./palette.ts";
import { quotaWindows } from "#footer/domain/quota.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";
import {
  DEFAULT_SYMBOLS,
  sourceSymbol,
  type SegmentId,
} from "#footer/configuration/settings.ts";
import { duration, text, tokens } from "#footer/shared/text.ts";
import {
  SegmentPainter,
  type SegmentText,
  type TextRun,
  type PaintTheme,
} from "./segment-text.ts";
import type { SymbolSetting } from "#footer/configuration/appearance.ts";
import { taskSummary } from "#footer/domain/workflow.ts";

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
  tokens: readonly (readonly TextRun[])[];
  priority: number;
  detailPriority?: number;
}
export interface Reading {
  id: SegmentId;
  state: "available" | "unavailable" | "idle" | "superseded";
  reason: string;
  parts: SegmentPart[];
  details: string[];
  summary?: string[];
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
const empty: SegmentText = { value: "", runs: [] };
function part(
  key: string,
  alternatives: readonly SegmentText[],
  priority: number,
  detailPriority?: number,
): SegmentPart {
  const result: SegmentPart = {
    key,
    variants: alternatives.map((value) => value.value),
    tokens: alternatives.map((value) => value.runs),
    priority,
  };
  if (detailPriority !== undefined) {
    result.detailPriority = detailPriority;
  }
  return result;
}
function available(
  id: SegmentId,
  value: SegmentText,
  options: {
    compact?: SegmentText;
    short?: SegmentText;
    details?: string[];
    summary?: string[];
    priority?: number;
  } = {},
): Reading {
  const alternatives: SegmentText[] = [];
  for (const variant of [value, options.compact, options.short]) {
    if (
      variant !== undefined &&
      !alternatives.some((choice) => choice.value === variant.value)
    ) {
      alternatives.push(variant);
    }
  }
  alternatives.push(empty);
  return {
    id,
    state: "available",
    reason: "",
    details: options.details ?? [],
    ...(options.summary === undefined ? {} : { summary: options.summary }),
    parts: [part(id, alternatives, options.priority ?? SEGMENTS[id].priority)],
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
  p: SegmentPainter,
): Reading {
  const cwd =
    home !== undefined &&
    home !== "" &&
    (state.cwd === home || state.cwd.startsWith(home + sep))
      ? "~" + state.cwd.slice(home.length)
      : state.cwd;
  const prefix = p.symbol(styles.directory, "", " ", { primary: true });
  return available(
    "directory",
    p.concat(prefix, p.text(styles.directory, text(cwd))),
    {
      compact: p.concat(
        prefix,
        p.text(styles.directory, text(basename(state.cwd))),
      ),
      details: [state.cwd],
    },
  );
}
function model(state: FooterSnapshot, p: SegmentPainter): Reading {
  if (!state.model || ["unknown", "no model"].includes(state.model)) {
    return hidden("model", "No known model selected");
  }
  const provider =
    state.provider === "openai-codex" ? "codex" : text(state.provider);
  const name = text(state.model);
  const prefix = p.symbol(styles.label, "", " ", {
    primary: true,
    role: "model",
  });
  return available(
    "model",
    p.concat(
      prefix,
      provider
        ? p.text(styles.provider, provider + "/", { role: "provider" })
        : "",
      p.text(styles.model, name, { role: "model" }),
    ),
    {
      compact: p.concat(prefix, p.text(styles.model, name, { role: "model" })),
      short: p.concat(
        prefix,
        p.text(styles.model, text(name, 12), { role: "model" }),
      ),
    },
  );
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
function thinking(state: FooterSnapshot, p: SegmentPainter): Reading {
  if (!state.reasoning || !state.thinking || state.model === "no model") {
    return hidden(
      "thinking",
      "Native model does not report reasoning capability",
    );
  }
  const symbol = THINKING_GLYPHS.find(
    ([level]) => level === state.thinking,
  )?.[1];
  const style = thinkingStyle(state.thinking);
  const options = { role: symbol === undefined ? undefined : state.thinking };
  const label = p.text(style, text(state.thinking), options);
  const details = ["Applicability comes from native model.reasoning"];
  if (symbol === undefined) {
    return available("thinking", label, { details });
  }
  const compact = p.symbol(style, symbol, "", options);
  if (state.thinking === "off") {
    return available("thinking", compact, { details });
  }
  return available(
    "thinking",
    p.concat(p.symbol(style, symbol, " ", options), label),
    { compact, details },
  );
}
function context(state: FooterSnapshot, p: SegmentPainter): Reading {
  const { percent, capacity } = state.context;
  if (percent === null && !capacity) {
    return hidden("context", "Context usage and capacity unavailable");
  }
  const label = p.symbol(styles.label, "◫", " ", { primary: true });
  const details = [
    `Active branch context; ${state.context.tokens ?? "unknown"} tokens; capacity ${capacity || "unknown"}`,
  ];
  if (percent === null) {
    return available(
      "context",
      p.concat(
        label,
        p.text(styles.detail, tokens(capacity), { role: "capacity" }),
      ),
      { details },
    );
  }
  let role = "used";
  if (percent >= 75) {
    role = "warning";
  }
  if (percent >= 90) {
    role = "error";
  }
  const value = p.concat(
    label,
    p.text(contextStyle(percent), `${percent.toFixed(1)}%`, {
      role,
      attention: percent >= 75,
    }),
  );
  return available(
    "context",
    p.concat(
      value,
      capacity
        ? p.text(styles.detail, `/${tokens(capacity)}`, { role: "capacity" })
        : "",
    ),
    { compact: value, details },
  );
}
function git(state: FooterSnapshot, p: SegmentPainter): Reading {
  const g = state.git;
  if (!g) {
    if (state.gitError !== undefined && state.gitError !== "") {
      return available(
        "git",
        p.symbol(styles.error, "", ` ⚠ ${text(state.gitError)}`, {
          role: "error",
          primary: true,
          attention: true,
        }),
        { details: [state.gitError], priority: 120 },
      );
    }
    return hidden("git", "No repository reading");
  }
  const counts = [
    [g.staged, "✚", styles.success, "staged"],
    [g.unstaged, "✎", styles.warning, "modified"],
    [g.untracked, "?", styles.label, "untracked"],
    [g.ahead, "↑", styles.label, "ahead"],
    [g.behind, "↓", styles.label, "behind"],
  ] as const;
  const branch = p.text(gitStyle(g), text(g.branch), {
    role: "branch",
    attention: g.stale || g.conflicts > 0,
  });
  const full = p.join([
    p.symbol(styles.label, "", "", { primary: true, role: "branch" }),
    branch,
    ...counts.flatMap(([count, symbol, style, role]) =>
      count ? [p.symbol(style, symbol, String(count), { role })] : [],
    ),
    g.stale
      ? p.text(styles.warning, "stale", { role: "stale", attention: true })
      : empty,
  ]);
  return available("git", full, {
    compact: p.concat(
      p.symbol(styles.label, "", " ", { primary: true, role: "branch" }),
      p.text(gitStyle(g), text(g.branch, 16), {
        role: "branch",
        attention: g.stale || g.conflicts > 0,
      }),
    ),
    details: [
      "Counts are paths and commits, not line changes",
      `Git data: ${g.stale ? "stale" : "fresh"}`,
      state.gitError ?? "No error reported",
    ],
  });
}
function activity(state: FooterSnapshot, p: SegmentPainter): Reading {
  const a = state.activity;
  const inactive = inactivity(a, state.now);
  if (a.waiting) {
    return available(
      "activity",
      p.symbol(styles.warning, "", " awaiting input", {
        role: "waiting",
        attention: true,
      }),
      {
        compact: p.symbol(styles.warning, "", " input!", {
          role: "waiting",
          attention: true,
        }),
      },
    );
  }
  if (a.compacting) {
    return available(
      "activity",
      p.symbol(styles.activity, "󰁯", " compacting", { role: "compacting" }),
    );
  }
  if (a.tool !== undefined && a.tool !== "") {
    return available(
      "activity",
      p.symbol(styles.tool, "", ` ${text(a.tool)}`, { role: "tool" }),
      { priority: 60 },
    );
  }
  if (a.outcome === "failed" || a.outcome === "cancelled") {
    return available(
      "activity",
      p.symbol(
        a.outcome === "failed" ? styles.error : styles.warning,
        a.outcome === "failed" ? "✗" : "⊘",
        ` run ${a.outcome}`,
        { role: a.outcome, attention: true },
      ),
    );
  }
  if (inactive !== undefined && inactive !== "") {
    return available(
      "activity",
      p.symbol(styles.warning, "◷", ` no content ${inactive}`, {
        role: "no-content",
        attention: true,
      }),
      {
        compact: p.symbol(styles.warning, "◷", " waiting", {
          role: "no-content",
          attention: true,
        }),
      },
    );
  }
  return hidden("activity", "No active attention state", "idle");
}
function diagnostics(state: FooterSnapshot, p: SegmentPainter): Reading {
  const d = state.diagnostics.summary();
  if (!d.errors && !d.warnings && !d.pending) {
    return hidden(
      "diagnostics",
      d.observed
        ? "No received findings; not a workspace-wide verdict"
        : "No diagnostics received",
    );
  }
  return available(
    "diagnostics",
    p.concat(
      p.symbol(d.errors ? styles.error : styles.detail, "⊗", String(d.errors), {
        role: "error",
        attention: d.errors > 0,
      }),
      " ",
      p.symbol(
        d.warnings ? styles.warning : styles.detail,
        "⚠",
        String(d.warnings),
        { role: "warning", attention: d.warnings > 0 },
      ),
      p.text(
        styles.warning,
        `${d.truncated ? "+" : ""}${d.pending ? " pending" : ""}`,
        { role: "pending", attention: true },
      ),
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
function quota(state: FooterSnapshot, p: SegmentPainter): Reading {
  const windows = quotaWindows(state.quota, state.now);
  const parts = windows
    .filter((w) => w.used !== undefined)
    .map((w, index) => {
      const base = p.concat(
        p.symbol(styles.label, "◴", ` ${w.label.toLowerCase()}`, {
          primary: true,
          role: "used",
        }),
        " ",
        p.text(quotaStyle(w.freshness), `${Math.round(w.used ?? 0)}%`, {
          role: "used",
          attention: w.freshness !== "fresh",
        }),
      );
      const freshness =
        w.freshness === "fresh"
          ? empty
          : p.text(styles.warning, ` ${w.freshness}`, {
              role: "stale",
              attention: true,
            });
      const reset =
        w.reset !== undefined && w.reset !== ""
          ? p.concat(
              p.text(styles.detail, " ", { role: "reset" }),
              p.symbol(styles.detail, "↻", w.reset, { role: "reset" }),
            )
          : empty;
      return part(
        `${index}:${w.label}`,
        [p.concat(base, reset, freshness), p.concat(base, freshness), empty],
        90,
        0,
      );
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
        p.symbol(styles.error, "◴", ` ⚠ ${text(state.quota.error)}`, {
          primary: true,
          role: "error",
          attention: true,
        }),
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
  return { id: "quota", state: "available", reason: "", parts, details };
}
function agents(state: FooterSnapshot, p: SegmentPainter): Reading {
  const a = state.agents;
  if (!a) {
    return hidden("agents", "No delegation publication");
  }
  const suffix = a.incomplete ? "+" : "";
  const stale = a.stale
    ? p.text(styles.warning, " stale", { role: "stale", attention: true })
    : empty;
  const parts: SegmentPart[] = [];
  if (a.active) {
    parts.push(
      part(
        "active",
        [
          p.concat(
            p.symbol(styles.workflow, "", ` ${a.active}`, {
              primary: true,
              role: "active",
            }),
            stale,
          ),
          empty,
        ],
        70,
      ),
    );
  }
  if (a.failed) {
    parts.push(
      part(
        "failed",
        [
          p.concat(
            p.symbol(styles.error, "", ` failed ${a.failed}${suffix}`, {
              primary: true,
              role: "failed",
              attention: true,
            }),
            stale,
          ),
          empty,
        ],
        120,
      ),
    );
  }
  if (a.paused) {
    parts.push(
      part(
        "paused",
        [
          p.concat(
            p.symbol(styles.warning, "", ` paused ${a.paused}${suffix}`, {
              primary: true,
              role: "paused",
              attention: true,
            }),
            stale,
          ),
          empty,
        ],
        110,
      ),
    );
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
  p: SegmentPainter,
  symbols: ReadonlyMap<string, SymbolSetting>,
): Reading {
  const parts: SegmentPart[] = [];
  const messages: string[] = [];
  const selected: string[] = [];
  for (const [source, status] of state.cooperativeStatuses) {
    if (source === "planning" || !status.active) {
      continue;
    }
    const symbol = sourceSymbol(symbols, source);
    const tail =
      status.text !== undefined && status.text !== "" ? ` ${status.text}` : "";
    parts.push(
      part(
        source,
        [
          p.symbol(styles.detail, symbol, tail, {
            role: "message",
            primary: true,
            source: symbols.get(source) ?? symbols.get("default"),
          }),
          empty,
        ],
        SEGMENTS.statuses.priority,
      ),
    );
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
    parts.push(
      part(
        key,
        [
          p.symbol(
            failure ? styles.error : styles.detail,
            symbol,
            ` ${message}`,
            {
              role: failure ? "error" : "message",
              primary: true,
              attention: failure,
              source: symbols.get(key) ?? symbols.get("default"),
            },
          ),
          empty,
        ],
        failure ? 120 : SEGMENTS.statuses.priority,
      ),
    );
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
  p: SegmentPainter,
  symbols: ReadonlyMap<string, SymbolSetting>,
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
        p.symbol(styles.activity, symbol, detail ? ` ${detail}` : "", {
          primary: true,
          source: symbols.get("planning") ?? symbols.get("default"),
        }),
      ),
      symbols: symbol,
    };
  }
  return { ...hidden("planning", "No planning publication"), symbols: symbol };
}
function cost(u: FooterSnapshot["usage"]): string {
  return `${u.costFromProvider ? "$" : "≈$"}${u.cost.toFixed(2)}`;
}
function pullRequest(state: FooterSnapshot, p: SegmentPainter): Reading {
  const source = state.pr;
  if (!source?.pullRequest) {
    return hidden("pr", "No pull request publication");
  }
  const pr = source.pullRequest;
  const blocked = ["blocked", "conflicting"].includes(pr.mergeState);
  let style: FooterStyle = blocked ? styles.error : styles.pullRequest;
  if (source.health !== "ok") {
    style = styles.detail;
  }
  let role = "number";
  if (blocked) {
    role = "blocked";
  }
  if (pr.mergeState === "conflicting") {
    role = "conflicting";
  }
  if (source.health !== "ok") {
    role = "unavailable";
  }
  return available(
    "pr",
    p.link(
      p.symbol(style, "", ` #${pr.target.number}`, {
        primary: true,
        role,
        attention: blocked || source.health !== "ok",
      }),
      pr.target.url,
    ),
    {
      details: [
        `Source ${source.health}; updated ${new Date(source.updatedAt).toISOString()}`,
      ],
    },
  );
}
function tasks(
  summary: ReturnType<typeof taskSummary>,
  p: SegmentPainter,
): Reading {
  if (summary.total <= summary.completed) {
    return hidden("tasks", "No unfinished tasks", "idle");
  }
  const progress = p.concat(
    p.symbol(styles.label, "☑", " ", { primary: true, role: "progress" }),
    p.text(styles.workflow, `${summary.completed}/${summary.total}`, {
      role: "progress",
    }),
  );
  const current =
    summary.current !== undefined && summary.current !== ""
      ? p.text(styles.text, ` ${summary.current}`, { role: "current" })
      : empty;
  return available("tasks", p.concat(progress, current), {
    compact: current.value === "" ? undefined : p.concat(progress, "…"),
  });
}
export function readSegments(
  state: FooterSnapshot,
  {
    theme,
    home,
    symbols = DEFAULT_SYMBOLS,
  }: {
    theme?: PaintTheme;
    home?: string;
    symbols?: ReadonlyMap<string, SymbolSetting>;
  } = {},
): Readings {
  const p = new SegmentPainter(theme);
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
          p.text(styles.detail, `${label} ${duration(state.now - start)}`),
        );
  return {
    model: model(state, p),
    thinking: thinking(state, p),
    directory: directory(state, home, p),
    context: context(state, p),
    git: git(state, p),
    tier:
      state.serviceTier !== undefined && state.serviceTier !== ""
        ? available("tier", p.text(styles.serviceTier, text(state.serviceTier)))
        : hidden("tier", "No service tier publication"),
    "git-operation":
      state.git?.operation !== undefined && state.git.operation !== ""
        ? available(
            "git-operation",
            p.symbol(styles.warning, "↻", ` ${text(state.git.operation)}`, {
              primary: true,
              role: "operation",
              attention: true,
            }),
          )
        : hidden("git-operation", "No operation reported", "idle"),
    "git-conflicts":
      (state.git?.conflicts ?? 0) > 0
        ? available(
            "git-conflicts",
            p.symbol(styles.error, "⚠", ` conflicts ${state.git?.conflicts}`, {
              primary: true,
              role: "error",
              attention: true,
            }),
          )
        : hidden("git-conflicts", "No conflicting paths reported", "idle"),
    pr: pullRequest(state, p),
    activity: activity(state, p),
    diagnostics: diagnostics(state, p),
    tasks: tasks(task, p),
    blocked: task.blocked
      ? available(
          "blocked",
          p.symbol(styles.warning, "", ` ${task.blocked}`, {
            primary: true,
            role: "blocked",
            attention: true,
          }),
        )
      : hidden("blocked", "No blocked tasks", "idle"),
    agents: agents(state, p),
    pending: state.pending
      ? available(
          "pending",
          p.symbol(styles.activity, "", " pending", { primary: true }),
        )
      : hidden("pending", "No queued messages", "idle"),
    planning: planning(state, p, symbols),
    ci:
      pr?.ci !== undefined && (pr.ci.failedCount ?? 0) > 0
        ? available(
            "ci",
            p.link(
              p.symbol(styles.error, "", ` ${pr.ci.failedCount} failed`, {
                primary: true,
                role: "failed",
                attention: true,
              }),
              pr.ci.url,
            ),
          )
        : hidden("ci", "No CI failures reported"),
    reviews:
      pr !== undefined && pr.unresolvedThreadCount > 0
        ? available(
            "reviews",
            p.link(
              p.symbol(styles.warning, "", ` ${pr.unresolvedThreadCount}`, {
                primary: true,
                role: "unresolved",
                attention: true,
              }),
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
            p.symbol(
              styles.detail,
              "",
              ` ${state.usage.latestHit.toFixed(1)}%`,
              { primary: true },
            ),
            {
              summary:
                state.cachePrompt === undefined
                  ? []
                  : [
                      `${state.cachePrompt.cached.toLocaleString("en-GB")} of ${state.cachePrompt.total.toLocaleString("en-GB")} prompt tokens cached`,
                    ],
              details: [
                "Latest active-branch request, not whole-session cache rate or invoice savings",
              ],
            },
          ),
    cost: measured
      ? available("cost", p.text(styles.detail, cost(state.usage)), {
          details: [
            "Whole-session scope, including abandoned branches and reported tool usage",
            costSource,
          ],
        })
      : hidden("cost", "Initial zero cost suppressed", "idle"),
    "auxiliary-cost": hasAux
      ? available(
          "auxiliary-cost",
          p.symbol(styles.detail, "", ` ${cost(aux)}`, { primary: true }),
          { details: ["Separate auxiliary scope, not added to session cost"] },
        )
      : hidden("auxiliary-cost", "No auxiliary usage", "idle"),
    age:
      measured || state.now - state.startedAt >= 60_000
        ? available(
            "age",
            p.symbol(
              styles.detail,
              "",
              ` ${duration(state.now - state.startedAt)}`,
              { primary: true },
            ),
          )
        : hidden("age", "Initial idle age suppressed", "idle"),
    input: available(
      "input",
      p.symbol(styles.detail, "↑", tokens(state.usage.input), {
        primary: true,
      }),
    ),
    output: available(
      "output",
      p.symbol(styles.detail, "↓", tokens(state.usage.output), {
        primary: true,
      }),
    ),
    "cache-read": available(
      "cache-read",
      p.text(styles.detail, `cache read ${tokens(state.usage.cacheRead)}`),
    ),
    "cache-write": available(
      "cache-write",
      p.text(styles.detail, `cache write ${tokens(state.usage.cacheWrite)}`),
    ),
    "run-duration": time("run-duration", state.activity.runningSince, "run"),
    "active-duration": available(
      "active-duration",
      p.text(
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
