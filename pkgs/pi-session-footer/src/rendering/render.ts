import { visibleWidth } from "@earendil-works/pi-tui";
import { contextStyle, styles } from "./palette.ts";
import {
  createPaint,
  readSegments,
  type Readings,
  type SegmentPart,
} from "./segments.ts";
import {
  paintText,
  SegmentPainter,
  truncateText,
  type PaintedText,
  type PaintTheme,
} from "./segment-text.ts";
import type { WidgetAppearance } from "#footer/configuration/appearance.ts";
import {
  REGIONS,
  SEGMENT_IDS,
  resolveSettings,
  widgetId,
  type Region,
  type ResolvedSettings,
  type SegmentId,
} from "#footer/configuration/settings.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";

export interface FitDecision {
  id: SegmentId;
  region: Region;
  child: string;
  decision: "full" | "shortened" | "omitted" | "truncated" | "suppressed";
  display: string;
  reason: string;
}
export interface PartEvidence extends PaintedText {
  key: string;
  variant: number;
  priority: number;
  detailPriority: number | undefined;
}
export interface PlacementEvidence {
  id: SegmentId;
  region: Region;
  display: string;
  budget: number;
  appearance: WidgetAppearance;
  parts: PartEvidence[];
  gauge: PaintedText | undefined;
}
export interface FittedRow {
  left: string;
  right: string;
  text: string;
  width: number;
}
export interface RenderFrame {
  at: number;
  mode: "composer" | "fallback" | "preview";
  top: FittedRow;
  bottom: FittedRow;
  readings: Readings;
  decisions: FitDecision[];
  placements: PlacementEvidence[];
  disabled: SegmentId[];
  contextPercent: number | null;
}
export interface FooterObservation {
  at: number;
  readings: Readings;
  contextPercent: number | null;
}
export interface FooterPresentation {
  settings: ResolvedSettings;
  theme?: PaintTheme;
  home?: string;
  mode?: RenderFrame["mode"];
}
interface Occurrence {
  id: SegmentId;
  region: Region;
  part: SegmentPart;
  appearance: WidgetAppearance;
  variants: PaintedText[];
  widths: number[];
  level: number;
  truncated?: PaintedText;
}
interface RowOptions {
  placement: "top" | "bottom";
  width: number;
  theme?: PaintTheme;
}
export interface FittedFooterRow {
  row: FittedRow;
  decisions: FitDecision[];
  placements: PlacementEvidence[];
}
interface Separator {
  value: string;
  width: number;
}
interface SideWidth {
  width: number;
  empty: boolean;
}
const EMPTY_TEXT: PaintedText = { value: "", runs: [], symbols: [] };
function groupKey(id: SegmentId, region: Region): string {
  return `${region}/${id}`;
}
function gaugeUsed(track: number, percent: number): number {
  return Math.round((track * Math.max(0, Math.min(100, percent))) / 100);
}
class RowFitter {
  private readonly observation: FooterObservation;
  private readonly settings: ResolvedSettings;
  private readonly options: RowOptions;
  private readonly regions: readonly [Region, Region];
  private readonly width: number;
  private readonly items: Occurrence[];
  private readonly groups = new Map<string, Occurrence[]>();
  private readonly custom: boolean;
  private readonly childSeparators: readonly [string, string];
  private readonly sideSeparators: readonly [Separator, Separator];
  private readonly compressedSeparator: Separator;
  private readonly rightPrefix: Separator;
  private readonly marker: Separator;
  private readonly gaugeUnits = new Map<
    Occurrence,
    { used: number; free: number }
  >();
  private compressed = false;
  private gauge: { owner: Occurrence; content: PaintedText } | undefined;

  constructor(
    observation: FooterObservation,
    settings: ResolvedSettings,
    options: RowOptions,
  ) {
    this.observation = observation;
    this.settings = settings;
    this.options = options;
    this.regions =
      options.placement === "top"
        ? ["top-left", "top-right"]
        : ["bottom-left", "bottom-right"];
    this.width = Math.max(0, Math.floor(options.width));
    this.custom =
      settings.separators.widgets !== undefined ||
      settings.separators.regions !== undefined;
    this.items = this.regions.flatMap((region) =>
      settings.regions[region].flatMap((placement) => {
        const id = widgetId(placement);
        const appearance = typeof placement === "string" ? {} : placement;
        return observation.readings[id].parts.map((part) => {
          const variants = part.tokens.map((runs) =>
            paintText(runs, appearance, options.theme),
          );
          return {
            id,
            region,
            part,
            appearance,
            level: 0,
            variants,
            widths: variants.map((variant) => visibleWidth(variant.value)),
          };
        });
      }),
    );
    for (const item of this.items) {
      const key = groupKey(item.id, item.region);
      const group = this.groups.get(key);
      if (group === undefined) {
        this.groups.set(key, [item]);
      } else {
        group.push(item);
      }
    }

    const paint = createPaint(options.theme);
    const separator = (value: string): Separator => {
      const painted = paint(styles.separator, value);
      return { value: painted, width: visibleWidth(painted) };
    };
    const defaults = ["  ", "  "] as const;
    const widgets = settings.separators.widgets;
    this.childSeparators = this.custom
      ? [" ", " "]
      : [separator(defaults[0]).value, separator(defaults[1]).value];
    this.sideSeparators = [
      separator(widgets ?? defaults[0]),
      separator(widgets ?? defaults[1]),
    ];
    this.compressedSeparator = separator(" ");
    this.rightPrefix = separator(" ");
    this.marker = separator(settings.separators.regions ?? " ");
  }

  private current(item: Occurrence): PaintedText {
    return item.truncated ?? item.variants[item.level] ?? EMPTY_TEXT;
  }

  private currentWidth(item: Occurrence): number {
    if (item.truncated !== undefined) {
      return visibleWidth(item.truncated.value);
    }
    return item.widths[item.level] ?? 0;
  }

  private children(id: SegmentId, region: Region): Occurrence[] {
    return this.groups.get(groupKey(id, region)) ?? [];
  }

  private group(id: SegmentId, region: Region): string {
    return this.children(id, region)
      .map((item) => this.current(item).value)
      .filter((value) => value !== "")
      .join(
        region === this.regions[0]
          ? this.childSeparators[0]
          : this.childSeparators[1],
      );
  }

  private widgetSeparator(side: 0 | 1): Separator {
    return this.compressed
      ? this.compressedSeparator
      : this.sideSeparators[side];
  }

  private side(side: 0 | 1): string {
    const region = this.regions[side];
    if (!this.custom) {
      const values = this.items
        .filter((item) => item.region === region)
        .map((item) => this.current(item).value)
        .filter((value) => value !== "");
      return side === 0
        ? values.join(this.sideSeparators[0].value)
        : values.map((value) => this.rightPrefix.value + value).join(" ");
    }
    return this.settings.regions[region]
      .map((placement) => this.group(widgetId(placement), region))
      .filter((value) => value !== "")
      .join(this.widgetSeparator(side).value);
  }

  private sideWidth(side: 0 | 1): SideWidth {
    const region = this.regions[side];
    if (!this.custom) {
      let count = 0;
      let width = 0;
      for (const item of this.items) {
        if (item.region === region && this.current(item).value !== "") {
          count++;
          width += this.currentWidth(item);
        }
      }
      if (count === 0) {
        return { width: 0, empty: true };
      }
      const separators =
        side === 0
          ? (count - 1) * this.sideSeparators[0].width
          : count * this.rightPrefix.width + count - 1;
      return { width: width + separators, empty: false };
    }

    let groups = 0;
    let width = 0;
    for (const placement of this.settings.regions[region]) {
      let count = 0;
      for (const item of this.children(widgetId(placement), region)) {
        if (this.current(item).value !== "") {
          count++;
          width += this.currentWidth(item);
        }
      }
      if (count > 0) {
        groups++;
        width += count - 1;
      }
    }
    if (groups === 0) {
      return { width: 0, empty: true };
    }
    return {
      width: width + (groups - 1) * this.widgetSeparator(side).width,
      empty: false,
    };
  }

  private gaugeOwner(): Occurrence | undefined {
    if (this.observation.contextPercent === null) {
      return undefined;
    }
    return this.items.find(
      (item) => item.id === "context" && this.current(item).value !== "",
    );
  }

  private gaugeRuns(percent: number) {
    const p = new SegmentPainter();
    return {
      used: p.symbol(contextStyle(percent), "━", "", {
        role: "gauge-used",
        attention: percent >= 75,
      }).runs,
      free: p.symbol(styles.separator, "─", "", {
        role: "gauge-free",
      }).runs,
    };
  }

  private gaugeWidth(owner: Occurrence, percent: number, gap: number): number {
    let units = this.gaugeUnits.get(owner);
    if (units === undefined) {
      const runs = this.gaugeRuns(percent);
      const roles = { roles: owner.appearance.roles };
      units = {
        used: visibleWidth(paintText(runs.used, roles).value),
        free: visibleWidth(paintText(runs.free, roles).value),
      };
      this.gaugeUnits.set(owner, units);
    }
    const track = gap - 2;
    const used = gaugeUsed(track, percent);
    return 2 + used * units.used + (track - used) * units.free;
  }

  private gapWidth(left: SideWidth, right: SideWidth, marker: number): number {
    let minimum = 0;
    if (!left.empty && !right.empty) {
      minimum = this.compressed ? 1 : 2;
    }
    return Math.max(minimum, this.width - left.width - right.width - marker);
  }

  private markerShown(left: SideWidth, right: SideWidth): boolean {
    return this.custom && !left.empty && !right.empty && !this.compressed;
  }

  private measure(): number {
    const left = this.sideWidth(0);
    const right = this.sideWidth(1);
    const marker = this.markerShown(left, right) ? this.marker.width : 0;
    const gap = this.gapWidth(left, right, marker);
    const owner = this.gaugeOwner();
    const percent = this.observation.contextPercent;
    let middle = right.empty ? 0 : gap;
    if (owner && percent !== null && gap >= 5) {
      middle = this.gaugeWidth(owner, percent, gap);
    }
    return left.width + middle + marker + right.width;
  }

  private render(): FittedRow {
    this.gauge = undefined;
    const leftWidth = this.sideWidth(0);
    const rightWidth = this.sideWidth(1);
    const left = this.side(0);
    const right = this.side(1);
    const marker = this.markerShown(leftWidth, rightWidth)
      ? this.marker
      : { value: "", width: 0 };
    const gapWidth = this.gapWidth(leftWidth, rightWidth, marker.width);
    const owner = this.gaugeOwner();
    const percent = this.observation.contextPercent;
    let gap = right === "" ? "" : " ".repeat(gapWidth);
    if (owner && percent !== null && gapWidth >= 5) {
      const track = gapWidth - 2;
      const used = gaugeUsed(track, percent);
      const runs = this.gaugeRuns(percent);
      const content = paintText(
        [
          ...Array.from({ length: used }, () => runs.used).flat(),
          ...Array.from({ length: track - used }, () => runs.free).flat(),
        ],
        { roles: owner.appearance.roles },
        this.options.theme,
      );
      this.gauge = { owner, content };
      gap = " " + content.value + " ";
    }
    return {
      left,
      right,
      text: left + gap + marker.value + right,
      width: this.width,
    };
  }

  private fitItems(): void {
    while (this.measure() > this.width) {
      if (this.custom && !this.compressed) {
        this.compressed = true;
        continue;
      }
      const remaining = this.items.filter(
        (item) => this.current(item).value !== "",
      ).length;
      const candidate = this.items
        .map((item, index) => {
          const next = item.variants[item.level + 1]?.value;
          return {
            item,
            index,
            next,
            priority:
              next !== undefined && next !== ""
                ? (item.part.detailPriority ?? item.part.priority)
                : item.part.priority,
          };
        })
        .filter(
          ({ next }) => next !== undefined && (next !== "" || remaining > 1),
        )
        .toSorted((a, b) => a.priority - b.priority || b.index - a.index)[0];
      if (candidate) {
        candidate.item.level++;
        continue;
      }
      const last = this.items.find((item) => this.current(item).value !== "");
      if (!last) {
        break;
      }
      const prefix = !this.custom && last.region === this.regions[1] ? 2 : 0;
      last.truncated = truncateText(
        this.current(last),
        Math.max(0, this.width - prefix),
        this.options.theme,
      );
      break;
    }
  }

  private decisions(): FitDecision[] {
    return this.regions.flatMap((region) =>
      this.settings.regions[region].flatMap((placement): FitDecision[] => {
        const id = widgetId(placement);
        const reading = this.observation.readings[id];
        if (reading.state !== "available") {
          return [
            {
              id,
              region,
              child: id,
              decision: "suppressed",
              display: "",
              reason: `${reading.state}: ${reading.reason}`,
            },
          ];
        }
        return this.children(id, region).map((item) => {
          const display = this.current(item).value;
          let decision: FitDecision["decision"] = "full";
          let reason = "";
          if (display === "") {
            decision = "omitted";
            reason = "Insufficient width";
          } else if (item.truncated !== undefined) {
            decision = "truncated";
            reason = "Fitted to actual region budget";
          } else if (item.level > 0) {
            decision = "shortened";
            reason = "Fitted to actual region budget";
          }
          return {
            id,
            region,
            child: item.part.key,
            display,
            decision,
            reason,
          };
        });
      }),
    );
  }

  fit(): FittedFooterRow {
    this.fitItems();
    const row = this.render();
    const placements = this.regions.flatMap((region) =>
      this.settings.regions[region].map((placement): PlacementEvidence => {
        const id = widgetId(placement);
        return {
          id,
          region,
          display: this.group(id, region),
          budget: this.width,
          gauge:
            this.gauge?.owner.id === id && this.gauge.owner.region === region
              ? this.gauge.content
              : undefined,
          appearance: typeof placement === "string" ? {} : placement,
          parts: this.children(id, region).map((item) => {
            const current = this.current(item);
            return {
              value: current.value,
              runs: current.runs,
              symbols: current.symbols,
              key: item.part.key,
              variant: item.level,
              priority: item.part.priority,
              detailPriority: item.part.detailPriority,
            };
          }),
        };
      }),
    );
    return { row, decisions: this.decisions(), placements };
  }
}
export function fitFooterRow(
  observation: FooterObservation,
  settings: ResolvedSettings,
  options: RowOptions,
): FittedFooterRow {
  return new RowFitter(observation, settings, options).fit();
}
export function observeFooter(
  state: FooterSnapshot,
  presentation: FooterPresentation,
): FooterObservation {
  const { settings, theme, home } = presentation;
  return {
    at: state.now,
    readings: readSegments(state, { theme, home, symbols: settings.symbols }),
    contextPercent: state.context.percent,
  };
}
export function composeFooterFrame(
  observation: FooterObservation,
  presentation: FooterPresentation,
  rows: { top: FittedFooterRow; bottom: FittedFooterRow },
): RenderFrame {
  const { settings, mode = "composer" } = presentation;
  const { top, bottom } = rows;
  return {
    ...observation,
    mode,
    top: top.row,
    bottom: bottom.row,
    decisions: [...top.decisions, ...bottom.decisions],
    placements: [...top.placements, ...bottom.placements],
    disabled: SEGMENT_IDS.filter(
      (id) =>
        !REGIONS.some((region) =>
          settings.regions[region].some(
            (placement) => widgetId(placement) === id,
          ),
        ),
    ),
  };
}
export function layoutFooter(
  state: FooterSnapshot,
  widths: { top: number; bottom: number },
  presentation: FooterPresentation,
): RenderFrame {
  const { settings, theme } = presentation;
  const observation = observeFooter(state, presentation);
  return composeFooterFrame(observation, presentation, {
    top: fitFooterRow(observation, settings, {
      placement: "top",
      width: widths.top,
      theme,
    }),
    bottom: fitFooterRow(observation, settings, {
      placement: "bottom",
      width: widths.bottom,
      theme,
    }),
  });
}
export function completeFooterFrame(
  frame: RenderFrame,
  bottom: FittedFooterRow,
): RenderFrame {
  return {
    ...frame,
    bottom: bottom.row,
    decisions: [
      ...frame.decisions.filter((decision) =>
        decision.region.startsWith("top-"),
      ),
      ...bottom.decisions,
    ],
    placements: [
      ...frame.placements.filter((placement) =>
        placement.region.startsWith("top-"),
      ),
      ...bottom.placements,
    ],
  };
}
export function renderFooter(
  state: FooterSnapshot,
  width: number,
  theme?: PaintTheme,
  home?: string,
): string[] {
  if (width <= 0) {
    return [];
  }
  const frame = layoutFooter(
    state,
    { top: width, bottom: width },
    { settings: resolveSettings({}), theme, home, mode: "fallback" },
  );
  return [frame.top.text, frame.bottom.text];
}
