import { expect, it } from "vitest";
import type { KeybindingsConfig } from "@earendil-works/pi-tui";
import { KeybindingsManager } from "#test/support/keybindings.ts";
import {
  Inspector,
  INSPECTOR_SECTIONS,
  type InspectorContext,
} from "#footer/ui/inspection/inspector.ts";
import { createSnapshot } from "#footer/domain/state.ts";
import { layoutFooter } from "#test/support/layout.ts";
import { gitState } from "#test/support/git.ts";
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
  state.git = gitState("main", 1000, { untracked: 1 });
  state.context = { percent: 12.7, tokens: 16624, capacity: 131072 };
  state.usage.latestHit = 25;
  state.cachePrompt = { cached: 4096, total: 16384 };
  const settings = resolveSettings(document);
  let frame: ReturnType<typeof layoutFooter> | undefined = layoutFooter(
    state,
    { top: 150, bottom: 120 },
    { settings },
  );
  const delegation: { current: unknown } = { current: undefined };
  const terminal = { rows: 24 };
  const keys = new KeybindingsManager({
    "tui.select.down": "j",
    "tui.select.up": "k",
    ...bindings,
  });
  type View = ReturnType<Parameters<InspectorContext["ui"]["custom"]>[0]>;
  const views: {
    component: View;
    settle(): void;
  }[] = [];
  const context: InspectorContext = {
    mode: "tui",
    ui: {
      select: async (): Promise<undefined> => {},
      notify() {},
      custom: (factory) =>
        new Promise<void>((resolve) => {
          views.push({
            component: factory(
              { terminal, requestRender() {} },
              { fg: (_role, value) => value },
              keys,
              resolve,
            ),
            settle: resolve,
          });
        }),
    },
  };
  const inspector = new Inspector(() => state, {
    frame: () => frame,
    enterUsage: () => {
      state.delegationCost = delegation.current;
    },
  });
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
    delegation,
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
  h.state.git = gitState("changed", 2000);
  h.refresh();
  const frozen = [
    "Footer › Explain",
    "›  main ?1  Git branch and file changes · Top left",
    "  G main ?1  Git branch and file changes · Bottom right",
    "  Sections…",
    "enter open · escape/ctrl+c close · s sections",
    "1/3 · k/j move · pageUp/pageDown page",
  ];
  expect({ before, after: h.render() }).toStrictEqual({
    before: frozen,
    after: frozen,
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
  const page = other.render();
  other.view().handleInput("\u001B");
  const cachePage = [
    "Footer › Explain › Cache hit rate",
    "4,096 of 16,384 prompt tokens cached",
    "›  25.0%  Bottom right",
    "  Rendering details",
    "  Open Usage",
    "  Sections…",
    "enter open · escape/ctrl+c back · s sections",
    "1/4 · k/j move · pageUp/pageDown page",
  ];
  expect({ selected, page, back: other.render() }).toStrictEqual({
    selected: cachePage,
    page: cachePage,
    back: [
      "Footer › Explain",
      "   footer-demo/scripted-demo  Model",
      "  ◒ high  Reasoning effort",
      "   main ?1  Git branch and file changes",
      "  ◫ 12.7%/131.1k  Context used",
      "›  25.0%  Cache hit rate",
      "  Sections…",
      "enter open · escape/ctrl+c close · s sections",
      "5/6 · k/j move · pageUp/pageDown page",
    ],
  });
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
  expect(h.render(24)).toStrictEqual([
    "Footer › Explain › Mode\u001B[0m…\u001B[0m",
    "",
    "footer-demo/abcdefghijkl",
    "abcdefghijklabcdefghijkl",
    "abcdefghijklabcdefghijkl",
    "abcdefghijklabcdefghijkl",
    "abcdefghijklabcdefghijkl",
    "abcdefghijkl",
    "Top left",
    "escape/ctrl+c back · s \u001B[0m…\u001B[0m",
    "1–8/8 · k/j move · page\u001B[0m…\u001B[0m",
  ]);
  h.inspector.dispose();
  await opened;
});
const expectedWidget: Record<string, unknown> = {
  missing: {
    page: [
      "Footer › Explain › Model",
      "The footer has not drawn yet.",
      "› Rendering details",
      "  Open Overview",
      "  Sections…",
      "enter open · escape/ctrl+c back · s sections",
      "1/3 · k/j move · pageUp/pageDown page",
    ],
    legend: [
      "Footer › Explain",
      "The footer has not drawn yet.",
      "› Sections…",
      "enter open · escape/ctrl+c close · s sections",
      "1/1 · k/j move · pageUp/pageDown page",
    ],
  },
  disabled: {
    page: [
      "Footer › Explain › Delegation",
      "Not enabled in this layout.",
      "› Rendering details",
      "  Open Workflow",
      "  Sections…",
      "enter open · escape/ctrl+c back · s sections",
      "1/3 · k/j move · pageUp/pageDown page",
    ],
    legend: [
      "Footer › Explain",
      "›  footer-demo/scripted-demo  Model",
      "  ◒ high  Reasoning effort",
      "   main ?1  Git branch and file changes",
      "  ◫ 12.7%/131.1k  Context used",
      "   25.0%  Cache hit rate",
      "  Sections…",
      "enter open · escape/ctrl+c close · s sections",
      "1/6 · k/j move · pageUp/pageDown page",
    ],
  },
  width: {
    page: [
      "Footer › Explain › Model",
      "Omitted because the footer was too narrow.",
      "› Rendering details",
      "  Open Overview",
      "  Sections…",
      "enter open · escape/ctrl+c back · s sections",
      "1/3 · k/j move · pageUp/pageDown page",
    ],
    legend: [
      "Footer › Explain",
      "No fields are visible in this layout.",
      "› Sections…",
      "enter open · escape/ctrl+c close · s sections",
      "1/1 · k/j move · pageUp/pageDown page",
    ],
  },
};
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
    const page = h.render();
    h.view().handleInput("\u001B");
    expect({ page, legend: h.render() }).toStrictEqual(expectedWidget[cause]);
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
  h.view().handleInput("\r");
  h.render(28);
  h.view().handleInput("\u001B");
  const back = h.render(28);
  h.terminal.rows = 12;
  const taller = h.render(42);
  const scrolled = [
    "Footer › Explain",
    "  Git branch and file",
    "  changes",
    "  ◫ 12.7%/131.1k",
    "  Context used",
    "›  25.0%  Cache hit rate",
    "enter open · escape/ctrl+c \u001B[0m…\u001B[0m",
    "5/6 · k/j move · pageUp/pag\u001B[0m…\u001B[0m",
  ];
  expect({ before, back, taller }).toStrictEqual({
    before: scrolled,
    back: scrolled,
    taller: [
      "Footer › Explain",
      "   footer-demo/scripted-demo  Model",
      "  ◒ high  Reasoning effort",
      "   main ?1  Git branch and file changes",
      "  ◫ 12.7%/131.1k  Context used",
      "›  25.0%  Cache hit rate",
      "  Sections…",
      "enter open · escape/ctrl+c close · s sect\u001B[0m…\u001B[0m",
      "5/6 · k/j move · pageUp/pageDown page",
    ],
  });
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
  h.delegation.current = { total: 1 };
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  const titles: string[] = [];
  for (let index = 0; index < INSPECTOR_SECTIONS.length; index++) {
    titles.push(h.render()[0] ?? "");
    h.view().handleInput("\t");
  }
  const entered = h.state.delegationCost;
  h.delegation.current = { total: 2 };
  h.view().handleInput("\t");
  expect({
    titles,
    entered,
    elsewhere: h.state.delegationCost,
  }).toStrictEqual({
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
    entered: { total: 1 },
    elsewhere: { total: 1 },
  });
  h.choose("Sections");
  h.choose("Customise");
  expect(await opened).toBe("customise");
});
const expectedBinding: Record<string, unknown> = {
  s: [
    "Footer › Explain",
    "   footer-demo/scripted-demo  Model",
    "› ◒ high  Reasoning effort",
    "   main ?1  Git branch and file changes",
    "  ◫ 12.7%/131.1k  Context used",
    "   25.0%  Cache hit rate",
    "  Sections…",
    "enter open · escape/ctrl+c close · alt+s sections",
    "2/6 · k/s move · pageUp/pageDown page",
  ],
  h: [
    "Footer › Explain",
    "   footer-demo/scripted-demo  Model",
    "› ◒ high  Reasoning effort",
    "   main ?1  Git branch and file changes",
    "  ◫ 12.7%/131.1k  Context used",
    "   25.0%  Cache hit rate",
    "  Sections…",
    "enter open · escape/ctrl+c close · s sections",
    "2/6 · k/h move · pageUp/pageDown page",
  ],
  tab: [
    "Footer › Explain",
    "   footer-demo/scripted-demo  Model",
    "› ◒ high  Reasoning effort",
    "   main ?1  Git branch and file changes",
    "  ◫ 12.7%/131.1k  Context used",
    "   25.0%  Cache hit rate",
    "  Sections…",
    "enter open · escape/ctrl+c close · s sections",
    "2/6 · k/tab move · pageUp/pageDown page",
  ],
};
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
    expect(h.render()).toStrictEqual(expectedBinding[binding]);
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
  expect({
    results: await Promise.all([first, second]),
    current: h.render(),
  }).toStrictEqual({ results: [undefined, undefined], current: [] });
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
