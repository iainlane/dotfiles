import { resolveSettings } from "#footer/configuration/settings.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";
import { FooterLayout } from "#footer/rendering/layout-cache.ts";
import {
  observeFooter,
  type FooterPresentation,
  type RenderFrame,
} from "#footer/rendering/render.ts";

export function layoutFooter(
  state: FooterSnapshot,
  widths: { top: number; bottom: number },
  presentation: FooterPresentation,
): RenderFrame {
  return new FooterLayout({
    observation: observeFooter(state, presentation),
    presentation,
  }).frame(widths);
}

export function renderFooter(state: FooterSnapshot, width: number): string[] {
  const frame = layoutFooter(
    state,
    { top: width, bottom: width },
    { settings: resolveSettings({}), mode: "fallback" },
  );
  return [frame.top.text, frame.bottom.text];
}
