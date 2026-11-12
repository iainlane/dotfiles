import type { Theme } from "@earendil-works/pi-coding-agent";
import {
  parseColor,
  sliceByColumn,
  visibleWidth,
} from "@earendil-works/pi-tui";
import {
  isThemeColour,
  symbolText,
  type Colour,
  type SymbolSetting,
  type WidgetAppearance,
} from "#footer/configuration/appearance.ts";
import { styles, type FooterStyle } from "./palette.ts";
import { link } from "#footer/shared/text.ts";

export type PaintTheme = Pick<Theme, "fg" | "bold" | "style">;
export interface RunOptions {
  role?: string;
  primary?: boolean;
  attention?: boolean;
  source?: SymbolSetting;
}
export type TextRun = TextSpan | LinkRun;
interface LinkRun {
  kind: "link";
  href: string;
  runs: readonly TextRun[];
}
interface TextSpan extends RunOptions {
  kind: "text" | "symbol";
  value: string;
  style?: FooterStyle;
  href?: string;
}
export interface SegmentText {
  value: string;
  runs: readonly TextRun[];
}
export interface PaintedSymbol {
  role: string | undefined;
  value: string;
  colour: Colour | undefined;
}
interface PaintGroup {
  value: string;
  colour: Colour | undefined;
  bold: boolean;
  href: string | undefined;
}
export interface PaintedRun extends PaintGroup {
  kind: TextSpan["kind"];
  role: string | undefined;
}
export interface PaintedText {
  value: string;
  symbols: PaintedSymbol[];
  runs: readonly PaintedRun[];
}
function symbolColour(setting: SymbolSetting | undefined): Colour | undefined {
  return typeof setting === "object" ? setting.colour : undefined;
}
function hasSymbolValue(setting: SymbolSetting | undefined): boolean {
  return (
    typeof setting === "string" ||
    setting?.text !== undefined ||
    setting?.alias !== undefined
  );
}
function paint(run: PaintGroup, theme: PaintTheme | undefined): string {
  let value = run.value;
  if (theme && run.colour !== undefined) {
    value = isThemeColour(run.colour)
      ? theme.fg(run.colour, value)
      : theme.style(value, { fg: parseColor(run.colour) });
  }
  if (theme && run.bold) {
    value = theme.bold(value);
  }
  return run.href === undefined ? value : link(value, run.href);
}
function materialise(
  runs: readonly PaintedRun[],
  theme: PaintTheme | undefined,
): PaintedText {
  const groups: PaintGroup[] = [];
  for (const run of runs) {
    const last = groups.at(-1);
    if (
      last &&
      last.colour === run.colour &&
      last.bold === run.bold &&
      last.href === run.href
    ) {
      last.value += run.value;
      continue;
    }
    groups.push({
      value: run.value,
      colour: run.colour,
      bold: run.bold,
      href: run.href,
    });
  }
  return {
    value: groups.map((group) => paint(group, theme)).join(""),
    runs,
    symbols: runs
      .filter((run) => run.kind === "symbol")
      .map(({ role, value, colour }) => ({ role, value, colour })),
  };
}
function* inlineRuns(
  runs: readonly TextRun[],
  href?: string,
): Generator<{ run: TextSpan; href: string | undefined }> {
  for (const run of runs) {
    if (run.kind === "link") {
      yield* inlineRuns(run.runs, run.href);
      continue;
    }
    yield { run, href: run.href ?? href };
  }
}
function resolveMarker(
  run: TextSpan,
  appearance: WidgetAppearance,
  primary: boolean,
): Pick<PaintedRun, "value" | "colour"> {
  const role =
    run.role === undefined ? undefined : appearance.roles?.[run.role];
  const main =
    run.attention !== true &&
    (run.primary === true || (!primary && !hasSymbolValue(appearance.symbol)))
      ? appearance.symbol
      : undefined;
  return {
    value: symbolText(role?.symbol ?? main, symbolText(run.source, run.value)),
    colour:
      symbolColour(role?.symbol) ??
      symbolColour(main) ??
      symbolColour(run.source) ??
      run.style?.color,
  };
}
function resolveSpan(
  entry: { run: TextSpan; href: string | undefined },
  appearance: WidgetAppearance,
  primary: boolean,
): PaintedRun {
  const { run, href } = entry;
  const marker =
    run.kind === "symbol" ? resolveMarker(run, appearance, primary) : undefined;
  let colour: Colour | undefined = run.style?.color;
  if (marker) {
    return {
      value: marker.value,
      colour: marker.colour,
      kind: run.kind,
      role: run.role,
      bold: run.style?.bold === true,
      href,
    };
  }
  if (run.style !== undefined) {
    const role =
      run.role === undefined ? undefined : appearance.roles?.[run.role];
    colour =
      role?.colour ??
      (run.attention === true ? undefined : appearance.colour) ??
      colour;
  }
  return {
    value: run.value,
    colour,
    kind: run.kind,
    role: run.role,
    bold: run.style?.bold === true,
    href,
  };
}
export function paintText(
  runs: readonly TextRun[],
  appearance: WidgetAppearance = {},
  theme?: PaintTheme,
): PaintedText {
  const painted: PaintedRun[] = [];
  const spans = [...inlineRuns(runs)];
  const primary = spans.some(
    ({ run }) => run.kind === "symbol" && run.primary === true,
  );
  if (runs.length > 0 && !primary && hasSymbolValue(appearance.symbol)) {
    const style: FooterStyle =
      spans.find(({ run }) => run.style !== undefined)?.run.style ??
      styles.detail;
    const value = symbolText(appearance.symbol, "");
    const colour = symbolColour(appearance.symbol) ?? style.color;
    const shared = {
      colour,
      bold: style.bold === true,
      href: undefined,
      role: undefined,
    };
    painted.push(
      { ...shared, kind: "symbol", value },
      { ...shared, kind: "text", value: " " },
    );
  }
  for (const entry of spans) {
    painted.push(resolveSpan(entry, appearance, primary));
  }
  return materialise(painted, theme);
}
export function truncateText(
  value: PaintedText,
  width: number,
  theme?: PaintTheme,
): PaintedText {
  const columns = value.runs.reduce(
    (sum, run) => sum + visibleWidth(run.value),
    0,
  );
  if (columns <= width) {
    return value;
  }
  if (width <= 0) {
    return materialise([], theme);
  }
  const kept: PaintedRun[] = [];
  let remaining = Math.max(0, width - 1);
  let last: PaintedRun | undefined;
  for (const run of value.runs) {
    last = run;
    if (remaining === 0) {
      break;
    }
    const full = visibleWidth(run.value);
    const fragment =
      full <= remaining
        ? run.value
        : sliceByColumn(run.value, 0, remaining, true);
    if (fragment !== "") {
      kept.push({ ...run, value: fragment });
    }
    if (full > remaining) {
      break;
    }
    remaining -= full;
  }
  kept.push({
    value: "…",
    kind: "text",
    role: undefined,
    colour: last?.colour,
    bold: last?.bold === true,
    href: last?.href,
  });
  return materialise(kept, theme);
}

export class SegmentPainter {
  constructor(private readonly theme?: PaintTheme) {}

  text(
    style: FooterStyle,
    value: string,
    options: RunOptions = {},
  ): SegmentText {
    const runs: TextRun[] =
      value === "" ? [] : [{ ...options, kind: "text", style, value }];
    return { value: this.base(style, value), runs };
  }

  symbol(
    style: FooterStyle,
    value: string,
    tail = "",
    options: RunOptions = {},
  ): SegmentText {
    const runs: TextRun[] = [{ ...options, kind: "symbol", style, value }];
    if (tail !== "") {
      runs.push({ ...options, kind: "text", style, value: tail });
    }
    return {
      value:
        options.source === undefined
          ? this.base(style, value + tail)
          : paintText(runs, {}, this.theme).value,
      runs,
    };
  }

  concat(...parts: readonly (SegmentText | string)[]): SegmentText {
    return {
      value: parts
        .map((part) => (typeof part === "string" ? part : part.value))
        .join(""),
      runs: parts.flatMap((part): readonly TextRun[] => {
        if (typeof part !== "string") {
          return part.runs;
        }
        if (part === "") {
          return [];
        }
        return [{ kind: "text", value: part }];
      }),
    };
  }

  join(parts: readonly SegmentText[], separator = " "): SegmentText {
    const visible = parts.filter((part) => part.value !== "");
    return this.concat(
      ...visible.flatMap((part, index) =>
        index === 0 ? [part] : [separator, part],
      ),
    );
  }

  link(part: SegmentText, url: string | undefined): SegmentText {
    const value = link(part.value, url);
    if (url === undefined || value === part.value) {
      return part;
    }
    return { value, runs: [{ kind: "link", href: url, runs: part.runs }] };
  }

  private base(style: FooterStyle, value: string): string {
    if (!this.theme) {
      return value;
    }
    const result = this.theme.fg(style.color, value);
    return style.bold === true ? this.theme.bold(result) : result;
  }
}
