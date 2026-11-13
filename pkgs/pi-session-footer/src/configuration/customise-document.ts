import {
  parseSymbol,
  type Appearance,
  type Colour,
  type SymbolAlias,
  type SymbolSetting,
  type WidgetAppearance,
} from "./appearance.ts";
import {
  parsePresentationDocument,
  resolveSettings,
  widgetId,
  REGIONS,
  type Preset,
  type PresentationDocument,
  type Region,
  type SegmentId,
  type WidgetPlacement,
} from "./settings.ts";

export class WidgetNotInRegionError extends Error {
  readonly region: Region;
  readonly id: SegmentId;

  constructor(region: Region, id: SegmentId) {
    super("The widget is no longer in this row");
    this.region = region;
    this.id = id;
    this.name = "WidgetNotInRegionError";
  }
}

export type AppearanceTarget =
  | { kind: "placement"; region: Region; id: SegmentId; role?: string }
  | { kind: "source"; key: string };
export type SymbolEdit =
  | { kind: "default" }
  | { kind: "literal"; text: string }
  | { kind: "alias"; alias: SymbolAlias }
  | { kind: "colour"; value: Colour | undefined };

export function profileDocument(
  input: PresentationDocument,
  preset: Preset,
  keepRows: boolean,
): PresentationDocument {
  const document = structuredClone(input);
  if (input.preset !== undefined || preset !== "rich") {
    document.preset = preset;
  }
  if (!keepRows) {
    for (const region of REGIONS) {
      delete document[region];
    }
  }
  return parsePresentationDocument(document);
}
export function regionDocument(
  input: PresentationDocument,
  region: Region,
  change: (values: WidgetPlacement[]) => void,
): PresentationDocument {
  const document = parsePresentationDocument(input);
  const inherited = resolveSettings(document).regions[region];
  const placements = structuredClone([...inherited]);
  change(placements);
  const result = parsePresentationDocument({
    ...document,
    [region]: placements,
  });
  if (
    document[region] === undefined &&
    JSON.stringify(resolveSettings(result).regions[region]) ===
      JSON.stringify(inherited)
  ) {
    return document;
  }
  return result;
}
function placement(
  input: PresentationDocument,
  target: Extract<AppearanceTarget, { kind: "placement" }>,
): WidgetPlacement {
  const value = resolveSettings(input).regions[target.region].find(
    (item) => widgetId(item) === target.id,
  );
  if (value === undefined) {
    throw new WidgetNotInRegionError(target.region, target.id);
  }
  return value;
}
export function decoration(
  input: PresentationDocument,
  target: AppearanceTarget,
): Appearance {
  if (target.kind === "source") {
    return { symbol: input.symbols?.[target.key] };
  }
  const item = placement(input, target);
  if (typeof item === "string") {
    return {};
  }
  if (target.role !== undefined) {
    return item.roles?.[target.role] ?? {};
  }
  return { colour: item.colour, symbol: item.symbol };
}
export function decorationDocument(
  input: PresentationDocument,
  target: AppearanceTarget,
  value: Appearance,
): PresentationDocument {
  if (target.kind === "source") {
    const document = structuredClone(input);
    const symbols = new Map(Object.entries(document.symbols ?? {}));
    if (value.symbol === undefined) {
      symbols.delete(target.key);
    } else {
      symbols.set(target.key, value.symbol);
    }
    document.symbols = Object.fromEntries(symbols);
    return parsePresentationDocument(document);
  }
  return regionDocument(input, target.region, (items) => {
    const index = items.findIndex((item) => widgetId(item) === target.id);
    const item = items[index];
    if (item === undefined) {
      throw new WidgetNotInRegionError(target.region, target.id);
    }
    const appearance: WidgetAppearance =
      typeof item === "string" ? {} : { ...item };
    if (target.role === undefined) {
      delete appearance.colour;
      delete appearance.symbol;
      if (value.colour !== undefined) {
        appearance.colour = value.colour;
      }
      if (value.symbol !== undefined) {
        appearance.symbol = value.symbol;
      }
    } else {
      const roles = new Map<string, Appearance>([
        ...Object.entries(appearance.roles ?? {}),
        [target.role, value],
      ]);
      appearance.roles = Object.fromEntries(roles);
    }
    items[index] = { ...appearance, id: target.id };
  });
}
export function symbolDocument(
  input: PresentationDocument,
  target: AppearanceTarget,
  edit: SymbolEdit,
): PresentationDocument {
  const current = decoration(input, target);
  const symbol =
    typeof current.symbol === "string"
      ? { text: current.symbol }
      : { ...current.symbol };
  if (
    edit.kind === "default" ||
    edit.kind === "literal" ||
    edit.kind === "alias"
  ) {
    delete symbol.text;
    delete symbol.alias;
  }
  if (edit.kind === "literal") {
    symbol.text = edit.text;
  }
  if (edit.kind === "alias") {
    symbol.alias = edit.alias;
  }
  if (edit.kind === "colour") {
    delete symbol.colour;
    if (edit.value !== undefined) {
      symbol.colour = edit.value;
    }
  }
  return decorationDocument(input, target, {
    ...current,
    symbol: parseSymbol(symbol, "symbol"),
  });
}
export function textColourDocument(
  input: PresentationDocument,
  target: AppearanceTarget,
  colour: Colour | undefined,
): PresentationDocument {
  const current = { ...decoration(input, target) };
  delete current.colour;
  if (colour !== undefined) {
    current.colour = colour;
  }
  return decorationDocument(input, target, current);
}
export function resetAppearanceDocument(
  input: PresentationDocument,
  target: AppearanceTarget,
): PresentationDocument {
  if (target.kind === "source" || target.role !== undefined) {
    return decorationDocument(input, target, {});
  }
  return regionDocument(input, target.region, (items) => {
    const index = items.findIndex((item) => widgetId(item) === target.id);
    if (index < 0) {
      throw new WidgetNotInRegionError(target.region, target.id);
    }
    items[index] = target.id;
  });
}
export function symbolColour(
  setting: SymbolSetting | undefined,
): Colour | undefined {
  return typeof setting === "object" ? setting.colour : undefined;
}
