import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { contextStyle, styles } from "./palette.ts";
import {
  createPaint,
  readSegments,
  type Readings,
  type SegmentPart,
} from "./segments.ts";
import {
  REGIONS,
  SEGMENT_IDS,
  resolveSettings,
  type Region,
  type ResolvedSettings,
  type SegmentId,
} from "./settings.ts";
import type { FooterSnapshot } from "./state.ts";

export interface FitDecision {
  id: SegmentId;
  region: Region;
  child: string;
  decision: "full" | "shortened" | "omitted" | "truncated" | "suppressed";
  display: string;
  reason: string;
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
  theme?: Pick<Theme, "fg" | "bold">;
  home?: string;
  mode?: RenderFrame["mode"];
}
interface Occurrence {
  id: SegmentId;
  region: Region;
  part: SegmentPart;
  level: number;
  truncated?: string;
}
export function fitFooterRow(
  observation: FooterObservation,
  settings: ResolvedSettings,
  options: {
    placement: "top" | "bottom";
    width: number;
    theme?: FooterPresentation["theme"];
  },
): { row: FittedRow; decisions: FitDecision[] } {
  const { readings, contextPercent } = observation;
  const regions: readonly [Region, Region] =
    options.placement === "top"
      ? ["top-left", "top-right"]
      : ["bottom-left", "bottom-right"];
  const paint = createPaint(options.theme);
  const width = Math.max(0, Math.floor(options.width));
  const items: Occurrence[] = regions.flatMap((region) =>
    settings.regions[region].flatMap((id) =>
      readings[id].parts.map((part) => ({ id, region, part, level: 0 })),
    ),
  );
  const value = (item: Occurrence) =>
    item.truncated ?? item.part.variants[item.level] ?? "";
  const join = () => {
    const left = items
      .flatMap((item) => {
        const display = value(item);
        return item.region === regions[0] && display ? [display] : [];
      })
      .join(paint(styles.separator, "  "));
    const right = items
      .flatMap((item) => {
        const display = value(item);
        return item.region === regions[1] && display
          ? [paint(styles.separator, " ") + display]
          : [];
      })
      .join(" ");
    const gapWidth = Math.max(
      left && right ? 2 : 0,
      width - visibleWidth(left) - visibleWidth(right),
    );
    const gauge =
      contextPercent !== null &&
      items.some((item) => item.id === "context" && value(item) !== "") &&
      gapWidth >= 5;
    let gap = right ? " ".repeat(gapWidth) : "";
    if (gauge) {
      const track = gapWidth - 2;
      const used = Math.round(
        (track * Math.max(0, Math.min(100, contextPercent ?? 0))) / 100,
      );
      gap =
        " " +
        paint(contextStyle(contextPercent), "━".repeat(used)) +
        paint(styles.separator, "─".repeat(track - used)) +
        " ";
    }
    return { left, right, text: left + gap + right, width };
  };
  while (visibleWidth(join().text) > width) {
    const remaining = items.filter((item) => value(item)).length;
    const candidate = items
      .map((item, index) => {
        const next = item.part.variants[item.level + 1];
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
    const last = items.find((item) => value(item));
    if (!last) {
      break;
    }
    const right = last.region === regions[1];
    // The final visible occurrence owns the remaining budget, including its separator.
    last.truncated = truncateToWidth(
      value(last),
      Math.max(0, width - (right ? 2 : 0)),
      "…",
    );
    if (!last.truncated) {
      last.level = last.part.variants.length - 1;
    }
    break;
  }
  const row = join();
  const decisions: FitDecision[] = regions.flatMap((region) =>
    settings.regions[region].flatMap((id): FitDecision[] => {
      const reading = readings[id];
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
      return items
        .filter((item) => item.id === id && item.region === region)
        .map((item): FitDecision => {
          const display = value(item);
          let decision: FitDecision["decision"] = "full";
          let reason = "";
          if (!display) {
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
  return { row, decisions };
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
    disabled: SEGMENT_IDS.filter(
      (id) => !REGIONS.some((region) => settings.regions[region].includes(id)),
    ),
  };
}
export function renderFooter(
  state: FooterSnapshot,
  width: number,
  theme?: Pick<Theme, "fg" | "bold">,
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
