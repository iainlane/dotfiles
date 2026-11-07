import type {
  ExtensionUIContext,
  KeybindingsManager,
} from "@earendil-works/pi-coding-agent";
import type { Component, TUI } from "@earendil-works/pi-tui";
import type { FooterRoute } from "./commands.ts";
import { createInspectorView } from "./inspector-view.ts";
import type { RenderFrame } from "./render.ts";
import type { LoadedSettings, Preset } from "./settings.ts";
import type { FooterSnapshot } from "./state.ts";
export { SECTIONS, detailsLines, type Section } from "./inspector-details.ts";

export interface InspectorContext {
  mode: string;
  ui: Pick<ExtensionUIContext, "select" | "notify"> & {
    custom: (
      factory: (
        tui: Pick<TUI, "requestRender"> & {
          terminal: Pick<TUI["terminal"], "rows">;
        },
        theme: Pick<ExtensionUIContext["theme"], "fg">,
        keys: Pick<KeybindingsManager, "matches" | "getKeys">,
        done: () => void,
      ) => Component & { dispose(): void; handleInput(data: string): void },
      options?: Parameters<ExtensionUIContext["custom"]>[1],
    ) => Promise<void>;
  };
}
export { INSPECTOR_SECTIONS, type InspectorSection } from "./inspector-view.ts";
export interface InspectorSources {
  frame(): RenderFrame | undefined;
  settings(): LoadedSettings;
  preview(preset: Preset): RenderFrame | undefined;
  enterUsage(): void;
}
export class Inspector {
  private close: (() => void) | undefined;
  constructor(
    private readonly snapshot: () => FooterSnapshot | undefined,
    private readonly sources: InspectorSources,
  ) {}
  dispose(): void {
    const close = this.close;
    this.close = undefined;
    close?.();
  }
  async open(ctx: InspectorContext, route: FooterRoute): Promise<void> {
    if (ctx.mode !== "tui") {
      ctx.ui.notify("The footer inspector is available in TUI mode.", "info");
      return;
    }
    this.dispose();
    if (!this.snapshot()) {
      return;
    }
    await ctx.ui.custom(
      (tui, theme, keys, done) => {
        const close = () => {
          done();
        };
        this.close = close;
        const view = createInspectorView(
          { tui, theme, keys },
          route,
          { snapshot: this.snapshot, sources: this.sources },
          close,
        );
        return {
          ...view,
          dispose: () => {
            view.dispose();
            if (this.close === close) {
              this.close = undefined;
            }
          },
        };
      },
      {
        overlay: true,
        overlayOptions: { anchor: "top-center", width: "100%" },
      },
    );
  }
}
