import type { ThemeColor } from "@earendil-works/pi-coding-agent";
import { visibleWidth } from "@earendil-works/pi-tui";
import type { SegmentId } from "./settings.ts";
import { record, text } from "#footer/shared/text.ts";
import {
  ExpectedObjectError,
  InlineTextTooWideError,
  InvalidColourError,
  InvalidInlineTextError,
  MultiColumnSymbolError,
  SymbolNotAllowedError,
  SymbolTextAndAliasError,
  TextColourNotAllowedError,
  UnknownSettingError,
  UnknownSymbolAliasError,
  UnknownWidgetPartError,
} from "./settings-errors.ts";

export const FOREGROUND_COLOURS = {
  accent: "Accent",
  border: "Border",
  borderAccent: "Border accent",
  borderMuted: "Border muted",
  success: "Success",
  error: "Error",
  warning: "Warning",
  muted: "Muted",
  dim: "Dim",
  text: "Text",
  thinkingText: "Thinking text",
  scrollbarTrack: "Scrollbar track",
  scrollbarThumb: "Scrollbar thumb",
  searchMatchText: "Search match text",
  userMessageText: "User message text",
  customMessageText: "Extension message text",
  customMessageLabel: "Extension message label",
  toolTitle: "Tool title",
  toolOutput: "Tool output",
  mdHeading: "Markdown heading",
  mdLink: "Markdown link",
  mdLinkUrl: "Markdown link URL",
  mdCode: "Markdown inline code",
  mdCodeBlock: "Markdown code block",
  mdCodeBlockBorder: "Markdown code border",
  mdQuote: "Markdown quotation",
  mdQuoteBorder: "Markdown quotation border",
  mdHr: "Markdown rule",
  mdListBullet: "Markdown list bullet",
  toolDiffAdded: "Added lines",
  toolDiffRemoved: "Removed lines",
  toolDiffContext: "Diff context",
  syntaxComment: "Syntax comment",
  syntaxKeyword: "Syntax keyword",
  syntaxFunction: "Syntax function",
  syntaxVariable: "Syntax variable",
  syntaxString: "Syntax string",
  syntaxNumber: "Syntax number",
  syntaxType: "Syntax type",
  syntaxOperator: "Syntax operator",
  syntaxPunctuation: "Syntax punctuation",
  thinkingOff: "Thinking off",
  thinkingMinimal: "Thinking minimal",
  thinkingLow: "Thinking low",
  thinkingMedium: "Thinking medium",
  thinkingHigh: "Thinking high",
  thinkingXhigh: "Thinking xhigh",
  thinkingMax: "Thinking max",
  bashMode: "Bash mode",
} satisfies Record<ThemeColor, string>;
export type Colour = ThemeColor | `#${string}`;

export const SYMBOL_ALIASES = {
  model: "",
  directory: "",
  git: "",
  "git.staged": "✚",
  "git.modified": "✎",
  "git.untracked": "?",
  "git.ahead": "↑",
  "git.behind": "↓",
  "git.operation": "↻",
  "git.conflicts": "⚠",
  "thinking.off": "⊘",
  "thinking.minimal": "○",
  "thinking.low": "◔",
  "thinking.medium": "◑",
  "thinking.high": "◒",
  "thinking.xhigh": "◕",
  "thinking.max": "◉",
  context: "◫",
  "activity.tool": "",
  "activity.waiting": "",
  "activity.compacting": "󰁯",
  "activity.failed": "✗",
  "activity.cancelled": "⊘",
  "activity.no-content": "◷",
  "diagnostics.error": "⊗",
  "diagnostics.warning": "⚠",
  tasks: "☑",
  blocked: "",
  agents: "",
  pending: "",
  planning: "≡",
  status: "◇",
  pr: "",
  ci: "",
  reviews: "",
  quota: "◴",
  reset: "↻",
  cache: "",
  auxiliary: "",
  age: "",
} as const;
export type SymbolAlias = keyof typeof SYMBOL_ALIASES;
export interface SymbolAppearance {
  text?: string;
  alias?: SymbolAlias;
  colour?: Colour;
}
export type SymbolSetting = string | SymbolAppearance;
export interface Appearance {
  colour?: Colour;
  symbol?: SymbolSetting;
}
export interface WidgetAppearance extends Appearance {
  roles?: Readonly<Record<string, Appearance>>;
}
export interface RoleDefinition {
  label: string;
  symbol: boolean;
  text: boolean;
  symbolColumns?: 1;
}
const marker = (label: string): RoleDefinition => ({
  label,
  symbol: true,
  text: true,
});
const plain = (label: string): RoleDefinition => ({
  label,
  symbol: false,
  text: true,
});
export const WIDGET_ROLES: Readonly<
  Record<SegmentId, Readonly<Record<string, RoleDefinition>>>
> = {
  model: { model: marker("Model"), provider: plain("Provider") },
  thinking: {
    off: { ...marker("Off"), text: false },
    minimal: marker("Minimal"),
    low: marker("Low"),
    medium: marker("Medium"),
    high: marker("High"),
    xhigh: marker("Extra high"),
    max: marker("Maximum"),
  },
  tier: {},
  directory: {},
  git: {
    branch: marker("Branch"),
    staged: marker("Staged files"),
    modified: marker("Modified files"),
    untracked: marker("Untracked files"),
    ahead: marker("Ahead"),
    behind: marker("Behind"),
    stale: plain("Stale"),
    error: marker("Error"),
  },
  "git-operation": { operation: marker("Operation") },
  "git-conflicts": { error: marker("Conflicts") },
  pr: {
    number: marker("Number"),
    blocked: marker("Blocked"),
    conflicting: marker("Conflicting"),
    unavailable: marker("Source unavailable"),
  },
  context: {
    used: plain("Used"),
    capacity: plain("Capacity"),
    warning: plain("Warning"),
    error: plain("Error"),
    "gauge-used": { ...marker("Gauge used"), text: false, symbolColumns: 1 },
    "gauge-free": { ...marker("Gauge free"), text: false, symbolColumns: 1 },
  },
  activity: {
    tool: marker("Tool"),
    waiting: marker("Awaiting input"),
    compacting: marker("Compacting"),
    failed: marker("Failed"),
    cancelled: marker("Cancelled"),
    "no-content": marker("No content"),
  },
  diagnostics: {
    error: marker("Errors"),
    warning: marker("Warnings"),
    pending: plain("Pending files"),
  },
  tasks: { progress: marker("Progress"), current: plain("Current task") },
  blocked: { blocked: marker("Blocked tasks") },
  agents: {
    active: marker("Active"),
    failed: marker("Failed"),
    paused: marker("Paused"),
    stale: plain("Stale"),
  },
  pending: {},
  planning: {},
  ci: { failed: marker("Failed checks") },
  reviews: { unresolved: marker("Unresolved threads") },
  statuses: { message: marker("Message"), error: marker("Error") },
  quota: {
    used: marker("Used"),
    reset: marker("Reset"),
    stale: plain("Stale"),
    error: marker("Error"),
  },
  cache: {},
  cost: {},
  "auxiliary-cost": {},
  age: {},
  input: {},
  output: {},
  "cache-read": {},
  "cache-write": {},
  "run-duration": {},
  "active-duration": {},
  "compaction-duration": {},
};

export function settingsRecord(
  value: unknown,
  field: string,
  keys: readonly string[],
): Record<string, unknown> {
  if (!record(value)) {
    throw new ExpectedObjectError(field);
  }
  const extra = Object.keys(value).find((key) => !keys.includes(key));
  if (extra !== undefined) {
    throw new UnknownSettingError(`${field}.${text(extra, 80)}`);
  }
  return value;
}

export function isThemeColour(value: string): value is ThemeColor {
  return Object.hasOwn(FOREGROUND_COLOURS, value);
}
function isHexColour(value: string): value is `#${string}` {
  return /^#[\da-f]{6}$/i.test(value);
}
export function parseColour(value: unknown, field: string): Colour {
  if (
    typeof value === "string" &&
    (isThemeColour(value) || isHexColour(value))
  ) {
    return value;
  }
  throw new InvalidColourError(field);
}
export function parseInline(
  value: unknown,
  field: string,
  allowEmpty = false,
): string {
  if (
    typeof value !== "string" ||
    value.length > 64 ||
    /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(value) ||
    (value !== "" && visibleWidth(value) < 1) ||
    (!allowEmpty && (!value.trim() || value !== value.trim()))
  ) {
    throw new InvalidInlineTextError(field);
  }
  if (visibleWidth(value) > 8) {
    throw new InlineTextTooWideError(field);
  }
  return value;
}
function isSymbolAlias(value: unknown): value is SymbolAlias {
  return typeof value === "string" && Object.hasOwn(SYMBOL_ALIASES, value);
}
export function parseSymbol(
  value: unknown,
  field: string,
): SymbolSetting | undefined {
  if (typeof value === "string") {
    return parseInline(value, field);
  }
  const object = settingsRecord(value, field, ["text", "alias", "colour"]);
  if (object.text !== undefined && object.alias !== undefined) {
    throw new SymbolTextAndAliasError(field);
  }
  const result: SymbolAppearance = {};
  if (object.text !== undefined) {
    result.text = parseInline(object.text, `${field}.text`);
  }
  if (object.alias !== undefined) {
    if (!isSymbolAlias(object.alias)) {
      throw new UnknownSymbolAliasError(`${field}.alias`);
    }
    result.alias = object.alias;
  }
  if (object.colour !== undefined) {
    result.colour = parseColour(object.colour, `${field}.colour`);
  }
  if (result.colour === undefined && result.text !== undefined) {
    return result.text;
  }
  return Object.keys(result).length > 0 ? result : undefined;
}
export function symbolText(
  value: SymbolSetting | undefined,
  fallback: string,
): string {
  if (typeof value === "string") {
    return value;
  }
  if (value?.text !== undefined) {
    return value.text;
  }
  return value?.alias === undefined ? fallback : SYMBOL_ALIASES[value.alias];
}

function parseDecoration(
  value: Record<string, unknown>,
  field: string,
  symbolAllowed: boolean,
): Appearance {
  const result: Appearance = {};
  if (value.colour !== undefined) {
    result.colour = parseColour(value.colour, `${field}.colour`);
  }
  if (value.symbol !== undefined) {
    if (!symbolAllowed) {
      throw new SymbolNotAllowedError(`${field}.symbol`);
    }
    const symbol = parseSymbol(value.symbol, `${field}.symbol`);
    if (symbol !== undefined) {
      result.symbol = symbol;
    }
  }
  return result;
}
export function parseAppearance(
  value: unknown,
  field: string,
  id: SegmentId,
): WidgetAppearance {
  const object = settingsRecord(value, field, ["colour", "symbol", "roles"]);
  const result: WidgetAppearance = parseDecoration(object, field, true);
  if (object.roles === undefined) {
    return result;
  }
  if (!record(object.roles)) {
    throw new ExpectedObjectError(`${field}.roles`);
  }
  const definitions = WIDGET_ROLES[id];
  const roles = Object.entries(object.roles).flatMap(([key, role]) => {
    const definition = Object.hasOwn(definitions, key)
      ? definitions[key]
      : undefined;
    const location = `${field}.roles.${text(key, 80)}`;
    if (!definition) {
      throw new UnknownWidgetPartError(location);
    }
    const appearance = parseDecoration(
      settingsRecord(role, location, ["colour", "symbol"]),
      location,
      definition.symbol,
    );
    if (!definition.text && appearance.colour !== undefined) {
      throw new TextColourNotAllowedError(`${location}.colour`);
    }
    const symbol = symbolText(appearance.symbol, "");
    if (
      definition.symbolColumns === 1 &&
      symbol !== "" &&
      visibleWidth(symbol) !== 1
    ) {
      throw new MultiColumnSymbolError(`${location}.symbol`);
    }
    return Object.keys(appearance).length > 0
      ? [[key, appearance] as const]
      : [];
  });
  if (roles.length > 0) {
    result.roles = Object.fromEntries(roles);
  }
  return result;
}
