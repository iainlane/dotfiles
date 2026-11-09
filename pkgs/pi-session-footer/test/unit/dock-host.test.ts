import type { ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { Container, Input, Text, type Component } from "@earendil-works/pi-tui";
import { expect, it, vi } from "vitest";
import { DockHost } from "#footer/ui/dock/dock-host.ts";
import type { DockVisibility } from "#footer/ui/dock/dock-guard.ts";
import { editorFixture } from "#test/support/editor.ts";
import { runtimeFixture } from "#test/support/runtime.ts";

async function harness(visibility?: DockVisibility) {
  const { tui } = editorFixture();
  const { context } = await runtimeFixture();
  const theme = context.ui.theme;
  const root = new Container();
  const original = new Input();
  original.setValue("draft 界é");
  root.addChild(original);
  tui.addChild(root);
  tui.setFocus(original);
  const widgetContainer = new Container();
  root.addChild(widgetContainer);
  const widgets = new Map<string, Component & { dispose?(): void }>();
  const ui: Pick<ExtensionUIContext, "setWidget"> = {
    setWidget(key, content) {
      const previous = widgets.get(key);
      if (previous) {
        previous.dispose?.();
        widgets.delete(key);
      }
      if (typeof content === "function") {
        const component = content(tui, theme);
        widgets.set(key, component);
      }
      widgetContainer.clear();
      for (const widget of widgets.values()) {
        widgetContainer.addChild(widget);
      }
    },
  };
  let owned = true;
  const host = new DockHost(ui, () => owned, visibility);
  return {
    tui,
    root,
    original,
    widgets,
    host,
    loseOwnership: () => {
      owned = false;
    },
  };
}

it.each([false, true])(
  "restores the original input and clear-on-shrink=%s",
  async (clearOnShrink) => {
    const h = await harness();
    h.tui.setClearOnShrink(clearOnShrink);
    const field = new Input();
    const opened = h.host.open(() => field);
    expect({
      field: field.focused,
      original: h.original.focused,
      widgets: h.widgets.size,
      clear: h.tui.getClearOnShrink(),
    }).toStrictEqual({ field: true, original: false, widgets: 1, clear: true });
    h.host.close();
    h.host.close();
    await opened;
    expect({
      focus: h.tui.getFocusedComponent() === h.original,
      draft: h.original.getValue(),
      widgets: h.widgets.size,
      clear: h.tui.getClearOnShrink(),
    }).toStrictEqual({
      focus: true,
      draft: "draft 界é",
      widgets: 0,
      clear: clearOnShrink,
    });
  },
);

it("waits for a nested overlay to release its native return target", async () => {
  const h = await harness();
  const opened = h.host.open(() => new Input());
  const popup = new Input();
  const overlay = h.tui.showOverlay(popup);
  await Promise.resolve();
  h.host.close();
  expect({
    popup: h.tui.getFocusedComponent() === popup,
    widgets: h.widgets.size,
  }).toStrictEqual({ popup: true, widgets: 1 });
  overlay.hide();
  await opened;
  expect({
    focus: h.tui.getFocusedComponent() === h.original,
    widgets: h.widgets.size,
  }).toStrictEqual({ focus: true, widgets: 0 });
});

it("closes while an overlay opened from another component has focus", async () => {
  const h = await harness();
  const opened = h.host.open(() => new Input());
  const other = new Input();
  h.root.addChild(other);
  h.tui.setFocus(other);
  const popup = new Input();
  const overlay = h.tui.showOverlay(popup);
  h.host.close();
  await opened;
  const closed = {
    popup: h.tui.getFocusedComponent() === popup,
    widgets: h.widgets.size,
  };
  overlay.hide();
  expect({
    closed,
    focus: h.tui.getFocusedComponent() === other,
  }).toStrictEqual({ closed: { popup: true, widgets: 0 }, focus: true });
});

it("does not restore an editor after another component takes ownership", async () => {
  const h = await harness();
  const opened = h.host.open(() => new Input());
  const replacement = new Input();
  h.root.addChild(replacement);
  h.loseOwnership();
  h.tui.setFocus(replacement);
  h.host.close();
  await opened;
  expect({
    replacement: h.tui.getFocusedComponent() === replacement,
    original: h.original.focused,
    widgets: h.widgets.size,
  }).toStrictEqual({ replacement: true, original: false, widgets: 0 });
});

it.each([
  { preview: [], paused: false },
  { preview: ["footer row"], paused: true },
])(
  "pauses only when a non-empty preview is missing: $preview",
  async ({ preview, paused }) => {
    const setPreviewVisible = vi.fn<DockVisibility["setPreviewVisible"]>();
    const h = await harness({
      previewLines: () => preview,
      setPreviewVisible,
      theme: () => ({ fg: (_colour, text) => text }),
      keys: { matches: () => false, getKeys: () => [] },
    });
    const opened = h.host.open(() => new Text("controls"));
    h.tui.renderNow();
    await Promise.resolve();
    const state = {
      overlay: h.tui.hasOverlay(),
      hidden: setPreviewVisible.mock.calls,
    };
    h.host.close();
    await opened;
    expect(state).toStrictEqual({
      overlay: paused,
      hidden: paused ? [[false]] : [],
    });
  },
);
