import { expect, it, vi } from "vitest";
import type { KeybindingsConfig } from "@earendil-works/pi-tui";
import { KeybindingsManager } from "#test/support/keybindings.ts";
import {
  Inspector,
  INSPECTOR_SECTIONS,
  type InspectorContext,
} from "#footer/ui/inspection/inspector.ts";
import { createSnapshot } from "#footer/domain/state.ts";
import { layoutFooter } from "#footer/rendering/render.ts";
import { parseGitStatus } from "#footer/integrations/git.ts";
import {
  resolveSettings,
  type PresentationDocument,
} from "#footer/configuration/settings.ts";
import { DetailViewport } from "#footer/ui/shared/viewport.ts";

const DEFAULT_LAYOUT = {
  "top-left": ["model", "thinking", "git"],
  "top-right": ["context"],
  "bottom-left": [],
  "bottom-right": ["cache"],
} satisfies PresentationDocument;
function harness(
  bindings: KeybindingsConfig = {},
  document: PresentationDocument = DEFAULT_LAYOUT,
) {
  const state = createSnapshot(1000, "/work");
  state.model = "scripted-demo";
  state.provider = "footer-demo";
  state.reasoning = true;
  state.thinking = "high";
  state.git = parseGitStatus("# branch.head main\n? new.txt", 1000);
  state.context = { percent: 12.7, tokens: 16624, capacity: 131072 };
  state.usage.latestHit = 25;
  state.cachePrompt = { cached: 4096, total: 16384 };
  const settings = resolveSettings(document);
  let frame: ReturnType<typeof layoutFooter> | undefined = layoutFooter(
    state,
    { top: 150, bottom: 120 },
    { settings },
  );
  const recorded = vi.fn<() => typeof frame>(() => frame);
  const enterUsage = vi.fn<() => void>();
  const terminal = { rows: 24 };
  const keys = new KeybindingsManager({
    "tui.select.down": "j",
    "tui.select.up": "k",
    ...bindings,
  });
  type View = ReturnType<Parameters<InspectorContext["ui"]["custom"]>[0]>;
  const views: {
    component: View;
    close: ReturnType<typeof vi.fn<() => void>>;
    settle(): void;
  }[] = [];
  const context: InspectorContext = {
    mode: "tui",
    ui: {
      select: async (): Promise<undefined> => {},
      notify: vi.fn<InspectorContext["ui"]["notify"]>(),
      custom: (factory) =>
        new Promise<void>((resolve) => {
          const close = vi.fn<() => void>(resolve);
          views.push({
            component: factory(
              { terminal, requestRender() {} },
              { fg: (_role, value) => value },
              keys,
              close,
            ),
            close,
            settle: resolve,
          });
        }),
    },
  };
  const inspector = new Inspector(() => state, { frame: recorded, enterUsage });
  const view = () => {
    const component = views.at(-1)?.component;
    if (!component) {
      throw new Error("Expected an inspector");
    }
    return component;
  };
  const render = (width = 120) =>
    view()
      .render(width)
      .map((line) => line.trimEnd());
  const select = (label: string) => {
    for (let attempts = 0; attempts < 100; attempts++) {
      if (
        render().some((line) => line.startsWith("› ") && line.includes(label))
      ) {
        return;
      }
      view().handleInput("j");
    }
    throw new Error(`Cannot select ${label}: ${render().join("\n")}`);
  };
  const choose = (label: string) => {
    select(label);
    view().handleInput("\r");
    render();
  };
  return {
    state,
    recorded,
    enterUsage,
    terminal,
    context,
    inspector,
    views,
    view,
    render,
    select,
    choose,
    refresh: (top = 150, bottom = 120) => {
      frame = layoutFooter(state, { top, bottom }, { settings });
      return frame;
    },
    hideFrame: () => {
      frame = undefined;
    },
  };
}
it("freezes the completed ordinary display and keeps composite widgets together", async () => {
  const h = harness(
    {},
    {
      "top-left": ["git"],
      "top-right": [],
      "bottom-left": [],
      "bottom-right": [{ id: "git", symbol: "G" }],
    },
  );
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  const before = h.render();
  h.state.git = parseGitStatus("# branch.head changed", 2000);
  h.refresh();
  expect({
    title: before[0],
    rows: before.filter((line) => line.includes("Git branch")),
    changed: h.render().some((line) => line.includes("changed")),
    captures: h.recorded.mock.calls.length,
  }).toStrictEqual({
    title: "Footer › Explain",
    rows: [
      "›  main ?1  Git branch and file changes · Top left",
      "  G main ?1  Git branch and file changes · Bottom right",
    ],
    changed: false,
    captures: 1,
  });
  h.inspector.dispose();
  await opened;
});
it("opens the same captured cache page from the legend and a direct command", async () => {
  const h = harness();
  const first = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  h.choose("Cache hit rate");
  const selected = h.render();
  const other = harness();
  const second = other.inspector.open(other.context, {
    view: "explain",
    segment: "cache",
  });
  expect(other.render()).toStrictEqual(selected);
  expect(selected.join("\n")).toContain("4,096 of 16,384 prompt tokens cached");
  other.view().handleInput("\u001B");
  expect(other.render().find((line) => line.startsWith("› "))).toContain(
    "25.0%",
  );
  h.inspector.dispose();
  other.inspector.dispose();
  await Promise.all([first, second]);
});
it("provides the full captured value from a narrow widget page", async () => {
  const h = harness(
    {},
    {
      "top-left": ["model"],
      "top-right": [],
      "bottom-left": [],
      "bottom-right": [],
    },
  );
  h.state.model = "abcdefghijkl".repeat(10);
  const frame = h.refresh(300);
  const value = frame.placements[0]?.display;
  if (value === undefined || value === "") {
    throw new Error("Expected a model placement");
  }
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: "model",
  });
  h.render(24);
  h.view().handleInput("\r");
  const content = h.render(24).slice(1, -2).join("").replaceAll(" ", "");
  expect(content).toContain(value.replaceAll(" ", ""));
  h.inspector.dispose();
  await opened;
});
it.each(["missing", "disabled", "width"] as const)(
  "explains a %s widget without inventing a visible placement",
  async (cause) => {
    const h = harness();
    if (cause === "missing") {
      h.hideFrame();
    }
    if (cause === "width") {
      h.refresh(0, 0);
    }
    const opened = h.inspector.open(h.context, {
      view: "explain",
      segment: cause === "disabled" ? "agents" : "model",
    });
    expect(h.render().join("\n")).toContain(
      cause === "missing"
        ? "The footer has not drawn yet."
        : cause === "disabled"
          ? "Not enabled in this layout."
          : "Omitted because the footer was too narrow.",
    );
    h.view().handleInput("\u001B");
    expect(h.render()[0]).toBe("Footer › Explain");
    expect(h.render().join("\n")).not.toMatch(
      /Not shown|Update capture|hidden on/,
    );
    h.inspector.dispose();
    await opened;
  },
);
it("scrolls to every legend row on a narrow short terminal and preserves back selection", async () => {
  const h = harness();
  h.terminal.rows = 8;
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  h.render(28);
  for (let index = 0; index < 4; index++) {
    h.view().handleInput("j");
    h.render(28);
  }
  const before = h.render(28);
  expect(before.find((line) => line.startsWith("› "))).toContain("25.0%");
  h.view().handleInput("\r");
  h.render(28);
  h.view().handleInput("\u001B");
  expect(h.render(28)).toStrictEqual(before);
  h.terminal.rows = 12;
  expect(h.render(42).find((line) => line.startsWith("› "))).toContain("25.0%");
  h.inspector.dispose();
  await opened;
});
it("preserves detail scroll through a section change", async () => {
  const h = harness();
  h.terminal.rows = 10;
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: "git",
  });
  h.choose("Rendering details");
  h.view().handleInput("\u001B[6~");
  const before = h.render();
  h.view().handleInput("s");
  h.choose("Workflow");
  expect(h.render()[0]).toBe("Footer › Workflow");
  h.view().handleInput("s");
  h.choose("Explain");
  expect(h.render()).toStrictEqual(before);
  h.inspector.dispose();
  await opened;
});
it("makes all sections selectable and refreshes delegation only on entering Usage", async () => {
  const h = harness();
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  const titles: string[] = [];
  for (let index = 0; index < INSPECTOR_SECTIONS.length; index++) {
    titles.push(h.render()[0] ?? "");
    h.view().handleInput("\t");
  }
  expect({ titles, requests: h.enterUsage.mock.calls }).toStrictEqual({
    titles: [
      "Footer › Explain",
      "Footer › Overview",
      "Footer › Quota",
      "Footer › Workflow",
      "Footer › Diagnostics",
      "Footer › Git",
      "Footer › Usage",
      "Footer › Help",
    ],
    requests: [[]],
  });
  h.choose("Sections");
  h.choose("Customise");
  expect(await opened).toBe("customise");
});
it.each(["s", "h", "tab"] as const)(
  "gives configured navigation precedence over %s",
  async (binding) => {
    const h = harness({ "tui.select.down": binding });
    const opened = h.inspector.open(h.context, {
      view: "explain",
      segment: undefined,
    });
    h.render();
    h.view().handleInput(binding === "tab" ? "\t" : binding);
    const display = h.render();
    expect({
      title: display[0],
      selected: display
        .find((line) => line.startsWith("› "))
        ?.includes("Reasoning effort"),
    }).toStrictEqual({ title: "Footer › Explain", selected: true });
    h.inspector.dispose();
    await opened;
  },
);
it.each([1, 2, 3, 4, 5])("bounds inspector chrome to %i rows", async (rows) => {
  const h = harness();
  h.terminal.rows = rows;
  const opened = h.inspector.open(h.context, { view: "help" });
  expect(h.render(40).length).toBeLessThanOrEqual(rows);
  h.inspector.dispose();
  await opened;
});
it("keeps a newer close handle and ignores disposed controls", async () => {
  const h = harness();
  const first = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  const stale = h.view();
  const second = h.inspector.open(h.context, { view: "help" });
  stale.dispose();
  stale.handleInput("s");
  stale.handleInput("\r");
  h.inspector.dispose();
  expect(h.views.map((value) => value.close.mock.calls.length)).toStrictEqual([
    1, 1,
  ]);
  await Promise.all([first, second]);
});
it("clips native detail scrolling and pages by viewport height", () => {
  const viewport = new DetailViewport();
  const values = Array.from({ length: 20 }, (_, index) => `Line ${index}`);
  const render = (height: number) =>
    viewport.render(values, 30, height, () => {}).map((line) => line.trimEnd());
  const first = render(4);
  viewport.move(viewport.height);
  const next = render(4);
  const resized = render(2);
  viewport.move(100);
  expect({ first, next, resized, last: render(2) }).toStrictEqual({
    first: ["Line 0", "Line 1", "Line 2", "Line 3"],
    next: ["Line 4", "Line 5", "Line 6", "Line 7"],
    resized: ["Line 4", "Line 5"],
    last: ["Line 18", "Line 19"],
  });
});
