import type {
  ExtensionUIContext,
  KeybindingsManager,
} from "@earendil-works/pi-coding-agent";
import type { Component, TUI } from "@earendil-works/pi-tui";
import type { FooterRoute } from "#footer/application/commands.ts";
import { createInspectorView } from "./inspector-view.ts";
import type { RenderFrame } from "#footer/rendering/render.ts";
import type { FooterSnapshot } from "#footer/domain/state.ts";
export { SECTIONS, detailsLines, type Section } from "./inspector-details.ts";
export {
  INSPECTOR_SECTIONS,
  type InspectorSection,
} from "./inspection-page.ts";

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
export interface InspectorSources {
  frame(): RenderFrame | undefined;
  enterUsage(): void;
}
export class Inspector {
  private readonly snapshot: () => FooterSnapshot | undefined;
  private readonly sources: InspectorSources;
  private close: (() => void) | undefined;
  private generation = 0;
  constructor(
    snapshot: () => FooterSnapshot | undefined,
    sources: InspectorSources,
  ) {
    this.snapshot = snapshot;
    this.sources = sources;
  }
  dispose(): void {
    this.generation++;
    const close = this.close;
    this.close = undefined;
    close?.();
  }
  async open(
    ctx: InspectorContext,
    route: FooterRoute,
  ): Promise<"customise" | undefined> {
    if (ctx.mode !== "tui") {
      ctx.ui.notify("The footer inspector is available in TUI mode.", "info");
      return undefined;
    }
    this.dispose();
    const generation = this.generation;
    if (!this.snapshot()) {
      return undefined;
    }
    if (route.view === "config") {
      return "customise";
    }
    let destination: "customise" | undefined;
    let ownedClose: (() => void) | undefined;
    await ctx.ui.custom(
      (tui, theme, keys, done) => {
        let settled = false;
        let view: ReturnType<typeof createInspectorView> | undefined;
        const close = (next?: "customise") => {
          if (settled) {
            return;
          }
          settled = true;
          destination = next;
          view?.dispose();
          done();
        };
        ownedClose = () => close();
        if (generation === this.generation) {
          this.close = ownedClose;
        }
        view = createInspectorView(
          { tui, theme, keys },
          route,
          { snapshot: this.snapshot, sources: this.sources },
          close,
        );
        if (generation !== this.generation) {
          close();
        }
        return {
          ...view,
          dispose: () => {
            view?.dispose();
            if (this.close === ownedClose) {
              this.close = undefined;
            }
            close();
          },
        };
      },
      {
        overlay: true,
        overlayOptions: { anchor: "top-center", width: "100%" },
      },
    );
    if (this.close === ownedClose) {
      this.close = undefined;
    }
    return generation === this.generation ? destination : undefined;
  }
}
