import {
  composeFooterFrame,
  fitFooterRow,
  type FittedFooterRow,
  type FooterObservation,
  type FooterPresentation,
  type RenderFrame,
} from "./render.ts";

export interface ObservedFooter {
  observation: FooterObservation;
  presentation: FooterPresentation;
}

export interface FooterLayoutSource {
  revision(): number;
  statuses(): ReadonlyMap<string, string>;
  observe(statuses: ReadonlyMap<string, string>): ObservedFooter;
}

export class FooterLayout {
  readonly observation: FooterObservation;
  readonly presentation: FooterPresentation;
  private readonly rows = new Map<string, FittedFooterRow>();

  constructor({ observation, presentation }: ObservedFooter) {
    this.observation = observation;
    this.presentation = presentation;
  }

  row(placement: "top" | "bottom", width: number): FittedFooterRow {
    const key = `${placement}:${width}`;
    const cached = this.rows.get(key);
    if (cached !== undefined) {
      return cached;
    }

    const row = fitFooterRow(this.observation, this.presentation.settings, {
      placement,
      width,
      theme: this.presentation.theme,
    });
    this.rows.set(key, row);
    return row;
  }

  frame(widths: { top: number; bottom: number }): RenderFrame {
    return composeFooterFrame(this.observation, this.presentation, {
      top: this.row("top", widths.top),
      bottom: this.row("bottom", widths.bottom),
    });
  }
}

function sameStatuses(
  previous: ReadonlyMap<string, string>,
  next: ReadonlyMap<string, string>,
): boolean {
  if (previous.size !== next.size) {
    return false;
  }

  const entries = previous.entries();
  for (const [key, value] of next) {
    const entry = entries.next();
    if (
      entry.done === true ||
      entry.value[0] !== key ||
      entry.value[1] !== value
    ) {
      return false;
    }
  }
  return true;
}

export class FooterLayoutCache {
  private readonly source: FooterLayoutSource;
  private cached:
    | {
        revision: number;
        statuses: ReadonlyMap<string, string>;
        layout: FooterLayout;
      }
    | undefined;

  constructor(source: FooterLayoutSource) {
    this.source = source;
  }

  current(): FooterLayout {
    const revision = this.source.revision();
    const statuses = this.source.statuses();
    // Pi updates its extension status map without notifying the footer.
    if (
      this.cached?.revision === revision &&
      sameStatuses(this.cached.statuses, statuses)
    ) {
      return this.cached.layout;
    }

    const observed = new Map(statuses);
    const layout = new FooterLayout(this.source.observe(observed));
    this.cached = { revision, statuses: observed, layout };
    return layout;
  }

  invalidate(): void {
    this.cached = undefined;
  }
}
