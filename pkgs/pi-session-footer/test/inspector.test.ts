import { expect, it, vi } from "vitest";
import type { KeybindingsConfig } from "@earendil-works/pi-tui";
import { KeybindingsManager } from "../node_modules/@earendil-works/pi-coding-agent/dist/core/keybindings.js";
import {
  Inspector,
  detailsLines,
  INSPECTOR_SECTIONS,
  type InspectorContext,
} from "../src/inspector.ts";
import { createSnapshot } from "../src/state.ts";
import { loadSettings, resolveSettings } from "../src/settings.ts";
import { layoutFooter } from "../src/render.ts";
import { DetailViewport } from "../src/viewport.ts";
import { configurationLines, explainSegment } from "../src/explanation.ts";

type View = ReturnType<Parameters<InspectorContext["ui"]["custom"]>[0]>;
function harness(bindings: KeybindingsConfig = {}) {
  const state = createSnapshot(1000, "/work");
  state.context.percent = 0;
  const frame = layoutFooter(
    state,
    { top: 120, bottom: 90 },
    { settings: resolveSettings({}) },
  );
  const settings = loadSettings(
    (): undefined => {},
    "/agent/session-footer.json",
  );
  const enterUsage = vi.fn<() => void>();
  const preview = vi.fn<() => typeof frame>(() => frame);
  const views: {
    component: View;
    close: ReturnType<typeof vi.fn<() => void>>;
    settle(): void;
  }[] = [];
  const terminal = { rows: 12 };
  const keys = new KeybindingsManager({
    "tui.select.down": "j",
    "tui.select.up": "k",
    ...bindings,
  });
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
              { terminal, requestRender: () => {} },
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
  let recorded: typeof frame | undefined = frame;
  const inspector = new Inspector(() => state, {
    frame: () => recorded,
    settings: () => settings,
    preview,
    enterUsage,
  });
  return {
    inspector,
    context,
    views,
    terminal,
    state,
    frame,
    settings,
    enterUsage,
    preview,
    refreshFrame: (bottom = 90) => {
      recorded = layoutFooter(state, { top: 120, bottom }, { settings });
      return recorded;
    },
    hideFrame: () => {
      recorded = undefined;
    },
  };
}
it.each(["idle", "width"] as const)(
  "keeps expanded field identity when the occurrence becomes hidden by %s",
  async (cause) => {
    const h = harness();
    h.terminal.rows = 40;
    h.state.activity.tool = "read";
    const frame = h.refreshFrame();
    const opened = h.inspector.open(h.context, {
      view: "explain",
      segment: undefined,
    });
    const view = h.views[0]?.component;

    if (!view) {
      throw new Error("Expected inspector");
    }

    view.render(140);
    const index = frame.decisions
      .filter(({ display }) => display)
      .findIndex(({ id }) => id === "activity");

    expect(index).toBeGreaterThanOrEqual(0);

    for (let step = 0; step < index; step++) {
      view.handleInput("j");
    }

    view.handleInput("\r");
    expect(view.render(140).map((line) => line.trimEnd())).toContain(
      "Activity",
    );

    if (cause === "idle") {
      h.state.activity.tool = undefined;
    }

    h.refreshFrame(cause === "width" ? 0 : 90);
    const lines = view.render(140).map((line) => line.trimEnd());
    const reason = "idle: No active attention state";

    expect({
      title: lines.includes("Activity"),
      reading: lines.find((line) => line.startsWith("Reading:")),
      placement: lines.find((line) =>
        line.startsWith("bottom-left · activity:"),
      ),
    }).toStrictEqual({
      title: true,
      reading:
        cause === "idle"
          ? "Reading: idle; No active attention state"
          : "Reading: available",
      placement:
        cause === "idle"
          ? `bottom-left · activity: suppressed (${reason})`
          : "bottom-left · activity: omitted (Insufficient width)",
    });

    view.handleInput("\u001B");
    view.handleInput("\u001B");
    await opened;
  },
);
it("keeps the current close handle after an older overlay is disposed", async () => {
  const h = harness();
  const first = h.inspector.open(h.context, { view: "config" });
  const second = h.inspector.open(h.context, { view: "help" });
  h.views[0]?.component.dispose();
  h.inspector.dispose();
  expect(h.views.map((v) => v.close.mock.calls.length)).toStrictEqual([1, 1]);
  for (const view of h.views) {
    view.settle();
  }
  await Promise.all([first, second]);
});
it("shows the actual completed budget and hidden reasons, not an overlay-width fit", async () => {
  const h = harness();
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: "context",
  });
  const view = h.views[0]?.component;
  if (!view) {
    throw new Error("Expected inspector");
  }
  const wide = view.render(100).join("\n");
  h.terminal.rows = 30;
  const narrow = view.render(40).join("\n");
  expect(wide).toContain("top 120, bottom 90");
  expect(narrow).toContain("top 120");
  expect(explainSegment(h.frame, "thinking").join(" ")).toContain(
    "Native model does not report reasoning capability",
  );
  view.handleInput("\u001B");
  view.handleInput("h");
  expect(view.render(100).join("\n")).toContain("hidden on");
  view.handleInput("\u001B");
  await opened;
});
it("navigates all retained domain views and refreshes cost only on entering Usage", async () => {
  const h = harness();
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  const view = h.views[0]?.component;
  if (!view) {
    throw new Error("Expected inspector");
  }
  const titles: string[] = [];
  for (const section of INSPECTOR_SECTIONS) {
    titles.push(view.render(100)[0] ?? "");
    if (section !== "help") {
      view.handleInput("\t");
    }
  }
  expect({
    sections: titles.map((title) => title.split(" · ")[0]),
    refreshes: h.enterUsage.mock.calls.length,
    previews: h.preview.mock.calls.length,
  }).toStrictEqual({
    sections: INSPECTOR_SECTIONS.map((section) => `Footer: ${section}`),
    refreshes: 1,
    previews: 0,
  });
  view.handleInput("\u001B");
  await opened;
});
it("browses presets without mutating active settings or frame and preserves selection on resize", async () => {
  const h = harness();
  const before = JSON.stringify([h.settings, h.frame]);
  const opened = h.inspector.open(h.context, { view: "config" });
  const view = h.views[0]?.component;
  if (!view) {
    throw new Error("Expected inspector");
  }
  view.render(100);
  view.handleInput("j");
  view.handleInput("\r");
  expect(view.render(100).join("\n")).toContain("passive preview only");
  h.terminal.rows = 20;
  expect(view.render(55).join("\n")).toContain("Preset rich");
  expect(JSON.stringify([h.settings, h.frame])).toBe(before);
  expect(h.enterUsage.mock.calls).toStrictEqual([]);
  view.handleInput("\u001B");
  view.handleInput("\u001B");
  await opened;
});
it("offers described section selection and responsive list/details", async () => {
  const h = harness();
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  const view = h.views[0]?.component;
  if (!view) {
    throw new Error("Expected inspector");
  }
  expect(view.render(140).join("\n")).toContain("Symbols:");
  expect(view.render(50).join("\n")).not.toContain("Symbols:");
  view.handleInput("s");
  expect(view.render(140).join("\n")).toContain(
    "Windows, resets, freshness and errors",
  );
  view.handleInput("j");
  view.handleInput("\r");
  expect(view.render(140)[0]).toContain("Footer: config");
  view.handleInput("\u001B");
  await opened;
});
it.each(["s", "h", "tab"] as const)(
  "gives configured navigation precedence over %s and hides shadowed hints",
  async (key) => {
    const h = harness({ "tui.select.down": key });
    const section = key === "h" ? "explain" : "config";
    const opened = h.inspector.open(h.context, {
      view: section,
      segment: undefined,
    });
    const view = h.views[0]?.component;
    if (!view) {
      throw new Error("Expected inspector");
    }
    const first = view.render(100).join("\n");
    view.handleInput(key === "tab" ? "\t" : key);
    const moved = view.render(100).join("\n");
    const hint = key === "s" ? "sections" : key === "h" ? "hidden" : "next";
    expect({
      section: moved.includes(`Footer: ${section}`),
      position: moved.includes(key === "h" ? "2/2" : "2/5"),
      hiddenHint: new RegExp(`(?:^| · )${key} ${hint}`, "m").test(first),
    }).toStrictEqual({ section: true, position: true, hiddenHint: false });
    view.handleInput("\u001B");
    await opened;
  },
);
it.each(["explain", "config", "sections"] as const)(
  "pages %s by its actual visible list capacity",
  async (target) => {
    const h = harness();
    h.terminal.rows = target === "explain" ? 12 : 8;
    const opened = h.inspector.open(h.context, {
      view: target === "config" ? "config" : "explain",
      segment: undefined,
    });
    const view = h.views[0]?.component;
    if (!view) {
      throw new Error("Expected inspector");
    }
    if (target === "explain") {
      view.handleInput("h");
    }
    if (target === "sections") {
      view.handleInput("s");
    }
    const position = () => {
      const line = view.render(80).find((entry) => /^\d+\/\d+/.test(entry));
      return Number(line?.split("/")[0]);
    };
    const before = position();
    view.handleInput("\u001B[6~");
    expect(position() - before).toBe(target === "explain" ? 4 : 2);
    view.handleInput("\u001B");
    if (target === "sections") {
      view.handleInput("\u001B");
    }
    await opened;
  },
);
it.each([1, 2, 3, 4, 5])(
  "bounds inspector chrome to %i terminal rows",
  async (rows) => {
    const h = harness();
    h.terminal.rows = rows;
    const opened = h.inspector.open(h.context, { view: "help" });
    const view = h.views[0]?.component;
    if (!view) {
      throw new Error("Expected inspector");
    }
    expect(view.render(50).length).toBeLessThanOrEqual(rows);
    view.handleInput("\u001B");
    await opened;
  },
);
it("reports an empty explanation list without a phantom selection", async () => {
  const h = harness();
  h.hideFrame();
  const opened = h.inspector.open(h.context, {
    view: "explain",
    segment: undefined,
  });
  const view = h.views[0]?.component;
  if (!view) {
    throw new Error("Expected inspector");
  }
  expect(view.render(100).join("\n")).toContain("0/0");
  view.handleInput("\u001B");
  await opened;
});
it.each(["quota", "statuses"] as const)(
  "uses typed %s placement identity rather than opaque child text",
  async (id) => {
    const h = harness();
    h.frame.decisions = [
      {
        id,
        region: "bottom-left",
        child: "integration:model:summary",
        decision: "full",
        display: "actual message",
        reason: "",
      },
    ];
    const opened = h.inspector.open(h.context, {
      view: "explain",
      segment: undefined,
    });
    const view = h.views[0]?.component;
    if (!view) {
      throw new Error("Expected inspector");
    }
    expect(view.render(140).join("\n")).toContain(
      id === "quota" ? "Symbols: ◴" : "Symbols: ◇",
    );
    view.handleInput("\u001B");
    await opened;
  },
);
it("clips native ScrollView after layout and pages by viewport height", () => {
  const viewport = new DetailViewport();
  const lines = Array.from({ length: 20 }, (_, i) => `Line ${i}`);
  const render = (height: number) =>
    viewport.render(lines, 30, height, () => {}).map((line) => line.trimEnd());
  const initial = render(4);
  viewport.move(viewport.height);
  const paged = render(4);
  const resized = render(2);
  viewport.move(100);
  const end = render(2);
  expect({ initial, paged, resized, end }).toStrictEqual({
    initial: ["Line 0", "Line 1", "Line 2", "Line 3"],
    paged: ["Line 4", "Line 5", "Line 6", "Line 7"],
    resized: ["Line 4", "Line 5"],
    end: ["Line 18", "Line 19"],
  });
});
it("reports repeated inherited placements and all live detail scopes", () => {
  const settings = loadSettings(
    () => '{"bottom-left":["context"]}',
    "/agent/session-footer.json",
  );
  expect(configurationLines(settings)).toContain(
    "Repeated context: top-right, bottom-left (each placement is intentional and fitted separately)",
  );
  const state = createSnapshot(1000, "/work");
  state.statuses = new Map([["planning", "Plan · 1 researching"]]);
  expect(detailsLines(state, "workflow")).toContain(
    "Plan: Plan · 1 researching",
  );
  expect(detailsLines(state, "usage").join(" ")).toContain(
    "not a verified invoice",
  );
  expect(detailsLines(state, "diagnostics").join(" ")).toContain(
    "does not establish clean files",
  );
  expect(detailsLines(state, "quota").join(" ")).toContain("not remaining");
  expect(detailsLines(state, "git").join(" ")).toContain(
    "not successful checks",
  );
});
