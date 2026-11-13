import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Input, getKeybindings, truncateToWidth } from "@earendil-works/pi-tui";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { ComposerEditor } from "#footer/ui/composer.ts";
import { DockHost } from "#footer/ui/dock/dock-host.ts";
import {
  fitFooterRow,
  layoutFooter,
  type RenderFrame,
} from "#footer/rendering/render.ts";
import { resolveSettings } from "#footer/configuration/settings.ts";
import { createSnapshot } from "#footer/domain/state.ts";

export default function dockFixture(pi: ExtensionAPI): void {
  const state = createSnapshot(Date.now(), "/native-dock");
  state.model = "dock-model";
  state.reasoning = true;
  state.thinking = "high";
  state.context = { percent: 20, capacity: 100_000, tokens: 20_000 };
  state.cooperativeStatuses = new Map([
    [
      "planning",
      {
        version: 1,
        source: "planning",
        sessionId: "fixture",
        active: true,
      },
    ],
  ]);
  let settings = resolveSettings({});
  let editor: ComposerEditor | undefined;
  let height = 3;
  let previewLines: readonly string[] = [];
  let mounts = 0;
  let modelTurns = 0;
  pi.on("agent_start", () => {
    modelTurns++;
  });
  let dock: DockHost | undefined;
  let frame: RenderFrame | undefined;

  pi.on("session_start", (_event, ctx) => {
    ctx.ui.setFooter(() => ({ render: () => [], invalidate() {} }));
  });
  pi.on("resources_discover", (_event, ctx) => {
    ctx.ui.setEditorComponent((tui, theme, keys) => {
      mounts++;
      editor = new ComposerEditor(tui, theme, keys, {
        top(width) {
          frame = layoutFooter(
            state,
            { top: width, bottom: 0 },
            { settings, theme: ctx.ui.theme },
          );
          return frame.top.text;
        },
        bottom(width) {
          return frame
            ? fitFooterRow(frame, settings, {
                placement: "bottom",
                width,
                theme: ctx.ui.theme,
              }).row.text
            : "";
        },
        completed(geometry) {
          previewLines = geometry.lines;
          if (geometry.height !== height) {
            height = geometry.height;
            tui.requestRender();
          }
        },
      });
      return editor;
    });
  });
  pi.registerCommand("dock-preview", {
    handler: async (args, ctx) => {
      const original = editor;
      if (!original) {
        throw new Error("Expected the mounted composer");
      }
      const draft =
        args.trim() === "long"
          ? Array.from(
              { length: 30 },
              (_, index) => `draft line ${index}`,
            ).join("\n")
          : "draft 界é\nsecond line\nthird line";
      ctx.ui.setEditorText(draft);
      const cursor = original.getCursor();
      const mounted = ctx.ui.getEditorComponent();
      const count = mounts;
      const active = settings;
      let draftSettings = settings;
      let previewVisible = true;
      let redraw: (() => void) | undefined;
      let visibilityChanges = 0;
      const keys = getKeybindings();
      const host = new DockHost(
        ctx.ui,
        () => ctx.ui.getEditorComponent() === mounted,
        {
          previewLines: () => previewLines,
          theme: () => ctx.ui.theme,
          keys,
          setPreviewVisible(visible) {
            previewVisible = visible;
            settings = visible ? draftSettings : active;
            visibilityChanges++;
            writeFileSync(
              join(ctx.cwd, "dock-preview-state.json"),
              JSON.stringify({
                visible,
                preset: settings.preset,
                changes: visibilityChanges,
              }),
            );
            redraw?.();
          },
        },
      );
      dock = host;
      await host.open((tui, _dockTheme, close) => {
        redraw = () => tui.requestRender();
        const input = new Input();
        input.setValue("≡");
        let page = "root";
        let focused = false;
        let controls: readonly string[] = [];
        const popup = async () => {
          try {
            await ctx.ui.custom(
              (_tui, _theme, _keys, done) => ({
                render: () => [
                  "Nested focus check",
                  "Esc returns; x closes the whole editor",
                ],
                invalidate() {},
                handleInput(data) {
                  if (data === "x") {
                    close();
                    done(undefined);
                    return;
                  }
                  if (keys.matches(data, "tui.select.cancel")) {
                    done(undefined);
                  }
                },
              }),
              { overlay: true },
            );
          } catch (error) {
            ctx.ui.notify(String(error), "error");
          }
        };
        return {
          capturesViewportInput: true,
          get focused() {
            return focused;
          },
          set focused(value: boolean) {
            focused = value;
            input.focused = value && page === "symbol";
          },
          render(width) {
            const capacity = Math.max(
              2,
              Math.min(8, tui.terminal.rows - height - 3),
            );
            const lines =
              page === "symbol"
                ? [
                    "Footer dock gate · Symbol",
                    ...input.render(width),
                    "Enter chooses · Esc back",
                  ]
                : [
                    "Footer dock gate · Profile",
                    "c Compact · r Rich · i Symbol · o Overlay",
                    "Esc cancels",
                  ];
            controls = lines
              .slice(0, 2)
              .map((line) => truncateToWidth(line, width));
            return lines
              .slice(0, capacity)
              .map((line) => truncateToWidth(line, width));
          },
          visibleControls() {
            return controls;
          },
          invalidate() {
            input.invalidate();
          },
          handleInput(data) {
            if (page === "symbol") {
              if (
                keys.matches(data, "tui.select.confirm") ||
                keys.matches(data, "tui.select.cancel")
              ) {
                page = "root";
                input.focused = false;
                return;
              }
              input.handleInput(data);
              const symbol = input.getValue();
              if (symbol.length > 0 && symbol.length <= 8) {
                draftSettings = resolveSettings({
                  preset: draftSettings.preset,
                  symbols: { planning: symbol },
                });
                if (previewVisible) {
                  settings = draftSettings;
                }
              }
              return;
            }
            if (keys.matches(data, "tui.select.cancel")) {
              close();
              return;
            }
            if (data === "c" || data === "r") {
              draftSettings = resolveSettings({
                preset: data === "c" ? "compact" : "rich",
              });
              if (previewVisible) {
                settings = draftSettings;
              }
            }
            if (data === "i") {
              page = "symbol";
              input.focused = focused;
            }
            if (data === "w") {
              ctx.ui.setWidget(
                "late-dock-widget",
                Array.from(
                  { length: 10 },
                  (_, index) => `Other widget ${index}`,
                ),
              );
            }
            if (data === "o") {
              void popup();
            }
          },
          dispose() {
            settings = active;
          },
        };
      });
      writeFileSync(
        join(ctx.cwd, "dock-result.json"),
        JSON.stringify({
          factory: ctx.ui.getEditorComponent() === mounted,
          instance: editor === original,
          mounts: mounts - count,
          modelTurns,
          draft: original.getText(),
          cursor: original.getCursor(),
          expectedCursor: cursor,
          focus: original.focused,
        }),
      );
      if (dock === host) {
        dock = undefined;
      }
    },
  });
  pi.on("session_shutdown", () => dock?.close());
}
