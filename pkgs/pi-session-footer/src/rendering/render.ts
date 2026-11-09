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
  level: number;
  truncated?: PaintedText;
}
interface RowOptions {
  placement: "top" | "bottom";
  width: number;
  theme?: PaintTheme;
}
interface FittedFooterRow {
  row: FittedRow;
  decisions: FitDecision[];
  placements: PlacementEvidence[];
}
class RowFitter {
  private readonly regions: readonly [Region, Region];
  private readonly width: number;
  private readonly items: Occurrence[];
  private readonly custom: boolean;
  private compressed = false;
  private gauge: { owner: Occurrence; content: PaintedText } | undefined;

  constructor(
    private readonly observation: FooterObservation,
    private readonly settings: ResolvedSettings,
    private readonly options: RowOptions,
  ) {
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
        return observation.readings[id].parts.map((part) => ({
          id,
          region,
          part,
          appearance,
          level: 0,
          variants: part.tokens.map((runs) =>
            paintText(runs, appearance, options.theme),
          ),
        }));
      }),
    );
  }

  private current(item: Occurrence): PaintedText {
    return (
      item.truncated ??
      item.variants[item.level] ?? { value: "", runs: [], symbols: [] }
    );
  }

  private children(id: SegmentId, region: Region): Occurrence[] {
    return this.items.filter(
      (item) => item.id === id && item.region === region,
    );
  }

  private childSeparator(region: Region): string {
    if (this.custom) {
      return " ";
    }
    return createPaint(this.options.theme)(
      styles.separator,
      region === this.regions[0] ? "  " : "  ",
    );
  }

  private group(id: SegmentId, region: Region): string {
    return this.children(id, region)
      .map((item) => this.current(item).value)
      .filter((value) => value !== "")
      .join(this.childSeparator(region));
  }

  private side(region: Region): string {
    const paint = createPaint(this.options.theme);
    if (!this.custom) {
      const values = this.items
        .filter((item) => item.region === region)
        .map((item) => this.current(item).value)
        .filter((value) => value !== "");
      return region === this.regions[0]
        ? values.join(paint(styles.separator, "  "))
        : values
            .map((value) => paint(styles.separator, " ") + value)
            .join(" ");
    }
    let separator =
      this.settings.separators.widgets ??
      (region === this.regions[0] ? "  " : "  ");
    if (this.compressed) {
      separator = " ";
    }
    return this.settings.regions[region]
      .map((placement) => this.group(widgetId(placement), region))
      .filter((value) => value !== "")
      .join(paint(styles.separator, separator));
  }

  private render(): FittedRow {
    this.gauge = undefined;
    const left = this.side(this.regions[0]);
    const right = this.side(this.regions[1]);
    const both = left !== "" && right !== "";
    const marker =
      this.custom && both && !this.compressed
        ? createPaint(this.options.theme)(
            styles.separator,
            this.settings.separators.regions ?? " ",
          )
        : "";
    let minimum = 0;
    if (both) {
      minimum = this.compressed ? 1 : 2;
    }
    const gapWidth = Math.max(
      minimum,
      this.width -
        visibleWidth(left) -
        visibleWidth(right) -
        visibleWidth(marker),
    );
    const context = this.items.find(
      (item) => item.id === "context" && this.current(item).value !== "",
    );
    let gap = right === "" ? "" : " ".repeat(gapWidth);
    if (context && this.observation.contextPercent !== null && gapWidth >= 5) {
      const track = gapWidth - 2;
      const percent = this.observation.contextPercent;
      const used = Math.round(
        (track * Math.max(0, Math.min(100, percent))) / 100,
      );
      const p = new SegmentPainter();
      const usedRuns = p.symbol(contextStyle(percent), "━", "", {
        role: "gauge-used",
        attention: percent >= 75,
      }).runs;
      const freeRuns = p.symbol(styles.separator, "─", "", {
        role: "gauge-free",
      }).runs;
      const runs = [
        ...Array.from({ length: used }, () => usedRuns).flat(),
        ...Array.from({ length: track - used }, () => freeRuns).flat(),
      ];
      const content = paintText(
        runs,
        { roles: context.appearance.roles },
        this.options.theme,
      );
      this.gauge = { owner: context, content };
      gap = " " + content.value + " ";
    }
    return {
      left,
      right,
      text: left + gap + marker + right,
      width: this.width,
    };
  }

  private fitItems(): void {
    while (visibleWidth(this.render().text) > this.width) {
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
      const last = this.items.findLast(
        (item) => this.current(item).value !== "",
      );
      if (!last) {
        break;
      }
      const current = this.current(last);
      const overflow = visibleWidth(this.render().text) - this.width;
      const truncated = truncateText(
        current,
        Math.max(0, visibleWidth(current.value) - overflow),
        this.options.theme,
      );
      if (visibleWidth(truncated.value) >= visibleWidth(current.value)) {
        break;
      }
      last.truncated = truncated;
      if (truncated.value === "") {
        last.level = last.variants.length - 1;
      }
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
export function layoutFooter(
  state: FooterSnapshot,
  widths: { top: number; bottom: number },
  presentation: FooterPresentation,
): RenderFrame {
  const { settings, theme, home, mode = "composer" } = presentation;
  const observation: FooterObservation = {
    at: state.now,
    readings: readSegments(state, { theme, home, symbols: settings.symbols }),
    contextPercent: state.context.percent,
  };
  const top = fitFooterRow(observation, settings, {
    placement: "top",
    width: widths.top,
    theme,
  });
  const bottom = fitFooterRow(observation, settings, {
    placement: "bottom",
    width: widths.bottom,
    theme,
  });
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
