import {
  parseAppearance,
  parseInline,
  parseSymbol,
  settingsRecord,
  SettingsError,
  symbolText,
  type SymbolSetting,
  type WidgetAppearance,
} from "./appearance.ts";
import { record, text } from "#footer/shared/text.ts";

export const DEFAULT_SYMBOLS: ReadonlyMap<string, string> = new Map([
  ["planning", "≡"],
  ["default", "◇"],
]);
export function sourceSymbol(
  symbols: ReadonlyMap<string, SymbolSetting>,
  source: string,
): string {
  const fallback =
    DEFAULT_SYMBOLS.get(source) ?? symbolText(symbols.get("default"), "◇");
  return symbolText(symbols.get(source), fallback);
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
export type WidgetPlacement =
  | SegmentId
  | (WidgetAppearance & { id: SegmentId });
export function widgetId(placement: WidgetPlacement): SegmentId {
  return typeof placement === "string" ? placement : placement.id;
}
export const REGIONS = [
  "top-left",
  "top-right",
  "bottom-left",
  "bottom-right",
] as const;
export type Region = (typeof REGIONS)[number];
export const REGION_LABELS = {
  "top-left": "Top left",
  "top-right": "Top right",
  "bottom-left": "Bottom left",
  "bottom-right": "Bottom right",
} satisfies Record<Region, string>;
export type Regions = Record<Region, readonly WidgetPlacement[]>;
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
export interface Separators {
  widgets?: string;
  regions?: string;
}
export interface PresentationDocument extends Partial<Regions> {
  preset?: Preset;
  symbols?: Readonly<Record<string, SymbolSetting>>;
  separators?: Separators;
}
export interface SettingsDocument extends PresentationDocument {
  persistence?: "local" | "session";
}
export interface ResolvedSettings {
  preset: Preset;
  regions: Regions;
  overridden: Region[];
  symbols: ReadonlyMap<string, SymbolSetting>;
  separators: Separators;
  persistence: "local" | "session";
}
export interface LoadedSettings extends ResolvedSettings {
  path: string;
  source: "default" | "file" | "fallback";
  diagnostic: string | undefined;
  document: SettingsDocument;
}
export function isSegmentId(value: unknown): value is SegmentId {
  return SEGMENT_IDS.some((id) => id === value);
}
function parsePlacement(value: unknown, field: string): WidgetPlacement {
  if (isSegmentId(value)) {
    return value;
  }
  if (!record(value)) {
    throw new SettingsError(field, "Expected a built-in widget ID or object");
  }
  if (!isSegmentId(value.id)) {
    throw new SettingsError(`${field}.id`, "Unknown widget");
  }
  const appearance = parseAppearance(
    Object.fromEntries(Object.entries(value).filter(([key]) => key !== "id")),
    field,
    value.id,
  );
  return Object.keys(appearance).length === 0
    ? value.id
    : { id: value.id, ...appearance };
}
const PRESENTATION_KEYS = ["preset", "symbols", "separators", ...REGIONS];

function parseDocument(
  value: unknown,
  keys: readonly string[],
): SettingsDocument {
  const object = settingsRecord(value, "settings", keys);
  const document: SettingsDocument = {};
  if (object.preset !== undefined) {
    const preset = PRESET_IDS.find((id) => id === object.preset);
    if (preset === undefined) {
      throw new SettingsError("preset", "Unknown preset");
    }
    document.preset = preset;
  }
  for (const region of REGIONS) {
    const input = object[region];
    if (input === undefined) {
      continue;
    }
    if (!Array.isArray(input)) {
      throw new SettingsError(region, "Expected an array of widgets");
    }
    const placements = input.map((item: unknown, index) =>
      parsePlacement(item, `${region}[${index}]`),
    );
    if (
      new Set(placements.map((placement) => widgetId(placement))).size !==
      placements.length
    ) {
      throw new SettingsError(region, "Expected distinct widget IDs");
    }
    document[region] = placements;
  }
  if (object.symbols !== undefined) {
    if (!record(object.symbols)) {
      throw new SettingsError("symbols", "Expected an object");
    }
    const symbols = Object.entries(object.symbols).flatMap(
      ([source, input]) => {
        const symbol = parseSymbol(input, `symbols.${text(source, 80)}`);
        return symbol === undefined ? [] : [[source, symbol] as const];
      },
    );
    if (symbols.length > 0) {
      document.symbols = Object.fromEntries(symbols);
    }
  }
  if (object.separators !== undefined) {
    const input = settingsRecord(object.separators, "separators", [
      "widgets",
      "regions",
    ]);
    const separators: Separators = {};
    if (input.widgets !== undefined) {
      separators.widgets = parseInline(
        input.widgets,
        "separators.widgets",
        true,
      );
    }
    if (input.regions !== undefined) {
      separators.regions = parseInline(
        input.regions,
        "separators.regions",
        true,
      );
    }
    if (Object.keys(separators).length > 0) {
      document.separators = separators;
    }
  }
  if (object.persistence !== undefined) {
    if (object.persistence !== "local" && object.persistence !== "session") {
      throw new SettingsError("persistence", "Expected local or session");
    }
    document.persistence = object.persistence;
  }
  return document;
}
export function parseSettingsDocument(value: unknown): SettingsDocument {
  return parseDocument(value, [...PRESENTATION_KEYS, "persistence"]);
}
export function parsePresentationDocument(
  value: unknown,
): PresentationDocument {
  return parseDocument(value, PRESENTATION_KEYS);
}
export function presentationDocument(
  document: SettingsDocument,
): PresentationDocument {
  const { persistence: _persistence, ...presentation } = document;
  return presentation;
}
export function resolveSettings(value: unknown): ResolvedSettings {
  const document = parseSettingsDocument(value);
  const preset = document.preset ?? "rich";
  const inherited = PRESETS[preset];
  const regions: Regions = {
    "top-left": [...inherited["top-left"]],
    "top-right": [...inherited["top-right"]],
    "bottom-left": [...inherited["bottom-left"]],
    "bottom-right": [...inherited["bottom-right"]],
  };
  const overridden: Region[] = [];
  for (const region of REGIONS) {
    const placements = document[region];
    if (placements !== undefined) {
      regions[region] = [...placements];
      overridden.push(region);
    }
  }
  const symbols = new Map<string, SymbolSetting>(DEFAULT_SYMBOLS);
  for (const [source, symbol] of Object.entries(document.symbols ?? {})) {
    symbols.set(source, symbol);
  }
  return {
    preset,
    regions,
    overridden,
    symbols,
    separators: document.separators ?? {},
    persistence: document.persistence ?? "local",
  };
}
/**
 * Resolves presentation documents and reuses the result while it is given the
 * same document. Documents are replaced, never changed in place, so a new
 * document is always a new object.
 */
export class PresentationResolver {
  private last:
    | { document: PresentationDocument; settings: ResolvedSettings }
    | undefined;

  resolve(document: PresentationDocument): ResolvedSettings {
    if (this.last?.document !== document) {
      this.last = { document, settings: resolveSettings(document) };
    }

    return this.last.settings;
  }
}
export function loadSettings(
  read: () => string | undefined,
  path: string,
): LoadedSettings {
  try {
    const content = read();
    const document = parseSettingsDocument(
      content === undefined ? {} : JSON.parse(content),
    );
    return {
      ...resolveSettings(document),
      path,
      source: content === undefined ? "default" : "file",
      diagnostic: undefined,
      document,
    };
  } catch (error) {
    const detail =
      error instanceof SettingsError
        ? error.message
        : "Check file permissions and JSON syntax";
    return {
      ...resolveSettings({}),
      path,
      source: "fallback",
      diagnostic: `Cannot load ${path}. ${detail}; using built-in rich. See /footer config.`,
      document: {},
    };
  }
}
