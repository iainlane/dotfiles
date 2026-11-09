import { expect, it } from "vitest";
import { stripTerminalSequences } from "@earendil-works/pi-tui";
import { SelectionViewport } from "#footer/ui/shared/selection-viewport.ts";

const theme = { fg: (_role: string, value: string) => value };
it("pages by rendered rows when descriptions wrap and preserves selection on resize", () => {
  const view = new SelectionViewport();
  const rows = Array.from({ length: 6 }, (_, index) => ({
    key: String(index),
    value: `value ${index}`,
    description: "Twenty letter label",
  }));
  const render = (height = 6) =>
    view
      .render(rows, 16, height, theme, () => {})
      .map((line) => line.trimEnd());
  const initial = render();
  view.move("pageDown");
  const next = render();
  const narrow = render(3);
  view.move("pageUp");
  const back = render(3);
  expect({
    initial,
    next,
    narrow,
    back,
    selected: view.selected,
  }).toStrictEqual({
    initial: [
      "› value 0",
      "  Twenty letter",
      "  label",
      "  value 1",
      "  Twenty letter",
      "  label",
    ],
    next: [
      "› value 2",
      "  Twenty letter",
      "  label",
      "  value 3",
      "  Twenty letter",
      "  label",
    ],
    narrow: ["› value 2", "  Twenty letter", "  label"],
    back: ["› value 1", "  Twenty letter", "  label"],
    selected: "1",
  });
});
it("shortens long displayed values without changing the original entry", () => {
  const view = new SelectionViewport();
  const rows = [
    { key: "value", value: "captured footer value", description: "Meaning" },
  ];
  expect({
    lines: view
      .render(rows, 12, 4, theme, () => {})
      .map((line) => stripTerminalSequences(line).trimEnd()),
    original: rows,
  }).toStrictEqual({
    lines: ["› captured …", "  Meaning"],
    original: [
      { key: "value", value: "captured footer value", description: "Meaning" },
    ],
  });
});
it("has no phantom selection for an empty list", () => {
  const view = new SelectionViewport();
  const lines = view.render([], 80, 8, theme, () => {});
  view.move("down");
  expect({
    lines,
    selected: view.selected,
    position: view.position,
  }).toStrictEqual({
    lines: [],
    selected: undefined,
    position: { current: 0, total: 0 },
  });
});
