import { visibleWidth } from "@earendil-works/pi-tui";
import { record } from "./text.ts";

export const DEFAULT_SYMBOLS: ReadonlyMap<string, string> = new Map([
  ["planning", "≡"],
  ["default", "◇"],
]);
export function sourceSymbol(
  symbols: ReadonlyMap<string, string>,
  source: string,
): string {
  return symbols.get(source) ?? symbols.get("default") ?? "◇";
}

export const SEGMENT_IDS = [
  "model",
  "thinking",
  "tier",
  "directory",
  "git",
  "git-operation",
  "git-conflicts",
  "pr",
  "context",
  "activity",
  "diagnostics",
  "tasks",
  "blocked",
  "agents",
  "pending",
  "planning",
  "ci",
  "reviews",
  "statuses",
  "quota",
  "cache",
  "cost",
  "auxiliary-cost",
  "age",
  "input",
  "output",
  "cache-read",
  "cache-write",
  "run-duration",
  "active-duration",
  "compaction-duration",
] as const;
export type SegmentId = (typeof SEGMENT_IDS)[number];
export const REGIONS = [
  "top-left",
  "top-right",
  "bottom-left",
  "bottom-right",
] as const;
export type Region = (typeof REGIONS)[number];
export type Regions = Record<Region, readonly SegmentId[]>;
const top: Pick<Regions, "top-left" | "top-right"> = {
  "top-left": [
    "model",
    "thinking",
    "tier",
    "directory",
    "git",
    "git-operation",
    "git-conflicts",
    "pr",
  ],
  "top-right": ["context"],
};
const workflow: readonly SegmentId[] = [
  "activity",
  "diagnostics",
  "tasks",
  "blocked",
  "agents",
  "pending",
  "planning",
  "ci",
  "reviews",
  "statuses",
];
export const PRESETS = {
  rich: {
    ...top,
    "bottom-left": workflow,
    "bottom-right": ["quota", "cache", "cost", "auxiliary-cost", "age"],
  },
  compact: { ...top, "bottom-left": [], "bottom-right": [] },
  minimal: {
    "top-left": ["directory", "git", "git-operation", "git-conflicts"],
    "top-right": ["context"],
    "bottom-left": [],
    "bottom-right": [],
  },
  workflow: { ...top, "bottom-left": workflow, "bottom-right": ["quota"] },
} as const satisfies Record<string, Regions>;
export type Preset = keyof typeof PRESETS;
export const PRESET_IDS = Object.keys(PRESETS).filter(
  (key): key is Preset => key in PRESETS,
);
export interface ResolvedSettings {
  preset: Preset;
  regions: Regions;
  overridden: Region[];
  symbols: ReadonlyMap<string, string>;
}
export interface LoadedSettings extends ResolvedSettings {
  path: string;
  source: "default" | "file" | "fallback";
  diagnostic: string | undefined;
}
export function isSegmentId(value: unknown): value is SegmentId {
  return SEGMENT_IDS.some((id) => id === value);
}
export function resolveSettings(value: unknown): ResolvedSettings {
  if (
    !record(value) ||
    Object.keys(value).some(
      (key) =>
        key !== "preset" &&
        key !== "symbols" &&
        !REGIONS.some((region) => region === key),
    )
  ) {
    throw new Error(
      "Expected preset, symbols and four optional region arrays only",
    );
  }
  const preset =
    value.preset === undefined
      ? "rich"
      : PRESET_IDS.find((id) => id === value.preset);
  if (!preset) {
    throw new Error("Unknown preset");
  }
  const inherited = PRESETS[preset];
  const regions: Regions = {
    "top-left": [...inherited["top-left"]],
    "top-right": [...inherited["top-right"]],
    "bottom-left": [...inherited["bottom-left"]],
    "bottom-right": [...inherited["bottom-right"]],
  };
  const overridden: Region[] = [];
  for (const region of REGIONS) {
    const ids = value[region];
    if (ids !== undefined) {
      if (
        !Array.isArray(ids) ||
        !ids.every((id): id is SegmentId => isSegmentId(id)) ||
        new Set(ids).size !== ids.length
      ) {
        throw new Error(`Expected distinct built-in segment IDs in ${region}`);
      }
      regions[region] = [...ids];
      overridden.push(region);
    }
  }
  const symbols = new Map(DEFAULT_SYMBOLS);
  if (value.symbols !== undefined) {
    if (!record(value.symbols)) {
      throw new Error("Expected a symbols object");
    }
    for (const [source, symbol] of Object.entries(value.symbols)) {
      if (
        typeof symbol !== "string" ||
        !symbol.trim() ||
        symbol !== symbol.trim() ||
        symbol.length > 64 ||
        /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(symbol) ||
        visibleWidth(symbol) < 1 ||
        visibleWidth(symbol) > 8
      ) {
        throw new Error("Expected safe inline symbols of one to eight columns");
      }
      symbols.set(source, symbol);
    }
  }
  return { preset, regions, overridden, symbols };
}
export function loadSettings(
  read: () => string | undefined,
  path: string,
): LoadedSettings {
  try {
    const content = read();
    return {
      ...resolveSettings(content === undefined ? {} : JSON.parse(content)),
      path,
      source: content === undefined ? "default" : "file",
      diagnostic: undefined,
    };
  } catch {
    return {
      ...resolveSettings({}),
      path,
      source: "fallback",
      diagnostic: `Cannot load ${path}. Check file permissions and JSON keys, preset and segment IDs; using built-in rich. See /footer config.`,
    };
  }
}
